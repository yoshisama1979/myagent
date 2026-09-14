#!/usr/bin/env python3
"""session-desk — このセッションは「どの窓口」か＝受信箱の身元を決める（LLM なし）。

契機＝2026-09-14 triage 依頼（data/triage/handoff-dev-mailbox-identity-20260914.md）。
同一VPS内の受信箱は、有人セッションでは `--as <宛名>` の**自己申告**だけで身元が決まっていた。
CLAUDE.md の手順は全セッションに自動で載るため、triage もマネジメントも同じ宛名を「自分宛」として
読めた＝2026-09-13、マネジメント宛の統括返信を triage が既読にした（実害）。

社長の運用＝**窓口＝`claude -r` で開くセッション**（tmux のウィンドウ名は対応していないので使わない）。
よって身元は **セッションID → 宛名 の対応表**（config/session-desks.json）で決める。

  session-desk.py resolve [--session ID]   機械可読（JSON）。未登録でも exit 0（registered=false）
  session-desk.py whoami  [--session ID]   人が読む。未登録・IDなしは exit 3、対応表の故障は exit 2
  session-desk.py name                     bin/mailbox.sh 用（desk= / error= / warn= の行）。常に exit 0
  session-desk.py hook                     UserPromptSubmit フック。未読があれば1行だけ出す。常に exit 0

設計：
- **未登録を黙って既定の宛名にしない**。前身（同じ窓口の続きとして生まれた元のID）が分かれば添えて止まる。
  前身は新IDの冒頭にある `read the full transcript at: …/<前身ID>.jsonl` でたどる。
  `/compact` 後は**自分自身**を指す行も入るので、それは前身として扱わない（実測 2026-09-14）。
  `claude -r` の再開で分岐したIDには、この行が無いことがある＝その場合は「前身なし」と正直に言う。
- **1つの宛名に動いているIDが2つ**（登録IDとその続きが24時間以内に両方更新）なら警告する
  ＝旧IDと新IDで同じ受信箱を取り合わない（2026-09-14 実測で分岐と並行利用の実例あり）。
- フックは**件名・本文を出さない**（件数だけ）。どんな失敗でも黙って exit 0＝本作業を止めない。
"""
import argparse
import glob
import json
import os
import re
import sys
import time

ROOT = os.environ.get("SESSION_DESK_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.environ.get("SESSION_DESK_TABLE") or os.path.join(ROOT, "config", "session-desks.json")
SESSIONS = os.environ.get("SESSION_DESK_SESSIONS") or os.path.expanduser(
    "~/.claude/projects/-home-vpsuser-projects-myagent")
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
SID_RE = re.compile(rf"^{UUID}$")
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
PRED_RE = re.compile(rf"read the full transcript at: [^\s\"\\]*/({UUID})\.jsonl")
HEAD_BYTES = 512 * 1024      # 前身の参照は冒頭（引き継ぎの要約）にある＝23MB のログを全部は読まない
ACTIVE_SEC = 24 * 3600       # 「動いている」＝24時間以内に更新された
TABLE_NAME = "config/session-desks.json"


class DeskError(Exception):
    pass


def short(sid):
    return (sid or "")[:8]


def load_table():
    try:
        with open(TABLE, encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        raise DeskError(f"窓口の対応表がありません（{TABLE_NAME}）")
    except (OSError, ValueError) as e:
        raise DeskError(f"窓口の対応表を読めません（{TABLE_NAME}・{e.__class__.__name__}）")
    if not isinstance(d, dict) or not isinstance(d.get("desks"), dict) or not isinstance(d.get("sessions"), dict):
        raise DeskError(f"窓口の対応表の形が違います（{TABLE_NAME} に desks と sessions が要ります）")
    desks = {k: v for k, v in d["desks"].items() if not k.startswith("_")}
    for k, v in desks.items():
        if not NAME_RE.match(k) or not isinstance(v, dict):
            raise DeskError(f"窓口の対応表に不正な宛名があります: {k!r}")
    sessions = {}
    for sid, desk in d["sessions"].items():
        if sid.startswith("_"):
            continue
        if not SID_RE.match(sid):
            raise DeskError(f"窓口の対応表に不正なセッションIDがあります: {sid!r}")
        if desk not in desks:
            raise DeskError(f"窓口の対応表で {short(sid)} の宛名 {desk!r} が desks に定義されていません")
        sessions[sid] = desk
    return desks, sessions


def get_sid(arg):
    sid = arg or os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not sid:
        raise DeskError("このセッションのIDが分かりません（CLAUDE_CODE_SESSION_ID が空）")
    if not SID_RE.match(sid):
        raise DeskError(f"セッションIDの形が不正です: {sid[:60]!r}")
    return sid


def _jsonl(sid):
    return os.path.join(SESSIONS, sid + ".jsonl")


def predecessor_id(sid):
    try:
        with open(_jsonl(sid), "rb") as f:
            head = f.read(HEAD_BYTES).decode("utf-8", "replace")
    except OSError:
        return None
    for m in PRED_RE.finditer(head):
        if m.group(1) != sid:            # /compact 後の自己参照は前身ではない
            return m.group(1)
    return None


def chain_to_registered(sid, sessions):
    """最も近い登録済みの祖先。無ければ直前の前身（desk=None）。系譜が無ければ None。"""
    seen, cur, first = {sid}, sid, None
    for _ in range(20):
        p = predecessor_id(cur)
        if not p or p in seen:
            break
        first = first or p
        if p in sessions:
            return {"id": p, "desk": sessions[p]}
        seen.add(p)
        cur = p
    return {"id": first, "desk": None} if first else None


def _active(path, now):
    try:
        return now - os.path.getmtime(path) <= ACTIVE_SEC
    except OSError:
        return False


def siblings(sid, sessions):
    """登録IDの続きとして生まれ、いまも動いている未登録のID（登録ID自身も動いているときだけ）。"""
    now = time.time()
    if not _active(_jsonl(sid), now):
        return []
    out = []
    for path in glob.glob(os.path.join(SESSIONS, "*.jsonl")):
        cand = os.path.basename(path)[:-len(".jsonl")]
        if cand == sid or cand in sessions or not SID_RE.match(cand) or not _active(path, now):
            continue
        anc = chain_to_registered(cand, sessions)
        if anc and anc["id"] == sid:
            out.append(cand)
    return sorted(out)


def resolve(sid):
    desks, sessions = load_table()
    desk = sessions.get(sid)
    info = desks.get(desk, {}) if desk else {}
    return {"session": sid, "registered": bool(desk), "desk": desk,
            "label": info.get("label"), "rule": info.get("rule"),
            "predecessor": chain_to_registered(sid, sessions),
            "siblings": siblings(sid, sessions) if desk else []}


def unread_count(desk):
    n = 0
    for p in glob.glob(os.path.join(ROOT, "data", "mailbox", "new", "*.json")):
        try:
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(d, dict) and d.get("to") == desk:
            n += 1
    return n


def unregistered_msg(r):
    s = f"このセッション（{short(r['session'])}）は窓口の対応表（{TABLE_NAME}）に未登録です"
    p = r["predecessor"]
    if p and p.get("desk"):
        s += f"。前身は {short(p['id'])}（宛名 {p['desk']}）"
    elif p:
        s += f"。前身は {short(p['id'])}（未登録）"
    return s + "＝黙って既定の宛名では読みません。どの窓口か社長に確認して対応表に登録してください"


def sibling_msg(r):
    ids = "・".join(short(x) for x in r["siblings"])
    return (f"窓口「{r['desk']}」の続きとして別のセッション（{ids}）も24時間以内に動いています"
            "＝同じ受信箱を取り合います。どちらを窓口にするか社長に確認し、対応表を組み替えてください")


def cmd_name(a):
    try:
        r = resolve(get_sid(a.session))
    except DeskError as e:
        print(f"error={e}")
        return 0
    if not r["registered"]:
        print("error=" + unregistered_msg(r))
        return 0
    print(f"desk={r['desk']}")
    if r["siblings"]:
        print("warn=" + sibling_msg(r))
    return 0


def cmd_hook():
    # 見た目と同じく「本作業を止めない」が最優先＝どんな失敗も黙って終える
    try:
        if os.environ.get("MYAGENT_UNATTENDED") == "1":
            return                        # 無人は MYAGENT_AGENT の世界＝ここでは扱わない
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
        sid = str(data.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID") or "")
        if not SID_RE.match(sid):
            return
        _, sessions = load_table()
        desk = sessions.get(sid)
        if not desk:
            return
        n = unread_count(desk)
        if n:
            print(f"📬 このセッションは窓口「{desk}」です。あなた宛の未読 {n}通"
                  "（読む＝bash bin/mailbox.sh local-inbox）")
    except Exception:
        return


def main():
    ap = argparse.ArgumentParser(description="このセッションはどの窓口か（受信箱の身元）")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("resolve", "whoami", "name"):
        sub.add_parser(c).add_argument("--session")
    sub.add_parser("hook")
    a = ap.parse_args()
    if a.cmd == "hook":
        cmd_hook()
        return 0
    if a.cmd == "name":
        return cmd_name(a)
    try:
        sid = get_sid(a.session)
    except DeskError as e:
        print(f"session-desk: {e}", file=sys.stderr)
        return 3
    try:
        r = resolve(sid)
    except DeskError as e:
        print(f"session-desk: {e}", file=sys.stderr)
        return 2
    if a.cmd == "resolve":
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return 0
    if not r["registered"]:
        print("⚠️ " + unregistered_msg(r))
        return 3
    print(f"このセッション（{short(sid)}）は窓口「{r['desk']}」＝{r['label'] or '（説明なし）'}です。")
    print(f"  受信箱: bash bin/mailbox.sh local-inbox（未読 {unread_count(r['desk'])}通）")
    print(f"  ルール: {r['rule'] or '（未設定）'}")
    if r["siblings"]:
        print("⚠️ " + sibling_msg(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
