#!/usr/bin/env bash
# 社内共有ダッシュボード（bin/build-team-board.py）の回帰テスト。
#
# 契機＝2026-09-23 経営会議で社長ご指示。社員が見る大型モニターに常時表示するため、
# **出してはいけないもの**（取引先名・人件費・現預金・赤字額・融資・採用／退職・経理の内部状態・
# board の決定台帳の生データ）が1つも出ないことを、約束ではなく**機械で**担保する。
# board の線引き＝data/board/spec-team-board-20260923.md §4。
#
# ここで固定するのは3つ：①線に当たる欄を出さないこと ②黙って減らないこと ③正を2つ持たないこと。
# 触ったら必ず流すこと：bash bin/test-build-team-board.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$PROJ/bin/build-team-board.py"
[ -f "$TOOL" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
case "$TMP" in /tmp/*) ;; *) echo "❌ 作業先が /tmp の外: $TMP" >&2; exit 2;; esac
R="$TMP/root"; mkdir -p "$R/site/business" "$R/data/board"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ok   $1"; }
ng() { FAIL=$((FAIL+1)); echo "  NG   $1"; }
run() { TEAM_BOARD_ROOT="$R" python3 "$TOOL" "$@" 2>&1; }

# 架空の目標ツリー（実データは使わない＝testing.md §6-1・取引先名も架空）
cat > "$R/site/business/goals.html" <<'HTML'
<h2>目標</h2>
<h3>G0. 架空の最上位目標</h3>
<span class="badge badge-status-active">進行中</span>
<h3>G0.1 ふつうの中目標</h3>
<span class="badge badge-status-active">進行中</span>
<table><tr><td>数値目標</td><td class="metric">月100件</td></tr>
<tr><td>現状</td><td class="metric">月40件</td></tr></table>
<h3>G0.2 線に当たる欄を持つ中目標</h3>
<span class="badge badge-status-active">進行中</span>
<table><tr><td>数値目標</td><td class="metric">現預金 500万円</td></tr>
<tr><td>現状</td><td class="metric">月40件</td></tr></table>
<h3>G0.3 未分類仕訳の解消</h3>
<span class="badge badge-status-active">進行中</span>
<h4>G0.3.1 深さ3は出さない</h4>
<span class="badge badge-status-draft">構想中</span>
<h3>G0.4 取引先の名前が入る中目標</h3>
<span class="badge badge-status-active">進行中</span>
<table><tr><td>数値目標</td><td class="metric">カブシキガイシャ架空商事の追加受注</td></tr></table>
HTML
printf '%s' '[{"client_name":"カブシキガイシャ架空商事"}]' > "$R/data/clients-cache.json"

echo "── 出してはいけないものを機械で止める（spec §4）"
out="$(run --dry-run)"
printf '%s' "$out" | grep -q '伏せた: G0.2 の目標値' \
  && ok "「現預金」を含む欄は出さない" || ng "現預金を伏せない: $out"
printf '%s' "$out" | grep -q '伏せた: G0.3 の目標そのもの' \
  && ok "題そのものが線に当たる目標は丸ごと出さない（未分類仕訳）" || ng "G0.3 を出してしまう: $out"
printf '%s' "$out" | grep -q '伏せた: G0.4 の目標値（取引先名）' \
  && ok "取引先名を含む欄は出さない（名簿はファイルから引く）" || ng "取引先名を伏せない: $out"
printf '%s' "$out" | grep -q '架空商事' \
  && ng "伏せた理由に実名を書いている（ログにも出さない約束）: $out" \
  || ok "伏せた理由に実名を書かない"
printf '%s' "$out" | grep -q '深さ3以上 1件は出さない' \
  && ok "深さ3は出さない（1画面に収める）" || ng "深さの絞りが効いていない: $out"

echo
echo "── 生成物そのものに線に当たる語が残っていない"
run >/dev/null
page="$R/site/business/team-board.html"
[ -f "$page" ] && ok "生成できる" || ng "生成できない"
for w in 現預金 未分類仕訳 架空商事 人件費 役員報酬 採用; do
  if grep -q "$w" "$page"; then ng "生成物に「$w」が残っている"; else ok "生成物に「$w」が無い"; fi
done
grep -q '手で編集しないでください' "$page" \
  && ok "生成物だと分かる印がある（手書きとの二重管理を防ぐ）" || ng "生成物の印が無い"

echo
echo "── 黙って減らない（goals.html の構造が変わったら止まる）"
cp "$R/site/business/goals.html" "$TMP/goals.bak"
printf '%s' '<h3>G0. 架空の最上位目標</h3>' > "$R/site/business/goals.html"
out="$(run)"; rc=$?
[ "$rc" -ne 0 ] && ok "前回より減ったら終了コードで止まる" || ng "減っても黙って書いた（rc=$rc）"
printf '%s' "$out" | grep -q '書きませんでした' \
  && ok "止めたことを明言する" || ng "止めた理由を言わない: $out"
out="$(run --accept-drop)"; rc=$?
[ "$rc" -eq 0 ] && ok "意図した減少は --accept-drop で通る" || ng "承知の減少も通らない（rc=$rc）"
cp "$TMP/goals.bak" "$R/site/business/goals.html"

echo
echo "── 取りこぼしを黙らない"
cat >> "$R/site/business/goals.html" <<'HTML'
<h3>G0.9</h3>
HTML
out="$(run --accept-drop)"
printf '%s' "$out" | grep -q '読めなかった見出し' \
  && ok "読めない見出しは名指しで申告する" || ng "取りこぼしを黙った: $out"

echo
echo "── 正が1つ（目標は goals.html だけ）"
grep -q 'goals.html' "$TOOL" && ok "目標の出どころは goals.html" || ng "出どころが不明"
if grep -qE '^\s*(GOALS|TREE)\s*=\s*\[' "$TOOL"; then ng "ツール内に目標の写しを持っている"; else ok "ツール内に目標を書き写していない"; fi

echo
echo "合計: 合格 ${PASS} ／ 不合格 ${FAIL}"
[ "$FAIL" -eq 0 ]
