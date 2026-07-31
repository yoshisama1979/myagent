#!/usr/bin/env python3
"""正本への書き戻し漏れを検出する（読み取り専用）。

社長が Slack で投げたプロダクトの機能・仕様の話は partner 台帳（A-NNN）に記録されるが、
それだけだとプロジェクト記録（＝仕様の正本）に載らず、backlog を見ても出てこない。
2026-07-31 に実際に取りこぼしが起きたため、宣言でなく機械で検出する。

検出するもの:
  1. 台帳 A-NNN のうち、プロダクトの機能・仕様の話を含むのに「📄正本転記済み」が無い行
  2. memo.html のうち、棚卸しされないまま日数が経っているもの

書き込み・外部送信はしない。終了コードは常に 0（検知の有無は出力で判断する）。
未転記が1件でもあれば見出しに 🔔 を出す＝partner はこれを朝礼に載せる。
"""

import re
import sys
import time
from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent
LEDGER = PROJ / "data/partner/ledger.md"
MEMO_STALE_DAYS = 14

# プロダクト名 → 正本（プロジェクト記録）の場所
PRODUCTS = [
    (re.compile(r"HANAチャット|Hanaチャット|hana-chat", re.I),
     "site/clients/hanasaka/projects/hana-chat/backlog.html"),
    (re.compile(r"HANAツール|Hanaツール|hana-tool(?!s)", re.I),
     "site/clients/hanasaka/projects/hana-tool/backlog.html"),
]

# 「機能・仕様の話が社長から来た」ことを示す語。これが無い行は営業・進行の話とみなす
FEATURE_HINT = re.compile(r"社長メモ|投函|追加機能|機能追加|仕様|要望|不具合|バグ|入れよう|作りたい")

DONE_MARK = "📄正本転記済み"
# 進行・営業の話で仕様ではない場合は「📄正本転記不要」を付けて黙らせる（判断を残すため理由も併記する）
SKIP_MARK = "📄正本転記不要"
CLOSED_MARK = re.compile(r"⏹|✅\*\*解消|✅解消|クローズ")


def ledger_rows(path):
    """台帳の A-NNN 行を (id, 本文) で返す。"""
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\|\s*(A-\d+)\s*\|", line)
        if m:
            rows.append((m.group(1), line))
    return rows


def find_unwritten(rows):
    out = []
    for aid, line in rows:
        if DONE_MARK in line or SKIP_MARK in line or CLOSED_MARK.search(line):
            continue
        if not FEATURE_HINT.search(line):
            continue
        for pat, dest in PRODUCTS:
            if pat.search(line):
                out.append((aid, dest, summarize(line)))
                break
    return out


def summarize(line, width=90):
    """台帳行から見出しだけを取り出す（第3カラム＝内容の冒頭）。"""
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    body = cells[2] if len(cells) > 2 else line
    body = re.sub(r"\*\*|`", "", body)
    return body[:width] + ("…" if len(body) > width else "")


def find_stale_memos():
    out = []
    now = time.time()
    for memo in sorted(PROJ.glob("site/clients/*/projects/*/memo.html")):
        if "_template" in str(memo):
            continue
        text = memo.read_text(encoding="utf-8", errors="replace")
        if "現在このメモは空です" in text:
            continue
        days = int((now - memo.stat().st_mtime) / 86400)
        if days >= MEMO_STALE_DAYS:
            out.append((memo.relative_to(PROJ), days))
    return out


def main():
    unwritten = find_unwritten(ledger_rows(LEDGER))
    stale = find_stale_memos()

    if not unwritten and not stale:
        print("✅ 書き戻し漏れなし（台帳→正本・memo棚卸しとも）")
        return 0

    if unwritten:
        print(f"🔔 台帳に載っているが正本へ未転記：{len(unwritten)}件")
        for aid, dest, body in unwritten:
            print(f"  - {aid} → {dest}")
            print(f"      {body}")
        print(f"  ※ 転記したら台帳の該当行に「{DONE_MARK}（日付）」を付ける（次回から出なくなる）")
        print(f"  ※ 仕様ではなく進行・営業の話なら「{SKIP_MARK}（理由）」を付ける＝判断を残して黙らせる")

    if stale:
        if unwritten:
            print()
        print(f"🔔 棚卸しされていない memo：{len(stale)}件（{MEMO_STALE_DAYS}日以上）")
        for path, days in stale:
            print(f"  - {path}（最終更新から {days} 日）")

    return 0


if __name__ == "__main__":
    sys.exit(main())
