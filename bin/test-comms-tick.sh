#!/usr/bin/env bash
# comms-tick.sh（蒸留の起動ガード＋起票の呼び出し）の回帰テスト。
#
# rules/testing.md §2 の必須3条件に該当（無人ループ本体／状態を書く／判定を持つ）。
# ★このスクリプトの価値は「起動していいときだけ起動する」＝
#   テストの主眼も「余計に動かさないか」「動くべきときに黙って落ちないか」に置く。
#
# 本物の agent-tick.sh（claude を起動する）と todo-post.py（hana-tools へ書く）は
# **絶対に呼ばない**。PROJ を一時ディレクトリへ差し替え、両方を偽物に置き換えて確かめる。
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJ/bin/comms-tick.sh"
[ -f "$SRC" ] || { echo "❌ comms-tick.sh が無い" >&2; exit 2; }
P=0; N=0
ok() { P=$((P+1)); echo "  ✅ $1"; }
ng() { N=$((N+1)); echo "  ❌ $1"; [ $# -ge 2 ] && echo "      → $2"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

setup() {  # $1=agent-tick の終了コード  $2=gm|nogm（メールraw を作るか。既定 gm）
  rm -rf "$T/w"; mkdir -p "$T/w/bin" "$T/w/data/comms/chatwork/raw" "$T/w/site/comms"
  [ "${2:-gm}" = "gm" ] && mkdir -p "$T/w/data/comms/gmail/raw"
  sed "s#^PROJ=\"/home/vpsuser/projects/myagent\"#PROJ=\"$T/w\"#" "$SRC" > "$T/w/bin/comms-tick.sh"
  chmod +x "$T/w/bin/comms-tick.sh"
  grep -q "^PROJ=\"$T/w\"$" "$T/w/bin/comms-tick.sh" || { echo "❌ PROJ 差し替え失敗" >&2; exit 2; }
  cat > "$T/w/bin/agent-tick.sh" <<AT
#!/bin/bash
echo "AGENT \$*" >> "$T/w/calls.txt"
touch "$T/w/site/comms/index.html" "$T/w/data/comms/chatwork/.last-distill"
exit $1
AT
  cat > "$T/w/bin/todo-post.py" <<'TP'
import os, sys
open(os.environ["W"] + "/calls.txt", "a").write("POST %s\n" % " ".join(sys.argv[1:]))
if os.environ.get("POST_FAIL") == "1":
    sys.stderr.write("起票に失敗しました（テスト）\n"); sys.exit(1)
print('{"mode":"post","created":[]}')
TP
  cat > "$T/w/bin/comms-who.py" <<'WHO'
print("だれ")
WHO
  chmod +x "$T/w/bin/agent-tick.sh" "$T/w/bin/todo-post.py" "$T/w/bin/comms-who.py"
  : > "$T/w/calls.txt"
  echo '{}' > "$T/w/data/comms/chatwork/raw/a.jsonl"
  echo 'C-001 | 👥 | 💬 R〔A→B〕 | x | y | 担当: A | 最終: 09/04 | cw: 1-2' \
       > "$T/w/data/comms/chatwork/ledger.md"
}
run() { W="$T/w" "$@" "$T/w/bin/comms-tick.sh" 2>&1; }
calls() { awk '{print $1}' "$T/w/calls.txt" | tr '\n' ' '; }

echo "=== 新着があるとき ==="
setup 0; r=$(run env)
grep -q "AGENT daily comms" "$T/w/calls.txt" \
  && ok "蒸留（agent-tick daily comms）を起動する" || ng "蒸留を起動しない" "$r"
grep -q "^POST post$" "$T/w/calls.txt" \
  && ok "★蒸留のあとに起票（todo-post.py post）を呼ぶ" || ng "起票を呼んでいない" "$r"
[ "$(calls)" = "AGENT POST " ] \
  && ok "★順番は 蒸留 → 起票（台帳が書き換わった後に起票する）" || ng "順番が違う" "$(calls)"

echo
echo "=== ★新着が無いときは何も動かさない（claude も起票も）==="
setup 0; touch "$T/w/data/comms/chatwork/.last-distill"
sleep 1; touch -d '-1 hour' "$T/w/data/comms/chatwork/raw/a.jsonl"
r=$(run env)
echo "$r" | grep -q "claude 不起動" \
  && ok "新着ゼロなら蒸留をスキップする" || ng "新着ゼロでも起動する" "$r"
[ -z "$(calls)" ] \
  && ok "★起票も呼ばない（起票すべき行は蒸留でしか生まれない）" || ng "余計に呼んでいる" "$(calls)"

echo
echo "=== ★蒸留が失敗したら起票しない（中途半端な台帳から起票しない）==="
setup 3; r=$(run env)
grep -q "AGENT daily comms" "$T/w/calls.txt" \
  && ok "蒸留は試みる" || ng "蒸留を試みない" "$r"
grep -q "POST" "$T/w/calls.txt" \
  && ng "★蒸留が失敗しても起票してしまう" "$r" || ok "★蒸留が失敗したら起票しない"
echo "$r" | grep -q "台帳が中途半端" \
  && ok "理由をログに残す（黙って飛ばさない）" || ng "理由が残らない" "$r"

echo
echo "=== ★起票が失敗しても comms-tick は止めない（次の2hティックが拾い直す）==="
setup 0; r=$(POST_FAIL=1 run env POST_FAIL=1); rc=$?
echo "$r" | grep -q "起票に失敗" \
  && ok "起票の失敗をログに申告する" || ng "失敗を黙っている" "$r"
[ "$rc" -eq 0 ] \
  && ok "★起票が失敗しても終了コードは蒸留のもの（ループを止めない）" || ng "起票の失敗でループが止まる（rc=$rc）"

echo
echo "=== ★起票の宿題は、新着ゼロでも再試行する（2026-09-04 Codexレビュー🔴）==="
# 「次の2hティックが拾い直す」は、新着が来ないと成立しない。
# 起票の成否は蒸留とは別のマーカーで持ち、失敗が残っていれば新着ゼロでも起票だけ走らせる。
setup 0 gm
r=$(POST_FAIL=1 run env POST_FAIL=1)
[ -f "$T/w/data/comms/chatwork/.post-pending" ] \
  && ok "★起票に失敗したら宿題マーカーを残す" || ng "失敗を記録していない" "$r"
# 続けて「新着ゼロ」のティックを回す（マーカーは前回の実行で更新済み）
: > "$T/w/calls.txt"
touch "$T/w/data/comms/chatwork/.last-distill"; sleep 1
touch -d '-1 hour' "$T/w/data/comms/chatwork/raw/a.jsonl"
r=$(run env)
echo "$r" | grep -q "post-retry" \
  && ok "★新着ゼロでも起票だけ再試行する" || ng "新着が来るまで宿題が残る" "$r"
[ "$(calls)" = "POST " ] \
  && ok "★そのとき蒸留（claude）は起動しない" || ng "claude まで起動している" "$(calls)"
[ ! -f "$T/w/data/comms/chatwork/.post-pending" ] \
  && ok "★再試行が成功したら宿題マーカーを消す" || ng "成功しても宿題が残る"

echo
echo "=== ★事後検査で不整合が出たら起票しない（不完全な台帳から外部へ書かない）==="
# 宛先記法〔→〕の無い行が増えた／掲示板が未再生成、は台帳が確定していない証拠。
# どちらも $MARK を消して次回の再蒸留を促すので、$MARK の有無を起票の条件にする。
setup 0 gm
cat > "$T/w/bin/agent-tick.sh" <<AT
#!/bin/bash
echo "AGENT \$*" >> "$T/w/calls.txt"
# 宛先記法の無い行を1本増やす（＝宛先を見ずに起票した疑い）
echo 'C-002 | 👥 | 💬 R | x | y | 担当: A | 最終: 09/04 | cw: 9-9' >> "$T/w/data/comms/chatwork/ledger.md"
touch "$T/w/site/comms/index.html" "$T/w/data/comms/chatwork/.last-distill"
exit 0
AT
chmod +x "$T/w/bin/agent-tick.sh"
r=$(run env)
echo "$r" | grep -q "宛先記法" \
  && ok "宛先記法の欠落を検出する（非回帰）" || ng "検出しない" "$r"
grep -q POST "$T/w/calls.txt" \
  && ng "★不整合が出ても起票してしまう" "$r" || ok "★不整合が出たら起票しない"
[ -f "$T/w/data/comms/chatwork/.post-pending" ] \
  && ok "そのぶんは宿題として残す（次回再蒸留後に起票）" || ng "宿題に残していない"

echo
echo "=== 2ソースの起動判定（v0.5＝メールを同じ台帳へ合流。元テストから継承）==="
# ★どちらか一方に新着があれば起動する。メール側だけの新着で止まると、
#   メールで来た依頼が丸ごと台帳に載らない（2026-07-30 の合流の主目的）。
setup 0 gm
touch -d '2020-01-01' "$T/w/data/comms/chatwork/raw/a.jsonl" "$T/w/data/comms/gmail/raw/b.jsonl"
touch "$T/w/data/comms/chatwork/.last-distill"
run env | grep -q "\[skip\]" \
  && ok "両rawともマーカーより古い → 不起動" || ng "不要に起動する"

setup 0 gm
touch -d '2020-01-01' "$T/w/data/comms/chatwork/raw/a.jsonl"
touch -d '2020-01-02' "$T/w/data/comms/chatwork/.last-distill"
touch "$T/w/data/comms/gmail/raw/b.jsonl"
grep -q "AGENT daily comms" <(run env >/dev/null; cat "$T/w/calls.txt") \
  && ok "★メール側だけ新着でも起動する" || ng "メールの新着で起動しない"

setup 0 gm
touch -d '2020-01-01' "$T/w/data/comms/gmail/raw/b.jsonl"
touch -d '2020-01-02' "$T/w/data/comms/chatwork/.last-distill"
touch "$T/w/data/comms/chatwork/raw/a.jsonl"
grep -q "AGENT daily comms" <(run env >/dev/null; cat "$T/w/calls.txt") \
  && ok "Chatwork側だけ新着でも起動する（非回帰）" || ng "Chatworkの新着で起動しない"

setup 0 gm
touch "$T/w/data/comms/chatwork/raw/a.jsonl"
grep -q "AGENT daily comms" <(run env >/dev/null; cat "$T/w/calls.txt") \
  && ok "マーカー無し（初回）は起動する" || ng "初回に起動しない"

echo
echo "=== raw ディレクトリが欠けたとき ==="
setup 0 nogm
touch -d '2020-01-01' "$T/w/data/comms/chatwork/raw/a.jsonl"
touch "$T/w/data/comms/chatwork/.last-distill"
r=$(run env)
echo "$r" | grep -q "メールの raw ディレクトリがありません" \
  && ok "メールraw が無ければ warn を出す" || ng "warn が出ない" "$r"
echo "$r" | grep -q "\[skip\]" \
  && ok "★メールraw が無くても Chatwork の判定は続ける（止めない）" || ng "メールraw 欠落で判定が止まる" "$r"

setup 0 gm; rm -rf "$T/w/data/comms/chatwork/raw"
r=$(run env); rc=$?
echo "$r" | grep -q "raw ディレクトリがありません" \
  && ok "Chatwork raw が無ければ warn を出す" || ng "warn が出ない" "$r"
[ "$rc" -ne 0 ] \
  && ok "★Chatwork raw が無ければ非0終了（poll 未稼働の異常を申告する）" || ng "0 で終了してしまう（rc=$rc）"
[ -z "$(calls)" ] \
  && ok "その場合は蒸留も起票も呼ばない" || ng "異常時に呼んでいる" "$(calls)"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
