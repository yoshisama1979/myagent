#!/usr/bin/env bash
# BigQuery 取得3本 bin/gsc-fetch.py・bin/ga4-fetch.py・bin/ads-fetch.py の回帰テスト。
#
# 契機＝2026-08-11、testing.md §7「無人ループが実行するツール 21本のうちテストが無い 13本」を
# 減らす作業の5本目。3本まとめて1スイートにしたのは、**同じ判定を3回書いている**からで、
# 片方だけ直して規約がずれるのが一番あり得る壊れ方（refactoring.md §6 の「不整合の芽」）。
#
# 守りたい不変条件：
#   (1) **BigQuery の識別子はパラメータ化できない＝文字列補間の前に必ず検証する**（SQLインジェクション）
#   (2) 期間・上限の引数を黙って解釈しない（入力ミスが「空データの正常終了」に化けない）
#   (3) 日付の起点がツールごとに違うことを固定する（広告の転送は前日分まで＝end は昨日）
#   (4) 値は必ずクエリパラメータ（@start 等）で渡し、SQL 文へ埋め込まない
#
# ⚠️ BigQuery へは一切接続しない（実APIを叩く関数は呼ばない）。google-cloud-bigquery が
#    入っていない環境でも流せる＝各ツールが SDK を関数内で遅延 import しているため。
# 触ったら必ず流すこと：bash bin/test-bq-fetch.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in gsc-fetch.py ga4-fetch.py ads-fetch.py; do
  [ -f "$PROJ/bin/$f" ] || { echo "❌ 起動位置がおかしい: $PROJ/bin/$f" >&2; exit 2; }
done

python3 - "$PROJ" <<'PYEOF'
import contextlib, datetime, importlib.util, io, json, sys, types
from pathlib import Path

proj = Path(sys.argv[1])
def load(name, mod):
    spec = importlib.util.spec_from_file_location(mod, proj / "bin" / name)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

gsc = load("gsc-fetch.py", "gscfetch")
ga4 = load("ga4-fetch.py", "ga4fetch")
ads = load("ads-fetch.py", "adsfetch")

P = N = 0
def ok(m, d=""):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

def code(fn, *a, **kw):
    """sys.exit の終了コードを返す（正常終了なら None）。stderr は吸う。"""
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            fn(*a, **kw)
    except SystemExit as e:
        return e.code
    return None

def A(**kw):
    """argparse の Namespace 代わり。既定は「妥当な値」にして、崩したい項目だけ渡す。"""
    base = dict(limit=100, max_gb=1.0, start=None, end=None, days=28,
                account="1234567890", mode="daily")
    base.update(kw)
    return types.SimpleNamespace(**base)

print("=== 識別子の検証（★SQLインジェクション対策・3本で同じ規約か）===")
# 3本が同じ判定を各自で持っている＝片方だけ直すとずれる。まず規約そのものの一致を見る。
(ok if gsc._IDENT_DATASET.pattern == ga4._IDENT_DATASET.pattern == ads._IDENT_DATASET.pattern
   else ng)("dataset の規約が3本で一致",
            [m._IDENT_DATASET.pattern for m in (gsc, ga4, ads)])
(ok if gsc._IDENT_PROJECT.pattern == ga4._IDENT_PROJECT.pattern == ads._IDENT_PROJECT.pattern
   else ng)("project の規約が3本で一致",
            [m._IDENT_PROJECT.pattern for m in (gsc, ga4, ads)])

GOOD_P, GOOD_D = "my-project-219202", "searchconsole_example"
BAD = [
    ("dataset に空白", GOOD_P, "search console"),
    ("dataset にバッククォート", GOOD_P, "ds`"),
    ("dataset にセミコロン", GOOD_P, "ds; DROP TABLE t"),
    ("dataset にハイフン（BQ の規約外）", GOOD_P, "search-console"),
    ("dataset にドット（別データセットを指せる）", GOOD_P, "other.ds"),
    ("dataset が空", GOOD_P, ""),
    ("dataset が None", GOOD_P, None),
]
for m, label in ((gsc, "gsc"), (ga4, "ga4")):
    (ok if code(m.validate_identifiers, GOOD_P, GOOD_D) is None else ng)(f"{label}: 正しい識別子は通る")
    for why, p, d in BAD:
        (ok if code(m.validate_identifiers, p, d) == 2 else ng)(f"{label}: {why}")
    for why, p in [("project が数字始まり", "1project"), ("project にアンダースコア", "my_project"),
                   ("project に空白", "my project"), ("project が空", "")]:
        (ok if code(m.validate_identifiers, p, GOOD_D) == 2 else ng)(f"{label}: {why}")

print("\n--- ads はテーブルサフィックスも補間する（数字のみ）---")
(ok if code(ads.validate_identifiers, GOOD_P, "google_ads", "1234567890") is None else ng)(
    "ads: 正しい識別子は通る")
for why, s in [("英字混じり", "123a"), ("空", ""), ("None", None),
               ("ワイルドカード", "*"), ("バッククォート付き", "123`")]:
    (ok if code(ads.validate_identifiers, GOOD_P, "google_ads", s) == 2 else ng)(
        f"ads: サフィックスが{why}なら止まる")

print("\n=== 引数の検証（入力ミスを『空データの正常終了』に化けさせない）===")
for m, label in ((gsc, "gsc"), (ga4, "ga4"), (ads, "ads")):
    (ok if code(m.validate_args, A()) is None else ng)(f"{label}: 妥当な引数は通る")
    (ok if code(m.validate_args, A(limit=0)) == 2 else ng)(f"{label}: limit=0 を弾く")
    (ok if code(m.validate_args, A(limit=10001)) == 2 else ng)(f"{label}: limit 上限超えを弾く")
    (ok if code(m.validate_args, A(limit=1)) is None else ng)(f"{label}: limit=1 は境界内")
    (ok if code(m.validate_args, A(limit=10000)) is None else ng)(f"{label}: limit=10000 は境界内")
    (ok if code(m.validate_args, A(max_gb=0)) == 2 else ng)(f"{label}: max_gb=0 を弾く（課金の歯止め）")
    (ok if code(m.validate_args, A(max_gb=-1)) == 2 else ng)(f"{label}: max_gb 負数を弾く")
    (ok if code(m.validate_args, A(start="2026/08/01", end="2026-08-10")) == 2 else ng)(
        f"{label}: 日付の書式違いを弾く")
    (ok if code(m.validate_args, A(start="2026-08-32", end="2026-08-10")) == 2 else ng)(
        f"{label}: 存在しない日付を弾く")
    (ok if code(m.validate_args, A(start="2026-08-10", end="2026-08-01")) == 2 else ng)(
        f"{label}: start が end より後なら弾く")
    (ok if code(m.validate_args, A(start="2026-08-01", end="2026-08-01")) is None else ng)(
        f"{label}: 同日指定は通す")

print("\n--- ads だけが持つ追加のガード（Codex指摘🔴1 の修理）---")
(ok if code(ads.validate_args, A(days=0)) == 2 else ng)("ads: days=0 を弾く")
(ok if code(ads.validate_args, A(start="2026-08-01", end=None)) == 2 else ng)(
    "ads: 片側だけの期間指定を黙って無視しない")
(ok if code(ads.validate_args, A(account="12a")) == 2 else ng)("ads: account は数字のみ")
(ok if code(ads.validate_args, A(mode="daily", account=None)) == 2 else ng)(
    "★ads: accounts 以外で --account 省略は止める（別アカウントの数字が混ざる）")
(ok if code(ads.validate_args, A(mode="accounts", account=None)) is None else ng)(
    "ads: accounts モードだけ全体俯瞰を許す")
# 3本の規約の違いを明示的に固定しておく（同じに見えて違う＝共通化するときに壊す点）
(ok if code(gsc.validate_args, A(start="2026-08-01", end=None)) is None else ng)(
    "gsc は片側だけの期間指定を弾かない（ads との規約差＝現状として固定）")

print("\n=== 期間の決め方（ツールごとに起点が違う）===")
today = datetime.date.today()
s, e = gsc.daterange(A(days=7))
(ok if e == today.isoformat() and s == (today - datetime.timedelta(days=7)).isoformat() else ng)(
    "gsc: end=今日／start=today-days", (s, e))
(ok if gsc.daterange(A(start="2026-01-01", end="2026-01-31")) == ("2026-01-01", "2026-01-31")
   else ng)("gsc: 明示指定はそのまま")
s, e = ads.daterange(A(days=7))
(ok if e == (today - datetime.timedelta(days=1)).isoformat() else ng)(
    "★ads: end=昨日（転送は前日分まで＝今日の空データで日別が欠けて見えない）", (s, e))
(ok if (datetime.date.fromisoformat(e) - datetime.date.fromisoformat(s)).days == 6 else ng)(
    "ads: days=7 はちょうど7日分（両端含む）", (s, e))
s, e = ga4.daterange(A(days=7))
(ok if len(s) == 8 and s.isdigit() and len(e) == 8 else ng)(
    "ga4: _TABLE_SUFFIX 用に YYYYMMDD で返す", (s, e))
(ok if ga4.daterange(A(start="2026-01-01", end="2026-01-31")) == ("20260101", "20260131") else ng)(
    "ga4: 明示指定もハイフンを外す")

print("\n=== WHERE 句の組み立て（値は必ず @パラメータ）===")
w = gsc._where(None, None)
(ok if w == "data_date BETWEEN @start AND @end" else ng)("gsc: 既定は期間だけ", w)
(ok if "@stype" not in gsc._where("ALL", None) else ng)("gsc: search_type=ALL は絞り込まない")
(ok if "@stype" in gsc._where("web", None) else ng)("gsc: 種別指定はパラメータで絞る")
(ok if "@site" in gsc._where(None, "https://example.test/") else ng)("gsc: サイト指定もパラメータ")
(ok if "example.test" not in gsc._where(None, "https://example.test/") else ng)(
    "★gsc: サイトURLを SQL 文へ埋め込まない（@site で束縛）")
(ok if "x = 1" in gsc._where(None, None, "x = 1") else ng)("gsc: 追加条件を AND で連結")
w = ads._where(A(account="123"))
(ok if "_PARTITIONDATE BETWEEN @start AND @end" in w and "segments_date BETWEEN @start AND @end" in w
   else ng)("ads: パーティション日と実日付の両方で絞る（スキャン最小化と正しさ）", w)
(ok if "customer_id = @cid" in w and "123" not in w else ng)(
    "★ads: customer_id をパラメータで束縛（SQL へ数値を埋めない）", w)
(ok if "@cid" not in ads._where(A(account=None)) else ng)("ads: account 未指定なら条件を足さない")

print("\n=== ga4 の UNION 分岐（daily と intraday の二重計上防止）===")
c = ga4.build_ga_cte(GOOD_P, "analytics_1", True, False)
(ok if "events_*" in c and "events_intraday_*" not in c else ng)("daily だけ", c)
(ok if f"`{GOOD_P}.analytics_1.events_*`" in c else ng)("検証済み識別子だけを補間する")
c = ga4.build_ga_cte(GOOD_P, "analytics_1", False, True)
(ok if "events_intraday_*" in c and "@daily_dates" not in c else ng)(
    "intraday だけのときは除外条件を付けない", c)
c = ga4.build_ga_cte(GOOD_P, "analytics_1", True, True)
(ok if "UNION ALL" in c and "event_date NOT IN UNNEST(@daily_dates)" in c else ng)(
    "★両方あるときは daily の日を intraday から除く（二重計上防止）", c)
(ok if ga4.build_ga_cte(GOOD_P, "analytics_1", False, False) is None else ng)(
    "どちらも無ければ None（呼び出し側でエラーにする）")

print("\n=== CVイベントの決め方（明示 > dataset別 > 既定）===")
(ok if ga4.cv_events_for("analytics_1", "a, b ,, c") == ["a", "b", "c"] else ng)(
    "明示指定はカンマ区切り・空白と空要素を落とす", ga4.cv_events_for("analytics_1", "a, b ,, c"))
(ok if ga4.cv_events_for("no-such-dataset", None) == ga4.DEFAULT_CV_EVENTS else ng)(
    "未知の dataset は全体の既定")
known = next(iter(ga4.DATASET_CV_EVENTS), None)
if known:
    (ok if ga4.cv_events_for(known, None) == ga4.DATASET_CV_EVENTS[known] else ng)(
        "登録済み dataset は専用の既定を使う")
    (ok if ga4.cv_events_for(known, "x") == ["x"] else ng)("明示指定は dataset 別より優先")
else:
    ok("dataset 別の既定は未登録（登録されたら上の2項目が効く）")

print("\n=== 表示の整形 ===")
out = gsc.fmt_rows([{"query": "料金", "ctr": 0.0525, "avg_position": 12.345, "clicks": 3}])
(ok if "ctr=5.25%" in out else ng)("gsc: CTR は百分率で2桁", out)
(ok if "avg_position=12.3" in out else ng)("gsc: 掲載順位は小数1桁", out)
(ok if "clicks=3" in out else ng)("gsc: そのほかはそのまま", out)
(ok if "（データなし）" in gsc.fmt_rows([]) else ng)("gsc: 空なら『データなし』と言う（黙らない）")
(ok if "（データなし）" in ga4.fmt_rows([]) else ng)("ga4: 空なら『データなし』と言う")
(ok if "（データなし）" in ads.fmt_rows([]) else ng)("ads: 空なら『データなし』と言う")
o = gsc.fmt_rows([{"query": "x", "ctr": None, "avg_position": None}])
(ok if "ctr=None" in o and "avg_position=None" in o else ng)("gsc: None で落ちない", o)
d = gsc.fmt_rows({"dry_run": True, "bytes": 1234})
(ok if json.loads(d)["bytes"] == 1234 else ng)("dict（dry-run/サマリ）は JSON で返す", d)

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
