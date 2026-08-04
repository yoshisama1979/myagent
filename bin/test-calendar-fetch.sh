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

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
