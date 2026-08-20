#!/usr/bin/env bash
# bin/journal-mcp-merge.py と bin/journal-mcp-export.sh（F-017 仕訳帳のMCP取り込み）の回帰テスト。
#
# 契機＝2026-08-18、F-017 実装。rules/testing.md §2 の必須3条件すべてに当たる：
#   ①夜間 cron から無人で走る ②status.json / サイドカーという状態ファイルを書く
#   ③貸借検算・削除検知・DRIFT・縮小ガードという判定ロジックを持つ
# 壊れ方が静か＝**仕訳帳が古いまま「最新」の顔をする**のが最悪。だから
#   「失敗したら前回CSVを絶対に書き換えない」「成功したときだけ last_success を進める」
# の2つを軸に置く。緩めば社長は古い★要確認を見て判断してしまう。
#
# ⚠️ MCP へも Slack へも接続しない：claude と slack.sh をスタブに差し替え、
#    データはすべて架空（社名・金額とも実在しない）。実データは1バイトも使わない。
# 触ったら必ず流すこと：bash bin/test-journal-mcp.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE="$PROJ/bin/journal-mcp-merge.py"
EXPORT="$PROJ/bin/journal-mcp-export.sh"
[ -f "$MERGE" ] && [ -f "$EXPORT" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

P=0; N=0
ok()  { P=$((P+1)); printf '✅ %s\n' "$1"; }
ng()  { N=$((N+1)); printf '❌ %s\n' "$1"; }

echo "── journal-mcp-merge.py（変換・マージ・検算）"
py_out="$T/py.out"
MERGE_PATH="$MERGE" python3 - >"$py_out" 2>&1 <<'PYEOF'
import importlib.util, io, json, os, pathlib, sys, tempfile

spec = importlib.util.spec_from_file_location("jm", os.environ["MERGE_PATH"])
jm = importlib.util.module_from_spec(spec); spec.loader.exec_module(jm)

P = N = 0
def ok(m):
    global P; P += 1; print("✅", m)
def ng(m):
    global N; N += 1; print("❌", m)
def eq(got, want, m):
    ok(m) if got == want else ng(f"{m}（期待 {want!r} / 実際 {got!r}）")
def truth(c, m):
    ok(m) if c else ng(m)

# ---- 架空の仕訳（実在しない社名・金額）--------------------------------------
def part(acct, sub=None, tax="対象外", value=0, tax_value=0, kind="INVOICE_KIND_NOT_TARGET",
         dept=None, partner=None):
    return {"account_name": acct, "sub_account_name": sub, "department_name": dept,
            "trade_partner_name": partner, "tax_long_name": tax, "tax_name": "略",
            "value": value, "tax_value": tax_value, "invoice_kind": kind}

J_SIMPLE = {"number": 10, "transaction_date": "2026-05-02", "tags": [], "memo": "",
            "branches": [{"debitor": part("通信費", "サーバー", "課税仕入 10%", 1000, 100,
                                          "INVOICE_KIND_QUALIFIED"),
                          "creditor": part("普通預金", "架空銀行ダミー支店", "対象外", 1100, 0),
                          "remark": "架空ホスティング"}]}

J_SPLIT = {"number": 11, "transaction_date": "2026-05-03", "tags": ["架空タグ"], "memo": "架空メモ",
           "branches": [{"debitor": part("消耗品費", None, "課税仕入 10%", 2000, 200),
                         "creditor": None, "remark": "諸口A"},
                        {"debitor": None,
                         "creditor": part("未払金", "架空カード", "対象外", 2200, 0),
                         "remark": "諸口B"}]}

# 1) 税込計算・税区分・日付書式・摘要
r = jm.journal_rows(J_SIMPLE)
eq(len(r), 1, "1 branch = CSV 1 行")
eq(r[0][0], "10", "取引No を写す")
eq(r[0][1], "2026/05/02", "取引日は '-' を '/' に直す（MFのCSV書式）")
eq(r[0][8], "1100", "借方金額は value+tax_value ＝**税込**（MCPは本体と税を分けて返す）")
eq(r[0][15], "1100", "貸方金額も税込")
eq(r[0][6], "課税仕入 10%", "税区分は tax_long_name（tax_name は CSV と表記が違う）")
eq(r[0][2], "通信費", "借方勘定科目")
eq(r[0][3], "サーバー", "借方補助科目")
eq(r[0][16], "架空ホスティング", "摘要は branch.remark")
eq(r[0][7], "", "借方インボイス列は空（実データも全行空）")

# 2) 片側 null（諸口）＝反対側の列と金額を空にする
r = jm.journal_rows(J_SPLIT)
eq(len(r), 2, "branch の数だけ行が出る（順序保持）")
eq(r[0][9:16], ["", "", "", "", "", "", ""], "creditor が null なら貸方列は**金額も**空")
eq(r[1][2:9], ["", "", "", "", "", "", ""], "debitor が null なら借方列は**金額も**空")
eq(r[0][8], "2200", "諸口でも借方金額は税込")
eq(r[0][17], "架空タグ", "タグは仕訳単位で全行に付く")
eq(r[0][18], "架空メモ", "メモは仕訳単位で全行に付く")

# 3) 未知の invoice_kind は黙って空にせず申告する
w = []
jm.journal_rows({"number": 12, "transaction_date": "2026-05-04", "branches": [
    {"debitor": part("仕入高", kind="INVOICE_KIND_MYSTERY", value=100), "creditor": None,
     "remark": ""}]}, w)
truth(any("INVOICE_KIND_MYSTERY" in x for x in w), "未知の invoice_kind を warn に出す（仕様の穴に気づける）")

# 4) CSV 読み書きの往復
tmp = pathlib.Path(tempfile.mkdtemp())
out = tmp / "FY2026.csv"
rows = jm.journal_rows(J_SIMPLE) + jm.journal_rows(J_SPLIT)
jm.write_csv(out, rows)
eq(jm.read_csv(out), rows, "cp932 で書いて読み戻すと一致する")
truth(out.read_bytes().startswith('"取引No"'.encode("cp932")), "全項目をクォートして書く（MFのCSVと同じ形）")
truth(b"\r\n" in out.read_bytes(), "改行は CRLF（MFのCSVと同じ）")
truth(not (tmp / "FY2026.csv.tmp").exists(), "書き終えたら一時ファイルを残さない（原子的な置き換え）")

# 5) cp932 に無い文字で落ちない（絵文字が摘要に混ざっても書き出しを止めない）
j_emoji = dict(J_SIMPLE); j_emoji = json.loads(json.dumps(J_SIMPLE))
j_emoji["branches"][0]["remark"] = "架空🎉店"
try:
    jm.write_csv(tmp / "emoji.csv", jm.journal_rows(j_emoji)); ok("cp932 で表せない文字があっても書き出しを止めない")
except Exception as e:
    ng(f"cp932 外の文字で落ちた: {e}")

# 6) 列が違う既存CSVは黙って受け入れない
bad = tmp / "bad.csv"
bad.write_bytes("取引No,取引日\r\n1,2026/04/01\r\n".encode("cp932"))
try:
    jm.read_csv(bad); ng("列が違う既存CSVを読み飛ばしてしまった")
except ValueError:
    ok("列が違う既存CSVは ValueError で止める（黙って壊さない）")

# ---- マージ -----------------------------------------------------------------
E = jm.journal_rows(J_SIMPLE) + jm.journal_rows(J_SPLIT)          # 5/2, 5/3
WIN = ["2026/05/03", "2026/05/31"]

# 7) 新規追加
J_NEW = {"number": 20, "transaction_date": "2026/05/10".replace("/", "-"), "tags": [], "memo": "",
         "branches": [{"debitor": part("旅費交通費", None, "課税仕入 10%", 500, 50),
                       "creditor": part("現金", None, "対象外", 550, 0), "remark": "架空移動"}]}
m, st = jm.merge(E, {"20": jm.journal_rows(J_NEW)}, WIN, {"11", "20"})
eq(len(m), 4, "新規仕訳を足す")
eq(st["added"], ["20"], "追加として数える")

# 8) 差し替え（同じ取引No が来たら丸ごと入れ替える）
J_FIX = json.loads(json.dumps(J_SPLIT)); J_FIX["branches"] = J_FIX["branches"][:1]
J_FIX["branches"][0]["creditor"] = part("未払金", "架空カード", "対象外", 2200, 0)
m, st = jm.merge(E, {"11": jm.journal_rows(J_FIX)}, WIN, {"11"})
eq([r[0] for r in m], ["10", "11"], "差し替え後も取引Noの重複が出ない")
eq(len([r for r in m if r[0] == "11"]), 1, "2行だった仕訳が1行に直る（古い行が残らない）")
eq(st["replaced"], ["11"], "差替として数える")

# 9) 窓の中で index に無い＝MF で消された → 落とす
m, st = jm.merge(E, {}, WIN, set())
eq([r[0] for r in m], ["10"], "窓の中で MF から消えた仕訳は手元からも消す")
eq(st["deleted_in_mf"], ["11"], "削除として数える")

# 10) ★窓の外は触らない（ここが緩むと過去が消える）
m, _ = jm.merge(E, {}, ["2026/06/01", "2026/06/30"], set())
eq(len(m), 3, "窓の外の仕訳は index に無くても絶対に消さない")

# 11) 並び順＝取引日昇順・同日は取引No昇順
J_A = {"number": 99, "transaction_date": "2026-05-01", "tags": [], "memo": "",
       "branches": [{"debitor": part("雑費", None, "対象外", 10), "creditor": part("現金", None, "対象外", 10), "remark": ""}]}
J_B = {"number": 5, "transaction_date": "2026-05-01", "tags": [], "memo": "",
       "branches": [{"debitor": part("雑費", None, "対象外", 20), "creditor": part("現金", None, "対象外", 20), "remark": ""}]}
m, _ = jm.merge([], {"99": jm.journal_rows(J_A), "5": jm.journal_rows(J_B)},
                ["2026/05/01", "2026/05/31"], {"5", "99"})
eq([r[0] for r in m], ["5", "99"], "同じ日は取引No 昇順（並びが毎回同じ＝差分が読める）")

# ---- 検算 -------------------------------------------------------------------
def probs(rows, total=None, prev=0, pct=5.0):
    return jm.validate(rows, total, prev, pct)

good = jm.journal_rows(J_SIMPLE)
eq(probs(good), [], "正常なら指摘なし")
truth(any("0件" in x for x in probs([])), "0件は異常として申告（取得失敗を成功に化けさせない）")

broken = json.loads(json.dumps(good)); broken[0][15] = "999"
truth(any("貸借" in x for x in probs(broken)), "貸借不一致を検出（転記漏れの最有力な兆候）")

bad_date = json.loads(json.dumps(good)); bad_date[0][1] = "2026-05-02"
truth(any("取引日" in x for x in probs(bad_date)), "取引日の書式違反を検出")

bad_amt = json.loads(json.dumps(good)); bad_amt[0][8] = "1,100"
truth(any("借方金額" in x for x in probs(bad_amt)), "金額に桁区切りが混ざったら検出")

short = json.loads(json.dumps(good)); short[0] = short[0][:5]
truth(any("列数" in x for x in probs(short)), "列数違いを検出")

truth(any(x.startswith("DRIFT:") for x in probs(good, total=99)),
      "MF の全件数と合わなければ DRIFT として申告（窓の外の増減に気づく唯一の手掛かり）")
truth(any("減りました" in x for x in probs(good, prev=100)),
      "行数が大きく減ったら中止する（取得漏れの地滑りを止める）")
truth(not any("減りました" in x for x in probs(good, prev=1)),
      "少数の削除は通す（正当な削除まで止めない）")
truth(not any("減りました" in x for x in probs(good, prev=3)),
      "★行数が少ない年度始めに 1〜2 行減っただけで止めない（割合だけで見ない）")

# ---- CLI（前回CSVを守るか）---------------------------------------------------
def run_cli(staging, out, extra=()):
    import subprocess
    a = [sys.executable, os.environ["MERGE_PATH"], "--staging", str(staging), "--out", str(out),
         "--window-start", "2026-05-01", "--window-end", "2026-05-31", *extra]
    r = subprocess.run(a, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr

def stage(d, index_lines, journals, total=None):
    d.mkdir(parents=True, exist_ok=True)
    (d / "index.jsonl").write_text("\n".join(index_lines), encoding="utf-8")
    (d / "changed.json").write_text(json.dumps({"fy_total_count": total, "journals": journals},
                                               ensure_ascii=False), encoding="utf-8")

base = tmp / "cli"; base.mkdir()
csv_path = base / "FY2026.csv"
jm.write_csv(csv_path, E)
before = csv_path.read_bytes()

# 12) 検算に落ちたら CSV を書き換えない
st_dir = base / "s1"
broken_j = json.loads(json.dumps(J_NEW)); broken_j["branches"][0]["creditor"]["value"] = 1
stage(st_dir, ['{"n":10,"u":"a"}', '{"n":11,"u":"b"}', '{"n":20,"u":"c"}'], [broken_j])
rc, o = run_cli(st_dir, csv_path)
eq(rc, 2, "貸借が合わない取り込みは rc=2 で中止")
truth(csv_path.read_bytes() == before, "★中止したとき前回CSVは1バイトも変えない")
truth("残しました" in o, "前回CSVを残したことを申告する")

# 13) index.jsonl が壊れていたら中止（前回CSVを守る）
st_dir = base / "s2"; st_dir.mkdir()
(st_dir / "index.jsonl").write_text('{"n":10,"u":"a"}\nこわれた\n', encoding="utf-8")
(st_dir / "changed.json").write_text('{"journals":[]}', encoding="utf-8")
rc, o = run_cli(st_dir, csv_path)
eq(rc, 2, "壊れた index.jsonl は rc=2 で中止")
truth(csv_path.read_bytes() == before, "壊れた入力でも前回CSVを守る")

# 14) staging が無ければ中止
rc, o = run_cli(base / "nope", csv_path)
eq(rc, 2, "staging が無ければ rc=2（空の取得を成功にしない）")

# 15) 正常系：書き換わる・サイドカーが更新される
st_dir = base / "s3"
side = base / "FY2026.updates.json"
side.write_text(json.dumps({"10": "a", "11": "b"}), encoding="utf-8")
stage(st_dir, ['{"n":10,"u":"a"}', '{"n":20,"u":"c"}'], [J_NEW], total=2)
rc, o = run_cli(st_dir, csv_path, ("--sidecar", str(side)))
eq(rc, 0, "正常な取り込みは rc=0")
after = jm.read_csv(csv_path)
truth(any(r[0] == "20" for r in after), "新しい仕訳が入る")
truth(not any(r[0] == "11" for r in after), "窓内で MF から消えた仕訳が消える")
sd = json.loads(side.read_text(encoding="utf-8"))
truth("11" not in sd and sd.get("20") == "c", "サイドカーが index に追随する（消えた分は消え、新しい版が入る）")

# 16) DRIFT は rc=3（書き出しはするが「成功」と言い切らない）
st_dir = base / "s4"
stage(st_dir, ['{"n":10,"u":"a"}', '{"n":20,"u":"c"}'], [], total=999)
rc, o = run_cli(st_dir, csv_path)
eq(rc, 3, "件数が MF と合わなければ rc=3（黙って成功にしない）")
truth("DRIFT" in o, "DRIFT を本文で申告する")

# 17) --dry-run は書き換えない
snapshot = csv_path.read_bytes()
st_dir = base / "s5"
stage(st_dir, ['{"n":10,"u":"a"}'], [], total=1)
rc, o = run_cli(st_dir, csv_path, ("--dry-run",))
truth(csv_path.read_bytes() == snapshot, "--dry-run は CSV を書き換えない")

print(f"PY_TOTAL {P} {N}")
PYEOF
cat "$py_out" | grep -v '^PY_TOTAL'
pyp=$(grep '^PY_TOTAL' "$py_out" | awk '{print $2}'); pyn=$(grep '^PY_TOTAL' "$py_out" | awk '{print $3}')
if [ -z "${pyp:-}" ]; then ng "Python 側のテストが最後まで走らなかった"; else P=$((P+pyp)); N=$((N+pyn)); fi

echo
echo "── journal-mcp-export.sh（起動・停止条件）"
# 偽プロジェクト：claude と slack.sh をスタブに差し替え、MCP へも Slack へも触らない
FP="$T/proj"; mkdir -p "$FP/bin" "$FP/data/financial/journal"
cp "$MERGE" "$FP/bin/"; cp "$EXPORT" "$FP/bin/"
cat > "$FP/bin/slack.sh" <<'S'
#!/usr/bin/env bash
cat > "$SLACK_REC"
S
chmod +x "$FP/bin/slack.sh"
export SLACK_REC="$T/slack-body"

# 架空の起点CSV（実データは使わない）
python3 - "$MERGE" "$FP/data/financial/journal/FY2026.csv" <<'S'
import importlib.util, pathlib, sys
s = importlib.util.spec_from_file_location("jm", sys.argv[1]); jm = importlib.util.module_from_spec(s); s.loader.exec_module(jm)
j = {"number": 1, "transaction_date": "2026-04-01", "tags": [], "memo": "", "branches": [
    {"debitor": {"account_name": "現金", "sub_account_name": None, "department_name": None,
                 "trade_partner_name": None, "tax_long_name": "対象外", "value": 1000, "tax_value": 0,
                 "invoice_kind": "INVOICE_KIND_NOT_TARGET"},
     "creditor": {"account_name": "資本金", "sub_account_name": None, "department_name": None,
                  "trade_partner_name": None, "tax_long_name": "対象外", "value": 1000, "tax_value": 0,
                  "invoice_kind": "INVOICE_KIND_NOT_TARGET"}, "remark": "架空開始残高"}]}
jm.write_csv(pathlib.Path(sys.argv[2]), jm.journal_rows(j))
S

GEN="$FP/data/financial/generated/journal-mcp"
run_exp() { MYAGENT_PROJ="$FP" CLAUDE="$T/fake-claude" JOURNAL_MCP_NO_SLACK=0 bash "$FP/bin/journal-mcp-export.sh" "$@" 2>&1; }

# 1) 起点が無いまま日次実行 → 中止して Slack で申告
rm -f "$SLACK_REC"
o=$(JOURNAL_MCP_TODAY=2026-05-10 run_exp); rc=$?
[ "$rc" -ne 0 ] && ok "起点CSVが無いまま日次実行したら中止する" || ng "起点が無いのに成功した"
grep -q "seed" <<<"$o" && ok "--seed をやれと案内する" || ng "案内が無い"
[ -f "$SLACK_REC" ] && ok "失敗は Slack へ申告する（黙って止まらない）" || ng "失敗が Slack に出ない"
grep -qi "token\|xox\|secret" "$SLACK_REC" 2>/dev/null && ng "Slack本文に秘密らしき語が出た" || ok "Slack本文に秘密情報を載せない"

# 2) --seed
o=$(JOURNAL_MCP_TODAY=2026-05-10 run_exp --seed); rc=$?
[ "$rc" -eq 0 ] && ok "--seed は成功する" || ng "--seed が失敗した: $o"
[ -f "$GEN/FY2026.csv" ] && ok "--seed が起点CSVを作る" || ng "起点CSVが出来ていない"
grep -q '"state": "ok"' "$GEN/status.json" && ok "--seed が status.json を残す" || ng "status.json が無い"

# 3) 年度判定＝3月は前年度（4月始まり）
o=$(JOURNAL_MCP_TODAY=2027-03-31 run_exp --seed 2>&1)
grep -q "FY2026.csv" <<<"$o" && ok "3月は前年度（FY2026）と判定する（会計年度は4月始まり）" || ng "年度判定が違う: $o"

# 4) claude が失敗したら CSV を書き換えず非0
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/fake-claude"; chmod +x "$T/fake-claude"
sum_before=$(md5sum < "$GEN/FY2026.csv")
success_before=$(python3 -c "import json;print(json.load(open('$GEN/status.json'))['last_success'])")
# ★1秒待つ理由★：時刻は秒までしか持たないので、直前の --seed と同じ秒に失敗させると
#   「進めてしまった」場合でも値が一致してテストが素通りする（変異テストで実際に素通りした）。
sleep 1
rm -f "$SLACK_REC"
o=$(JOURNAL_MCP_TODAY=2026-05-10 run_exp); rc=$?
[ "$rc" -ne 0 ] && ok "claude の取得失敗は非0で終わる" || ng "取得に失敗したのに成功扱い"
[ "$(md5sum < "$GEN/FY2026.csv")" = "$sum_before" ] && ok "★取得失敗時に前回CSVを書き換えない" || ng "取得失敗でCSVが壊れた"
[ -f "$SLACK_REC" ] && ok "取得失敗を Slack へ申告する" || ng "取得失敗が黙って終わった"
grep -q '"state": "error"' "$GEN/status.json" && ok "status.json に失敗を刻む" || ng "status に失敗が残らない"
# ★秒単位の時刻で比べると同一秒に走ったとき誤判定する。**失敗前後で値が変わらない**ことを見る
[ "$(python3 -c "import json;print(json.load(open('$GEN/status.json'))['last_success'])")" = "$success_before" ] \
  && ok "★失敗しても last_success は進めない（画面が古さを出せる）" || ng "失敗で last_success が進んだ"

# 5) 前回の staging を持ち越さない（取れていないのに取れたことにしない）
mkdir -p "$GEN/.staging"
echo '{"n":1,"u":"x"}' > "$GEN/.staging/index.jsonl"
echo '{"journals":[]}' > "$GEN/.staging/changed.json"
JOURNAL_MCP_TODAY=2026-05-10 run_exp >/dev/null 2>&1
[ ! -s "$GEN/.staging/index.jsonl" ] && ok "★実行のたびに staging を空にする（前回の残骸を今回の取得と取り違えない）" \
  || ng "前回の staging が残ったまま使われる"

# 6) claude が index/changed を作らなかったら中止
printf '#!/usr/bin/env bash\necho done 0 0\nexit 0\n' > "$T/fake-claude"; chmod +x "$T/fake-claude"
sum_before=$(md5sum < "$GEN/FY2026.csv")
o=$(JOURNAL_MCP_TODAY=2026-05-10 run_exp); rc=$?
[ "$rc" -ne 0 ] && ok "claude が正常終了でもファイルが無ければ中止（認証切れの形）" || ng "空取得を成功にした"
[ "$(md5sum < "$GEN/FY2026.csv")" = "$sum_before" ] && ok "空取得でも前回CSVを守る" || ng "空取得でCSVが壊れた"

# 7) 正常系：スタブ claude が staging を作れば取り込まれる
cat > "$T/fake-claude" <<'C'
#!/usr/bin/env bash
d="$FAKE_STAGING"
mkdir -p "$d"
printf '{"n":1,"u":"v1"}\n{"n":2,"u":"v1"}\n' > "$d/index.jsonl"
cat > "$d/changed.json" <<'J'
{"fy_total_count": 2, "journals": [
 {"number": 2, "transaction_date": "2026-05-08", "tags": [], "memo": "",
  "branches": [{"debitor": {"account_name":"雑費","sub_account_name":null,"department_name":null,
                 "trade_partner_name":null,"tax_long_name":"対象外","value":300,"tax_value":0,
                 "invoice_kind":"INVOICE_KIND_NOT_TARGET"},
                "creditor": {"account_name":"現金","sub_account_name":null,"department_name":null,
                 "trade_partner_name":null,"tax_long_name":"対象外","value":300,"tax_value":0,
                 "invoice_kind":"INVOICE_KIND_NOT_TARGET"}, "remark": "架空の追加"}]}]}
J
echo "done 2 1"
C
chmod +x "$T/fake-claude"
export FAKE_STAGING="$GEN/.staging"
o=$(JOURNAL_MCP_TODAY=2026-05-10 run_exp); rc=$?
[ "$rc" -eq 0 ] && ok "正常な取得は rc=0" || ng "正常系が失敗した: $o"
grep -q "架空の追加" <(iconv -f cp932 -t utf-8 "$GEN/FY2026.csv") && ok "取り込んだ仕訳がCSVに入る" || ng "取り込まれていない"
grep -q '"state": "ok"' "$GEN/status.json" && ok "成功を status.json に刻む" || ng "status が ok にならない"
[ ! -d "$GEN/.staging" ] && ok "成功したら staging を片付ける" || ng "staging が残る"
python3 -c "
import json,sys; d=json.load(open('$GEN/FY2026.updates.json'))
sys.exit(0 if d.get('2')=='v1' else 1)" && ok "サイドカーに版が記録される（次回の差分判定に効く）" || ng "サイドカーが更新されない"

# 8) 実データに触れていないこと（このテストは架空データだけで完結する）
grep -rq "サンヒル\|HEROES" "$T" 2>/dev/null && ng "実在の取引先名がテスト作業先に混入した" || ok "実データ・実在名を1件も使っていない"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
