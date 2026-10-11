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
- 相談チャンネル SLACK_TALK_CHANNEL_ID（既定＝従来の SLACK_PARTNER_CHANNEL_ID）… トップレベル投稿は
  talk へ（軽い相談窓口。2026-08-19 に「会話」と「日1回の重い処理」を器ごと分離）。
- レポートチャンネル SLACK_REPORT_CHANNEL_ID（任意）… トップレベル投稿は partner へ（日次/週次/月次レポート）。
  ※ 相談chの**過去スレッドへの返信**は threads.json の持ち主に従うので、従来どおり partner に届く。
  未設定ならメモ窓口は無効（従来どおり1チャンネル運用）。last-seen はチャンネル別キーで保持。
  追跡スレッドは threads.json に channel を記録し、返信走査を正しいチャンネルで行う。

使い方:
  slack-poll.py fetch            # 全チャンネルの新着(トップ+スレッド返信)→mailbox→last-seen更新（既定）
  slack-poll.py fetch --init     # 全チャンネルの last-seenを今にして終了（過去は読まない）
  slack-poll.py post  [--as <agent>] [--channel main|memo|talk|report|<C...>] "本文"   # トップ投稿（戻り値thread_ts）
  slack-poll.py reply <thread_ts> [--as <agent>] [--channel main|memo|talk|report|<C...>] "本文"  # スレッドへ返信
  （talk＝相談ch／report＝レポートch。"partner" は talk の別名として移行期のみ残置）
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
import contextlib
import fcntl
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
# 相談チャンネル（SLACK_TALK_CHANNEL_ID・未設定なら従来の #partner）のトップレベル投稿の受け先。
# 2026-08-19 社長決定＝「会話」と「日1回の重い処理」を器ごと分ける。#partner は社長の定位置
# （実績113件）なのでそのまま相談窓口に残し、レポートは新設 #report へ移した。
#   ・#partner に新規投稿      → talk（軽い器。起動時に台帳を読まない＝1回$1〜2）
#   ・#partner の過去スレに返信 → これまでどおり partner（threads.json がスレッド単位で持ち主を覚えている）
#   ・#report                  → partner（日次/週次/月次レポート。重い器＝1回$70）
TALK_AGENT = "talk"
MAX_PER_POLL = 50
# 追跡スレッドの保持期限（日）。最終活動（作成 or 最後に見た返信）からこの日数を超えたスレッドは
# fetch 冒頭で自動 untrack する。目的は2つ：
#  (1) threads.json の無限成長を止める（memo は夜バッチが毎日掃除するが、hp-loop/blog 等の
#      日報スレッドには掃除役がおらず1日1本ずつ永久に増えていた）
#  (2) レート制限の解消：2分ごとの fetch が全追跡スレッドへ conversations.replies を一斉に
#      叩くため、追跡数がAPI上限を超えると走査順の後ろ＝新しいスレッドほど毎回失敗し、
#      社長の返信を拾い損ねていた（2026-07-08 に138スレッドで観測・修理）。
# トレードオフ：期限超過の古い日報スレッドに社長が返信しても拾えない（その場合はトップレベルで
# 投稿してもらう＝既定の会話窓口が受ける）。.env の SLACK_THREAD_RETENTION_DAYS で変更可。
THREAD_RETENTION_DAYS = 14
# 親の投稿そのものが存在しない＝何度試しても同じ答えしか返らないエラー。
# ★ ここに入れるのは「存在しない」が確定し、かつ**本番で実際に観測したもの**だけ。
#   - `ratelimited`・通信エラー … 時間が経てば成功する（入れると生きた追跡を落とす）
#   - `channel_not_found` … ボットを招き直せば復活する
#   - `no_permission`・`missing_scope` … 権限の問題で、親は存在している
#   - `message_not_found` … conversations.replies の公式エラー一覧に無く、本番でも未観測。
#     「未文書化の一時エラー」である可能性を消せないので**入れない**（Codex🟡 2026-10-11）。
# ⚠️ `thread_not_found` は Slack の定義では「ts が欠落または無効」であって「親が削除された」とは
#   限らない。保存した channel が別チャンネルのIDに化けていれば、生きた親でもこれが返り得る。
#   現在の 69件は全て登録時の正しい channel を持つ（実測）ため即削除で運用するが、
#   状態が壊れた日に備えて **外した ts と理由は必ずログへ名指しで残す**（下の報告）。
GONE_ERRORS = ("thread_not_found",)
# 輪番走査：保持期限内でも全スレッドを毎tick走査すると conversations.replies の Tier 3 上限
# （約50回/分）を超えるため、「最終活動が RECENT_WINDOW_H 時間以内＝毎tick走査」
# 「それより古い＝SCAN_SHARDS 分の1ずつ輪番走査（thread_ts の剰余で機械的に分担）」にする。
# 古いスレッドへの返信も通常 tick間隔×SCAN_SHARDS（既定 2分×5=10分）以内に拾える＝非同期設計上は十分
# （tick が飛んだ回の担当シャードは次の巡回まで持ち越し）。
RECENT_WINDOW_H = 24
SCAN_SHARDS = 5
# 1回の fetch での conversations.replies 呼び出し上限（Tier 3≒50回/分の安全マージン。
# auth_test / conversations.history 数回分を除いて余裕を残す）。超過分は次tickの輪番に回る。
MAX_REPLY_CALLS_PER_FETCH = 40


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


@contextlib.contextmanager
def state_lock():
    """last-seen.json / threads.json の read-modify-write を直列化する。

    ★なぜ必要か（2026-08-19 Codexレビュー）：以前は「無人の書き手は agent-tick.sh の
      flock で直列化されるから実害はない」という前提でロックを持っていなかった。
      ところが (a) 取り込み(fetch)をメインロックの外へ出した (b) overseer は自分でも
      `slack-poll.py fetch` を実行する、の2点でその前提は成り立たない。
      ロック無しだと「fetch が古いスナップショットを読む → 別プロセスが新しい追跡スレッドを
      登録 → fetch が古い内容で書き戻す → **社長の返信が永久に届かない**」が起こる。
      os.replace は書きかけの破損を防ぐだけで、この上書きは防げない。
    ロックは**呼び出し側でなくここ**に置く＝どの経路から使われても必ず掛かる。
    """
    os.makedirs(SLACK_DIR, exist_ok=True)
    with open(os.path.join(SLACK_DIR, ".state.lock"), "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


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
    # 以下2つは memo と同じく fetch では追跡しない（False）：トップ投稿を ingest するだけで、
    # 会話を続けたいスレッドだけ各エージェントが reply 経由で追跡する（threads.json を肥大させない）。
    #
    # 相談チャンネル→talk。既定は従来の #partner（SLACK_PARTNER_CHANNEL_ID）＝社長の定位置を
    # そのまま相談窓口にする（2026-08-19）。**report より先に登録する**：同じIDを両方に設定して
    # しまった場合、先に登録されたほうが既定の受け先になるため、軽い talk が勝つ順序にしておく
    # （取り違えても $70 でなく $1 側に倒れる＝安全側の既定）。
    talk = get_env("SLACK_TALK_CHANNEL_ID") or get_env("SLACK_PARTNER_CHANNEL_ID")
    if talk and talk not in seen:
        out.append((talk, TALK_AGENT, False))
        seen.add(talk)
    # レポートch（日次/週次/月次）→partner。ここへの社長のトップ投稿は「レポートへの指摘」なので
    # 深掘りの partner が受ける。未設定なら対象に含めない（＝移行前は talk 側だけが動く）。
    report = get_env("SLACK_REPORT_CHANNEL_ID")
    if report and report not in seen:
        out.append((report, PARTNER_AGENT, False))
        seen.add(report)
    return out


def _resolve_channel(val):
    """--channel の値（alias main/memo または生ID）をチャンネルIDへ。未指定は None。"""
    if not val:
        return None
    if val == "main":
        return get_env("SLACK_CHANNEL_ID")
    if val == "memo":
        return get_env("SLACK_MEMO_CHANNEL_ID")
    if val == "talk" or val == "partner":
        # 相談ch（＝従来の #partner）。"partner" は移行期の別名として残す＝古い手順書や
        # 途中のスレッドが宛先無しで失敗しない。未設定なら既定チャンネルへフォールバック。
        return (get_env("SLACK_TALK_CHANNEL_ID") or get_env("SLACK_PARTNER_CHANNEL_ID")
                or get_env("SLACK_CHANNEL_ID"))
    if val == "report":
        # レポートch（日次/週次/月次）。未設定なら従来の #partner へ落とす＝移行途中でも
        # 朝礼が宛先無しで落ちない（黙って消えるより、見慣れた場所に出るほうが安全）。
        return (get_env("SLACK_REPORT_CHANNEL_ID") or get_env("SLACK_PARTNER_CHANNEL_ID")
                or get_env("SLACK_CHANNEL_ID"))
    return val


def _now_ts():
    return f"{datetime.now(JST).timestamp():.6f}"


def _max_ts(a, b):
    return a if float(a) >= float(b) else b


def load_channel_seen(channel):
    return _read_json(LAST_SEEN, {}).get(channel)


def save_channel_seen(channel, ts):
    with state_lock():
        data = _read_json(LAST_SEEN, {})
        data[channel] = ts
        _write_json(LAST_SEEN, data)


def register_thread(thread_ts, agent, last_seen, channel=None):
    """スレッドを追跡対象に登録（既存があれば agent/channel は保持、last_seen は据え置き）。

    channel は返信走査(conversations_replies)を正しいチャンネルで行うために記録する。
    未指定（既存仕様の呼び出し）なら省略＝走査時に既定チャンネルへフォールバック。

    read-modify-write は state_lock() で直列化する（2026-08-19）。以前は「agent-tick.sh の
    flock で直列化されるから不要」としていたが、取り込みをメインロックの外へ出したこと、
    および overseer が自分でも fetch することで、その前提は成り立たなくなった。
    """
    with state_lock():
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
    with state_lock():
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

    # --- (b0) 保持期限の判定（THREAD_RETENTION_DAYS 参照。削除はまだしない＝走査後） ---
    # Codexレビュー反映（2026-07-08）：期限切れ候補を即削除すると、輪番の谷間（最大10分＋tick skip）に
    # 届いた返信を走査前に消してしまう。候補は (b) で必ず強制走査し、新着が無かったものだけ (b2) で削除する。
    try:
        retention_days = float(get_env("SLACK_THREAD_RETENTION_DAYS") or THREAD_RETENTION_DAYS)
    except ValueError:
        retention_days = THREAD_RETENTION_DAYS
    now_epoch = datetime.now(JST).timestamp()
    cutoff = now_epoch - retention_days * 86400
    threads = _read_json(THREADS, {})

    def _activity(thread_ts, info):
        """(info_dict, last_activity, ts_broken) を返す。壊れた threads.json 値でも fetch を落とさない。"""
        if not isinstance(info, dict):
            info = {}
        try:
            ts_val = float(thread_ts)
        except (TypeError, ValueError):
            return info, 0.0, True   # ts 自体が壊れている＝Slackに問い合わせ不能・掃除対象
        try:
            seen_val = float(info.get("last_seen", ts_val))
        except (TypeError, ValueError):
            seen_val = ts_val        # last_seen だけ壊れている＝作成時刻にフォールバック（誤削除しない）
        return info, max(ts_val, seen_val), False

    expired_candidates = set()   # 期限超過（今tickで強制走査→新着なしなら削除）
    broken_ts = set()            # ts が壊れていて走査不能（即削除）
    for thread_ts, info in threads.items():
        _, last_activity, ts_bad = _activity(thread_ts, info)
        if ts_bad:
            broken_ts.add(thread_ts)
        elif last_activity < cutoff:
            expired_candidates.add(thread_ts)

    # --- (b) 追跡中スレッドの新着返信（新しい順に走査・古いものは輪番・1tickの呼び出し上限あり） ---
    main_ch = get_env("SLACK_CHANNEL_ID")
    shard = int(now_epoch // 120) % SCAN_SHARDS  # 2分tick前提のシャード番号。通常は最大 tick間隔×SCAN_SHARDS
    #                                              （既定10分）で全巡回。tickが飛んだ回のシャードは次巡回まで持ち越し
    skipped_rotation = 0
    skipped_budget = 0
    reply_calls = 0
    scanned_ok = set()           # replies 走査が成功したスレッド（期限候補の削除判定に使う）
    gone = {}                    # 親が存在しないスレッド {ts: エラーコード}＝走査不能なので untrack
    # 新しい順に走査：呼び出し上限で切れる場合も「返信が来やすい新しいスレッド」を優先する
    ordered = sorted(threads.items(), key=lambda kv: _activity(kv[0], kv[1])[1], reverse=True)
    for thread_ts, info in ordered:
        info, last_activity, ts_bad = _activity(thread_ts, info)
        if ts_bad:
            continue  # (b2) で削除
        is_expired = thread_ts in expired_candidates
        if (not is_expired                                  # 期限候補は輪番に関係なく最後に1回見る
                and now_epoch - last_activity > RECENT_WINDOW_H * 3600
                and int(last_activity) % SCAN_SHARDS != shard):
            skipped_rotation += 1  # 古いスレッドは今tickの担当シャードだけ走査（レート制限対策）
            continue
        if reply_calls >= MAX_REPLY_CALLS_PER_FETCH:
            skipped_budget += 1    # 上限超過分は次tickへ（期限候補も削除されず持ち越し＝安全側）
            continue
        t_seen = info.get("last_seen", thread_ts)
        agent = info.get("agent", DEFAULT_AGENT)
        t_channel = info.get("channel", main_ch)   # 旧データ（channel無し）は既定チャンネル
        reply_calls += 1
        try:
            r = w.conversations_replies(channel=t_channel, ts=thread_ts, oldest=t_seen,
                                        inclusive=False, limit=MAX_PER_POLL)
        except Exception as e:  # noqa: BLE001 — レート制限・スレッド消失等。スキップして継続
            # SlackApiError は本文の error コード（ratelimited / thread_not_found 等）が原因特定の鍵。
            # ★ data は dict だけでなく bytes のこともある（Slack SDK の SlackResponse.data）。
            #   `(data or {}).get(...)` だと非dictで AttributeError になり、**この except 節自身が
            #   落ちて fetch が丸ごと止まる**＝1本のスレッドをスキップするはずが全停止する
            #   （Codex🔴 2026-10-11・非JSONのエラーボディで再現）。
            _data = getattr(getattr(e, "response", None), "data", None)
            code = _data.get("error", "") if isinstance(_data, dict) else ""
            print(f"[warn] replies取得失敗 thread={thread_ts}: {code or e}", file=sys.stderr)
            # ★ 2026-10-11（O-078）：ここで continue するだけだと scanned_ok に入らず、
            #   (b2) の削除条件「強制走査で新着が無かった」を永久に満たさない＝毎tick
            #   同じ失敗を繰り返す。実害＝ts の小数部が欠けた1本（2026-07-31 作成）に対して
            #   thread_not_found が 1分おきに 1,527回。「存在しない」が確定するものは untrack する。
            if code in GONE_ERRORS:
                gone[thread_ts] = code
            continue
        scanned_ok.add(thread_ts)
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
            expired_candidates.discard(thread_ts)  # 期限間際に返信あり＝活動再開なので削除しない

    # --- (b2) 掃除の確定：①強制走査で新着が無かった期限候補 ②壊れた ts ③親が存在しないもの ---
    to_remove = {t for t in expired_candidates if t in scanned_ok} | broken_ts | set(gone)
    if gone:
        # 件数だけでは「何が消えたか」が後から追えない＝必ず ts と理由を名指しで残す
        for ts_, code in sorted(gone.items()):
            # ★ `(threads.get(ts_) or {}).get(...)` だと、値が空でない非dict（壊れた threads.json の
            #   「文字列になっている」行など）で AttributeError になり、**fetch が丸ごと落ちて
            #   untrack されず毎分同じ失敗を繰り返す**＝直したはずの O-078 が形を変えて復活する
            #   （Codex🔴 2026-10-11）。既存テストが守っている「非dictでも fetch を落とさない」を
            #   壊していた。
            _info = threads.get(ts_)
            agent_ = _info.get("agent", DEFAULT_AGENT) if isinstance(_info, dict) else DEFAULT_AGENT
            print(f"追跡を外しました thread={ts_}（{agent_}）：{code}＝親の投稿が存在しません")
    if to_remove:
        with state_lock():
            threads = _read_json(THREADS, {})  # 走査中の set_thread_seen を上書きしないよう読み直す
            for ts_ in to_remove:
                threads.pop(ts_, None)
            _write_json(THREADS, threads)
        print(f"追跡期限切れ {len(to_remove)} 件を untrack（保持 {retention_days:g}日・残り {len(threads)} 件）")

    if skipped_rotation or skipped_budget:
        print(f"（輪番走査：古いスレッド {skipped_rotation} 件スキップ／呼び出し上限 {MAX_REPLY_CALLS_PER_FETCH} 超過 {skipped_budget} 件＝次tick以降で走査）")
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
            # ★重複は即エラー（2026-08-19 Codexレビュー）：ここが「後勝ち」だと、
            #   呼び出し側のガードが最初の値を見て許可し、実行時は最後の値が使われる
            #   ＝検査時と実行時で主体が変わる（`--as talk ... --as overseer` で騙れる）。
            if agent is not None:
                sys.exit("ERROR: --as は1回だけ指定できます（重複指定は認めません）")
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
            if chan is not None:      # 重複禁止の理由は _pop_as と同じ（後勝ち偽装の封じ）
                sys.exit("ERROR: --channel は1回だけ指定できます（重複指定は認めません）")
            chan = val
            i += 2
            continue
        out.append(args[i])
        i += 1
    return chan, out


def _reject_unknown_flags(args, cmd):
    """★未知の --xxx を本文に飲み込まない（K-778・2026-09-10 hp-loop ycom で実害）★

    post / reply は --as・--channel を取り除いた残りをそのまま本文にするので、存在しないオプション
    （--thread-ts 等）を渡すと「--thread-ts 1.2 本文」が**社長チャンネルへ投稿**されていた。
    mailbox local-send の O-081（3ffbd5e で修理）と同型＝外部送信側に番人が居なかった。
    弾くのは -- に英字が続く形だけ＝「- 箇条書き」で始まる本文は通す。
    """
    for a in args:
        if a.startswith("--") and len(a) > 2 and a[2].isalpha():
            sys.exit(f"ERROR: {cmd}: 不明なオプション {a}（使えるのは --as / --channel だけ。"
                     "本文はそのまま渡すか標準入力で）＝投稿していません")


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
    """partner エージェントは「レポートch」と「相談ch」以外へ投稿させない。

    経営情報が他チャンネルや生ID指定で暴発するのをコード側で物理的に防ぐ
    （memo と対称・automation.md「外部送信暴発を潰す」）。

    2026-08-19、レポートを #report へ分離した。**相談ch（旧#partner）も許可に残す**のは、
    そこに partner が立てた過去の朝礼スレッドが残っており、社長がそこへ返信したとき
    partner が同じスレッドへ返せなくなる（＝会話が片道になる）のを防ぐため。
    どちらも元から partner の場所なので、許可範囲は実質広がっていない。
    """
    if agent != PARTNER_AGENT:
        return
    allowed = {c for c in (_resolve_channel("report"), _resolve_channel("talk")) if c}
    if channel not in allowed:
        sys.exit("ERROR: --as partner は #report（SLACK_REPORT_CHANNEL_ID）か "
                 "相談ch（SLACK_TALK_CHANNEL_ID／旧SLACK_PARTNER_CHANNEL_ID）へのみ投稿できます")


def _guard_talk_channel(agent, channel):
    """talk（相談役）は相談ch以外へ投稿させない。

    talk は軽い器で、判断材料を持たないまま素早く答える。だからこそ投稿先を1つに固定する
    ＝取り違えて #report やクライアント向けチャンネルへ出すことがコード上ありえないようにする。
    """
    if agent != TALK_AGENT:
        return
    allowed = _resolve_channel("talk")
    if not allowed or channel != allowed:
        sys.exit("ERROR: --as talk は相談ch（SLACK_TALK_CHANNEL_ID／旧SLACK_PARTNER_CHANNEL_ID）へのみ投稿できます")


def cmd_post(args):
    as_agent, args = _pop_as(args)
    chan_arg, args = _pop_channel(args)
    _reject_unknown_flags(args, "post")
    channel = _resolve_channel(chan_arg) or get_env("SLACK_CHANNEL_ID")
    if not channel:
        sys.exit("ERROR: 投稿先チャンネルが特定できません（--channel か .env を確認）")
    _guard_memo_channel(as_agent or DEFAULT_AGENT, channel)
    _guard_partner_channel(as_agent or DEFAULT_AGENT, channel)
    _guard_talk_channel(as_agent or DEFAULT_AGENT, channel)
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
    _reject_unknown_flags(args, "reply")
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
    _guard_talk_channel(owner, channel)   # post 側と対で必ず掛ける（片方だけだと抜け道になる）
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
    # ★自分宛の便しか処理済みにできない（2026-08-19 Codexレビュー）。
    #   これが無いと、外部入力に誘導された無人エージェントが他モード宛の便を done でき、
    #   その仕事は**二度とディスパッチされず黙って消える**（最も気づきにくい壊れ方）。
    #   MYAGENT_AGENT は agent-tick / talk-tick が無人起動時にだけ渡す＝有人セッションは従来どおり。
    me = os.environ.get("MYAGENT_AGENT", "")
    if me:
        try:
            with open(src, encoding="utf-8") as f:
                owner = (json.load(f) or {}).get("to", "")
        except Exception:
            owner = ""
        if owner != me:
            sys.exit(f"ERROR: {msg_id} は {owner or '不明'} 宛です。{me} は自分宛の便しか done できません")
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
    with state_lock():
        data = _read_json(THREADS, {})
        removed = data.pop(thread_ts, None) is not None
        if removed:
            _write_json(THREADS, data)
    if removed:
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
