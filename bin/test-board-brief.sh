#!/usr/bin/env bash
# bin/board-brief.py の回帰テスト（rules/testing.md §2＝判定ロジックを持つ＝スイート必須）
#
# 見張っている「静かに壊れる経路」：
#   ① 見直し期日が来ているのに exit 0 を返す（＝board が冒頭で扱わず、決定が腐る）
#   ② 台帳が壊れているのに 0件と読む（＝決定が消えたことに気づけない）
#   ③ 説明表を「読めなかった行」と鳴らし続けて警報が意味を失う
#   ④ hana-tools の日付を [:10] で切って1日前倒しに読む（2026-08-25 に2度の実害）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/bin/board-brief.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
ng()  { fail=$((fail+1)); printf '  NG   %s\n     %s\n' "$1" "$2"; }

# mk <file> <行...>  … 説明表つきの台帳を作る（実物と同じ形）
mk() {
  local f="$1"; shift
  {
    echo "# 決定台帳"
    echo
    echo "## 列の意味"
    echo "| 列 | 中身 |"
    echo "|---|---|"
    echo "| \`ID\` | D-001 から連番 |"
    echo "| \`状態\` | open / done |"
    echo
    echo "## 決定一覧"
    echo
    echo "| ID | 決めた日 | 決定 | 枝 | 降ろし先 | 見直し | 状態 |"
    echo "|---|---|---|---|---|---|---|"
    local r; for r in "$@"; do echo "$r"; done
    echo
    echo "## 詳細（根拠・経緯）"
    echo "ここは読まない。| これは表に見えるが節の外 |"
  } > "$f"
}

# t <名前> <期待exit> <期待文字列|-> <台帳> [追加引数...]
t() {
  local name="$1" want="$2" pat="$3" f="$4"; shift 4
  local out rc
  out="$(python3 "$TOOL" --no-api --file "$f" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then ng "$name" "exit=$rc（期待 $want）: $(echo "$out" | head -2 | tr '\n' ' ')"; return; fi
  if [ "$pat" != "-" ] && ! grep -qF -- "$pat" <<<"$out"; then
    ng "$name" "出力に「$pat」が無い: $(echo "$out" | tr '\n' ' ' | cut -c1-160)"; return
  fi
  ok "$name"
}

echo "§1 正常系（判定の本体）"
mk "$TMP/empty.md"
t "空の台帳は 0件・exit 0"            0 "全 0 件"      "$TMP/empty.md" --date 2026-09-06

mk "$TMP/ahead.md" "| D-001 | 2026-09-01 | ストック目標を月+20万で維持 | G0.2 | ToDo #251 | 2026-10-01 | open |"
t "期日前の open は exit 0"           0 "あと25日"     "$TMP/ahead.md" --date 2026-09-06
t "期日前は open 1件と数える"         0 "open 1・決着 0" "$TMP/ahead.md" --date 2026-09-06

t "見直し当日は exit 1（本日）"       1 "（本日）"     "$TMP/ahead.md" --date 2026-10-01
t "見直し超過は exit 1（日数つき）"   1 "5日超過"      "$TMP/ahead.md" --date 2026-10-06
t "超過は🔴の節に出る"                1 "🔴 見直しの期日が来ている" "$TMP/ahead.md" --date 2026-10-06
t "決定本文が表示される"              1 "ストック目標を月+20万で維持" "$TMP/ahead.md" --date 2026-10-06
t "決定からの経過日数を出す"          1 "決定から35日"  "$TMP/ahead.md" --date 2026-10-06

echo "§2 決着済みは鳴らさない（見直しが — でも通る）"
mk "$TMP/closed.md" \
  "| D-001 | 2026-06-01 | 決めて実行した件 | G0.1 | commit abc1234 | — | done |" \
  "| D-002 | 2026-06-02 | 取りやめた件 | G0.2 | なし | — | dropped |" \
  "| D-003 | 2026-06-03 | 置き換えられた件 | G1 | 社長 | — | superseded:D-001 |"
t "done/dropped/superseded は open に数えない" 0 "open 0・決着 3" "$TMP/closed.md" --date 2026-12-31
t "内訳を出す"                        0 "done 1・dropped 1・superseded 1" "$TMP/closed.md" --date 2026-12-31
t "open が無ければその旨を言う"       0 "open の決定はありません" "$TMP/closed.md" --date 2026-12-31

echo "§3 壊れた台帳は 0件と読まずに exit 2（②の見張り）"
mk "$TMP/badstate.md" "| D-001 | 2026-09-01 | x | G1 | なし | 2026-10-01 | オープン |"
t "状態が不正 → exit 2"               2 "状態が不正"   "$TMP/badstate.md" --date 2026-09-06

mk "$TMP/badcols.md" "| D-001 | 2026-09-01 | x | G1 | なし | open |"
t "列数が足りない → exit 2"           2 "列数が"       "$TMP/badcols.md" --date 2026-09-06

mk "$TMP/dup.md" \
  "| D-001 | 2026-09-01 | x | G1 | なし | 2026-10-01 | open |" \
  "| D-001 | 2026-09-02 | y | G1 | なし | 2026-10-01 | open |"
t "ID重複 → exit 2"                   2 "重複"         "$TMP/dup.md" --date 2026-09-06

mk "$TMP/baddate.md" "| D-001 | 2026/09/01 | x | G1 | なし | 2026-10-01 | open |"
t "決めた日が日付の形でない → exit 2" 2 "日付の形ではありません" "$TMP/baddate.md" --date 2026-09-06

mk "$TMP/noday.md" "| D-001 | 2026-02-30 | x | G1 | なし | 2026-10-01 | open |"
t "実在しない日付 → exit 2"           2 "実在しない日付" "$TMP/noday.md" --date 2026-09-06

mk "$TMP/mon13.md" "| D-001 | 2026-13-99 | x | G1 | なし | 2026-10-01 | open |"
t "13月は形が合うので実在判定で落ちる" 2 "実在しない日付" "$TMP/mon13.md" --date 2026-09-06

mk "$TMP/noreview.md" "| D-001 | 2026-09-01 | x | G1 | なし | — | open |"
t "open なのに見直しが無い → exit 2"  2 "見直し"       "$TMP/noreview.md" --date 2026-09-06

printf '# 決定台帳\n\n本文だけで見出しが無い\n' > "$TMP/nosection.md"
t "決定一覧の見出しが無い → exit 2"   2 "決定一覧"     "$TMP/nosection.md" --date 2026-09-06

t "台帳が存在しない → exit 2"         2 "台帳を読めません" "$TMP/missing.md" --date 2026-09-06

mk "$TMP/ok.md" "| D-001 | 2026-09-01 | x | G1 | なし | 2026-10-01 | open |"
t "--date が形式違い → exit 2"        2 "日付の形ではありません" "$TMP/ok.md" --date 2026/09/06
t "--date が実在しない日 → exit 2"    2 "実在しない日付" "$TMP/ok.md" --date 2026-99-99

echo "§4 取りこぼしを黙らない／誤検知しない（③の見張り）"
t "説明表は「読めなかった行」に数えない" 0 "-" "$TMP/ok.md" --date 2026-09-06
if python3 "$TOOL" --no-api --file "$TMP/ok.md" --date 2026-09-06 2>&1 | grep -q "読めなかった行"; then
  ng "説明表で警報を鳴らさない" "節の外の表を数えている＝警報が常時点灯する"
else ok "説明表で警報を鳴らさない"; fi

mk "$TMP/junk.md" \
  "| D-001 | 2026-09-01 | x | G1 | なし | 2026-10-01 | open |" \
  "| Dー002 | 2026-09-02 | 全角ハイフンのID | G1 | なし | 2026-10-01 | open |"
t "節の中の読めない行は数えて鳴らす"  0 "読めなかった行が 1 行" "$TMP/junk.md" --date 2026-09-06
t "読めない行があっても正常な行は読む" 0 "open 1・決着 0" "$TMP/junk.md" --date 2026-09-06

echo "§5 ToDo の宛先を拾う／--no-api で外部を叩かない"
mk "$TMP/todo.md" "| D-001 | 2026-09-01 | x | G1 | ToDo #251 | 2026-10-01 | open |"
t "--no-api では照会しないと明示する" 0 "--no-api のため実行していません" "$TMP/todo.md" --date 2026-09-06

echo "§6 日付の JST 換算（④の見張り・[:10] で切ると1日前倒し）"
python3 - "$TOOL" <<'PY'
import importlib.util, sys, datetime
spec = importlib.util.spec_from_file_location("bb", sys.argv[1])
bb = importlib.util.module_from_spec(spec); spec.loader.exec_module(bb)
cases = [
    ("2026-08-27T15:00:00.000000Z", datetime.date(2026, 8, 28), "UTC15時=JST翌0時（切ると1日前倒し）"),
    ("2026-08-28T00:00:00.000000Z", datetime.date(2026, 8, 28), "UTC0時=JST同日9時"),
    ("2026-12-31T15:00:00Z",        datetime.date(2027, 1, 1),  "年をまたぐ"),
    (None,                          None,                       "None は None"),
    ("",                            None,                       "空は None"),
    ("not-a-date",                  None,                       "壊れた値は None（例外にしない）"),
]
bad = 0
for v, want, why in cases:
    got = bb.jst_date(v)
    if got != want:
        print(f"  NG   jst_date({v!r}) -> {got}（期待 {want}・{why}）"); bad += 1
    else:
        print(f"  ok   jst_date: {why}")
sys.exit(1 if bad else 0)
PY
if [ $? -eq 0 ]; then pass=$((pass+6)); else fail=$((fail+1)); fi

echo "── §7 節の見出しは完全一致で選ぶ（Codex 再現A）"
{
  echo "# 決定台帳"; echo
  echo "## 決定一覧の書き方"; echo "説明の節（ここに表は無い）"; echo
  echo "## 決定一覧"; echo
  echo "| ID | 決めた日 | 決定 | 枝 | 降ろし先 | 見直し | 状態 |"
  echo "|---|---|---|---|---|---|---|"
  echo "| D-001 | 2026-09-01 | あ | G0 | なし | 2026-09-30 | open |"
} > "$TMP/head.md"
out="$(python3 "$TOOL" --file "$TMP/head.md" --date 2026-09-12 --no-api 2>&1)"; rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'D-001'; then
  ok "説明用の「## 決定一覧の書き方」に引っかからず本物の表を読む"
else ng "説明節を拾って本物の表を読み飛ばした（静かに0件）" "rc=$rc / $out"; fi
{
  echo "# 決定台帳"; echo
  echo "## 決定一覧"; echo "| ID | 決めた日 | 決定 | 枝 | 降ろし先 | 見直し | 状態 |"; echo
  echo "## 決定一覧"; echo "| ID | 決めた日 | 決定 | 枝 | 降ろし先 | 見直し | 状態 |"
} > "$TMP/dup-head.md"
out="$(python3 "$TOOL" --file "$TMP/dup-head.md" --date 2026-09-12 --no-api 2>&1)"; rc=$?
if [ "$rc" = "2" ] && printf '%s' "$out" | grep -q '見出しが 2 個'; then
  ok "同じ見出しが2つあれば、どちらか勝手に選ばず落ちる"
else ng "見出しが重複しても黙って片方を選んだ" "rc=$rc / $out"; fi

echo "── §8 先頭の | が欠けた決定行を黙って捨てない（Codex 再現B）"
mk "$TMP/nopipe.md" \
  "| D-001 | 2026-09-01 | あ | G0 | なし | 2026-09-30 | open |" \
  "D-002 | 2026-09-01 | い | G0 | なし | 2026-09-30 | open |"
out="$(python3 "$TOOL" --file "$TMP/nopipe.md" --date 2026-09-12 --no-api 2>&1)"
if printf '%s' "$out" | grep -q '読めなかった行'; then
  ok "| が欠けた行を「読めなかった行」として申告する"
else ng "| が欠けた決定行が見えないまま消えた" "$out"; fi

echo "── §9 ToDo 照会の経路（Codex 指摘＝ここが丸ごと消えてもテストが通っていた）"
python3 - "$TOOL" <<'PYX'
import importlib.util, sys, datetime
spec = importlib.util.spec_from_file_location("bb", sys.argv[1])
bb = importlib.util.module_from_spec(spec); spec.loader.exec_module(bb)
today = datetime.date(2026, 9, 12)
def row(rid, state, tid):
    return {"id": rid, "is_open": state == "open", "state": state, "todo_id": tid}
P = N = 0
def chk(cond, msg):
    global P, N
    if cond: P += 1; print(f"  ok   {msg}")
    else:    N += 1; print(f"  NG   {msg}")
# 照会できなかったときは「無い」と混ぜない
chk("照会できず" in bb.todo_line(row("D-1","open",7), {}, "接続失敗", today),
    "照会失敗を「ToDoが無い」と混ぜない")
chk("見つかりません" in bb.todo_line(row("D-1","open",7), {}, None, today),
    "照会できたが無い、は別の文言で出す")
# 両方向の食い違い＝回収を社長の申告に頼らない
done_t = {7: {"id": 7, "completed_at": "2026-09-10T00:00:00+09:00"}}
chk("台帳は open のまま" in bb.todo_line(row("D-1","open",7), done_t, None, today),
    "実行は完了なのに台帳が open なら名指しする")
open_t = {7: {"id": 7, "completed_at": None, "due_date": "2026-09-01T00:00:00+09:00"}}
chk("実行は未完了" in bb.todo_line(row("D-1","done",7), open_t, None, today),
    "台帳が done なのに実行が未完了なら名指しする（★社長の申告を信じない）")
chk(bb.todo_line(row("D-1","open",None), {}, None, today) is None,
    "降ろし先が ToDo でない決定は照会しない")
# タイムゾーン規約（todo-brief.py と揃える）
chk(bb.jst_date("2026-09-11T15:00:00Z") == datetime.date(2026, 9, 12),
    "UTC 15:00 は JST 翌日として読む")
chk(bb.jst_date("2026-09-12T00:00:00") == datetime.date(2026, 9, 12),
    "タイムゾーン無しは JST とみなす（todo-brief.py と同じ規約）")
# 担当IDの形を決め打たない
import json, tempfile, os, pathlib
d = tempfile.mkdtemp()
for shape, label in (({"a": 34}, "辞書"), ([34, 39], "配列")):
    pathlib.Path(d, "m.json").write_text(json.dumps({"hana_user_ids": shape}), encoding="utf-8")
    bb.MEMBERS = os.path.join(d, "m.json")
    bb.API = "/bin/false"
    got, err = bb.fetch_todos()
    chk(got is None and err and "AttributeError" not in err,
        f"hana_user_ids が{label}でも例外で落ちない（終了コードの衝突を防ぐ）")
print(f"__COUNT__ {P} {N}")
PYX
if [ $? -eq 0 ]; then pass=$((pass+9)); else fail=$((fail+1)); fi

echo "── §10 集計の書式（自分自身が数えられる形か）"
if grep -q '合計: 合格' "$0" && ! grep -q 'pass=\$pass fail=' "$0"; then
  ok "bin/test-all.sh が読める書式で集計を出す（rules/testing.md §5）"
else ng "独自書式のままで 0項目と数えられる" "$0"; fi

echo
# ★書式は rules/testing.md §5 が正★ bin/test-all.sh:29 は「合格 N／不合格 M」しか読めず、
#   独自書式だと **0項目** と数えられる＝スイートが丸ごと壊れても総数が減らない（Codex 指摘）。
echo "合計: 合格 ${pass} ／ 不合格 ${fail}"
[ "$fail" -eq 0 ] || exit 1
