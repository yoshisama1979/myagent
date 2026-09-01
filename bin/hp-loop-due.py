#!/usr/bin/env python3
"""hp-loop-due — 「今日はこのサイトの解析日か」を判定する（LLM なし・状態ファイルなし）。

2026-09-01 社長決定。契機＝実装（開発）は「業務の合間に、1案件おおむね週1回」のペースで
動いており、毎日6サイトを解析しても消化されない。解析の頻度を案件ごとに設定できるようにし、
対象外の日は **claude を起動しない**（＝トークン消費ゼロ）。

判定は **完全に決定的**（状態ファイルを持たない）：

    解析日 ⟺ (その日の通し番号 - ずらし幅) % ペース日数 == 0

- ペース日数＝`data/hp-loop/config.md` の「解析ペース」表が正（社長が数字を書き換えるだけで変わる）。
- ずらし幅＝同表の並び順（0,1,2,…）。同じ日に全サイトが集中しないよう1日ずつずらす。
  ⚠️ **表の途中に行を足す／消すと、それ以降のサイトの走る日がその日からずれる**（Codex🟡 2026-09-01）。
  ずれても「走らなくなる」ことは無く（周期は変わらない）分散も保たれるが、
  「明日この案件が走る」と思っていた予定は変わる。**追加は表の末尾に足すのが安全**で、
  途中に足したときは `--schedule` で新しい予定を確認すること。
- 状態ファイルを持たないのは、状態が壊れたり消えたりしたときに
  「黙って解析が止まる／毎日走る」のどちらにも化けるため（この repo の事故はほぼ全部その形）。

⚠️ **cron は毎日のまま**（`agent-tick.sh daily hp-loop-<site>` を毎日呼ぶ）。
   ペースはこのツールが決める。crontab 側を「3日おき」に書き換えないこと＝
   ①月末31日→1日で2日連続になる ②ペースの正が crontab と config の2箇所に散る。

終了コード：
  0 … 今日は解析日（起動する）
  1 … 今日は対象外（スキップする）
  2 … 判定できない（未登録・表が読めない等）＝呼び出し側は **起動する**（fail-open）。
      設定ミスで解析が黙って止まる方が、余分に1回走るより危険なため。
"""
import argparse
import datetime
import os
import re
import sys

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CONFIG = os.path.join(PROJ, "data", "hp-loop", "config.md")

# 「## 解析ペース」節の中の表だけを読む（登録表など他の表を巻き込まない）
SECTION_RE = re.compile(r"^##\s*解析ペース", re.M)
ROW_RE = re.compile(r"^\|\s*`([a-z0-9-]+)`\s*\|\s*([^|]+?)\s*\|")
# 「3日」「3」「毎日」「1日」を受ける。「—」「手動」は cron 対象外＝ここでは扱わない。
DAYS_RE = re.compile(r"^(\d+)\s*日?$")


def load_cadence(config_path):
    """[(site_key, days), ...] を表の並び順で返す。並び順がそのまま「ずらし幅」になる。"""
    with open(config_path, encoding="utf-8") as fh:
        text = fh.read()
    m = SECTION_RE.search(text)
    if not m:
        raise LookupError("config.md に「## 解析ペース」節が見つかりません")
    # 次の見出しまでを対象にする
    rest = text[m.end():]
    nxt = re.search(r"^##\s", rest, re.M)
    body = rest[: nxt.start()] if nxt else rest

    rows = []
    for line in body.splitlines():
        rm = ROW_RE.match(line.strip())
        if not rm:
            continue
        key, raw = rm.group(1), rm.group(2).strip()
        if raw in ("—", "-", "手動", "なし"):
            continue
        dm = DAYS_RE.match(raw.replace("毎日", "1"))
        if not dm:
            raise ValueError(f"{key} の解析ペース「{raw}」を数字として読めません")
        days = int(dm.group(1))
        if days < 1:
            raise ValueError(f"{key} の解析ペース「{raw}」が 1 未満です")
        if any(k == key for k, _ in rows):
            # 同じ site-key が2行あると、上の行の「ずらし幅」だけが使われ下の行は永久に無視される
            # ＝表を直したつもりが効かない（黙って設定が効かない経路）。読めない設定として弾く。
            raise ValueError(f"site-key `{key}` が解析ペース表に重複しています")
        rows.append((key, days))
    if not rows:
        raise LookupError("「## 解析ペース」表に有効な行がありません")
    return rows


def due_on(day, offset, days):
    """その日にそのサイトが走るか。**判定式はここ1本だけ**。

    以前は同じ式が is_due / next_dates / --schedule の2箇所の計4箇所に散っており、
    片方だけ直すと **`--schedule` の予定表と実際に走る日が食い違う**（＝予告が嘘をつく）。
    このリポジトリの事故は「2箇所に書いた同じ規則が静かにズレる」形が多いので1本に集約する。
    """
    return (day.toordinal() - offset) % days == 0


def is_due(site, rows, on_date):
    """(due:bool, days:int, offset:int) を返す。未登録なら LookupError。"""
    for offset, (key, days) in enumerate(rows):
        if key == site:
            return (due_on(on_date, offset, days), days, offset)
    raise LookupError(f"site-key `{site}` は解析ペース表にありません")


def next_dates(rows, site, on_date, count=7):
    _, days, offset = is_due(site, rows, on_date)
    out, d = [], on_date
    while len(out) < count:
        if due_on(d, offset, days):
            out.append(d)
        d += datetime.timedelta(days=1)
    return out


def main():
    ap = argparse.ArgumentParser(description="今日はこのサイトの解析日か（0=解析日 / 1=対象外 / 2=判定不能）")
    ap.add_argument("site", nargs="?", help="site-key（例 ycom）")
    ap.add_argument("--date", help="判定する日（YYYY-MM-DD・既定=今日）")
    ap.add_argument("--config", default=DEFAULT_CONFIG, help="config.md のパス")
    ap.add_argument("--schedule", action="store_true", help="全サイトの今後14日の予定表を出す")
    ap.add_argument("--quiet", "-q", action="store_true", help="終了コードだけ返す")
    args = ap.parse_args()

    on = datetime.date.today()
    if args.date:
        try:
            on = datetime.date.fromisoformat(args.date)
        except ValueError:
            print(f"日付が読めません: {args.date}", file=sys.stderr)
            return 2

    try:
        rows = load_cadence(args.config)
    except (OSError, LookupError, ValueError) as e:
        print(f"[判定不能] {e}", file=sys.stderr)
        return 2

    if args.schedule:
        print(f"解析ペース（基準日 {on}／cron は毎日・実際に走る日はこの表が決める）")
        print(f"{'site':<12}{'ペース':>7}{'ずらし':>7}   今後14日で走る日")
        for offset, (key, days) in enumerate(rows):
            ds = [d for d in (on + datetime.timedelta(days=i) for i in range(14))
                  if due_on(d, offset, days)]
            print(f"{key:<12}{str(days) + '日':>7}{offset:>7}   " + " ".join(d.strftime("%m/%d") for d in ds))
        # 1日あたり何サイト走るかも出す（分散できているかの目視確認）
        print("\n日別の本数：", end="")
        for i in range(14):
            d = on + datetime.timedelta(days=i)
            n = sum(1 for offset, (_, days) in enumerate(rows) if due_on(d, offset, days))
            print(f" {d.strftime('%m/%d')}={n}", end="")
        print()
        return 0

    if not args.site:
        ap.error("site を指定してください（--schedule のときは不要）")

    try:
        due, days, offset = is_due(args.site, rows, on)
    except LookupError as e:
        print(f"[判定不能] {e}", file=sys.stderr)
        return 2

    if not args.quiet:
        nxt = next_dates(rows, args.site, on, 1)[0] if not due else on
        if due:
            print(f"{args.site}: {on} は解析日です（{days}日ごと・ずらし{offset}）")
        else:
            print(f"{args.site}: {on} は対象外です（{days}日ごと・ずらし{offset}・次は {nxt}）")
    return 0 if due else 1


if __name__ == "__main__":
    sys.exit(main())
