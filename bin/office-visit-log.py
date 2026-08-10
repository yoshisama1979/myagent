#!/usr/bin/env python3
"""office-visit-log.py — 「声をかけに行く」再生用の委任イベントを1行追記する（見た目専用）

usage: office-visit-log.py <from-id> <to-id>

3Dオフィスで「エージェントAがサブエージェントBを呼んだ」瞬間を、Aのアバターが
実際にBの机まで歩いて声をかける再生（ストック再生＝リアルタイムでなくてよい・
社長承認 2026-08-10）に使う。office-beacon-hook.py の pre から呼ばれるほか、
手動テストでも同じ入口を使う。

鉄則（office-beacon.sh と同じ）：
  - 書くのはエージェントid（status.php 台帳の id）と時刻だけ。**タスク本文・依頼文・
    クライアント実名は絶対に書かない**（この行はダッシュボードAPIにそのまま載る）。
  - どんな失敗でも exit 0＝本作業を止めない。出力もしない。
  - 読む側（status.php）は読み取り専用のまま＝丸め（ローテ）もこの書き手がやる。
"""
import fcntl
import json
import os
import re
import sys
import time


def main():
    if len(sys.argv) < 3:
        return
    frm, to = sys.argv[1], sys.argv[2]
    # ASCII の小文字英数とハイフンだけ＝日本語や記号（クライアント名等）は原本にすら書かない
    # （Codexレビュー 2026-08-10 🔴＝isalnum() は日本語も通してしまう）
    ok = lambda s: re.fullmatch(r"[a-z0-9-]{1,40}", s) is not None
    if not ok(frm) or not ok(to) or frm == to:
        return
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(root, "data", "office", "live", "visits.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    line = json.dumps({"ts": int(time.time()), "from": frm, "to": to}) + "\n"
    # 追記も丸めも同じ flock で守る＝丸めの最中に他プロセスの追記が消えない。
    # ロックは**待たない**＝競合したらこのイベントは捨てる（見た目専用・フックの呼び出し元
    # ＝PreToolUse を絶対に待たせない。Codexレビュー 2026-08-10 🔴反映）
    with open(path, "a+", encoding="utf-8") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return
        f.write(line)
        f.flush()
        size = os.path.getsize(path)
        if size > 100 * 1024:                    # 100KB 超で末尾200行に丸める
            # 事故で巨大化していても全件は読まない＝末尾256KBから行を拾う（Codex🟡）。
            # 先頭の欠け行が混ざっても、読む側(status.php)の json_decode が捨てるので実害なし
            f.seek(max(0, size - 256 * 1024))
            tail = f.readlines()[-200:]
            f.seek(0)
            f.truncate()
            f.writelines(tail)


try:
    main()
except Exception:
    pass                                         # 見た目専用＝失敗しても何も言わず素通し
sys.exit(0)
