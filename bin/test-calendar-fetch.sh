#!/usr/bin/env bash
# カレンダー取得（bin/calendar-fetch.py）の回帰テスト。
#
# 契機＝2026-08-03 Codex レビュー。実機で「今日・明日が出た」ことは確認したが、
# それは当日の予定が2件しか無かったから通っただけで、境界条件は保証していなかった。
# とくに「指定外のカレンダーに触れない」は許可リストの解析が唯一の砦なので、ここを固定する。
#
# 触ったら必ず流すこと：bash bin/test-calendar-fetch.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/calendar-fetch.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import importlib.util, json, os, sys, tempfile
from datetime import datetime, timedelta
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("cf", proj / "bin/calendar-fetch.py")
cf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cf)

P = N = 0
def ok(m):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

T = Path(tempfile.mkdtemp())
cf.DATA = T
cf.CAL_LIST = T / "calendars.md"
cf.OUT_FILE = T / "events.json"
cf.STATUS_FILE = T / "fetch-status.json"

# 本物のファイルを触っていないことを必ず確かめる（テストが本番を壊さない）
for p in (cf.CAL_LIST, cf.OUT_FILE, cf.STATUS_FILE):
    if not str(p).startswith(str(T)):
        print(f"❌ テストの書き先が一時ディレクトリの外: {p}", file=sys.stderr); sys.exit(2)


def load(text):
    cf.CAL_LIST.write_bytes(text if isinstance(text, bytes) else text.encode("utf-8"))
    return cf.load_calendars()


def dies(text, why):
    try:
        load(text)
    except SystemExit:
        ok(why); return
    ng(why, "異常終了しなかった＝そのまま API に送ってしまう")


print("=== 許可リスト（触れるカレンダーを決める唯一の砦）===")

r = load("abc@group.calendar.google.com  # 仕事用\n")
(ok if r == [("abc@group.calendar.google.com", "仕事用")] else ng)(f"通常の1行を読める（{r}）")

# BOM 付きで保存されると、先頭行がコメント扱いされず BOM が ID になる（実際に起きた）
r = load(b"\xef\xbb\xbf# \xe3\x82\xb3\xe3\x83\xa1\xe3\x83\xb3\xe3\x83\x88\nabc@x.com  # A\n")
(ok if r == [("abc@x.com", "A")] else ng)(f"BOM 付きでも壊れない（{r}）")

# 祝日カレンダーは ID 自体に # を含む＝# でコメントを切ると ID が壊れる
r = load("ja.japanese#holiday@group.v.calendar.google.com  # 祝日\n")
(ok if r and r[0][0] == "ja.japanese#holiday@group.v.calendar.google.com"
   else ng)(f"ID に含まれる # で切断しない（{r}）")

dies("primary  # 既定カレンダー\n", "primary は拒否する（私生活側を読む恐れ）")
dies("PRIMARY\n", "primary は大文字でも拒否する")
dies("a@x.com  # A\na@x.com  # B\n", "重複したIDは拒否する（同じ予定を二重に数えない）")
dies("これはIDではない\n", "@ を含まない行は拒否する")
dies("a　b@x.com\n", "全角空白を含むIDは拒否する")

r = load("# 全部コメント\n\n   \n")
(ok if r == [] else ng)(f"コメントと空行だけなら空（{r}）")

print("\n=== 日付の判定（予定が静かに消えない）===")


def show(events, fetched=None, errors=None):
    """cmd_show を走らせて (出力, 終了コード) を返す"""
    import io, contextlib
    cf.OUT_FILE.write_text(json.dumps({
        "fetched_at": (fetched or datetime.now(cf.JST)).isoformat(),
        "calendars": ["テスト"], "errors": errors or [], "events": events}), encoding="utf-8")
    buf = io.StringIO()
    code = 0
    try:
        with contextlib.redirect_stdout(buf):
            cf.cmd_show()
    except SystemExit as e:
        code = e.code or 0
    return buf.getvalue(), code


today = datetime.now(cf.JST).date()
tomorrow = today + timedelta(days=1)


def ev(summary, start, end, all_day=False, busy=True):
    return {"summary": summary, "start": start, "end": end, "all_day": all_day,
            "busy": busy, "location": "", "calendar": "テスト"}


out, _ = show([ev("通常", f"{today}T11:00:00+09:00", f"{today}T12:00:00+09:00")])
(ok if "通常" in out else ng)("当日の時刻付き予定が出る")

# 複数日にまたがる終日予定＝開始日だけで判定すると2日目以降が消える
out, _ = show([ev("連泊出張", str(today - timedelta(days=1)), str(tomorrow + timedelta(days=1)), all_day=True)])
(ok if out.count("連泊出張") == 2 else ng)(f"またぐ終日予定が今日・明日の両方に出る（{out.count('連泊出張')}回）")

# UTC 表記（日本の夜＝UTCでは前日）
out, _ = show([ev("UTC表記", f"{today}T13:00:00Z", f"{today}T14:00:00Z")])
(ok if "UTC表記" in out else ng)("UTC 表記の予定も当日として出る")

# 深夜をまたぐ
out, _ = show([ev("深夜またぎ", f"{today}T23:00:00+09:00", f"{tomorrow}T01:00:00+09:00")])
(ok if out.count("深夜またぎ") == 2 else ng)(f"深夜をまたぐ予定は両日に出る（{out.count('深夜またぎ')}回）")

out, _ = show([ev("明後日", str(today + timedelta(days=2)), str(today + timedelta(days=3)), all_day=True)])
(ok if "明後日" not in out and "予定なし" in out else ng)("対象外の日の予定は出さない")

print("\n=== 古いデータ・壊れたデータで黙って進まない ===")

out, code = show([ev("昨日取得", f"{today}T11:00:00+09:00", f"{today}T12:00:00+09:00")],
                 fetched=datetime.now(cf.JST) - timedelta(days=1))
(ok if "未取得" in out and code != 0 else ng)(f"前日取得なら『未取得』と言い、非0で終わる（code={code}）")

out, code = show([], errors=["取得失敗"])
(ok if "未取得" in out and code != 0 else ng)(f"取得エラーがあれば『未取得』扱い（code={code}）")

cf.OUT_FILE.write_text("{壊れたJSON", encoding="utf-8")
try:
    cf.cmd_show(); ng("壊れたファイルで異常終了する")
except SystemExit as e:
    (ok if e.code else ng)("壊れたファイルは分かりやすく異常終了する")

print("\n=== 権限 ===")
cf.atomic_write(cf.OUT_FILE, "{}", secret=True)
mode = oct(os.stat(cf.OUT_FILE).st_mode & 0o777)
(ok if mode == "0o600" else ng)(f"予定ファイルは 0600（{mode}）")
dmode = oct(os.stat(T).st_mode & 0o777)
(ok if dmode == "0o700" else ng)(f"保存先ディレクトリは 0700（{dmode}）")

print("\n=== 書き込み系を使っていない ===")
src = (proj / "bin/calendar-fetch.py").read_text(encoding="utf-8")
bad = [w for w in ("events().insert", "events().update", "events().delete",
                   "events().patch", "calendars().insert", "calendars().delete") if w in src]
(ok if not bad else ng)(f"作成・変更・削除の API を呼んでいない（{bad or 'なし'}）")
(ok if "calendar.readonly" in src and "auth/calendar\"" not in src
   else ng)("スコープは calendar.readonly のみ")

print("\n=== 失敗の通知（静かに壊れない）===")
# 契機＝2026-08-17。カレンダーの OAuth が 8/11 に失効し、fetch-status.json には
# 毎朝 失敗が記録されていたのに 7日間 誰も気づかなかった（社長が「今見れないの?」と
# 聞いて初めて発覚）。記録するだけでは穴は塞がらない＝鳴らすところまでを機械で持つ。
# ただし壊れっぱなしの間ずっと毎朝鳴らすと警報疲れで無視されるので、間引きを固定する。
# 本物の Slack を物理的に叩けなくする（stub 関数の差し替えを忘れても飛ばない）
cf.SLACK_SH = T / "slack-stub-not-exist.sh"
if not str(cf.SLACK_SH).startswith(str(T)):
    print("❌ Slack の送信先が一時ディレクトリの外", file=sys.stderr); sys.exit(2)
try:
    cf.send_slack("これは飛んではいけない")
    ng("実体の無い slack.sh なら送信は失敗する（＝本番に飛ばない）")
except Exception:
    ok("テスト中は本物の Slack を叩けない（送信先が実在しない）")

NOW = datetime(2026, 8, 17, 6, 55, tzinfo=cf.JST)
def iso(d): return d.isoformat()

d = cf.notify_decision(None, NOW)
(ok if d["send"] else ng)("初回の失敗は必ず鳴らす")
(ok if d["first_failed_at"] == iso(NOW) else ng)("初回は first_failed_at に今を入れる")
(ok if d["days_down"] == 0 else ng)(f"初回の days_down は 0（{d['days_down']}）")

# 現に本番に置かれている旧形式（failed_at と errors だけ）を食わせる
old = {"failed_at": iso(NOW - timedelta(days=6)), "errors": ["RefreshError"]}
d = cf.notify_decision(old, NOW)
(ok if d["send"] else ng)("旧形式（notified_at 無し）は未通知とみなして鳴らす")
(ok if d["first_failed_at"] == old["failed_at"] else ng)("旧形式でも failed_at を継続起点として引き継ぐ")
(ok if d["days_down"] == 6 else ng)(f"継続日数を数える（{d['days_down']}）")

base = {"first_failed_at": iso(NOW - timedelta(days=10))}
d = cf.notify_decision({**base, "notified_at": iso(NOW)}, NOW)
(ok if not d["send"] else ng)("同じ日に二度は鳴らさない")
d = cf.notify_decision({**base, "notified_at": iso(NOW - timedelta(days=2))}, NOW)
(ok if not d["send"] else ng)("2日後はまだ鳴らさない（間引きの境界・内側）")
d = cf.notify_decision({**base, "notified_at": iso(NOW - timedelta(days=3))}, NOW)
(ok if d["send"] else ng)("3日空いたら鳴らし直す（間引きの境界・外側）")
(ok if d["first_failed_at"] == base["first_failed_at"] else ng)("鳴らし直しても継続起点は動かさない")

for broken in ({}, {"first_failed_at": "こわれた日付"}, {"notified_at": None}):
    try:
        d = cf.notify_decision(broken, NOW)
        (ok if d["send"] else ng)(f"壊れた状態は初回扱いで鳴らす（{broken}）")
    except Exception as e:
        ng(f"壊れた状態で例外を出さない（{broken}）", f"{type(e).__name__}: {e}")

(ok if cf.recovery_decision({"notified_at": iso(NOW)}) else ng)("壊れたと知らせた相手には復旧も知らせる")
(ok if not cf.recovery_decision({"first_failed_at": iso(NOW)}) else ng)("一度も鳴らしていなければ復旧も鳴らさない")
(ok if not cf.recovery_decision(None) else ng)("そもそも壊れていなければ復旧を鳴らさない")

# 送信が落ちても取得処理を巻き込まない（cron で毎朝 exit する事故を作らない）
sent = []
def boom(text):
    sent.append(text); raise RuntimeError("webhook 落ちてる")
real, cf.send_slack = cf.send_slack, boom
try:
    cf.notify_failure({"first_failed_at": iso(NOW)}, NOW, ["RefreshError: invalid_grant"])
    ok("通知が失敗しても例外を投げない")
except Exception as e:
    ng("通知が失敗しても例外を投げない", f"{type(e).__name__}: {e}")
cf.send_slack = real
(ok if sent and "カレンダー" in sent[0] else ng)("通知本文に対象（カレンダー）が入る")
(ok if sent and "invalid_grant" in sent[0] else ng)("通知本文に原因が入る＝受け取った人が次の手を選べる")
(ok if sent and "calendar-fetch.py login" in sent[0] else ng)("通知本文に復旧コマンドが入る")

# 状態ファイルに継続起点と通知時刻が残る（次回の間引き判断の材料）
sent2 = []
real, cf.send_slack = cf.send_slack, lambda t: sent2.append(t)
cf.STATUS_FILE.unlink(missing_ok=True)
cf.record_failure(["RefreshError: invalid_grant"], NOW)
st = json.loads(cf.STATUS_FILE.read_text(encoding="utf-8"))
(ok if st.get("first_failed_at") and st.get("notified_at") else ng)("状態ファイルに継続起点と通知時刻を残す")
(ok if st.get("errors") == ["RefreshError: invalid_grant"] else ng)("既存の errors は残す（cmd_show が読む）")
(ok if st.get("failed_at") else ng)("既存の failed_at も残す（後方互換）")
(ok if len(sent2) == 1 else ng)(f"初回は1本だけ送る（{len(sent2)}）")
cf.record_failure(["RefreshError: invalid_grant"], NOW + timedelta(hours=1))
(ok if len(sent2) == 1 else ng)(f"同日の再実行では鳴らし直さない（{len(sent2)}）")
cf.send_slack = real

print("\n=== 通知の頑健性（2026-08-17 Codex クロスレビュー）===")
# 🔴 naive な日時1つで通知経路そのものが死ぬ穴があった。
#    _parse_dt はTZ無しISOも「正常値」として返すが now は aware＝(now - notified) が TypeError。
#    しかも例外は notify_failure の try より手前＝握られず record_failure の保存にも到達しない。
#    ＝状態ファイルを手で1回直しただけで、失敗記録も通知も両方止まる。
#    ※ 現在の判定は .date() 同士なので減算は起きないが、**それは今の実装がそうなだけ**。
#      正規化そのものを直接ピン留めしておく（後で差分を取る実装が来ても穴が再発しない）。
#      ここを .date() 経由のケースだけで担保したつもりになっていた＝mutation で発覚。
_n = cf._parse_dt("2026-08-14T06:55:00")
(ok if _n is not None and _n.tzinfo is not None
   else ng)("TZ無しの ISO を aware に正規化して返す（naive を素通しさせない）")
(ok if _n is not None and _n.utcoffset() == cf.JST.utcoffset(None)
   else ng)("補うTZは JST（このスクリプトの時刻は全部 JST）")
(ok if cf._parse_dt("2026-08-14T06:55:00+09:00").utcoffset() == cf.JST.utcoffset(None)
   else ng)("TZ付きはそのまま（上書きしない）")
for key in ("notified_at", "first_failed_at"):
    try:
        d = cf.notify_decision({key: "2026-08-14T06:55:00"}, NOW)   # TZ無し
        ok(f"TZ無しの {key} でも判定が落ちない")
    except Exception as e:
        ng(f"TZ無しの {key} でも判定が落ちない", f"{type(e).__name__}: {e}")
d = cf.notify_decision({"first_failed_at": "2026-08-11T06:55:00"}, NOW)
(ok if d["days_down"] == 6 else ng)(f"TZ無しでも継続日数を JST 基準で数える（{d['days_down']}）")

# 🟡 .days は72時間の切り捨て＝秒のズレで「3日おき」が4日後にずれる。暦日で数える。
d = cf.notify_decision({"notified_at": iso(NOW - timedelta(days=3) + timedelta(seconds=1))}, NOW)
(ok if d["send"] else ng)("3日前の1秒後でも暦日3日なら鳴らす（cron の秒ズレを拾わない）")
d = cf.notify_decision({"notified_at": iso(NOW - timedelta(days=2, hours=7))}, NOW)
(ok if d["send"] else ng)("暦日で3日跨いでいれば鳴らす（前々日の23時台→3日目の朝）")
d = cf.notify_decision({"notified_at": iso(NOW - timedelta(hours=23))}, NOW)
(ok if not d["send"] else ng)("暦日1日しか経っていなければ鳴らさない")

# 🟡 Slack のメンション記法・アドレスを本文に素通しさせない
sent3 = []
real, cf.send_slack = cf.send_slack, lambda t: sent3.append(t)
cf.notify_failure({}, NOW, ["<!channel> 進捗会議 <someone@example.com>: RefreshError"])
body = sent3[0] if sent3 else ""
(ok if "<!channel>" not in body else ng)("Slack のメンション記法をそのまま流さない（全員に飛ぶ事故を防ぐ）")
(ok if "someone@example.com" not in body else ng)("メールアドレス形式は伏せる（カレンダーIDが素で出る）")
(ok if "RefreshError" in body else ng)("原因そのものは残す（伏せすぎて役に立たないのは困る）")
cf.send_slack = real

print("\n=== 配達経路そのもの（今回の事故は「検知」でなく「配達」だった）===")
stub = T / "slack-stub.sh"
log = T / "slack-stub.log"
stub.write_text(f'#!/usr/bin/env bash\ncat > "{log}"\nexit ${{STUB_RC:-0}}\n', encoding="utf-8")
os.chmod(stub, 0o755)
cf.SLACK_SH = stub
try:
    cf.send_slack("本文テスト")
    ok("slack.sh を実際に起動できる（正常系）")
except Exception as e:
    ng("slack.sh を実際に起動できる（正常系）", f"{type(e).__name__}: {e}")
(ok if log.is_file() and log.read_text(encoding="utf-8").strip() == "本文テスト"
   else ng)("本文が標準入力で渡る（引数でなく stdin）")
os.environ["STUB_RC"] = "1"
try:
    cf.send_slack("落ちるはず"); ng("slack.sh が非0で終わったら例外にする")
except Exception:
    ok("slack.sh が非0で終わったら例外にする（＝呼び出し側が握って記録を残せる）")
os.environ.pop("STUB_RC", None)
cf.SLACK_SH = T / "slack-stub-not-exist.sh"

print("\n=== 送信できない日が続いても記録は残り、翌朝もう一度試す ===")
cf.STATUS_FILE.unlink(missing_ok=True)
def always_fail(t): raise RuntimeError("webhook 落ちてる")
real, cf.send_slack = cf.send_slack, always_fail
cf.record_failure(["RefreshError"], NOW)
st = json.loads(cf.STATUS_FILE.read_text(encoding="utf-8"))
(ok if st.get("notified_at") is None else ng)("送信に失敗した日は「通知済み」にしない")
(ok if st.get("errors") == ["RefreshError"] else ng)("送信に失敗しても失敗の記録自体は残す")
d = cf.notify_decision(st, NOW + timedelta(days=1))
(ok if d["send"] else ng)("翌朝もう一度送信を試す（通知経路の復旧を自動で拾う）")
(ok if d["first_failed_at"] == st["first_failed_at"] else ng)("再試行しても継続起点は動かさない")
cf.send_slack = real

(ok if not cf.recovery_decision({"notified_at": "こわれた日付"}) else ng)("壊れた notified_at は「通知済み」と読まない")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
