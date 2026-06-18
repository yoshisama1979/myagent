#!/usr/bin/env python3
"""Slack ポーリング・ヘルパー — 「ループが回るたびに新着だけ見る」道具。

常駐デーモンではない。/loop が回るたびに `fetch` を1回呼び、前回見た位置以降の
新着「だけ」を取得して mailbox(data/mailbox/new/) に投函する。返信投稿もここで行う。

重要（Slack APIの仕様）:
- conversations.history は「トップレベル投稿」しか返さない。**スレッド内返信は返さない**。
- よって新着は2系統で取る：
  (a) チャンネルの新着トップレベル … conversations.history(oldest=channel last-seen)
  (b) 追跡中スレッドの新着返信   … conversations.replies(thread, oldest=各スレッドの last-seen)
- 追跡対象スレッドは data/slack/threads.json に登録（post/reply/新規トップレベルで自動登録）。

トークン設計：初回は last-seen を「今」にして過去を読まない。毎回 新着だけ。0件ならほぼ0コスト。

使い方:
  slack-poll.py fetch            # 新着(トップ+スレッド返信)→mailbox→last-seen更新（既定）
  slack-poll.py fetch --init     # last-seenを今にして終了（過去は読まない）
  slack-poll.py post  [--as <agent>] "本文"      # トップ投稿（戻り値thread_ts・スレッド追跡に登録）
  slack-poll.py reply <thread_ts> [--as <agent>] "本文"   # スレッドへ返信（本文は引数末尾 or 標準入力）

  --as <agent>：そのスレッドの持ち主（社長の返信先エージェント）を明示。無指定なら従来動作
                （post=DEFAULT_AGENT / reply=既存スレッドの持ち主）＝後方互換。

必要な .env: SLACK_BOT_TOKEN(xoxb-) / SLACK_CHANNEL_ID(C...)
読み取りは groups:history（非公開）/ channels:history（公開）、投稿は chat:write。
"""
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

from slack_sdk import WebClient

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ENV_FILE = os.path.join(ROOT, ".env")
MAILBOX_NEW = os.path.join(ROOT, "data", "mailbox", "new")
MAILBOX_CUR = os.path.join(ROOT, "data", "mailbox", "cur")
SLACK_DIR = os.path.join(ROOT, "data", "slack")
LAST_SEEN = os.path.join(SLACK_DIR, "last-seen.json")   # チャンネル単位（トップレベル走査用）
THREADS = os.path.join(SLACK_DIR, "threads.json")        # 追跡スレッド {ts: {agent, last_seen}}

JST = timezone(timedelta(hours=9))
# 新規トップレベル投稿（社長の気軽な会話）の既定の受け先＝会話担当（主担当）。
# overseer / hp-loop は自分の日報を post --as <自分> でスレッド化し、社長がそのスレッドに
# 返信した時だけ各ループが拾う（スレッドの持ち主は threads.json に保持される）。
DEFAULT_AGENT = "hanasaka-main"
MAX_PER_POLL = 50


def get_env(key):
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


def _read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def _write_json(path, data):
    os.makedirs(SLACK_DIR, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def _now_ts():
    return f"{datetime.now(JST).timestamp():.6f}"


def _max_ts(a, b):
    return a if float(a) >= float(b) else b


def load_channel_seen(channel):
    return _read_json(LAST_SEEN, {}).get(channel)


def save_channel_seen(channel, ts):
    data = _read_json(LAST_SEEN, {})
    data[channel] = ts
    _write_json(LAST_SEEN, data)


def register_thread(thread_ts, agent, last_seen):
    """スレッドを追跡対象に登録（既存があれば agent は保持、last_seen は前進しない=据え置き）。"""
    data = _read_json(THREADS, {})
    cur = data.get(thread_ts)
    if cur is None:
        data[thread_ts] = {"agent": agent, "last_seen": last_seen}
    else:
        cur.setdefault("agent", agent)
    _write_json(THREADS, data)


def set_thread_seen(thread_ts, last_seen):
    data = _read_json(THREADS, {})
    if thread_ts in data:
        data[thread_ts]["last_seen"] = last_seen
        _write_json(THREADS, data)


def agent_for_thread(thread_ts):
    e = _read_json(THREADS, {}).get(thread_ts)
    return (e or {}).get("agent", DEFAULT_AGENT)


def write_mailbox(channel, msg, agent):
    """1件のSlackメッセージを mailbox new/ に president→agent で書く（重複は書かない）。"""
    os.makedirs(MAILBOX_NEW, exist_ok=True)
    ts = msg.get("ts", "")
    dt = datetime.fromtimestamp(float(ts), JST) if ts else datetime.now(JST)
    stamp = dt.strftime("%Y%m%dT%H%M%S")
    seq = (ts.split(".")[-1] if "." in ts else "000")[:6]
    msg_id = f"M-{stamp}-president-{seq}"
    thread_ts = msg.get("thread_ts") or ts
    text = msg.get("text", "") or ""
    subject = (text.strip().splitlines() or [""])[0][:60] or "(本文のみ)"
    out = {
        "id": msg_id, "thread": f"slack-{thread_ts}", "from": "president",
        "to": agent, "type": "request", "needs_approval": False,
        "ts": dt.isoformat(), "subject": subject, "body": text,
        "slack": {"channel": channel, "thread_ts": thread_ts,
                  "event_ts": ts, "user": msg.get("user", "")},
    }
    final = os.path.join(MAILBOX_NEW, f"{msg_id}.json")
    if os.path.exists(final):
        return None
    tmp = os.path.join(MAILBOX_NEW, f".{msg_id}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    os.replace(tmp, final)
    return msg_id


def _ingestable(m, me):
    return (m.get("ts") and not m.get("subtype") and not m.get("bot_id")
            and m.get("user") and m.get("user") != me)


def client():
    bot = get_env("SLACK_BOT_TOKEN")
    if not bot.startswith("xoxb-"):
        sys.exit("ERROR: .env の SLACK_BOT_TOKEN（xoxb-）が未設定です")
    return WebClient(token=bot)


def cmd_fetch(args):
    channel = get_env("SLACK_CHANNEL_ID")
    if not channel:
        sys.exit("ERROR: .env の SLACK_CHANNEL_ID が未設定です")
    w = client()
    me = w.auth_test().get("user_id", "")

    if "--init" in args or load_channel_seen(channel) is None:
        save_channel_seen(channel, _now_ts())
        print("初期化：last-seen を現在時刻に設定しました（過去履歴は読み込みません）。次回以降の新着のみ取得します。")
        return

    saved = []  # (msg_id, agent, preview)

    # --- (a) 新着トップレベル ---
    ch_seen = load_channel_seen(channel)
    resp = w.conversations_history(channel=channel, oldest=ch_seen, inclusive=False, limit=MAX_PER_POLL)
    tops = [m for m in resp.get("messages", []) if m.get("ts", "0") > ch_seen and _ingestable(m, me)]
    tops.sort(key=lambda m: m["ts"])
    newest_ch = ch_seen
    for m in tops:
        register_thread(m["ts"], DEFAULT_AGENT, m["ts"])  # 新規スレッドとして追跡開始
        mid = write_mailbox(channel, m, DEFAULT_AGENT)
        newest_ch = _max_ts(newest_ch, m["ts"])
        if mid:
            saved.append((mid, DEFAULT_AGENT, (m.get("text", "") or "")[:50]))
    if newest_ch != ch_seen:
        save_channel_seen(channel, newest_ch)

    # --- (b) 追跡中スレッドの新着返信 ---
    threads = _read_json(THREADS, {})
    for thread_ts, info in list(threads.items()):
        t_seen = info.get("last_seen", thread_ts)
        agent = info.get("agent", DEFAULT_AGENT)
        try:
            r = w.conversations_replies(channel=channel, ts=thread_ts, oldest=t_seen,
                                        inclusive=False, limit=MAX_PER_POLL)
        except Exception as e:  # noqa: BLE001 — スレッドが消えた等。スキップして継続
            print(f"[warn] replies取得失敗 thread={thread_ts}: {e}", file=sys.stderr)
            continue
        reps = [m for m in r.get("messages", [])
                if m.get("ts", "0") > t_seen and _ingestable(m, me)]
        reps.sort(key=lambda m: m["ts"])
        newest_t = t_seen
        for m in reps:
            mid = write_mailbox(channel, m, agent)
            newest_t = _max_ts(newest_t, m["ts"])
            if mid:
                saved.append((mid, agent, (m.get("text", "") or "")[:50]))
        if newest_t != t_seen:
            set_thread_seen(thread_ts, newest_t)

    if not saved:
        print("新着なし")
        return
    print(f"新着 {len(saved)} 件を mailbox に投函しました：")
    for mid, agent, preview in saved:
        print(f"  - {mid} → {agent} : {preview!r}")


def _pop_as(args):
    """引数列から `--as <agent>` を取り除き (agent|None, 残りの引数) を返す。

    投稿者（スレッドの持ち主）を明示するための任意フラグ。無指定なら従来動作
    （post=DEFAULT_AGENT / reply=既存スレッドの持ち主）にフォールバックする＝後方互換。
    """
    out, agent, i = [], None, 0
    args = list(args)
    while i < len(args):
        if args[i] == "--as":
            val = args[i + 1] if i + 1 < len(args) else ""
            if not val or val.startswith("-"):   # 空・フラグ様の値を持ち主に保存させない
                sys.exit("ERROR: --as にはエージェント名が必要です")
            agent = val
            i += 2
            continue
        out.append(args[i])
        i += 1
    return agent, out


def _body_from(args):
    return " ".join(args) if args else sys.stdin.read()


def cmd_post(args):
    as_agent, args = _pop_as(args)
    channel = get_env("SLACK_CHANNEL_ID")
    text = _body_from(args).strip()
    if not text:
        sys.exit("ERROR: 投稿本文が空です")
    ts = client().chat_postMessage(channel=channel, text=text).get("ts", "")
    if ts:
        # 自分が立てたスレッドを「--as の主」で追跡（社長の返信を正しいエージェントへ振り分ける）
        register_thread(ts, as_agent or DEFAULT_AGENT, ts)
    print(ts)


def cmd_reply(args):
    as_agent, args = _pop_as(args)
    if not args:
        sys.exit("ERROR: reply <thread_ts> [本文] が必要です")
    thread_ts = args[0]
    text = _body_from(args[1:]).strip()
    if not text:
        sys.exit("ERROR: 返信本文が空です")
    channel = get_env("SLACK_CHANNEL_ID")
    # 既存スレッドは持ち主を保持（register_thread が setdefault）。未知スレッドは --as で主を主張できる
    register_thread(thread_ts, as_agent or agent_for_thread(thread_ts), thread_ts)
    r = client().chat_postMessage(channel=channel, text=text, thread_ts=thread_ts)
    print(f"OK: スレッド {thread_ts} に返信（ts={r.get('ts','')}）")


def cmd_done(args):
    """処理済みメッセージを new/ から cur/ へ原子的に移す（本文は編集しない・raw mv を避ける）。"""
    if not args:
        sys.exit("ERROR: done <msg_id> が必要です")
    msg_id = args[0]
    src = os.path.join(MAILBOX_NEW, f"{msg_id}.json")
    if not os.path.exists(src):
        sys.exit(f"ERROR: {msg_id} は new/ に見つかりません")
    os.makedirs(MAILBOX_CUR, exist_ok=True)
    os.replace(src, os.path.join(MAILBOX_CUR, f"{msg_id}.json"))
    print(f"done: {msg_id} → cur/")


def main():
    argv = sys.argv[1:]
    cmd = argv[0] if argv else "fetch"
    rest = argv[1:]
    if cmd == "fetch":
        cmd_fetch(rest)
    elif cmd == "post":
        cmd_post(rest)
    elif cmd == "reply":
        cmd_reply(rest)
    elif cmd == "done":
        cmd_done(rest)
    else:
        sys.exit(f"不明なコマンド: {cmd}（fetch / post / reply / done）")


if __name__ == "__main__":
    main()
