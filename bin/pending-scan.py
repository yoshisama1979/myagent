#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""社長の判断待ち項目を、全レーンの台帳・掲示板から集めて仕分けの土俵に載せる（LLM なし）。

契機＝2026-08-27 社長ご指示。無人ループの台帳がどれも上限超え（合計985KB）になり、
ヘッドレスの25分制限に当たり始めた。中身を数えたところ、いちばん太い ycom の提案台帳は
**71%が「社長の回答待ち」**で、退避で減らせるのは9%しかなかった＝太る原因はゴミの堆積ではなく
**決まらないまま積み上がった案件**そのもの。よって「捨てる／退避する」ではなく
**「決める」を回す**ための道具を置く。

設計（todo-brief.py / todo-post.py と同じ「判断と計算の分離」）:
- ここ（Python）は **集める・数える・状態を覚える** だけ。**どれを社長に聞くか・何と聞くかは
  LLM（/triage）の仕事**。分類の判断はここに書かない。
- **状態ファイルに本文を持たない**（ID・置き場・行番号・ハッシュだけ）。理由＝台帳には
  取引先名・案件の実体が入る。写しを増やすと漏れる面が増える。表示は毎回ソースから読み直す。
- 回答の書き戻しは各レーンの `from-president.md`（既存の入口）へ。**他モードの台帳を
  横から書き換えない**＝所有者が自分で閉じる。閉じたかどうかは scan が次回に実測する
  （項目がソースから消える＝gone）。[[feedback_writeback-to-source-of-truth]]

使い方:
  pending-scan.py scan            # ソースを走査して状態を更新（消えた項目は gone に落ちる）
  pending-scan.py stats           # レーン別の件数
  pending-scan.py list [--lane X] [--status open|asked] [--limit N]
  pending-scan.py ask <key>...    # 社長に提示した印（同じものを翌日また聞かない）
  pending-scan.py decide <key> --kind <president|ai-close|do-now> [--note ...]
  pending-scan.py verify          # 決めたのに台帳から消えていないものを洗い出す（書き戻しの実測）
  pending-scan.py wip [--lane X]  # 在庫上限に達したレーンを出す（達していれば終了コード1）
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent
STATE_DIR = PROJ / "data" / "triage"
STATE_FILE = STATE_DIR / "state.json"
LOCK_FILE = STATE_DIR / ".scan.lock"

# 判断待ちの印。台帳・掲示板の共通規律 §7「社長の判断が要る気づきには印を付ける」の 🔔 が正。
PENDING_MARK = "🔔"
# ID の形。レーンごとに接頭辞が違う（R-014c / R-F17(B) / A-078 / Q-F10 / O-056）
ID_RE = re.compile(r"\b([ROPQKAFT]-[A-Z]?\d{2,3}[a-z]?)(?:\([A-Za-z0-9]+\))?")
# 「🔔→✅」の履歴表記。印と同じセルに解決の履歴を残す台帳があるため、印だけを見ると水増しになる。
RESOLVED_HIST_RE = re.compile(r"🔔\s*→\s*[✅❌]")
# 解決済みの状態セル。上の履歴表記に「行頭が ✅/❌」を足したもの＝解決印を増やすときは
# RESOLVED_HIST_RE だけを直せば両方に効く（2つに書き分けると数え方が食い違う）。
RESOLVED_RE = re.compile(RESOLVED_HIST_RE.pattern + r"|^\**\s*[✅❌]")


def live_mark_lines(text):
    """まだ生きている 🔔 を持つ行を返す。

    ★数える単位を「印の出現回数」でなく「行」に揃える（2026-09-02・Codexレビュー指摘）。
    項目は表の1行＝1件なので、出現回数で数えると (a) 1行に 🔔 が2個ある行を2件と数え
    (b) 解決済みの「🔔→✅」まで在庫に数えてしまう。実測（ycom coverage.md）＝
    🔔 総数70・複数印の行6・解決済み表記2 ＝ この分だけ「数の外」が水増しされていた。
    """
    return [ln for ln in text.splitlines()
            if ln.count(PENDING_MARK) > len(RESOLVED_HIST_RE.findall(ln))]

HP_SITES = ("ycom", "fujisaka", "yoshida", "yokohawaii", "konjaku", "hikita", "rally", "shigatoyota")

# ★在庫上限（WIP limit・2026-08-27 社長決定）★
#   社長のお言葉＝「一定数貯まれば止めるようにしましょうか。溜まっている状態で新たな課題を
#   見つけても対応できないので、上がった問題を対応仕分けできたら、その分新しく回していく」。
#   AI は作る側の速度で走り、社長は捌く側の速度でしか走れない＝上限が無ければ差は必ず開く。
#   **止めるのは「新規の起票」だけで、分析そのものは止めない**（効果検証・既存提案の根拠の
#   深掘り・台帳の整理は続ける）＝2026-07 の社長ご指示「回答待ちで分析を止めるな」と両立させる。
WIP_LIMIT = 15


def sources():
    """(lane, path, kind) の一覧。存在しないものは黙って飛ばす。"""
    out = []
    for s in HP_SITES:
        out.append((f"hp-loop:{s}", PROJ / "site" / "hp-analysis" / s / "index.html", "html_table"))
        out.append((f"hp-loop:{s}", PROJ / "data" / "hp-loop" / s / "coverage.md", "md_table"))
    out.append(("partner", PROJ / "data" / "partner" / "ledger.md", "md_table"))
    out.append(("blog-loop:ycom", PROJ / "site" / "hp-analysis" / "ycom" / "blog" / "index.html", "html_table"))
    return [(l, p, k) for l, p, k in out if p.is_file()]


# 地の文に ID が埋まっていて行/表として取り出せない置き場。
# 黙って落とすと「全部見た」と誤読されるので、件数だけは必ず表に出す（silent cap を作らない）。
NARRATIVE = [("overseer", PROJ / "site" / "overseer" / "index.html", re.compile(r"O-\d{3}"))]


def _strip_tags(s):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", s)).strip()


def extract(path, kind):
    """(item_id, 行番号, 先頭セル, 状態セル) を返す。判断待ちの印がある項目行だけ。"""
    text = path.read_text(encoding="utf-8", errors="replace")
    rows = []
    if kind == "html_table":
        for m in re.finditer(r"<tr\b.*?</tr>", text, re.S):
            if PENDING_MARK not in m.group(0):
                continue
            cells = [_strip_tags(c) for c in
                     re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", m.group(0), re.S)]
            if len(cells) < 2:
                continue
            rows.append((cells, text.count("\n", 0, m.start()) + 1))
    else:  # md_table
        for i, ln in enumerate(text.split("\n"), 1):
            t = ln.strip()
            if not t.startswith("|") or PENDING_MARK not in t:
                continue
            cells = [c.strip() for c in t.strip("|").split("|")]
            if len(cells) < 2 or set(cells[0]) <= set("-: "):
                continue
            rows.append((cells, i))

    out = []
    for cells, line in rows:
        # ★印の列位置はレーンごとに違う（実測 2026-08-27＝2列目/3列目/5列目が混在）。
        #   「2列目が状態」と決め打つと、掲示板ごとに静かに取りこぼす（yoshida 12→1件・rally 11→0件）。
        #   よって**印は行のどこにあってもよい**とし、ID が先頭セルにあることだけを項目の条件にする。
        if not any(PENDING_MARK in c for c in cells):
            continue
        m = ID_RE.search(cells[0])
        if not m:
            continue          # 先頭セルに ID が無い＝項目行ではない（凡例・見出し・グループ見出し）
        status = next((c for c in cells[1:] if PENDING_MARK in c), cells[0])
        # ★台帳は「🔔→✅」のように**解錠された履歴**を同じセルに残す（実測 2026-08-27＝R-F02 は
        #   08-21 に解決済みなのに判断待ちに数えていた）。少なく数えるのと同じくらい、
        #   水増しも悪い＝社長に「まだ40件あります」と誤って言うことになる。
        if RESOLVED_RE.search(status):
            continue
        out.append({"id": m.group(0), "line": line,
                    "head": cells[0][:80], "status": status[:160]})
    return out


def key_of(lane, item_id):
    return f"{lane}|{item_id}"


def load_state():
    if not STATE_FILE.is_file():
        return {"v": 1, "items": {}}
    try:
        st = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        die("state.json を読めません（壊れている可能性）。勝手に初期化しません＝手当てが要ります")
    if not isinstance(st, dict) or not isinstance(st.get("items"), dict):
        die("state.json の形がおかしい（items が辞書でない）")
    return st


def save_state(st):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, STATE_FILE)


def die(msg):
    print(f"⚠️ pending-scan: {msg}", file=sys.stderr)
    sys.exit(1)


def _lock():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    f = open(LOCK_FILE, "w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        die("別の scan が動作中です")
    return f


def today():
    return time.strftime("%Y-%m-%d")


def cmd_scan(quiet=False):
    lock = _lock()                       # noqa: F841  プロセス終了まで保持する
    st = load_state()
    items = st["items"]
    seen = set()
    src = sources()
    if not src:
        die("走査対象が1つも見つかりません（起動位置がおかしい？）")
    for lane, path, kind in src:
        for it in extract(path, kind):
            k = key_of(lane, it["id"])
            seen.add(k)
            rec = items.get(k)
            if rec is None:
                items[k] = {"lane": lane, "id": it["id"],
                            "src": str(path.relative_to(PROJ)), "line": it["line"],
                            "first_seen": today(), "last_seen": today(), "status": "open"}
            else:
                rec["last_seen"] = today()
                rec["src"] = str(path.relative_to(PROJ))
                rec["line"] = it["line"]
                # 一度 gone にした項目がまた出てきた＝所有者が閉じ切っていない。open へ戻す
                if rec.get("status") == "gone":
                    rec["status"] = "open"
                    rec.pop("gone_at", None)
    gone = 0
    for k, rec in items.items():
        if k not in seen and rec.get("status") != "gone":
            rec["status"] = "gone"
            rec["gone_at"] = today()
            gone += 1
    save_state(st)
    if not quiet:
        opens = sum(1 for r in items.values() if r["status"] == "open")
        asked = sum(1 for r in items.values() if r["status"] == "asked")
        print(f"走査 {len(src)}ファイル: 判断待ち {len(seen)}件"
              f"（未提示 {opens} / 提示済 {asked}）／今回消えた {gone}件")
    return st


def narrative_counts():
    out = []
    for lane, path, rx in NARRATIVE:
        # NARRATIVE は取り込み時の PROJ で解決済み。テスト等で PROJ を差し替えると
        # この配下から外れる＝その走査対象ではないので黙って飛ばす（relative_to が例外を投げる）。
        try:
            rel = str(path.relative_to(PROJ))
        except ValueError:
            continue
        if path.is_file():
            # ★「判断待ち」だけを数える＝生きた 🔔 のある行にある ID に限る（2026-09-02・Codexレビュー指摘）。
            #   以前はファイル内の全 ID を数えていたため、解決済み・過去の記録まで在庫の死角に混ざっていた
            #   （実測＝site/overseer/index.html は全ID 56件に対し 🔔 行の ID は26件＝30件が過大）。
            #   単位を 🔔 ベースに揃えたので、coverage_gap の「数の外」と合算してよい。
            text = path.read_text(encoding="utf-8", errors="replace")
            ids = set()
            for ln in live_mark_lines(text):
                ids.update(rx.findall(ln))
            out.append((lane, rel, len(ids)))
    return out


def coverage_gap():
    """各ソースの「印の総数」と「項目として取り出せた数」の差を返す。

    ★黙って少なく数えるのが一番危い（実測 2026-08-27＝印の列位置を決め打っていたとき
    yoshida は 12件中1件しか取れず、それでも「35件」と平然と報告できてしまった）。
    表以外（箇条書き・地の文）にある印は取り出さない設計なので、**取りこぼしの数を必ず表に出す**。
    """
    out = []
    for lane, path, kind in sources():
        text = path.read_text(encoding="utf-8", errors="replace")
        marks = len(live_mark_lines(text))
        got = len(extract(path, kind))
        if marks - got > 0:
            out.append((lane, str(path.relative_to(PROJ)), marks, got))
    return out


def cmd_stats():
    st = load_state()
    per = {}
    for r in st["state" if False else "items"].values():
        if r["status"] in ("gone",):
            continue
        d = per.setdefault(r["lane"], {"open": 0, "asked": 0, "decided": 0})
        d[r["status"]] = d.get(r["status"], 0) + 1
    print(f"  {'レーン':18} {'未提示':>6} {'提示済':>6} {'決定済':>6}")
    tot = {"open": 0, "asked": 0, "decided": 0}
    for lane in sorted(per):
        d = per[lane]
        for k in tot:
            tot[k] += d.get(k, 0)
        print(f"  {lane:18} {d.get('open',0):6} {d.get('asked',0):6} {d.get('decided',0):6}")
    print(f"  {'合計':18} {tot['open']:6} {tot['asked']:6} {tot['decided']:6}")
    gap = coverage_gap()
    if gap:
        tot_m = sum(g[2] for g in gap); tot_g = sum(g[3] for g in gap)
        print(f"\n  ⚠️ 表の行として取り出せなかった印が {tot_m - tot_g}件あります"
              f"（印の総数 {tot_m} / 項目として取得 {tot_g}）＝箇条書き・地の文の中にある分。"
              f"\n     この道具は「表の行」だけを項目として扱います。残りは人が読む必要があります:")
        for lane, p, m, g in sorted(gap, key=lambda x: -(x[2] - x[3]))[:8]:
            print(f"     {lane:18} {p:46} 印{m:3} / 取得{g:3} → 残り{m-g:3}")
    nar = narrative_counts()
    if nar:
        print("\n  ⚠️ 機械で項目に切り出せない置き場（地の文に ID が埋まっている）＝ここは人が読む:")
        for lane, p, n in nar:
            print(f"     {lane:16} {p}  ID {n}件")


def cmd_list(lane=None, status="open", limit=None):
    st = load_state()
    rows = [(k, r) for k, r in st["items"].items()
            if (status in ("all", r["status"])) and (not lane or r["lane"].startswith(lane))]
    rows.sort(key=lambda kv: (kv[1]["lane"], kv[1]["first_seen"], kv[1]["id"]))
    if limit:
        rows = rows[:limit]
    if not rows:
        print("該当なし")
        return
    for k, r in rows:
        p = PROJ / r["src"]
        live = ""
        if p.is_file():
            for it in extract(p, "html_table" if p.suffix == ".html" else "md_table"):
                if it["id"] == r["id"]:
                    live = it["status"]
                    break
        age = ""
        try:
            days = (time.mktime(time.strptime(today(), "%Y-%m-%d"))
                    - time.mktime(time.strptime(r["first_seen"], "%Y-%m-%d"))) / 86400
            age = f"{int(days)}日"
        except Exception:
            pass
        print(f"[{k}] {r['status']} 滞留{age}  {r['src']}:{r['line']}")
        print(f"    {live or '（ソースから読めませんでした＝閉じられた可能性）'}")


def _get(st, key):
    r = st["items"].get(key)
    if r is None:
        die(f"そのキーはありません: {key}")
    return r


def cmd_ask(keys):
    lock = _lock()                       # noqa: F841
    st = load_state()
    for k in keys:
        r = _get(st, k)
        r["status"] = "asked"
        r["asked_at"] = today()
    save_state(st)
    print(f"提示済にしました: {len(keys)}件")


DECISIONS = ("president", "ai-close", "do-now")


def cmd_decide(key, kind, note):
    if kind not in DECISIONS:
        die(f"--kind は {'/'.join(DECISIONS)} のいずれか")
    lock = _lock()                       # noqa: F841
    st = load_state()
    r = _get(st, key)
    r["status"] = "decided"
    r["decision"] = kind
    r["decided_at"] = today()
    # 本文は持たない。note は「どこへ書いたか」の参照だけ（取引先名を状態に残さない）
    if note:
        if len(note) > 120:
            die("note は参照用の短い文字列だけ（本文を状態ファイルに写さない）")
        r["note_ref"] = note
    save_state(st)
    print(f"決定を記録: {key} → {kind}")


def cmd_verify():
    """決めたのに台帳から消えていないもの＝書き戻しが届いていない項目を洗い出す。"""
    st = cmd_scan(quiet=True)
    stuck = [(k, r) for k, r in st["items"].items()
             if r["status"] == "decided" and r.get("last_seen") == today()]
    if not stuck:
        print("✅ 決定済みの項目はすべて台帳から消えています（所有モードが閉じました）")
        return 0
    print(f"⚠️ 決めたのに台帳に残っている項目が {len(stuck)}件あります"
          f"（from-president.md へ届いていない／所有モードがまだ回っていない）:")
    for k, r in sorted(stuck):
        print(f"  {k}  決定 {r.get('decided_at')}（{r.get('decision')}）  {r['src']}:{r['line']}")
    return 1


def cmd_wip(lane=None):
    """レーンごとの在庫が上限に達しているか。達していれば終了コード1（＝新規起票を止める合図）。

    ★必ず走査し直してから判定する。古い状態で判定すると「止めるべきときに止まらない／
    もう減っているのに止め続ける」の両方が起きる。
    """
    st = cmd_scan(quiet=True)
    per = {}
    for r in st["items"].values():
        if r["status"] in ("open", "asked"):
            per[r["lane"]] = per.get(r["lane"], 0) + 1
    # ★門番が「何を見ていないか」を判定と同じ行に出す（O-057・2026-09-01 社長承認）。
    #   数えられた件数だけを見せると、上限に達していないことが安全の証拠に見えてしまう。
    #   実際にはこの道具は表の行しか取り出さないので、印の総数との差＝死角を必ず併記する。
    blind = {}
    for l, _p, m, g in coverage_gap():
        if m > g:
            blind[l] = blind.get(l, 0) + (m - g)
    # 死角しか無いレーン（数えた件数が0）も必ず行に出す＝黙って一覧から消さない。
    lanes = ([lane] if lane else
             sorted(set(per) | set(blind) | {f"hp-loop:{s}" for s in HP_SITES}))
    blocked = []
    for l in lanes:
        n = per.get(l, 0)
        b = blind.get(l, 0)
        note = f"／⚠️ 数の外 {b}件（表の行として取り出せない印）" if b else ""
        if n >= WIP_LIMIT:
            blocked.append(l)
            print(f"🛑 {l}: 判断待ち {n}/{WIP_LIMIT} ＝ **新規の起票を止める**"
                  f"（分析・効果検証・根拠の深掘り・台帳の整理は続ける）{note}")
        else:
            print(f"✅ {l}: 判断待ち {n}/{WIP_LIMIT} ＝ 起票可（残り {WIP_LIMIT - n}件）{note}")
    # 合計は「いま表に出したレーン」だけで取る（--lane 指定時に全レーンの合計を出すと数が食い違う）。
    tot_b = sum(blind.get(l, 0) for l in lanes)
    tot_n = sum(per.get(l, 0) for l in lanes)
    nar = narrative_counts() if lane is None else []
    if tot_b or nar:
        print(f"\n  ⚠️ この門番の視野：数えた {tot_n}件／数の外 "
              f"{tot_b + sum(n for _l, _p, n in nar)}件。"
              f"\n     上限 {WIP_LIMIT} は**数えられた分だけ**に効きます＝"
              f"「✅ 起票可」は在庫が少ない証拠にはなりません。")
        for l, p2, n in nar:
            print(f"     {l:16} {p2}  ID {n}件（地の文＝人が読む）")
    if blocked:
        print(f"\n止まっているレーン {len(blocked)}件。"
              f"減らすには `/triage` で仕分けて回答する（1回5件まで）。")
    return 1 if blocked else 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("scan")
    sub.add_parser("stats")
    p = sub.add_parser("list")
    p.add_argument("--lane"); p.add_argument("--status", default="open")
    p.add_argument("--limit", type=int)
    p = sub.add_parser("ask"); p.add_argument("keys", nargs="+")
    p = sub.add_parser("decide"); p.add_argument("key")
    p.add_argument("--kind", required=True); p.add_argument("--note")
    sub.add_parser("verify")
    p = sub.add_parser("wip"); p.add_argument("--lane")
    a = ap.parse_args()
    if a.cmd == "scan":
        cmd_scan()
    elif a.cmd == "stats":
        cmd_stats()
    elif a.cmd == "list":
        cmd_list(a.lane, a.status, a.limit)
    elif a.cmd == "ask":
        cmd_ask(a.keys)
    elif a.cmd == "decide":
        cmd_decide(a.key, a.kind, a.note)
    elif a.cmd == "verify":
        sys.exit(cmd_verify())
    elif a.cmd == "wip":
        sys.exit(cmd_wip(a.lane))
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
