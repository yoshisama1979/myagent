#!/usr/bin/env python3
"""loop-quality — 解析ループの「産出量」を数える（LLM なし・良し悪しの判断はしない）。

契機＝2026-09-11 社長ご指示。hp-loop の起動頻度を本来の「3日に1回」へ戻すにあたり、
**「質が下がっていないか」を私の見立てではなく数字で見張る**ため。

設計（todo-brief.py / pending-scan.py と同じ「判断と計算の分離」）:
- ここは **数える・並べる** だけ。「十分か」「落ちたか」の判断は書かない。
- **台帳の構造に依存しない**＝7サイトの coverage.md は §番号も節名もばらばら
  （ycom の §3＝提案ライフサイクル／yoshida の §3＝効果検証の予約／rally・konjaku は番号なし）。
  節を当てにせず「表の行の1列目が提案IDか」だけで拾う。
- **読めなかった行は黙って捨てず件数を申告する**（triage の教訓）。
- 取引先名・本文は出さない（件数と日付だけ）。

  loop-quality.py report [--days N]   3つの指標を出す（既定14日）
  loop-quality.py snapshot [--days N] 同じ値を data/hp-loop/quality-log.md に1行追記する
"""
import argparse
import collections
import datetime
import glob
import json
import os
import re
import sys

# ROOT はテストで差し替えられるようにする（本番では引数なしで repo ルートを指す）。
ROOT = os.environ.get("LOOP_QUALITY_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SESSION_DIR = os.environ.get(
    "LOOP_QUALITY_SESSIONS",
    os.path.expanduser("~/.claude/projects/-home-vpsuser-projects-myagent"),
)
JST = datetime.timezone(datetime.timedelta(hours=9))
CMD_RE = re.compile(r"<command-name>/?([a-zA-Z0-9_-]+)</command-name>")
ARG_RE = re.compile(r"<command-args>([^<]*)</command-args>")
SKIP_CMDS = {"compact", "clear", "init", "usage", "cost", "model", "resume"}
# 表の1列目に来る提案ID。サイトごとに接頭辞が違う（R-001 / R-Y31 / R-K05 / B-3 / R-014c）。
ROW_ID_RE = re.compile(r"^\|\s*\*{0,2}([RBKT]-[A-Za-z0-9]+)")
DEPLOY_DATE_RE = re.compile(r"^\|\s*(\d{4}-\d{2}-\d{2})")
# 状態の判定は「先に当たったもの勝ち」。台帳の書式が揃っていないため厳密な列指定はできない＝
# あくまで目安で、分類できなかった行は「不明」として件数を出す。
STATES = [
    ("中止・却下", ("❌", "中止", "却下", "撤回")),
    ("クローズ", ("✅", "クローズ", "完了")),
    ("効果検証中", ("効果検証", "検証中", "⏳")),
    ("反映済", ("反映済", "本番反映", "実装済")),
    ("着手", ("着手", "実装中", "引き渡し")),
    ("提案", ("🆕", "提案", "未着手")),
]


def jst_day(ts):
    """ISO 文字列を JST の日付にする。タイムゾーン無しは JST とみなす（todo-brief.py と同じ規約）。"""
    if not ts:
        return None
    try:
        dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=JST)
    return dt.astimezone(JST).date()


def sites():
    return sorted(
        os.path.basename(os.path.dirname(p))
        for p in glob.glob(os.path.join(ROOT, "data/hp-loop/*/coverage.md"))
    )


def indicator1(since):
    """1起動あたりの産出＝掲示板・台帳への書き込み回数と文字数."""
    agg = collections.defaultdict(lambda: {"runs": 0, "writes": 0, "chars": 0})
    unreadable = 0
    for path in sorted(glob.glob(os.path.join(SESSION_DIR, "*.jsonl"))):
        try:
            with open(path, errors="replace") as f:
                head = f.read(16384)
        except OSError:
            unreadable += 1
            continue
        mode = None
        for m in CMD_RE.finditer(head):
            if m.group(1) not in SKIP_CMDS:
                mode = m.group(1)
                break
        if mode != "hp-loop":
            continue
        a = ARG_RE.search(head)
        site = (a.group(1).strip() if a else "") or "ycom"
        writes = chars = 0
        in_range = False
        with open(path, errors="replace") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                day = jst_day(rec.get("timestamp"))
                if day is None or day < since:
                    continue
                msg = rec.get("message") or {}
                if msg.get("usage"):
                    in_range = True
                if msg.get("role") != "assistant":
                    continue
                for b in msg.get("content") or []:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    if b.get("name") not in ("Edit", "Write"):
                        continue
                    inp = b.get("input") or {}
                    fp = str(inp.get("file_path", ""))
                    if "/hp-loop/" in fp or "/hp-analysis/" in fp:
                        writes += 1
                        chars += len(str(inp.get("new_string") or inp.get("content") or ""))
        if in_range:
            s = agg[site]
            s["runs"] += 1
            s["writes"] += writes
            s["chars"] += chars
    return agg, unreadable


def indicator2():
    """実装の受信簿＝deploy-log.md の記録と、まだ処理されていない mailbox の便."""
    out = {}
    for site in sites():
        path = os.path.join(ROOT, "data/hp-loop", site, "deploy-log.md")
        rows, last = 0, None
        if os.path.exists(path):
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = DEPLOY_DATE_RE.match(line)
                    if m:
                        rows += 1
                        last = max(last or m.group(1), m.group(1))
        out[site] = {"exists": os.path.exists(path), "rows": rows, "last": last, "mail": 0, "oldest": None}
    today = datetime.datetime.now(JST).date()
    newdir = os.path.join(ROOT, "data/mailbox/new")
    unreadable = 0
    for p in glob.glob(os.path.join(newdir, "*.json")):
        try:
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            unreadable += 1
            continue
        to = str(d.get("to", ""))
        if not to.startswith("hp-loop-"):
            continue
        site = to[len("hp-loop-"):]
        if site not in out:
            out[site] = {"exists": False, "rows": 0, "last": None, "mail": 0, "oldest": None}
        out[site]["mail"] += 1
        day = jst_day(d.get("ts"))
        if day:
            age = (today - day).days
            out[site]["oldest"] = max(out[site]["oldest"] or age, age)
    return out, unreadable


def indicator3():
    """提案がどこまで進んだか。台帳の節構造に依存せず、表の行の1列目だけを見る."""
    out = {}
    for site in sites():
        counts = collections.Counter()
        unknown = 0
        seen = set()
        for name in ("coverage.md", "coverage-archive.md"):
            path = os.path.join(ROOT, "data/hp-loop", site, name)
            if not os.path.exists(path):
                continue
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = ROW_ID_RE.match(line)
                    if not m:
                        continue
                    rid = m.group(1)
                    if rid in seen:        # 本体と archive の重複は本体を優先（先に読む）
                        continue
                    seen.add(rid)
                    for label, keys in STATES:
                        if any(k in line for k in keys):
                            counts[label] += 1
                            break
                    else:
                        unknown += 1
        out[site] = {"counts": counts, "unknown": unknown, "total": len(seen)}
    return out


def report(days):
    since = datetime.datetime.now(JST).date() - datetime.timedelta(days=days)
    print(f"■ 解析ループの産出量（{since} 以降 {days}日・数えるだけで良し悪しは判断しない）\n")

    agg, un1 = indicator1(since)
    print("【1】1起動あたりの産出（掲示板・台帳への書き込み）")
    print(f"  {'site':<14}{'起動':>5}{'書込':>7}{'書込/回':>9}{'文字/回':>11}")
    tr = tw = tc = 0
    for site, s in sorted(agg.items(), key=lambda x: -x[1]["runs"]):
        print(f"  {site:<14}{s['runs']:>5}{s['writes']:>7}"
              f"{s['writes']/s['runs']:>9.1f}{s['chars']/s['runs']:>11,.0f}")
        tr += s["runs"]; tw += s["writes"]; tc += s["chars"]
    if tr:
        print(f"  {'合計':<14}{tr:>5}{tw:>7}{tw/tr:>9.1f}{tc/tr:>11,.0f}")
    if un1:
        print(f"  ⚠️ 読めなかったセッションログ {un1} 本")

    print("\n【2】実装の受信簿（deploy-log.md）と未処理の実装報告")
    dep, un2 = indicator2()
    print(f"  {'site':<14}{'記録':>5}{'最終記録':>13}{'未処理の便':>11}{'最古(日)':>9}")
    for site in sorted(dep):
        d = dep[site]
        last = d["last"] or ("—" if d["exists"] else "ファイル無し")
        old = f"{d['oldest']}" if d["oldest"] is not None else "—"
        print(f"  {site:<14}{d['rows']:>5}{last:>13}{d['mail']:>11}{old:>9}")
    if un2:
        print(f"  ⚠️ 読めなかったメッセージ {un2} 件")

    print("\n【3】提案（R-NNN 等）がどこまで進んだか")
    print("  ※台帳の書式がサイトごとに違うため行全体から状態語を拾う目安。分類できない行は「不明」に出す。")
    lab = [l for l, _ in STATES]
    print("  " + f"{'site':<14}" + "".join(f"{l:>11}" for l in lab) + f"{'不明':>7}{'計':>6}")
    for site, d in sorted(indicator3().items()):
        row = "".join(f"{d['counts'].get(l, 0):>11}" for l in lab)
        print(f"  {site:<14}{row}{d['unknown']:>7}{d['total']:>6}")
    return 0


def snapshot(days):
    since = datetime.datetime.now(JST).date() - datetime.timedelta(days=days)
    agg, _ = indicator1(since)
    runs = sum(s["runs"] for s in agg.values())
    writes = sum(s["writes"] for s in agg.values())
    chars = sum(s["chars"] for s in agg.values())
    dep, _ = indicator2()
    mail = sum(d["mail"] for d in dep.values())
    ver = sum(d["counts"].get("効果検証中", 0) + d["counts"].get("クローズ", 0)
              for d in indicator3().values())
    path = os.path.join(ROOT, "data/hp-loop/quality-log.md")
    new = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as f:
        if new:
            f.write("# 解析ループの産出量の推移（bin/loop-quality.py snapshot が追記・手で書かない）\n\n"
                    "| 記録日 | 期間(日) | 起動 | 書込/回 | 文字/回 | 未処理の実装報告 | 効果検証以降のR |\n"
                    "|---|---|---|---|---|---|---|\n")
        today = datetime.datetime.now(JST).date()
        f.write(f"| {today} | {days} | {runs} | {writes/runs if runs else 0:.1f} | "
                f"{chars/runs if runs else 0:,.0f} | {mail} | {ver} |\n")
    print(f"追記しました: {os.path.relpath(path, ROOT)}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cmd", nargs="?", default="report", choices=["report", "snapshot"])
    ap.add_argument("--days", type=int, default=14)
    a = ap.parse_args()
    if a.days < 1:
        sys.exit("--days は1以上にしてください")
    return snapshot(a.days) if a.cmd == "snapshot" else report(a.days)


if __name__ == "__main__":
    sys.exit(main())
