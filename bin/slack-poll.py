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

複数チャンネル（2026-06-24）:
- 既定チャンネル SLACK_CHANNEL_ID … トップレベル投稿は会話担当(hanasaka-main)へ。
- メモ専用チャンネル SLACK_MEMO_CHANNEL_ID（任意）… トップレベル投稿は memo へ（日常メモ窓口）。
- 経営パートナー専用チャンネル SLACK_PARTNER_CHANNEL_ID（任意）… トップレベル投稿は partner へ（経営情報窓口）。
  未設定ならメモ窓口は無効（従来どおり1チャンネル運用）。last-seen はチャンネル別キーで保持。
  追跡スレッドは threads.json に channel を記録し、返信走査を正しいチャンネルで行う。

使い方:
  slack-poll.py fetch            # 全チャンネルの新着(トップ+スレッド返信)→mailbox→last-seen更新（既定）
  slack-poll.py fetch --init     # 全チャンネルの last-seenを今にして終了（過去は読まない）
  slack-poll.py post  [--as <agent>] [--channel main|memo|partner|<C...>] "本文"   # トップ投稿（戻り値thread_ts）
  slack-poll.py reply <thread_ts> [--as <agent>] [--channel main|memo|partner|<C...>] "本文"  # スレッドへ返信
  slack-poll.py done  <msg_id>      # 処理済みを cur/ へ（new/ または memo-stock/ から探す）
  slack-poll.py stock <msg_id>      # triage済みメモを new/ → memo-stock/（夜の /memo-intake がまとめて処理）
  slack-poll.py untrack <thread_ts> # 解決した確認スレッドを threads.json から外す（自己掃除）

  --as <agent>：そのスレッドの持ち主（社長の返信先エージェント）を明示。無指定なら従来動作
                （post=DEFAULT_AGENT / reply=既存スレッドの持ち主）＝後方互換。
  --channel：投稿先チャンネル。alias（main/memo）または生のチャンネルID。無指定なら
             reply は登録スレッドのチャンネル→既定、post は既定チャンネル。

メモ2層運用（2026-06-24）:
- 日中：反応tickの /memo-triage が new/ のメモを軽く点検し、曖昧なら #memo のそのメモの
  スレッドへ質問（reply で当該メモだけ追跡開始）。点検済みは stock で memo-stock/ へ退避
  （new/ が空になり再起動・再質問しない）。社長の返信は (b) スレッド走査で to:memo に戻る。
- 夜：daily の /memo-intake が memo-stock/ をまとめて notes.html へ清書し、done で cur/ へ。
  解決した確認スレッドは untrack で外す（threads.json を有界に保つ）。

必要な .env: SLACK_BOT_TOKEN(xoxb-) / SLACK_CHANNEL_ID(C...)（メモ窓口は SLACK_MEMO_CHANNEL_ID・経営パートナー窓口は SLACK_PARTNER_CHANNEL_ID も）
読み取りは groups:history（非公開）/ channels:history（公開）、投稿は chat:write。
Bot は対象チャンネル（#memo 含む）に招待しておくこと。
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
MAILBOX_STOCK = os.path.join(ROOT, "data", "mailbox", "memo-stock")  # triage済みメモを夜バッチまで保管
SLACK_DIR = os.path.join(ROOT, "data", "slack")
LAST_SEEN = os.path.join(SLACK_DIR, "last-seen.json")   # チャンネル単位（トップレベル走査用）
THREADS = os.path.join(SLACK_DIR, "threads.json")        # 追跡スレッド {ts: {agent, last_seen}}

JST = timezone(timedelta(hours=9))
# 新規トップレベル投稿（社長の気軽な会話）の既定の受け先＝会話担当（主担当）。
# overseer / hp-loop は自分の日報を post --as <自分> でスレッド化し、社長がそのスレッドに
# 返信した時だけ各ループが拾う（スレッドの持ち主は threads.json に保持される）。
DEFAULT_AGENT = "hanasaka-main"
# メモ専用チャンネル（SLACK_MEMO_CHANNEL_ID）のトップレベル投稿の受け先。
# 社長が #memo に投げた日常メモを /memo-intake が notes.html へ追記する。
MEMO_AGENT = "memo"
# 経営パートナー専用チャンネル（SLACK_PARTNER_CHANNEL_ID）のトップレベル投稿の受け先。
# 社長が #partner（経営パートナーch）に渡した経営情報を /partner が取り込む（毎朝の朝礼もこのchへ）。
PARTNER_AGENT = "partner"
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


def channels():
    """走査対象 (channel_id, トップレベル投稿の受け先agent, トップ投稿をスレッド追跡するか) のリスト。

    既定チャンネル→hanasaka-main（会話なので追跡する＝社長の返信を拾う）。
    メモ専用チャンネル（任意）→memo（**fetch では追跡しない**：トップ投稿を ingest 時に自動追跡は
    しない。代わりに日中の /memo-triage が「返信したメモ」だけ reply 経由でスレッド追跡し会話を続け、
    夜の /memo-intake が当日メモスレッドをまとめて untrack する＝threads.json は1日単位で有界・毎晩
    リセット。fetch で自動追跡すると triage が返信しなかった/失敗したメモまで残るため False が正しい）。
    メモが未設定なら従来どおり1チャンネルのみ。重複IDは1つに畳む。
    """
    out, seen = [], set()
    main = get_env("SLACK_CHANNEL_ID")
    if main:
        out.append((main, DEFAULT_AGENT, True))
        seen.add(main)
    memo = get_env("SLACK_MEMO_CHANNEL_ID")
    if memo and memo not in seen:
        out.append((memo, MEMO_AGENT, False))
        seen.add(memo)
    # 経営パートナー専用チャンネル（任意）→partner。memo と同じく fetch では追跡しない（False）：
    # トップ投稿は to: partner として ingest し、会話を続けたいスレッドだけ partner が reply 経由で
    # 追跡する（threads.json を肥大させない）。未設定なら従来どおり対象に含めない。
    partner = get_env("SLACK_PARTNER_CHANNEL_ID")
    if partner and partner not in seen:
        out.append((partner, PARTNER_AGENT, False))
        seen.add(partner)
    return out


def _resolve_channel(val):
    """--channel の値（alias main/memo または生ID）をチャンネルIDへ。未指定は None。"""
    if not val:
        return None
    if val == "main":
        return get_env("SLACK_CHANNEL_ID")
    if val == "memo":
        return get_env("SLACK_MEMO_CHANNEL_ID")
    if val == "partner":
        # 経営パートナーch。未設定なら既定チャンネルへフォールバック（朝礼が宛先無しで失敗しない）。
        return get_env("SLACK_PARTNER_CHANNEL_ID") or get_env("SLACK_CHANNEL_ID")
    return val


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


def register_thread(thread_ts, agent, last_seen, channel=None):
    """スレッドを追跡対象に登録（既存があれば agent/channel は保持、last_seen は据え置き）。

    channel は返信走査(conversations_replies)を正しいチャンネルで行うために記録する。
    未指定（既存仕様の呼び出し）なら省略＝走査時に既定チャンネルへフォールバック。

    注：threads.json は read-modify-write でファイルロックはしていない。無人運用の書き手
    （fetch/post/reply/untrack）は agent-tick.sh の flock で直列化されるため実害はない。
    手動実行を並走させる場合は同時更新で取りこぼし得る点に留意（必要になれば flock 化する）。
    """
    data = _read_json(THREADS, {})
    cur = data.get(thread_ts)
    if cur is None:
        entry = {"agent": agent, "last_seen": last_seen}
        if channel:
            entry["channel"] = channel
        data[thread_ts] = entry
    else:
        cur.setdefault("agent", agent)
        if channel:
            cur.setdefault("channel", channel)
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
    # 重複防止：同一Slackイベント(=同一msg_id)が new/・memo-stock/・cur/ のどこかに既にあれば書かない。
    # fetch投函→triage が memo-stock/ へ退避→last-seen保存前にクラッシュ→再fetch、でも二重投函しない。
    for d in (MAILBOX_NEW, MAILBOX_STOCK, MAILBOX_CUR):
        if os.path.exists(os.path.join(d, f"{msg_id}.json")):
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
    # 既定チャンネルは必須（システム全体が前提）。未設定なら memo だけ設定でも進めない＝
    # channel無しの旧threadが空チャンネルへフォールバックして走査失敗するのを防ぐ（後方互換の不変条件）。
    if not get_env("SLACK_CHANNEL_ID"):
        sys.exit("ERROR: .env の SLACK_CHANNEL_ID が未設定です")
    chans = channels()
    w = client()
    me = w.auth_test().get("user_id", "")
    force_init = "--init" in args
    saved = []  # (msg_id, agent, preview)

    # --- (a) 各チャンネルの新着トップレベル（チャンネル別の受け先agentへ振り分け） ---
    for channel, default_agent, track_tops in chans:
        ch_seen = load_channel_seen(channel)
        if force_init or ch_seen is None:
            # 新規チャンネルは last-seen を現在に。過去履歴は読まない（メモ窓口を後から足しても暴発しない）。
            save_channel_seen(channel, _now_ts())
            print(f"初期化：channel {channel} の last-seen を現在時刻に設定（過去は読み込みません）。")
            continue
        resp = w.conversations_history(channel=channel, oldest=ch_seen, inclusive=False, limit=MAX_PER_POLL)
        tops = [m for m in resp.get("messages", []) if m.get("ts", "0") > ch_seen and _ingestable(m, me)]
        tops.sort(key=lambda m: m["ts"])
        newest_ch = ch_seen
        for m in tops:
            if track_tops:
                register_thread(m["ts"], default_agent, m["ts"], channel)  # 新規スレッドとして追跡開始
            mid = write_mailbox(channel, m, default_agent)
            newest_ch = _max_ts(newest_ch, m["ts"])
            if mid:
                saved.append((mid, default_agent, (m.get("text", "") or "")[:50]))
        if newest_ch != ch_seen:
            save_channel_seen(channel, newest_ch)

    if force_init:
        return

    # --- (b) 追跡中スレッドの新着返信（スレッドごとに記録チャンネルで走査） ---
    main_ch = get_env("SLACK_CHANNEL_ID")
    threads = _read_json(THREADS, {})
    for thread_ts, info in list(threads.items()):
        t_seen = info.get("last_seen", thread_ts)
        agent = info.get("agent", DEFAULT_AGENT)
        t_channel = info.get("channel", main_ch)   # 旧データ（channel無し）は既定チャンネル
        try:
            r = w.conversations_replies(channel=t_channel, ts=thread_ts, oldest=t_seen,
                                        inclusive=False, limit=MAX_PER_POLL)
        except Exception as e:  # noqa: BLE001 — スレッドが消えた等。スキップして継続
            print(f"[warn] replies取得失敗 thread={thread_ts}: {e}", file=sys.stderr)
            continue
        reps = [m for m in r.get("messages", [])
                if m.get("ts", "0") > t_seen and _ingestable(m, me)]
        reps.sort(key=lambda m: m["ts"])
        newest_t = t_seen
        for m in reps:
            mid = write_mailbox(t_channel, m, agent)
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


def _pop_channel(args):
    """引数列から `--channel <alias|id>` を取り除き (値|None, 残りの引数) を返す。"""
    out, chan, i = [], None, 0
    args = list(args)
    while i < len(args):
        if args[i] == "--channel":
            val = args[i + 1] if i + 1 < len(args) else ""
            if not val or val.startswith("-"):
                sys.exit("ERROR: --channel には main/memo またはチャンネルIDが必要です")
            chan = val
            i += 2
            continue
        out.append(args[i])
        i += 1
    return chan, out


def _body_from(args):
    return " ".join(args) if args else sys.stdin.read()


def _guard_memo_channel(agent, channel):
    """memo エージェントは #memo（SLACK_MEMO_CHANNEL_ID）以外へ投稿させない。

    日常メモの内容が社長メインチャンネル等へ暴発するのをコード側で物理的に防ぐ（許可リストや
    プロンプト規約だけに頼らない＝automation.md「外部送信暴発を潰す」）。
    """
    if agent != MEMO_AGENT:
        return
    memo_ch = get_env("SLACK_MEMO_CHANNEL_ID")
    if not memo_ch or channel != memo_ch:
        sys.exit("ERROR: --as memo は #memo（SLACK_MEMO_CHANNEL_ID）へのみ投稿できます")


def _guard_partner_channel(agent, channel):
    """partner エージェントは #partner（SLACK_PARTNER_CHANNEL_ID）以外へ投稿させない。

    未設定なら既定チャンネル(SLACK_CHANNEL_ID)のみ許可。経営情報が他チャンネルや生ID指定で
    暴発するのをコード側で物理的に防ぐ（memo と対称・automation.md「外部送信暴発を潰す」）。
    """
    if agent != PARTNER_AGENT:
        return
    allowed = get_env("SLACK_PARTNER_CHANNEL_ID") or get_env("SLACK_CHANNEL_ID")
    if not allowed or channel != allowed:
        sys.exit("ERROR: --as partner は #partner（SLACK_PARTNER_CHANNEL_ID／未設定時は既定ch）へのみ投稿できます")


def cmd_post(args):
    as_agent, args = _pop_as(args)
    chan_arg, args = _pop_channel(args)
    channel = _resolve_channel(chan_arg) or get_env("SLACK_CHANNEL_ID")
    if not channel:
        sys.exit("ERROR: 投稿先チャンネルが特定できません（--channel か .env を確認）")
    _guard_memo_channel(as_agent or DEFAULT_AGENT, channel)
    _guard_partner_channel(as_agent or DEFAULT_AGENT, channel)
    text = _body_from(args).strip()
    if not text:
        sys.exit("ERROR: 投稿本文が空です")
    ts = client().chat_postMessage(channel=channel, text=text).get("ts", "")
    if ts:
        # 自分が立てたスレッドを「--as の主」＋チャンネルで追跡（社長の返信を正しく振り分ける）
        register_thread(ts, as_agent or DEFAULT_AGENT, ts, channel)
    print(ts)


def cmd_reply(args):
    as_agent, args = _pop_as(args)
    chan_arg, args = _pop_channel(args)
    if not args:
        sys.exit("ERROR: reply <thread_ts> [本文] が必要です")
    thread_ts = args[0]
    text = _body_from(args[1:]).strip()
    if not text:
        sys.exit("ERROR: 返信本文が空です")
    # チャンネルは --channel → 登録スレッドのchannel → 既定 の順で決める
    info = _read_json(THREADS, {}).get(thread_ts, {})
    channel = _resolve_channel(chan_arg) or info.get("channel") or get_env("SLACK_CHANNEL_ID")
    if not channel:
        sys.exit("ERROR: 返信先チャンネルが特定できません（--channel か .env を確認）")
    owner = as_agent or agent_for_thread(thread_ts)
    _guard_memo_channel(owner, channel)
    _guard_partner_channel(owner, channel)
    # 先に投稿し、成功してから追跡登録する（投稿失敗時に未質問のスレッドを threads.json に残さない）。
    r = client().chat_postMessage(channel=channel, text=text, thread_ts=thread_ts)
    # 既存スレッドは持ち主/チャンネルを保持（register_thread が setdefault）。未知スレッドは owner/channel で主張
    register_thread(thread_ts, owner, thread_ts, channel)
    print(f"OK: スレッド {thread_ts} に返信（ts={r.get('ts','')}）")


def cmd_done(args):
    """処理済みメッセージを cur/ へ原子的に移す（new/ または memo-stock/ から探す）。

    本文は編集しない・raw mv を避ける（os.replace で atomic）。メモは triage が memo-stock/ に
    退避するため、夜の /memo-intake が done するときは memo-stock/ 側にある。
    """
    if not args:
        sys.exit("ERROR: done <msg_id> が必要です")
    msg_id = args[0]
    src = None
    for d in (MAILBOX_NEW, MAILBOX_STOCK):
        cand = os.path.join(d, f"{msg_id}.json")
        if os.path.exists(cand):
            src = cand
            break
    if src is None:
        sys.exit(f"ERROR: {msg_id} は new/ にも memo-stock/ にも見つかりません")
    os.makedirs(MAILBOX_CUR, exist_ok=True)
    os.replace(src, os.path.join(MAILBOX_CUR, f"{msg_id}.json"))
    print(f"done: {msg_id} → cur/")


def cmd_stock(args):
    """triage済みメモを new/ から memo-stock/ へ原子的に移す（夜の /memo-intake がまとめて処理）。

    本文は編集しない。new/ から外すことで、反応tickの /memo-triage が同じメモで再起動・再質問
    しないようにする（new/ の to:memo 件数が pending 判定の根拠なので0に戻す）。
    """
    if not args:
        sys.exit("ERROR: stock <msg_id> が必要です")
    msg_id = args[0]
    src = os.path.join(MAILBOX_NEW, f"{msg_id}.json")
    if not os.path.exists(src):
        sys.exit(f"ERROR: {msg_id} は new/ に見つかりません")
    os.makedirs(MAILBOX_STOCK, exist_ok=True)
    os.replace(src, os.path.join(MAILBOX_STOCK, f"{msg_id}.json"))
    print(f"stock: {msg_id} → memo-stock/")


def cmd_untrack(args):
    """解決した確認スレッドを threads.json から外す（追跡解除＝自己掃除）。

    memo の確認スレッドは「未解決の質問」の間だけ追跡し、回答を受けて整理し終えたら外す。
    これで threads.json が無限に膨らまない（メモ窓口導入時の肥大懸念への対処）。
    """
    if not args:
        sys.exit("ERROR: untrack <thread_ts> が必要です")
    thread_ts = args[0]
    data = _read_json(THREADS, {})
    if thread_ts in data:
        del data[thread_ts]
        _write_json(THREADS, data)
        print(f"untrack: {thread_ts} を追跡解除しました")
    else:
        print(f"untrack: {thread_ts} は追跡対象にありません（スキップ）")


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
    elif cmd == "stock":
        cmd_stock(rest)
    elif cmd == "untrack":
        cmd_untrack(rest)
    else:
        sys.exit(f"不明なコマンド: {cmd}（fetch / post / reply / done / stock / untrack）")


if __name__ == "__main__":
    main()
