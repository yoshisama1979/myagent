#!/usr/bin/env bash
# bin/slack-poll.py（agent-tick が毎tick呼ぶ Slack 取り込み）の回帰テスト。
#
# 契機＝2026-08-11、testing.md §7 の「無人ループが実行するツール 21本のうちテストが無い 13本」を
# 減らす作業の1本目。このツールを最優先にしたのは §2 の3条件すべてに当たるため＝
#   ①毎tick(2分)の無人ループから呼ばれる ②カーソル(last-seen.json / threads.json)を書く
#   ③判定を持つ（取り込み可否・チャンネルガード・保持期限・輪番走査）。
# 壊れ方はいつも「静か」：カーソルが巻き戻れば二重投函、進みすぎれば社長の返信を永久に取りこぼす。
# 実害の前例＝2026-07-08 に追跡138スレッドでレート制限に当たり、走査順の後ろ（＝新しいスレッド）
# ほど毎回失敗して返信を拾い損ねていた（→ 輪番走査と保持期限はその修理）。
#
# ⚠️ 秘密値は一切扱わない（架空のチャンネルID・架空のトークン名だけを一時ディレクトリに書く）。
#    本番の data/mailbox・data/slack・.env には触れない（冒頭で書き先を差し替え、外なら exit 2）。
# 触ったら必ず流すこと：bash bin/test-slack-poll.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/slack-poll.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

# 本番と同じ解釈系で流せるならそちらを使う（agent-tick.sh の PY と同じ venv）。
PY="$PROJ/bin/.venv/bin/python3"
[ -x "$PY" ] || PY=python3

"$PY" - "$PROJ" <<'PYEOF'
import contextlib, importlib.util, io, json, os, sys, tempfile, types
from datetime import datetime, timedelta, timezone
from pathlib import Path

proj = Path(sys.argv[1])

# slack_sdk は本番 venv(bin/.venv) にだけ入っている。素の python3 でも流せるよう、無ければ
# **名前だけの偽モジュール**を差し込む。WebClient の実体はこのテストで一度も生成しない
# （client() を丸ごと差し替えるため）＝本物・スタブどちらで流しても結果は同じ。
try:
    import slack_sdk  # noqa: F401
    SDK = "本物"
except ImportError:
    _m = types.ModuleType("slack_sdk")
    class _WebClient:                       # noqa: N801 — 本番と同じ名前だけ用意する
        def __init__(self, token=None):
            raise AssertionError("テストが実 Slack クライアントを作ろうとした")
    _m.WebClient = _WebClient
    sys.modules["slack_sdk"] = _m
    SDK = "スタブ"

spec = importlib.util.spec_from_file_location("slack_poll", proj / "bin/slack-poll.py")
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)

P = N = 0
def ok(m, d=""):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

# ---- 本番のファイルに触れない（testing.md §6-1）----
T = Path(tempfile.mkdtemp())
if not str(T).startswith("/tmp"):
    print(f"❌ テストの作業先が /tmp の外: {T}", file=sys.stderr); sys.exit(2)
sp.ENV_FILE      = str(T / ".env")
sp.SLACK_DIR     = str(T / "slack")
sp.LAST_SEEN     = str(T / "slack" / "last-seen.json")
sp.THREADS       = str(T / "slack" / "threads.json")
sp.MAILBOX_NEW   = str(T / "mailbox" / "new")
sp.MAILBOX_CUR   = str(T / "mailbox" / "cur")
sp.MAILBOX_STOCK = str(T / "mailbox" / "memo-stock")
for _p in (sp.ENV_FILE, sp.SLACK_DIR, sp.LAST_SEEN, sp.THREADS,
           sp.MAILBOX_NEW, sp.MAILBOX_CUR, sp.MAILBOX_STOCK):
    if not _p.startswith("/tmp"):
        print(f"❌ 書き先の差し替えに失敗: {_p}", file=sys.stderr); sys.exit(2)

MAIN, MEMO, PARTNER = "C_MAIN", "C_MEMO", "C_PARTNER"
ME = "UBOT"                                   # 自分（bot）の user_id
PRES = "UPRES"                                # 社長

def write_env(**kv):
    Path(sp.ENV_FILE).write_text(
        "".join(f"{k}={v}\n" for k, v in kv.items()), encoding="utf-8")

def reset(env=True):
    """状態ファイルとメールボックスを毎ケース初期化する。"""
    for d in (T / "slack", T / "mailbox"):
        if d.exists():
            for f in sorted(d.rglob("*"), reverse=True):
                f.unlink() if f.is_file() else f.rmdir()
            d.rmdir()
    if env:
        write_env(SLACK_CHANNEL_ID=MAIN)

def caught(fn, *a, **kw):
    """SystemExit を捕まえる（ガードは sys.exit で止める設計）。"""
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            fn(*a, **kw)
    except SystemExit as e:
        return str(e)
    return None

def run(fn, *a, **kw):
    """標準出力を吸って返す（cmd_* は print で報告する）。"""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fn(*a, **kw)
    return buf.getvalue()

print(f"=== .env の読み取り（slack_sdk={SDK}）===")
write_env(A="1", B="2")
(ok if sp.get_env("A") == "1" else ng)("キーの値を返す")
(ok if sp.get_env("NOPE") == "" else ng)("無いキーは空文字（例外にしない）")
write_env(A=' "1" ')
(ok if sp.get_env("A") == "1" else ng)("引用符と前後の空白を落とす")
Path(sp.ENV_FILE).write_text("A=1\r\nB=2\r\n", encoding="utf-8")
(ok if sp.get_env("A") == "1" else ng)("CRLF の末尾 CR を落とす（Windows で編集された .env）")
Path(sp.ENV_FILE).write_text("URL=https://x/?a=1&b=2\n", encoding="utf-8")
(ok if sp.get_env("URL") == "https://x/?a=1&b=2" else ng)("値の中の = を壊さない")
Path(sp.ENV_FILE).write_text("# A=9\nA=1\n", encoding="utf-8")
(ok if sp.get_env("A") == "1" else ng)("コメント行は拾わない")
Path(sp.ENV_FILE).write_text("TOKEN_SUB=x\nTOKEN=y\n", encoding="utf-8")
(ok if sp.get_env("TOKEN") == "y" else ng)("TOKEN_SUB を TOKEN と誤認しない")
# ⚠️ ここは _env.py（共有ヘルパー）と**規約が逆**＝あちらは「最初の定義」を採る。
#    このツールを _env.py へ移行するときに黙って挙動が変わる箇所なので、現状を固定しておく。
Path(sp.ENV_FILE).write_text("A=first\nA=second\n", encoding="utf-8")
(ok if sp.get_env("A") == "second" else ng)(
    "重複キーは**最後**が勝つ（_env.py は最初が勝つ＝移行時に変わる点として固定）")
os.remove(sp.ENV_FILE)
(ok if sp.get_env("A") == "" else ng)(".env が無くても空文字（落ちない）")

print("\n=== 投稿先チャンネルの決定 ===")
write_env(SLACK_CHANNEL_ID=MAIN, SLACK_MEMO_CHANNEL_ID=MEMO, SLACK_PARTNER_CHANNEL_ID=PARTNER)
(ok if sp._resolve_channel("main") == MAIN else ng)("alias main")
(ok if sp._resolve_channel("memo") == MEMO else ng)("alias memo")
(ok if sp._resolve_channel("partner") == PARTNER else ng)("alias partner")
(ok if sp._resolve_channel("C_RAW") == "C_RAW" else ng)("生のチャンネルIDはそのまま")
(ok if sp._resolve_channel("") is None else ng)("未指定は None")
write_env(SLACK_CHANNEL_ID=MAIN)
(ok if sp._resolve_channel("partner") == MAIN else ng)(
    "partner 未設定なら既定chへフォールバック（朝礼が宛先無しで失敗しない）")
(ok if sp._resolve_channel("memo") == "" else ng)("memo 未設定はフォールバックしない（暴発防止）")

print("\n=== 走査対象チャンネルの組み立て ===")
write_env(SLACK_CHANNEL_ID=MAIN)
(ok if sp.channels() == [(MAIN, sp.DEFAULT_AGENT, True)] else ng)("既定chのみ＝従来どおり1本")
write_env(SLACK_CHANNEL_ID=MAIN, SLACK_MEMO_CHANNEL_ID=MEMO, SLACK_PARTNER_CHANNEL_ID=PARTNER)
got = sp.channels()
(ok if got == [(MAIN, sp.DEFAULT_AGENT, True), (MEMO, sp.MEMO_AGENT, False),
               (PARTNER, sp.PARTNER_AGENT, False)] else ng)(
    "3ch＝それぞれの受け先agent、追跡は既定chだけ True", got)
write_env(SLACK_CHANNEL_ID=MAIN, SLACK_MEMO_CHANNEL_ID=MAIN)
(ok if len(sp.channels()) == 1 else ng)("同じIDを2役に設定しても1つに畳む（二重取り込み防止）")

print("\n=== 新着判定 ===")
(ok if sp._max_ts("10.000000", "9.000000") == "10.000000" else ng)(
    "カーソル比較は数値（文字列比較だと 9 > 10 になり巻き戻る）")
(ok if sp._max_ts("1.000002", "1.000010") == "1.000010" else ng)("小数部も数値で比較")
(ok if sp._max_ts("5.0", "5.0") == "5.0" else ng)("同値ならそのまま")
mk = lambda **kw: {**{"ts": "1.0", "user": PRES}, **kw}
(ok if sp._ingestable(mk(), ME) else ng)("社長の通常投稿は取り込む")
(ok if not sp._ingestable(mk(user=ME), ME) else ng)("自分の投稿は取り込まない（自己ループ防止）")
(ok if not sp._ingestable(mk(bot_id="B1"), ME) else ng)("bot投稿は取り込まない")
(ok if not sp._ingestable(mk(subtype="channel_join"), ME) else ng)("参加通知等のsubtypeは取り込まない")
(ok if not sp._ingestable(mk(user=""), ME) else ng)("user不明は取り込まない")
(ok if not sp._ingestable({"user": PRES}, ME) else ng)("ts が無いものは取り込まない")

print("\n=== 引数の取り出し ===")
(ok if sp._pop_as(["--as", "memo", "本文"]) == ("memo", ["本文"]) else ng)("--as を取り除いて返す")
(ok if sp._pop_as(["本文"]) == (None, ["本文"]) else ng)("--as 無指定は None（後方互換）")
(ok if caught(sp._pop_as, ["--as"]) else ng)("--as の値が無ければエラーで止まる")
(ok if caught(sp._pop_as, ["--as", "--channel", "main"]) else ng)(
    "--as にフラグ様の値を持ち主として保存させない")
(ok if sp._pop_channel(["--channel", "memo", "本文"]) == ("memo", ["本文"]) else ng)("--channel を取り除く")
(ok if caught(sp._pop_channel, ["--channel"]) else ng)("--channel の値が無ければエラーで止まる")
got = sp._pop_channel(["--channel", "main", "a", "b", "c"])[1]
(ok if got == ["a", "b", "c"] else ng)("本文の語順を保つ", got)

print("\n=== 外部送信の暴発ガード（automation.md）===")
write_env(SLACK_CHANNEL_ID=MAIN, SLACK_MEMO_CHANNEL_ID=MEMO, SLACK_PARTNER_CHANNEL_ID=PARTNER)
(ok if caught(sp._guard_memo_channel, "memo", MEMO) is None else ng)("memo → #memo は通す")
(ok if caught(sp._guard_memo_channel, "memo", MAIN) else ng)("memo → 既定ch は止める（日常メモの暴発）")
(ok if caught(sp._guard_memo_channel, "memo", "C_OTHER") else ng)("memo → 生ID指定も止める")
(ok if caught(sp._guard_memo_channel, sp.DEFAULT_AGENT, MAIN) is None else ng)("他エージェントは対象外")
(ok if caught(sp._guard_partner_channel, "partner", PARTNER) is None else ng)("partner → #partner は通す")
(ok if caught(sp._guard_partner_channel, "partner", MAIN) else ng)("partner → 既定ch は止める（経営情報の暴発）")
write_env(SLACK_CHANNEL_ID=MAIN)
(ok if caught(sp._guard_partner_channel, "partner", MAIN) is None else ng)(
    "partner 未設定時は既定chのみ許可")
(ok if caught(sp._guard_partner_channel, "partner", "C_OTHER") else ng)(
    "partner 未設定でも他chへは出さない")
write_env(SLACK_CHANNEL_ID=MAIN, SLACK_PARTNER_CHANNEL_ID=PARTNER)
(ok if caught(sp._guard_memo_channel, "memo", MEMO) else ng)(
    "memo 未設定なら memo はどこへも投稿できない（既定chへ落ちない）")

print("\n=== カーソル（last-seen.json / threads.json）===")
reset()
sp.save_channel_seen(MAIN, "100.000000")
(ok if sp.load_channel_seen(MAIN) == "100.000000" else ng)("チャンネルカーソルを保存・再読込")
sp.save_channel_seen(MEMO, "200.000000")
(ok if sp.load_channel_seen(MAIN) == "100.000000" else ng)("チャンネルごとに独立して持つ")
(ok if sp.load_channel_seen("C_NEW") is None else ng)("未知チャンネルは None（＝初期化扱い）")
(ok if not [f for f in os.listdir(T / "slack") if f.endswith(".tmp")] else ng)(
    "書き込み後に .tmp を残さない（os.replace で原子的）")
Path(sp.LAST_SEEN).write_text("{壊れた", encoding="utf-8")
(ok if sp.load_channel_seen(MAIN) is None else ng)("壊れた JSON でも落ちない（既定値へ）")

reset()
sp.register_thread("10.0", "hp-loop", "10.0", MAIN)
d = json.loads(Path(sp.THREADS).read_text(encoding="utf-8"))
(ok if d["10.0"] == {"agent": "hp-loop", "last_seen": "10.0", "channel": MAIN} else ng)(
    "スレッドを持ち主とチャンネル付きで登録", d)
sp.set_thread_seen("10.0", "11.0")
sp.register_thread("10.0", "partner", "10.0", MEMO)
d = json.loads(Path(sp.THREADS).read_text(encoding="utf-8"))["10.0"]
(ok if d["agent"] == "hp-loop" else ng)("再登録で持ち主を奪わない（setdefault）", d)
(ok if d["channel"] == MAIN else ng)("再登録でチャンネルも書き換えない", d)
(ok if d["last_seen"] == "11.0" else ng)("再登録でカーソルを巻き戻さない（取りこぼし防止）", d)
sp.set_thread_seen("99.0", "1.0")
(ok if "99.0" not in json.loads(Path(sp.THREADS).read_text(encoding="utf-8")) else ng)(
    "未登録スレッドに set_thread_seen しても作らない")
(ok if sp.agent_for_thread("10.0") == "hp-loop" else ng)("スレッドの持ち主を引ける")
(ok if sp.agent_for_thread("nope") == sp.DEFAULT_AGENT else ng)("未知スレッドは既定の受け先")

print("\n=== mailbox への投函 ===")
reset()
msg = {"ts": "1723300000.000123", "user": PRES, "text": "一行目です\n二行目"}
mid = sp.write_mailbox(MAIN, msg, "partner")
body = json.loads(Path(sp.MAILBOX_NEW, f"{mid}.json").read_text(encoding="utf-8"))
(ok if mid and mid.startswith("M-") and mid.endswith("-president-000123") else ng)(
    "msg_id は 時刻＋president＋Slack ts の下6桁", mid)
(ok if body["from"] == "president" and body["to"] == "partner" else ng)("差出人・宛先", body)
(ok if body["subject"] == "一行目です" else ng)("件名は本文の1行目", body["subject"])
(ok if body["thread"] == "slack-1723300000.000123" else ng)("thread_ts 無しなら自分の ts をスレッドに")
(ok if body["needs_approval"] is False else ng)("取り込み時点では承認待ちにしない")
(ok if sp.write_mailbox(MAIN, msg, "partner") is None else ng)(
    "同じSlackイベントを二重投函しない（new/ に既にある）")
os.replace(Path(sp.MAILBOX_NEW, f"{mid}.json"), Path(sp.MAILBOX_CUR).joinpath(f"{mid}.json")
           if os.makedirs(sp.MAILBOX_CUR, exist_ok=True) is None else None)
(ok if sp.write_mailbox(MAIN, msg, "partner") is None else ng)(
    "処理済み(cur/)に移った後も再投函しない（カーソル保存前のクラッシュ対策）")
os.makedirs(sp.MAILBOX_STOCK, exist_ok=True)
os.replace(Path(sp.MAILBOX_CUR, f"{mid}.json"), Path(sp.MAILBOX_STOCK, f"{mid}.json"))
(ok if sp.write_mailbox(MAIN, msg, "partner") is None else ng)(
    "退避中(memo-stock/)でも再投函しない")
reset()
mid = sp.write_mailbox(MEMO, {"ts": "1723300001.000000", "user": PRES, "text": ""}, "memo")
b = json.loads(Path(sp.MAILBOX_NEW, f"{mid}.json").read_text(encoding="utf-8"))
(ok if b["subject"] == "(本文のみ)" else ng)("本文が空でも件名を作る", b["subject"])
mid = sp.write_mailbox(MAIN, {"ts": "1723300002.000000", "user": PRES, "text": "あ" * 80,
                              "thread_ts": "1723200000.000000"}, "partner")
b = json.loads(Path(sp.MAILBOX_NEW, f"{mid}.json").read_text(encoding="utf-8"))
(ok if len(b["subject"]) == 60 else ng)("長い1行目は60字で切る", len(b["subject"]))
(ok if b["thread"] == "slack-1723200000.000000" else ng)("返信は親スレッドに紐づく")
(ok if b["body"] == "あ" * 80 else ng)("本文そのものは切らない")
(ok if not [f for f in os.listdir(sp.MAILBOX_NEW) if f.startswith(".")] else ng)(
    "投函後に .tmp を残さない")

print("\n=== 処理済みの移動（done / stock / untrack）===")
reset()
os.makedirs(sp.MAILBOX_NEW, exist_ok=True)
Path(sp.MAILBOX_NEW, "M-1.json").write_text("{}", encoding="utf-8")
run(sp.cmd_done, ["M-1"])
(ok if os.path.isfile(os.path.join(sp.MAILBOX_CUR, "M-1.json")) else ng)("new/ → cur/ へ移す")
os.makedirs(sp.MAILBOX_STOCK, exist_ok=True)
Path(sp.MAILBOX_STOCK, "M-2.json").write_text("{}", encoding="utf-8")
run(sp.cmd_done, ["M-2"])
(ok if os.path.isfile(os.path.join(sp.MAILBOX_CUR, "M-2.json")) else ng)("memo-stock/ → cur/ へも移す")
(ok if caught(sp.cmd_done, ["M-404"]) else ng)("存在しない ID はエラーで止まる（黙って成功しない）")
(ok if caught(sp.cmd_done, []) else ng)("引数無しはエラー")
Path(sp.MAILBOX_NEW, "M-3.json").write_text("{}", encoding="utf-8")
run(sp.cmd_stock, ["M-3"])
(ok if os.path.isfile(os.path.join(sp.MAILBOX_STOCK, "M-3.json"))
      and not os.path.isfile(os.path.join(sp.MAILBOX_NEW, "M-3.json")) else ng)(
    "stock は new/ から外す（triage の再起動・再質問を止める）")
(ok if caught(sp.cmd_stock, ["M-3"]) else ng)("stock 済みを再度 stock しない")
sp.register_thread("50.0", "memo", "50.0", MEMO)
out = run(sp.cmd_untrack, ["50.0"])
(ok if "50.0" not in json.loads(Path(sp.THREADS).read_text(encoding="utf-8")) else ng)("untrack で外れる")
out = run(sp.cmd_untrack, ["404.0"])
(ok if "スキップ" in out else ng)("未追跡の untrack は落ちずにスキップと報告", out.strip())

print("\n=== fetch を丸ごと回す（偽Slack API）===")
NOW = datetime.now(sp.JST).timestamp()
def ts(offset_sec):
    """現在からの相対秒で Slack ts 文字列を作る。"""
    return f"{NOW + offset_sec:.6f}"

class Fake:
    def __init__(self, tops=None, replies=None, fail=()):
        self.tops, self.replies, self.fail = tops or {}, replies or {}, set(fail)
        self.hist, self.reps = [], []
    def auth_test(self):
        return {"user_id": ME}
    def conversations_history(self, channel, oldest, inclusive, limit):
        self.hist.append((channel, oldest))
        return {"messages": list(self.tops.get(channel, []))}
    def conversations_replies(self, channel, ts, oldest, inclusive, limit):
        self.reps.append((channel, ts, oldest))
        if ts in self.fail:
            raise RuntimeError("ratelimited")
        return {"messages": list(self.replies.get(ts, []))}

def fetch(fake, args=None):
    sp.client = lambda: fake
    return run(sp.cmd_fetch, args or [])

def new_count():
    return len(os.listdir(sp.MAILBOX_NEW)) if os.path.isdir(sp.MAILBOX_NEW) else 0

reset()
f = Fake(tops={MAIN: [{"ts": ts(-60), "user": PRES, "text": "過去の投稿"}]})
out = fetch(f)
(ok if not f.hist else ng)("初回は履歴を1回も読まない（過去を遡らない）", f.hist)
(ok if sp.load_channel_seen(MAIN) is not None else ng)("初回でカーソルを現在時刻に置く")
(ok if new_count() == 0 else ng)("初回に過去の投稿を投函しない")

reset()
sp.save_channel_seen(MAIN, ts(-300))
f = Fake(tops={MAIN: [{"ts": ts(-100), "user": PRES, "text": "新着A"},
                      {"ts": ts(-50), "user": PRES, "text": "新着B"},
                      {"ts": ts(-400), "user": PRES, "text": "カーソルより古い"},
                      {"ts": ts(-60), "user": ME, "text": "自分の投稿"}]})
out = fetch(f)
(ok if new_count() == 2 else ng)("カーソル以降の社長投稿だけを投函（古い・自分の分は除く）", out)
(ok if sp.load_channel_seen(MAIN) == ts(-50) else ng)("カーソルは最新の ts まで進む")
tracked = json.loads(Path(sp.THREADS).read_text(encoding="utf-8"))
(ok if len(tracked) == 2 and all(v["agent"] == sp.DEFAULT_AGENT for v in tracked.values()) else ng)(
    "既定chの新規トップ投稿は会話担当のスレッドとして追跡開始", tracked)
out2 = fetch(Fake(tops={MAIN: []}))
(ok if "新着なし" in out2 and new_count() == 2 else ng)("2回目は新着なし＝二重投函しない", out2.strip())

reset()
write_env(SLACK_CHANNEL_ID=MAIN, SLACK_MEMO_CHANNEL_ID=MEMO)
sp.save_channel_seen(MAIN, ts(-300)); sp.save_channel_seen(MEMO, ts(-300))
f = Fake(tops={MAIN: [{"ts": ts(-100), "user": PRES, "text": "会話"}],
               MEMO: [{"ts": ts(-90), "user": PRES, "text": "日常メモ"}]})
fetch(f)
tos = sorted(json.loads(Path(sp.MAILBOX_NEW, n).read_text(encoding="utf-8"))["to"]
             for n in os.listdir(sp.MAILBOX_NEW))
(ok if tos == [sp.DEFAULT_AGENT, sp.MEMO_AGENT] else ng)("チャンネル別に受け先を振り分ける", tos)
tracked = json.loads(Path(sp.THREADS).read_text(encoding="utf-8"))
(ok if len(tracked) == 1 else ng)(
    "#memo のトップ投稿は自動追跡しない（threads.json を1日単位で有界に保つ）", tracked)
write_env(SLACK_CHANNEL_ID=MAIN)

reset()
sp.save_channel_seen(MAIN, ts(-10))
sp.register_thread(ts(-3600), "hp-loop", ts(-3600), MAIN)
th = ts(-3600)
f = Fake(replies={th: [{"ts": th, "user": PRES, "text": "親（既読）"},
                       {"ts": ts(-30), "user": PRES, "text": "社長の返信"}]})
fetch(f)
b = [json.loads(Path(sp.MAILBOX_NEW, n).read_text(encoding="utf-8")) for n in os.listdir(sp.MAILBOX_NEW)]
(ok if len(b) == 1 and b[0]["to"] == "hp-loop" else ng)(
    "スレッド返信はそのスレッドの持ち主へ届く", b)
(ok if json.loads(Path(sp.THREADS).read_text(encoding="utf-8"))[th]["last_seen"] == ts(-30) else ng)(
    "返信を取り込んだらスレッドのカーソルも進む")

reset()
sp.save_channel_seen(MAIN, ts(-10))
th = ts(-3600)
sp.register_thread(th, "hp-loop", th, MAIN)
f = Fake(fail=[th])
out = fetch(f)
(ok if json.loads(Path(sp.THREADS).read_text(encoding="utf-8"))[th]["last_seen"] == th else ng)(
    "返信取得に失敗したスレッドのカーソルは進めない（取りこぼし防止）")
(ok if th in json.loads(Path(sp.THREADS).read_text(encoding="utf-8")) else ng)(
    "取得失敗でスレッドを消さない")

print("\n--- 保持期限の掃除（2026-07-08 レート制限修理の不変条件）---")
DAY = 86400
reset()
sp.save_channel_seen(MAIN, ts(-10))
old = ts(-20 * DAY)                      # 保持期限 14日 を超過
sp.register_thread(old, "hp-loop", old, MAIN)
f = Fake(replies={old: []})
out = fetch(f)
(ok if any(c[1] == old for c in f.reps) else ng)(
    "期限切れ候補も削除前に必ず1回は走査する（輪番の谷間に届いた返信を消さない）")
(ok if old not in json.loads(Path(sp.THREADS).read_text(encoding="utf-8")) else ng)(
    "走査して新着が無ければ untrack する")

reset()
sp.save_channel_seen(MAIN, ts(-10))
old = ts(-20 * DAY)
sp.register_thread(old, "hp-loop", old, MAIN)
f = Fake(replies={old: [{"ts": ts(-30), "user": PRES, "text": "期限間際の返信"}]})
fetch(f)
(ok if old in json.loads(Path(sp.THREADS).read_text(encoding="utf-8")) else ng)(
    "期限超過でも返信が来ていたら残す（活動再開）")
(ok if new_count() == 1 else ng)("その返信は取り込む")

reset()
sp.save_channel_seen(MAIN, ts(-10))
old = ts(-20 * DAY)
sp.register_thread(old, "hp-loop", old, MAIN)
fetch(Fake(fail=[old]))
(ok if old in json.loads(Path(sp.THREADS).read_text(encoding="utf-8")) else ng)(
    "走査に失敗した期限切れ候補は消さない（安全側・次tickへ持ち越し）")

reset()
sp.save_channel_seen(MAIN, ts(-10))
Path(sp.THREADS).write_text(json.dumps({
    "こわれたts": {"agent": "x", "last_seen": "1.0"},
    ts(-100): "文字列になっている",
    ts(-200): {"agent": "hp-loop", "last_seen": "壊れた値"},
}, ensure_ascii=False), encoding="utf-8")
f = Fake()
out = fetch(f)
left = json.loads(Path(sp.THREADS).read_text(encoding="utf-8"))
(ok if "こわれたts" not in left else ng)("ts 自体が壊れた行は掃除する（Slackに問い合わせ不能）")
(ok if ts(-100) in left else ng)("値が dict でない行があっても fetch を落とさない")
(ok if ts(-200) in left else ng)("last_seen だけ壊れている行は誤削除しない（作成時刻へフォールバック）")

print("\n--- 輪番走査と呼び出し上限（レート制限の予防）---")
reset()
sp.save_channel_seen(MAIN, ts(-10))
# 「24時間より古く、保持期限内」＝輪番の対象。剰余が異なる5本を置くと、1tickでは1本だけ走査される。
picked = {}
for k in range(sp.SCAN_SHARDS):
    base = int(NOW - 3 * DAY)
    cand = next(x for x in range(base, base + 100) if x % sp.SCAN_SHARDS == k)
    picked[k] = f"{cand}.000000"
    sp.register_thread(picked[k], "hp-loop", picked[k], MAIN)
f = Fake()
out = fetch(f)
(ok if len(f.reps) == 1 else ng)(
    f"古いスレッドは {sp.SCAN_SHARDS} 分の1ずつ輪番で走査（{len(f.reps)}本走査）", out.strip())
(ok if "スキップ" in out else ng)("スキップ件数を報告する（黙って見送らない）", out.strip())

reset()
sp.save_channel_seen(MAIN, ts(-10))
for i in range(sp.MAX_REPLY_CALLS_PER_FETCH + 5):
    t = ts(-100 - i)                       # 24時間以内＝毎tick走査の対象
    sp.register_thread(t, "hp-loop", t, MAIN)
f = Fake()
out = fetch(f)
(ok if len(f.reps) == sp.MAX_REPLY_CALLS_PER_FETCH else ng)(
    f"1tickの replies 呼び出しは {sp.MAX_REPLY_CALLS_PER_FETCH} 回で頭打ち", len(f.reps))
(ok if "上限" in out else ng)("上限超過を報告する（次tickへ持ち越し）", out.strip())

print("\n=== 既定chが未設定なら動かない（後方互換の不変条件）===")
reset(env=False)
write_env(SLACK_MEMO_CHANNEL_ID=MEMO)
(ok if caught(sp.cmd_fetch, []) else ng)(
    "SLACK_CHANNEL_ID 未設定なら fetch は止まる（旧threadが空chへフォールバックするのを防ぐ）")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
