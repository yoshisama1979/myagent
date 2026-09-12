#!/usr/bin/env bash
# test-loop-quality.sh ── bin/loop-quality.py の回帰テスト
#
# なぜ要るか（rules/testing.md §2）：snapshot が data/hp-loop/quality-log.md に追記する＝状態を書く。
# さらに「台帳の書式がサイトごとに違う」という前提の上で数えるため、判定ロジックを持つ。
# 本番のデータは使わず、LOOP_QUALITY_ROOT / LOOP_QUALITY_SESSIONS で作った一時ツリーで検証する。
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$PROJ/bin/loop-quality.py"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
R="$TMP/root"; S="$TMP/sessions"
mkdir -p "$R/data/hp-loop" "$R/data/mailbox/new" "$S"
run() { LOOP_QUALITY_ROOT="$R" LOOP_QUALITY_SESSIONS="$S" python3 "$TOOL" "$@" 2>&1; }
# 同じ site 名が【1】【2】【3】に出るため、検査する節を切り出す
sec3() { printf '%s' "$1" | awk '/^【3】/{f=1} f'; }

# --- 台帳（節構造をわざと3通りにする：番号あり・§記法・番号なし）------------------
mkdir -p "$R/data/hp-loop/alpha" "$R/data/hp-loop/beta" "$R/data/hp-loop/gamma"
cat > "$R/data/hp-loop/alpha/coverage.md" <<'MD'
## 3. 提案ライフサイクル台帳
| ID | 内容 | 状態 |
|---|---|---|
| R-001 | あ | ✅クローズ |
| R-002 | い | 🆕提案 |
| R-003 | う | 着手 |
| **R-004** | え | ❌中止 |
MD
cat > "$R/data/hp-loop/beta/coverage.md" <<'MD'
## §3 効果検証の予約（ここは提案台帳ではない）
| R-B01 | か | 効果検証 |
| R-B02 | き | 反映済 |
| R-B03 | き | （状態語なし） |
MD
cat > "$R/data/hp-loop/gamma/coverage.md" <<'MD'
## ページ・観点の踏査状況（番号なしの台帳）
| R-G1 | さ | ✅クローズ |
MD
cat > "$R/data/hp-loop/alpha/coverage-archive.md" <<'MD'
| R-001 | あ（archive の重複） | ❌中止 |
| R-050 | お | ✅クローズ |
MD

echo "── §1 台帳の構造に依存せず提案IDを拾う"
out="$(run report --days 30)"
printf '%s' "$out" | grep -qE 'alpha +1 +2 ' && ok "節に番号がある台帳を読める" \
  || { echo "$out" | grep -A6 '【3】' >&2; ng "alpha の集計が合わない"; }
printf '%s' "$out" | grep -q 'beta' && ok "§記法・別の節名でも読める" || ng "beta を読めない"
printf '%s' "$out" | grep -q 'gamma' && ok "節に番号が無い台帳でも読める" || ng "gamma を読めない"
a="$(sec3 "$out" | awk '/^  alpha/{print $NF}')"
[ "$a" = "5" ] && ok "本体4件＋archive の新規1件＝5件（重複 R-001 は二重に数えない）" || ng "alpha の計が 5 でなく $a"

echo "── §2 状態の分類（先に当たったもの勝ち・優先順位）"
sec3 "$out" | awk '/^  alpha/{exit ($2==1 && $3==2) ? 0 : 1}' \
  && ok "❌中止と✅クローズを取り違えない" || ng "中止/クローズの分類が合わない"
b="$(sec3 "$out" | awk '/^  beta/{print $(NF-1)}')"
[ "$b" = "1" ] && ok "状態語が無い行は「不明」に出す（黙って捨てない）" || ng "不明が 1 でなく $b"

echo "── §3 deploy-log と未処理の実装報告"
mkdir -p "$R/data/hp-loop/alpha"
cat > "$R/data/hp-loop/alpha/deploy-log.md" <<'MD'
| 2026-08-01 | R-001 | 反映 | id1 |
| 2026-09-04 | R-002 | 反映 | id2 |
| 2026-08-20 | R-003 | 反映 | id3 |
MD
mkmail() { printf '{"id":"%s","to":"%s","from":"dev","type":"report","ts":"%s","subject":"s","body":"b"}\n' "$1" "$2" "$3" > "$R/data/mailbox/new/$1.json"; }
mkmail M-1 hp-loop-alpha "2026-09-01T10:00:00+09:00"
mkmail M-2 hp-loop-alpha "2026-09-10T10:00:00+09:00"
mkmail M-3 other-agent    "2026-09-01T10:00:00+09:00"
out="$(run report --days 30)"
printf '%s' "$out" | grep -qE 'alpha +3 +2026-09-04 +2' \
  && ok "記録3件・最終記録は最大の日付・自分宛の便だけ数える" || ng "deploy-log の集計が合わない"
printf '%s' "$out" | grep -q 'hp-loop-alpha' && ng "他レーン宛(other-agent)を混ぜている" || ok "他レーン宛は数えない"
echo 'こわれた' > "$R/data/mailbox/new/M-4.json"
out="$(run report --days 30)"
printf '%s' "$out" | grep -q '読めなかったメッセージ 1 件' \
  && ok "読めないメッセージを申告する" || ng "壊れたメッセージを黙って捨てている"
rm -f "$R/data/mailbox/new/M-4.json"

echo "── §4 日付は JST で数える（UTC のまま切ると1日ずれる＝実害2件の前例）"
mkses() { # mkses <file> <site> <ISO時刻>
  { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<command-name>/hp-loop</command-name><command-args>%s</command-args>"}}\n' "$3" "$2"
    printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/x/data/hp-loop/%s/coverage.md","new_string":"12345"}}]}}\n' "$3" "$2"
  } > "$S/$1.jsonl"
}
# 2026-09-11T20:00:00Z = JST では 2026-09-12 05:00。JST で数えれば「今日」に入る。
mkses s1 alpha "2026-09-11T20:00:00Z"
out="$(LOOP_QUALITY_ROOT="$R" LOOP_QUALITY_SESSIONS="$S" python3 "$TOOL" report --days 1 2>&1)"
printf '%s' "$out" | grep -qE '^  alpha +1 +1' \
  && ok "UTC 20:00（JST 翌日5:00）を JST の日付で数える" || ng "UTC のまま数えて1日ずれている"

echo "── §5 産出量の集計"
mkses s2 alpha "2026-09-11T21:00:00Z"
out="$(run report --days 30)"
printf '%s' "$out" | grep -qE '^  alpha +2 +2 +1\.0 +5' \
  && ok "起動2・書込2・書込/回1.0・文字/回5" || ng "産出量の集計が合わない"

echo "── §6 snapshot（状態の書き込み）"
run snapshot --days 30 >/dev/null
LOG="$R/data/hp-loop/quality-log.md"
[ -f "$LOG" ] && ok "quality-log.md を作る" || ng "quality-log.md ができない"
grep -q '^| 記録日 |' "$LOG" && ok "初回はヘッダを書く" || ng "ヘッダが無い"
run snapshot --days 30 >/dev/null
[ "$(grep -c '^| 記録日 |' "$LOG")" = "1" ] && ok "2回目はヘッダを重ねない" || ng "ヘッダが重複した"
[ "$(grep -cE '^\| 2[0-9]{3}-' "$LOG")" = "2" ] && ok "2回目は行だけ追記する" || ng "追記行数が合わない"
grep -q '手で書かない' "$LOG" && ok "手で書かない旨をファイル自身が言う" || ng "注意書きが無い"

echo "── §7 異常系"
out="$(run report --days 0)"; printf '%s' "$out" | grep -q -- '--days は1以上' && ok "--days 0 を弾く" || ng "--days 0 が通る"
out="$(run bogus)"; [ $? -ne 0 ] && ok "未知のサブコマンドを弾く" || ng "未知のサブコマンドが通る"
rm -rf "$R/data/mailbox/new"
out="$(run report --days 30)"; [ -n "$out" ] && ok "mailbox が無くても落ちない" || ng "mailbox 不在で落ちる"

echo
echo "合計: 合格 ${PASS} ／ 不合格 ${FAIL}"
[ "$FAIL" -eq 0 ]
