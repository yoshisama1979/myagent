#!/usr/bin/env python3
"""Slack 受信リスナー（Socket Mode）— 双方向Slackの「受信」側。

社長が Slack チャンネルで発言/スレッド返信すると、それを mailbox の受信箱
（data/mailbox/new/）に president 発のメッセージとして投函する。各エージェントは
自分の /loop の先頭で受信箱を読んで対応する。

設計（.claude/rules/mailbox.md / project_slack-two-way）:
- 1チャンネル＋スレッド運用。スレッド↔エージェントの対応は data/slack/thread-map.json。
  対応が無いスレッド/トップ発言は既定で overseer（統括）へ回す。
- Socket Mode なので外部公開不要（VPSからSlackへ常時接続）。Tailscale内VPSに適合。
- 読むのは Slack イベントのみ。書くのは内部の mailbox だけ（外部送信はしない）。
  → automation.md：小さく作って手動検証してから /loop 常駐化する。

実行: bin/.venv/bin/python3 bin/slack-listen.py
必要な .env: SLACK_APP_TOKEN(xapp-) / SLACK_BOT_TOKEN(xoxb-) / SLACK_CHANNEL_ID(C...)
※トークン実値はコード/ログに出さない（automation.md §2）。
"""
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone

from slack_sdk import WebClient
from slack_sdk.socket_mode import SocketModeClient
from slack_sdk.socket_mode.request import SocketModeRequest
from slack_sdk.socket_mode.response import SocketModeResponse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ENV_FILE = os.path.join(ROOT, ".env")
MAILBOX_NEW = os.path.join(ROOT, "data", "mailbox", "new")
SLACK_DIR = os.path.join(ROOT, "data", "slack")
THREAD_MAP = os.path.join(SLACK_DIR, "thread-map.json")

JST = timezone(timedelta(hours=9))
DEFAULT_AGENT = "overseer"  # 対応スレッドが無いときの既定の宛先


def get_env(key):
    """.env を source せず KEY=value の最後の定義だけ安全に取り出す（slack.sh と同方針）。"""
    if not os.path.exists(ENV_FILE):
        return ""
    val = ""
    with open(ENV_FILE, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^\s*" + re.escape(key) + r"=(.*)$", line.rstrip("\n"))
            if m:
                val = m.group(1)
    val = val.rstrip("\r").strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
        val = val[1:-1]
    return val


def load_thread_map():
    try:
        with open(THREAD_MAP, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def route_for(thread_ts):
    """スレッドの紐付け先エージェントを返す。無ければ既定（overseer）。"""
    m = load_thread_map()
    entry = m.get(thread_ts)
    if isinstance(entry, dict):
        return entry.get("agent", DEFAULT_AGENT), entry.get("thread", "")
    if isinstance(entry, str):
        return entry, ""
    return DEFAULT_AGENT, ""


def write_mailbox(agent, mbox_thread, text, ev):
    """mailbox の new/ に president→agent の1メッセージを書く（一時ファイル→rename で原子的に）。"""
    os.makedirs(MAILBOX_NEW, exist_ok=True)
    ev_ts = ev.get("ts", "")
    dt = datetime.fromtimestamp(float(ev_ts), JST) if ev_ts else datetime.now(JST)
    stamp = dt.strftime("%Y%m%dT%H%M%S")
    seq = (ev_ts.split(".")[-1] if "." in ev_ts else "000")[:6]
    msg_id = f"M-{stamp}-president-{seq}"
    thread_ts = ev.get("thread_ts") or ev_ts
    subject = (text.strip().splitlines() or [""])[0][:60] or "(本文のみ)"
    msg = {
        "id": msg_id,
        "thread": mbox_thread or f"slack-{thread_ts}",
        "from": "president",
        "to": agent,
        "type": "request",
        "needs_approval": False,  # 社長発＝承認者本人。内部調整なので false
        "ts": dt.isoformat(),
        "subject": subject,
        "body": text,
        "slack": {
            "channel": ev.get("channel", ""),
            "thread_ts": thread_ts,
            "event_ts": ev_ts,
            "user": ev.get("user", ""),
        },
    }
    tmp = os.path.join(MAILBOX_NEW, f".{msg_id}.tmp")
    final = os.path.join(MAILBOX_NEW, f"{msg_id}.json")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(msg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, final)
    return msg_id


def main():
    app_token = get_env("SLACK_APP_TOKEN")
    bot_token = get_env("SLACK_BOT_TOKEN")
    channel_id = get_env("SLACK_CHANNEL_ID")
    label = get_env("SLACK_DESTINATION_LABEL")

    missing = [k for k, v in (
        ("SLACK_APP_TOKEN", app_token),
        ("SLACK_BOT_TOKEN", bot_token),
        ("SLACK_CHANNEL_ID", channel_id),
    ) if not v]
    if missing:
        sys.exit("ERROR: .env に未設定のキー: " + ", ".join(missing))
    if not app_token.startswith("xapp-"):
        sys.exit("ERROR: SLACK_APP_TOKEN は App-Level Token（xapp- で始まる）である必要があります")
    if not bot_token.startswith("xoxb-"):
        sys.exit("ERROR: SLACK_BOT_TOKEN は Bot Token（xoxb- で始まる）である必要があります")

    web = WebClient(token=bot_token)
    bot_user_id = ""
    try:
        bot_user_id = web.auth_test().get("user_id", "")
    except Exception as e:  # noqa: BLE001 — 起動時の疎通確認。失敗は明示して落とす
        sys.exit(f"ERROR: Slack 認証に失敗（bot token を確認）: {e}")

    os.makedirs(SLACK_DIR, exist_ok=True)
    client = SocketModeClient(app_token=app_token, web_client=web)

    def handle(c: SocketModeClient, req: SocketModeRequest):
        # まず即 ack（再送ループ防止）
        c.send_socket_mode_response(SocketModeResponse(envelope_id=req.envelope_id))
        if req.type != "events_api":
            return
        ev = (req.payload or {}).get("event", {})
        if ev.get("type") != "message":
            return
        # bot自身・編集/削除/参加等のサブタイプは無視（無限ループ・ノイズ防止）
        if ev.get("subtype") or ev.get("bot_id"):
            return
        if not ev.get("user") or ev.get("user") == bot_user_id:
            return
        if ev.get("channel") != channel_id:
            return  # 対象チャンネル以外は見ない
        text = ev.get("text", "") or ""
        thread_ts = ev.get("thread_ts") or ev.get("ts")
        agent, mbox_thread = route_for(thread_ts)
        try:
            mid = write_mailbox(agent, mbox_thread, text, ev)
            print(f"[recv] {mid} → {agent} (thread {thread_ts}) : {text[:40]!r}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"[error] mailbox 書込失敗: {e}", file=sys.stderr, flush=True)

    client.socket_mode_request_listeners.append(handle)
    print(f"[start] Slack受信リスナー稼働 channel={channel_id}"
          f"{' ('+label+')' if label else ''} bot_user={bot_user_id} default→{DEFAULT_AGENT}",
          flush=True)
    client.connect()
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        print("[stop] 終了", flush=True)


if __name__ == "__main__":
    main()
