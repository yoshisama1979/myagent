#!/usr/bin/env python3
"""無人(cron)実行時に、社長ゲート対象ファイルへの Edit/Write を拒否する PreToolUse フック。

背景：無人ループは `claude -p ... --permission-mode acceptEdits` で動くため、ルール文
（overseer.md「SYSTEM.md の編集は社長合意後のみ」等）があっても編集が自動承認されてしまう。
2026-06-26 に統括ループが SYSTEM.md（地図）を社長ゲートを越えて自動編集した事例の再発防止。

仕組み：
  - agent-tick.sh が無人起動する claude に環境変数 MYAGENT_UNATTENDED=1 を渡す。
  - 本フックは PreToolUse(Edit|Write|MultiEdit) で発火し、
      ・MYAGENT_UNATTENDED!=1（＝有人セッション） → 何もしない（従来どおり編集可）
      ・無人 かつ 対象がゲート対象ファイル        → exit 2 で拒否（stderr を Claude に返す）
  - ＝有人（社長同席）の編集は一切邪魔せず、無人時だけゲート対象を物理的に書けなくする。

ゲート対象（無人では直接編集させない＝更新案を掲示板に出すべきもの）：
  SYSTEM.md / CLAUDE.md / OVERVIEW.md（地図・本体指示）
  .claude/rules/** ・ rules/**（モードのルール）
  .claude/commands/**（スラッシュコマンド定義）
  .claude/settings.json ・ .claude/settings.local.json（権限・自動化設定）

stdlib のみ。判定不能時は安全側に倒さず「許可(exit 0)」する（フックの誤爆で正常編集まで
止めない＝gate対象の判定に確信が持てるときだけ拒否する）。
"""
import json
import os
import sys

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}

# bin/ の親＝プロジェクトルート
ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def is_gated(rel: str) -> bool:
    rel = rel.replace("\\", "/")
    if rel.startswith("./"):
        rel = rel[2:]
    if rel in ("SYSTEM.md", "CLAUDE.md", "OVERVIEW.md",
               ".claude/settings.json", ".claude/settings.local.json"):
        return True
    for pre in (".claude/rules/", "rules/", ".claude/commands/"):
        if rel.startswith(pre):
            return True
    return False


def main() -> int:
    # 有人セッションは対象外（環境変数が無ければ何もしない）
    if os.environ.get("MYAGENT_UNATTENDED") != "1":
        return 0

    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # 入力が読めないなら邪魔しない（安全側＝許可）

    tool = data.get("tool_name", "")
    if tool not in EDIT_TOOLS:
        return 0

    ti = data.get("tool_input", {}) or {}
    path = ti.get("file_path") or ti.get("notebook_path") or ""
    if not path:
        return 0

    try:
        abspath = os.path.realpath(path if os.path.isabs(path) else os.path.join(ROOT, path))
        rel = os.path.relpath(abspath, ROOT)
    except Exception:
        return 0
    if rel.startswith(".."):  # ルート外は対象外
        return 0

    if is_gated(rel):
        sys.stderr.write(
            f"⛔ 無人実行ではゲート対象ファイル（{rel}）を直接編集できません。\n"
            "これは社長承認が必要な領域です（SYSTEM.md・CLAUDE.md・ルール/コマンド/設定）。\n"
            "編集する代わりに、変更内容を『更新案（具体的な差分）』として掲示板 O-NNN と\n"
            "Slack 日報に出し、社長の承認後に有人セッションで反映してください。\n"
            "（再発防止フック guard-unattended-edits.py による拒否）\n"
        )
        return 2  # PreToolUse: exit 2 = ツール実行をブロックし stderr を Claude に返す

    return 0


if __name__ == "__main__":
    sys.exit(main())
