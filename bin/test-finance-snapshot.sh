#!/usr/bin/env bash
# bin/finance-snapshot.py（T-019・週次朝礼と月初レビューが読む財務ダイジェスト）の回帰テスト。
#
# 契機＝2026-08-11、testing.md §7「無人ループが実行するツール 21本のうちテストが無い 13本」を
# 減らす作業の3本目。読み取り専用だが §2 の条件③「判定を持つ」に強く当たる＝
# ここが間違うと**社長が誤った数字で経営判断をする**。守りたい不変条件は4つ：
#   (1) 会計年度は4月始まり（FY2026 = 2026-04〜2027-03）＝境界を跨いで1年ずれない
#   (2) **期中PLを年換算しない**（費用の入力が遅れている時期に利益を過大表示する。設計原則の核）
#   (3) **取引先名を集計結果に残さない**（data/financial/README.md。売掛金の補助科目には実名が入る）
#   (4) キャッシュの鮮度を偽らない（stale を fresh として朝礼に出さない＝Codex指摘🔴6の修理）
#
# ⚠️ 本番の data/financial/（git外・実額）は読まない：一時ディレクトリに**架空の会社の
#    Shift-JIS CSV** を組んで流す。金額も社名もすべて架空。実データを表示する箇所は無い。
#    末尾のスモークだけ実データを通すが、**出力は捨てて終了コードしか見ない**（数字を画面に出さない）。
# 触ったら必ず流すこと：bash bin/test-finance-snapshot.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/finance-snapshot.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import csv, importlib.util, io, json, os, re, subprocess, sys, tempfile
from datetime import date
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("finsnap", proj / "bin/finance-snapshot.py")
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)

P = N = 0
def ok(m, d=""):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

# ---- 本番の data/financial に触れない（testing.md §6-1）----
T = Path(tempfile.mkdtemp())
if not str(T).startswith("/tmp"):
    print(f"❌ テストの作業先が /tmp の外: {T}", file=sys.stderr); sys.exit(2)
PROD_FIN = fs.FINANCIAL                      # スモークで戻すために控える
fs.FINANCIAL      = T / "financial"
fs.GOALS_HTML     = T / "goals.html"
fs.RECURRING_HTML = T / "recurring.html"
fs.PROJECTS_CACHE = T / "cache.json"
fs.PROJECTS_SCRIPT = T / "fake-projects.py"
for _p in (fs.FINANCIAL, fs.GOALS_HTML, fs.RECURRING_HTML, fs.PROJECTS_CACHE):
    if not str(_p).startswith("/tmp"):
        print(f"❌ 読み先の差し替えに失敗: {_p}", file=sys.stderr); sys.exit(2)
fs.FINANCIAL.mkdir(parents=True)

def sjis(path: Path, rows):
    """架空の会計 CSV を Shift-JIS(cp932) で置く（マネーフォワードの書き出しと同じ文字コード）。

    金額の桁区切りカンマは**引用符で囲む**＝MF の実物と同じ形。素で書くと csv が列を割ってしまい、
    「テストの都合で壊れた入力」を本物だと誤認したまま緑になる（最初にここで踏んだ）。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    buf = io.StringIO()
    csv.writer(buf, quoting=csv.QUOTE_ALL, lineterminator="\n").writerows(rows)
    path.write_bytes(buf.getvalue().encode("cp932"))

print("=== 会計年度（4月始まり）===")
(ok if fs.fiscal_year(date(2026, 4, 1)) == 2026 else ng)("4/1 は新年度の初日")
(ok if fs.fiscal_year(date(2026, 3, 31)) == 2025 else ng)("3/31 はまだ前年度（1年ずれない）")
(ok if fs.fiscal_year(date(2026, 12, 31)) == 2026 else ng)("年末は同じFY")
(ok if fs.fiscal_year(date(2027, 1, 1)) == 2026 else ng)("年明けもFYは変わらない")
(ok if fs.closed_month_count(date(2026, 4, 15), 2026) == 0 else ng)("期初の当月は締め前＝0ヶ月")
(ok if fs.closed_month_count(date(2026, 8, 11), 2026) == 4 else ng)("8月時点で締めるべきは4ヶ月（4〜7月）")
(ok if fs.closed_month_count(date(2027, 3, 31), 2026) == 11 else ng)("期末月も当月は数えない")
(ok if fs.closed_month_count(date(2026, 1, 1), 2026) == 0 else ng)("FY開始前は負にならず0")

print("\n--- 入力の遅れ（月インデックスの差で数える）---")
(ok if fs.lag_months("2026-06-30", date(2026, 8, 11)) == 1 else ng)("6月まで入力・8月時点は1ヶ月遅れ")
(ok if fs.lag_months("2026-07-31", date(2026, 8, 11)) == 0 else ng)("前月まで入っていれば遅れ0")
(ok if fs.lag_months("2026-08-31", date(2026, 8, 11)) == 0 else ng)("先行入力でも負にしない")
(ok if fs.lag_months("2025-12-31", date(2026, 1, 15)) == 0 else ng)("年をまたぐ1月時点（12月まで入力＝遅れ0）")
(ok if fs.lag_months("2025-11-30", date(2026, 1, 15)) == 1 else ng)("年をまたいでも月差で正しく数える")
(ok if fs.lag_months("2026-02-28", date(2026, 7, 1)) == 4 else ng)(
    "月末の日数差（2/28 と 6/30）で端数が出ない")

print("\n=== 文字コード（MF は Shift-JIS で書き出す）===")
p = T / "enc.csv"
p.write_bytes("勘定科目,金額\n売上高,100\n".encode("cp932"))
(ok if "売上高" in fs.read_sjis(p) else ng)("cp932 を読める")
p.write_bytes("﻿勘定科目\n".encode("utf-8"))
(ok if fs.read_sjis(p).lstrip("﻿").startswith("勘定科目") else ng)("BOM付き UTF-8 も読める")
# ⚠️ 実挙動の固定（アラではなく既知の性質）：cp932 を最初に試すので、BOM が無い UTF-8 の
#    日本語は**例外にならず文字化けして「読めてしまう」**。MF の書き出しは cp932 なので現状は
#    実害が無いが、他ソースの CSV を足すと科目名が一致せず静かにゼロ扱いになる経路。
p.write_bytes("勘定科目\n".encode("utf-8"))
(ok if "勘定科目" not in fs.read_sjis(p) else ng)(
    "BOM無し UTF-8 は cp932 として化ける（現状の仕様として固定＝別途起票）")
p.write_bytes(b"\x81\x40\xff\xfe abc\n")
try:
    fs.read_sjis(p); ok("壊れたバイトでも例外にしない（置換して読む）")
except Exception as e:
    ng("壊れたバイトでも例外にしない", repr(e))

print("\n=== PL の読み取り（架空の会社）===")
CUR = fs.FINANCIAL / "2026" / "pl.csv"
sjis(CUR, [
    ["", "", "", "2026-04-01", "", "2026-06-30", "当期残高"],
    ["売上高合計", "", "", "", "", "", "9,000,000"],
    ["売上総利益", "", "", "", "", "", "5,000,000"],
    ["販売費及び一般管理費"],                                   # ← 短い行が販管費セクションの開始
    ["", "旅費交通費", "", "", "", "", "100,000"],
    ["", "旅費交通費", "タクシー代", "", "", "", "50,000"],      # 補助科目＝親と二重計上になる
    ["", "★要確認", "", "", "", "", "90,000"],
    ["", "こわれた行", "", "", "", "", "金額ではない"],
    ["販売費及び一般管理費合計", "", "", "", "", "", "300,000"],
    ["", "受取利息", "", "", "", "", "1,000"],                   # 販管費セクションの外
    ["営業利益", "", "", "", "", "", "2,000,000"],
])
cur = fs.parse_pl(2026)
(ok if cur and cur["start"] == "2026-04-01" and cur["end"] == "2026-06-30" else ng)("期間を見出しから取る", cur)
(ok if cur["months"] == 3 else ng)("入力済み月数＝3ヶ月", cur["months"])
(ok if cur["is_full_year"] is False else ng)("通期でないことを持つ")
(ok if cur["items"].get("売上高合計") == 9000000 else ng)("桁区切りのカンマを外して整数化")
(ok if cur["sga"].get("旅費交通費") == 100000 else ng)("販管費の科目を拾う")
(ok if "タクシー代" not in json.dumps(cur, ensure_ascii=False) else ng)(
    "補助科目の行は飛ばす（親科目と二重計上しない）")
(ok if "受取利息" not in cur["sga"] else ng)("販管費合計より後の科目を販管費に入れない")
(ok if cur["items"].get("受取利息") == 1000 else ng)("ただし科目としては拾う")
(ok if "こわれた行" not in cur["items"] else ng)("金額が数値でない行は捨てる（例外にしない）")
(ok if fs.parse_pl(1999) is None else ng)("ファイルが無ければ None")
sjis(fs.FINANCIAL / "1998" / "pl.csv", [["日付の無い見出し"], ["売上高合計", "", "", "", "", "", "1"]])
(ok if fs.parse_pl(1998) is None else ng)("期間が読めない CSV は None（推測で埋めない）")

PREV = fs.FINANCIAL / "2025" / "pl.csv"
sjis(PREV, [
    ["", "", "", "2025-04-01", "", "2026-03-31", "当期残高"],
    ["売上高合計", "", "", "", "", "", "40,000,000"],
    ["販売費及び一般管理費"],
    ["", "旅費交通費", "", "", "", "", "1,000,000"],
    ["", "保険料", "", "", "", "", "600,000"],
    ["", "消耗品費", "", "", "", "", "100,000"],
    ["販売費及び一般管理費合計", "", "", "", "", "", "4,000,000"],
    ["営業利益", "", "", "", "", "", "8,000,000"],
])
prev = fs.parse_pl(2025)
(ok if prev["months"] == 12 and prev["is_full_year"] else ng)("前年は通期12ヶ月")

print("\n=== BS の読み取りと資金の危険信号 ===")
sjis(fs.FINANCIAL / "2026" / "bs.csv", [
    ["", "", "", "2026-04-01", "", "2026-06-30", "当期残高"],
    ["現金及び預金合計", "", "", "5,000,000", "", "", "3,000,000"],
    ["", "売掛金", "", "1,000,000", "", "", "4,000,000"],
    ["", "", "架空商事株式会社", "", "", "", "3,000,000"],       # ← 補助科目に取引先名が入る
    ["", "", "テスト工業株式会社", "", "", "", "1,000,000"],
    ["売上債権合計", "", "", "1,000,000", "", "", "4,000,000"],
    ["", "仮受金", "", "0", "", "", "120,000"],
    ["資産の部合計", "", "", "9,000,000", "", "", "10,000,000"],
    ["負債の部合計", "", "", "5,000,000", "", "", "6,000,000"],
    ["純資産の部合計", "", "", "4,000,000", "", "", "4,000,000"],
])
bs = fs.parse_bs(2026)
dump = json.dumps(bs, ensure_ascii=False)
(ok if bs["closing"]["cash"] == 3000000 and bs["opening"]["cash"] == 5000000 else ng)("期首・期末を取る")
(ok if bs["delta"]["cash"] == -2000000 else ng)("増減を出す")
(ok if abs(bs["equity_ratio"] - 40.0) < 0.01 else ng)("自己資本比率", bs.get("equity_ratio"))
(ok if "架空商事株式会社" not in dump and "テスト工業株式会社" not in dump else ng)(
    "★取引先名を集計結果に一切残さない（data/financial/README.md）", dump[:200])
c = bs["receivable_concentration"]
(ok if c["clients"] == 2 and abs(c["top1_pct"] - 75.0) < 0.01 else ng)("依存度は名前を伏せた比率だけ", c)
(ok if c["basis"] == 4000000 else ng)("分母は補助科目のプラス残高の合計")
(ok if any(u["name"] == "仮受金" for u in bs["unclassified"]) else ng)("未分類の勘定を拾う")

alerts = fs.balance_alerts(bs)
txt = " / ".join(alerts)
(ok if any("現金になっていない" in a for a in alerts) else ng)(
    "現預金が減り売掛金が増えていたら回収を疑う", txt)
(ok if any("1社に集中" in a for a in alerts) else ng)("1社集中30%以上で警告", txt)
(ok if any("未分類" in a for a in alerts) else ng)("未分類残高を警告", txt)
(ok if "架空商事" not in txt and "テスト工業" not in txt else ng)("★警告文にも取引先名を出さない", txt)
(ok if fs.balance_alerts(None) == [] else ng)("BS が無ければ黙る（推測で警告しない）")

print("\n=== 経理入力の状況 ===")
(fs.FINANCIAL / "2026-04").mkdir(exist_ok=True)
(fs.FINANCIAL / "2026-04" / "dummy.csv").write_text("x", encoding="utf-8")
(ok if fs.monthly_dirs(2026) == ["2026-04"] else ng)("月次フォルダの投入状況", fs.monthly_dirs(2026))
st, cur, prev = fs.accounting_status(date(2026, 8, 11))
al = " / ".join(st["alerts"])
(ok if st["fy"] == 2026 and st["prev_fy"] == 2025 else ng)("当期と前期を決める")
(ok if st["closed_months"] == 4 and st["entered_months"] == 3 else ng)("締めるべき4／入力済み3")
(ok if st["lag_months"] == 1 and "1ヶ月 遅れ" in al else ng)("遅れを警告", al)
(ok if any(u["name"] == "★要確認" for u in st["unclassified"]) else ng)("PL側の未分類も拾う")
names = [a["name"] for a in st["missing_accounts"]]
(ok if names == ["保険料"] else ng)("前年にあって今期ゼロの主要費目を検知", names)
(ok if st["missing_accounts"][0]["expected"] == 150000 else ng)(
    "前年ペースでの相当額（600,000÷12×3）", st["missing_accounts"][0]["expected"])
(ok if "消耗品費" not in names else ng)("売上比1%未満の小さな科目は騒がない（警報疲れ防止）")
(ok if any("決算期にまとめて計上する会社もある" in a for a in st["alerts"]) else ng)(
    "入力漏れと年次計上を決めつけない（社長に確認を促す）")
(ok if abs(st["sga_pace_pct"] - 30.0) < 0.01 else ng)("販管費の前年同ペース比", st.get("sga_pace_pct"))
(ok if any("一部だけ入力" in a for a in st["alerts"]) else ng)(
    "ゼロでなく「一部だけ入力」の取りこぼしも拾う（偽陰性の穴埋め）", al)
st2, c2, p2 = fs.accounting_status(date(2020, 8, 11))
(ok if c2 is None and any("未投入" in a for a in st2["alerts"]) else ng)("PL が無い年度は未投入と言う")

print("\n=== 実績の出し方（★年換算しない）===")
fin = fs.financials(cur, prev, 48000000, st["missing_accounts"])
rev = fin["items"]["売上高合計"]
(ok if rev["value"] == 9000000 and rev["per_month"] == 3000000 else ng)("入力済み期間と月平均", rev)
(ok if rev["prev_pace"] == 10000000 else ng)("前年の同期間ペース（40,000,000÷12×3）", rev)
(ok if abs(rev["diff_pct"] + 10.0) < 0.01 else ng)("前年同ペース比", rev)
(ok if fin["target_monthly"] == 4000000 and abs(fin["target_pace_pct"] - 75.0) < 0.01 else ng)(
    "目標に対する進捗（goals.html の年間目標を12分割）", fin.get("target_pace_pct"))
(ok if fin["unverified_cost"] == 150000 else ng)("未確認の費用はレンジとして別枠で持つ")
blob = json.dumps(fin, ensure_ascii=False)
annualized = [k for k in ("annual", "forecast", "projection", "年換算", "年間予測") if k in blob]
(ok if not annualized else ng)("★年換算・年間予測のキーを持たない", annualized)
(ok if 9000000 * 4 not in [v for r in fin["items"].values() for v in r.values() if isinstance(v, int)]
   else ng)("★入力3ヶ月を12ヶ月へ単純換算した値を出さない（利益の過大表示を作らない）")
(ok if fs.financials(None, prev, 48000000) is None else ng)("PL が無ければ何も語らない")
fin0 = fs.financials(cur, prev, None)
(ok if "target_pace_pct" not in fin0 else ng)("目標が読めないときは進捗率を捏造しない")

print("\n=== 目標とストック収益（正は別ファイル・ここは読むだけ）===")
(ok if fs.read_target_revenue() is None else ng)("goals.html が無ければ None")
fs.GOALS_HTML.write_text("<p>標準ライン</p><td>¥48,000,000</td>", encoding="utf-8")
(ok if fs.read_target_revenue() == 48000000 else ng)("年間売上目標を読む", fs.read_target_revenue())
(ok if fs.read_recurring() is None else ng)("recurring-revenue.html が無ければ None")
fs.RECURRING_HTML.write_text(
    "月額合計 <b>¥350,000</b> 有効契約数 <span>12 件</span> 最終更新: 2026-08-01", encoding="utf-8")
r = fs.read_recurring()
(ok if r == {"monthly": 350000, "contracts": 12, "updated": "2026-08-01"} else ng)("ストック収益を読む", r)

print("\n=== 案件シートの鮮度（stale を fresh と偽らない）===")
data, src, fresh = fs.load_projects(no_fetch=True)
(ok if data is None and fresh is False else ng)("キャッシュも取得も無ければ fresh=False", (src, fresh))
fs.PROJECTS_CACHE.write_text(json.dumps({"details": {}, "state_data": []}), encoding="utf-8")
data, src, fresh = fs.load_projects(no_fetch=True)
(ok if fresh is True and "--no-fetch" in src else ng)("新しいキャッシュは fresh", (src, fresh))
old = fs.PROJECTS_CACHE.stat().st_mtime - (fs.CACHE_MAX_AGE_SEC + 3600)
os.utime(fs.PROJECTS_CACHE, (old, old))
data, src, fresh = fs.load_projects(no_fetch=True)
(ok if fresh is False and "キャッシュ" in src else ng)(
    "★古いキャッシュは fresh=False（朝礼が『今週取得済み』と誤認しない）", (src, fresh))
fs.PROJECTS_SCRIPT.write_text(
    'print(\'{"details": {}, "state_data": [], "fetched_at": "2026-08-11"}\')', encoding="utf-8")
data, src, fresh = fs.load_projects(no_fetch=False)
(ok if fresh is True and src == "fresh" else ng)("取得できたら fresh", (src, fresh))
fs.PROJECTS_SCRIPT.write_text(
    'import sys; print("SECRET-LOOKING-OUTPUT"); sys.exit(3)', encoding="utf-8")
data, src, fresh = fs.load_projects(no_fetch=False)
(ok if fresh is False and "取得失敗" in src else ng)("取得に失敗したら fresh=False", (src, fresh))
(ok if "SECRET-LOOKING-OUTPUT" not in src else ng)(
    "失敗時にスクリプトの出力を label へ載せない", src)
# 「中身を載せない」を緩く見ると素通りする（str(e) に変えても JSONDecodeError の文言には
# 出力が含まれないため）。**ラベルに載ってよいのは例外クラス名だけ**という形で縛る。
inner = re.search(r"取得失敗\(([^)]*)\)", src)
(ok if inner and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", inner.group(1)) else ng)(
    "★失敗ラベルは例外のクラス名だけ（メッセージ・パス・認証情報を混ぜない）", src)
fs.PROJECTS_CACHE.write_text("{壊れた", encoding="utf-8")
data, src, fresh = fs.load_projects(no_fetch=True)
(ok if data is None and src == "キャッシュ破損" and fresh is False else ng)("壊れたキャッシュを検知", (src, fresh))

print("\n=== 案件サマリ（会計と合算しない）===")
ps = fs.projects_summary({"details": {"2026/04": [{"money": 100, "bucket": "受注"},
                                                  {"money": 900, "bucket": "見込"}],
                                      "2026/05": [{"money": 200, "bucket": "受注"}]},
                          "state_data": [{"label": "請求待ち", "count": 2, "money": 500}]},
                         2026, date(2026, 8, 11))
(ok if ps["fy_total"] == 300 else ng)("受注だけを合計する（見込を混ぜない）", ps["fy_total"])
(ok if [m["month"] for m in ps["months"]] == ["2026/04", "2026/05", "2026/06", "2026/07", "2026/08"]
   else ng)("FY開始月から当月までを並べる", [m["month"] for m in ps["months"]])
(ok if ps["states"]["請求待ち"]["money"] == 500 else ng)("状態別の件数と金額")
(ok if fs.projects_summary(None, 2026, date(2026, 8, 11)) is None else ng)("データが無ければ None")

print("\n=== 本番データでのスモーク（★出力は捨てる・終了コードだけ見る）===")
# render() は116行あり上の単体テストでは通らない。実データで1回だけ通し、例外で落ちないことを見る。
# 数字・社名を画面に出さないため stdout は捨て、失敗時も先頭の例外行しか表示しない。
if PROD_FIN.is_dir():
    r = subprocess.run([sys.executable, str(proj / "bin/finance-snapshot.py"), "--no-fetch"],
                       capture_output=True, text=True, timeout=180, cwd=str(proj))
    (ok if r.returncode == 0 else ng)("人が読む要約が最後まで生成できる",
                                      (r.stderr.strip().splitlines() or [""])[-1][:120])
    (ok if len(r.stdout) > 200 else ng)(f"出力が空でない（{len(r.stdout)}字・内容は表示しない）")
    r = subprocess.run([sys.executable, str(proj / "bin/finance-snapshot.py"), "--json", "--no-fetch"],
                       capture_output=True, text=True, timeout=180, cwd=str(proj))
    try:
        snap = json.loads(r.stdout)
        ok("--json が妥当な JSON を返す")
        (ok if set(snap) >= {"accounting", "financials", "projects", "recurring"} else ng)(
            "JSON の骨格キーが揃う", sorted(snap))
    except Exception as e:
        ng("--json が妥当な JSON を返す", type(e).__name__)
    # 読み取り専用の確認：本番の財務ディレクトリに書き込みが起きていないこと
    before = sorted((p.name, p.stat().st_mtime) for p in PROD_FIN.iterdir())
    subprocess.run([sys.executable, str(proj / "bin/finance-snapshot.py"), "--no-fetch"],
                   capture_output=True, text=True, timeout=180, cwd=str(proj))
    after = sorted((p.name, p.stat().st_mtime) for p in PROD_FIN.iterdir())
    (ok if before == after else ng)("読み取り専用（data/financial/ を書き換えない）")
else:
    print("  ⏭  data/financial/ が無い環境のためスモークは省略")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
