#!/usr/bin/env python3
"""office-beacon-hook.py — Claude Code フック → 在席ビーコンのアダプタ（見た目専用）

.claude/settings.local.json の hooks から呼ばれる：
  pre    : PreToolUse(Task)   … サブエージェント委任の瞬間に委任先の机を点灯
  post   : PostToolUse(Task)  … 委任が終わったら消灯（自分のリースだけ）
  prompt : UserPromptSubmit   … 社長がメッセージを送るたび会話窓口(hanasaka-main)の在席を更新
                                （返信が済んでもTTL=10分は在席のまま→自然消灯＝stop不要）

鉄則（このファイルの存在理由より優先）：
  - どんな失敗でも exit 0・stdout/stderr に一切出力しない＝本作業を絶対に止めない・
    コンテキストを汚さない（UserPromptSubmit の stdout は会話に注入されるため特に）。
  - task は下の表の固定ラベルのみ。生のプロンプト・依頼文・Bashコマンド・クライアント実名を
    ビーコンに渡さない（Codexレビュー 2026-07-29 🟡＝task はダッシュボードAPIにそのまま載る）。
  - 会話窓口を点灯する条件は「無人かどうか」ではなく「相手が誰か」で見る（2026-07-29 修正）。
    Slack で社長が話しかけたときも agent-tick.sh はヘッドレス起動（MYAGENT_UNATTENDED=1）
    なので、無人だからと抑止すると *社長との会話中こそ机が光らない* という逆の穴になる。
    ＝ MYAGENT_AGENT が会話窓口（hanasaka-main）の実行、または有人セッションのときだけ点灯し、
    それ以外の無人実行（cron の /comms・/overseer 等）では点灯しない。
  - 委任点灯は無人でも行う＝partner が finance に委任した瞬間が見えるのはむしろ本命
    （依頼元は MYAGENT_AGENT から取る）。
"""
import json
import os
import subprocess
import sys

# サブエージェント種別 → (机のid, 固定ラベル)。表に無い種別は点灯しない（安全側・机も無い）
SUBAGENT_DESKS = {
    "finance": ("finance", "経理の調べもの"),
}

CONVERSATION_DESK = ("hanasaka-main", "社長と会話中")

BEACON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "office-beacon.sh")


def run_beacon(args):
    subprocess.run(["bash", BEACON, *args],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    data = json.load(sys.stdin)

    # リースキー＝セッションID（英数._-のみに正規化）。同一セッション内は同じ鍵で更新される
    sid = str(data.get("session_id") or "nokey")
    key = "hook-" + "".join(c for c in sid if c.isalnum() or c in "._-")[:40]

    # 依頼元＝無人なら cron の宛名（partner 等）・有人なら会話窓口
    caller = os.environ.get("MYAGENT_AGENT") or "hanasaka-main"

    if mode in ("pre", "post"):
        tool_input = data.get("tool_input") or {}
        desk = SUBAGENT_DESKS.get(str(tool_input.get("subagent_type") or ""))
        if not desk:
            return
        if mode == "pre":
            run_beacon(["start", desk[0], desk[1], caller, key])
        else:
            run_beacon(["stop", desk[0], key])
    elif mode == "prompt":
        # 有人セッション、または Slack 経由の会話窓口（ヘッドレスだが相手は社長）だけ点灯。
        # 他の無人実行（/comms・/overseer 等）は「社長と会話中」ではないので点灯しない。
        unattended = os.environ.get("MYAGENT_UNATTENDED") == "1"
        if unattended and os.environ.get("MYAGENT_AGENT") != CONVERSATION_DESK[0]:
            return
        run_beacon(["start", CONVERSATION_DESK[0], CONVERSATION_DESK[1], "", key])


try:
    main()
except Exception:
    pass                                 # 見た目専用＝失敗しても何も言わず素通し
sys.exit(0)
