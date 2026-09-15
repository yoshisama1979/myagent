#!/usr/bin/env bash
# test-ledger-watch.sh ── bin/ledger-watch.py の回帰テスト
#
# なぜ要るか（rules/testing.md §2）：snapshot が状態を書き、フラグ分けは判定ロジックだから。
# とくに §1 は 2026-09-12 に実際に踏んだバグの固定＝**履歴の無い器が「横ばい」に化ける**
# （shigatoyota は7日で +62KB なのに「週あたり 0.0K」＝🟡 と出た）。
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$PROJ/bin/ledger-watch.py"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
R="$TMP/root"
mkdir -p "$R/bin" "$R/data/overseer" "$R/data/mailbox/new" "$R/data/mailbox/hold" \
         "$R/data/ledgers" "$R/data/triage" "$R/data/hp-improve"
run() { LEDGER_WATCH_ROOT="$R" python3 "$TOOL" "$@" 2>&1; }
DAY() { date -d "$1 days ago" +%Y-%m-%d; }

# 閾値の正＝system-health.py（本物と同じ契約のスタブを置く）
cat > "$R/bin/system-health.py" <<'PYS'
KB = 1024
STATE_FILES = [
    ("data/ledgers/growing.md", 10 * KB, "テスト"),
    ("data/ledgers/shrinking.md", 10 * KB, "テスト"),
    ("data/ledgers/brandnew.md", 10 * KB, "テスト"),
    ("data/ledgers/fine.md", 10 * KB, "テスト"),
    ("data/ledgers/absent.md", 10 * KB, "テスト"),
]
def hp_loop_states():
    return [("data/ledgers/dynamic.md", 10 * KB, "テスト（動的）")]
if __name__ == "__main__":
    raise SystemExit("この行が走ったら import が実行してしまっている")
PYS

mk() { python3 -c "import sys;open(sys.argv[1],'wb').write(b'x'*int(sys.argv[2]))" "$R/$1" "$2"; }
mk data/ledgers/growing.md   40960   # 40K（上限10K・増加中）
mk data/ledgers/shrinking.md 20480   # 20K（上限10K・減少中）
mk data/ledgers/brandnew.md  30720   # 30K（履歴なし）
mk data/ledgers/fine.md       1024   # 1K（上限内）
mk data/ledgers/dynamic.md   51200   # 50K（動的定義側）

# サイズ履歴（28日前・14日前・本日相当）
{
  printf '{"ts":"%sT01:00:00","states":[{"path":"data/ledgers/growing.md","bytes":10240},{"path":"data/ledgers/shrinking.md","bytes":40960},{"path":"data/ledgers/fine.md","bytes":1024},{"path":"data/ledgers/dynamic.md","bytes":10240}]}\n' "$(DAY 28)"
  printf '{"ts":"%sT01:00:00","states":[{"path":"data/ledgers/growing.md","bytes":30720},{"path":"data/ledgers/shrinking.md","bytes":30720},{"path":"data/ledgers/fine.md","bytes":1024},{"path":"data/ledgers/dynamic.md","bytes":30720}]}\n' "$(DAY 7)"
  printf 'これは壊れた行\n'
} > "$R/data/overseer/system-health.jsonl"

echo "── §1 傾きの基準（履歴の無い器を「横ばい」に化けさせない）"
out="$(run report)"
printf '%s' "$out" | grep -qE '🆕.*brandnew\.md.*傾き不明' \
  && ok "履歴が無い器は🆕＋「傾き不明」（0と名乗らない）" || { printf '%s\n' "$out" | head -14 >&2; ng "brandnew が 🆕/傾き不明 になっていない"; }
printf '%s' "$out" | grep -qE '🔴.*growing\.md' && ok "超過かつ増加は🔴" || ng "growing が 🔴 でない"
printf '%s' "$out" | grep -qE '🟡.*shrinking\.md' && ok "超過だが減少は🟡" || ng "shrinking が 🟡 でない"
printf '%s' "$out" | grep -q 'fine.md' && ng "上限内のものを一覧に出している" || ok "上限内は省略する（鳴りっぱなしにしない）"
printf '%s' "$out" | grep -q 'absent.md' && ng "存在しないファイルを出している" || ok "存在しないファイルは飛ばす"

echo "── §2 閾値の正は system-health.py（2つ目の定義を作らない）"
printf '%s' "$out" | grep -qE 'dynamic\.md' \
  && ok "hp_loop_states() の動的定義も拾う" || ng "動的定義を拾えていない"
python3 - "$R" <<'PYX'
import io,sys
p=sys.argv[1]+"/bin/system-health.py"
s=io.open(p,encoding="utf-8").read().replace('("data/ledgers/growing.md", 10 * KB','("data/ledgers/growing.md", 1000 * KB')
io.open(p,"w",encoding="utf-8").write(s)
PYX
out2="$(run report)"
printf '%s' "$out2" | grep -q 'growing.md' && ng "閾値を上げても超過のまま＝読み込んでいない" || ok "閾値を変えると結果が変わる＝正を1つにできている"
python3 - "$R" <<'PYX'
import io,sys
p=sys.argv[1]+"/bin/system-health.py"
s=io.open(p,encoding="utf-8").read().replace('("data/ledgers/growing.md", 1000 * KB','("data/ledgers/growing.md", 10 * KB')
io.open(p,"w",encoding="utf-8").write(s)
PYX

echo "── §3 キュー（mailbox）"
mkmail() { printf '{"id":"%s","to":"%s","from":"x","type":"report","ts":"%sT10:00:00+09:00","subject":"s","body":"b"}\n' "$1" "$2" "$3" > "$R/data/mailbox/$4/$1.json"; }
mkmail M-1 lane-a "$(DAY 30)" new
mkmail M-2 lane-a "$(DAY 3)"  new
mkmail M-3 lane-b "$(DAY 5)"  new
mkmail M-4 lane-c "$(DAY 9)"  hold
out="$(run report)"
printf '%s' "$out" | grep -qE 'mailbox new/ → lane-a +2 +30' && ok "宛先別に件数と最古の滞留日数を出す" || ng "lane-a の件数/最古が合わない"
printf '%s' "$out" | grep -qE 'mailbox hold/ → lane-c +1 +9' && ok "hold/（社長承認待ち）も別に数える" || ng "hold/ を数えていない"
echo 'こわれた' > "$R/data/mailbox/new/M-9.json"
out="$(run report)"
printf '%s' "$out" | grep -q '読めなかったメッセージ 1 件' && ok "読めない便を黙って捨てず申告する" || ng "壊れた便を黙殺している"
rm -f "$R/data/mailbox/new/M-9.json"

echo "── §4 判断待ち（triage 索引・skill-kaizen）"
printf '{"items":{"a":{"status":"open","lane":"hp-loop:x"},"b":{"status":"open","lane":"skill-kaizen"},"c":{"status":"asked","lane":"partner"},"d":{"status":"decided","lane":"partner"},"e":{"status":"open","lane":"skill-kaizen"}}}' > "$R/data/triage/state.json"
cat > "$R/data/hp-improve/skill-kaizen.md" <<'MD'
### K-001 あ
未判断のまま
### K-002 い
ステータス: ✅反映済み(2026-01-01)
### K-003 う
ステータス: ❌却下
### K-004 え
MD
python3 -c "
import io,sys
p=sys.argv[1]+'/data/hp-improve/skill-kaizen.md'
s=io.open(p,encoding='utf-8').read()
io.open(p,'w',encoding='utf-8').write(s.replace('### K-004 え','### K-004 え\n'+'z'*9000))
" "$R"
out="$(run report)"
printf '%s' "$out" | grep -qE '社長の判断待ち（未提示） +3' && ok "未提示(open)を数える" || ng "open の件数が合わない"
printf '%s' "$out" | grep -qE '社長へ提示済み・未決 +1' && ok "提示済み(asked)を数える" || ng "asked の件数が合わない"
printf '%s' "$out" | grep -qE 'スキル改善提案の未採否 +2' \
  && ok "件数は pending-scan の state から採る（パーサを2つ持たない）" || ng "未採否の件数が state 由来になっていない"
printf '%s' "$out" | grep -q 'うち スキル改善提案 2件（下段と同じもの・二重に数えない）' \
  && ok "合計に含まれる分を明示して二重計上に見えないようにする" || ng "内訳の注記が無い"
printf '%s' "$out" | grep -q '8KB超の肥大 1件' && ok "8KB超の肥大エントリを数える（サイズの主因を示す）" || ng "肥大エントリを数えていない"
printf '%s' "$out" | grep -q 'K-001' && ng "エントリ本文・見出しを出力している（取引先名の漏れ）" || ok "件数だけ出し本文は出さない"

echo "── §4b 見出しは ## も ### も区切り（8KB超を飲み込みで水増ししない・2026-09-14）"
python3 - "$R" <<'PYX'
import io,sys
io.open(sys.argv[1]+"/data/hp-improve/skill-kaizen.md","w",encoding="utf-8").write("### K-201 あ\n"+"a"*5000+"\n## K-202 い\n"+"b"*5000+"\n")
PYX
out="$(run report)"
printf '%s' "$out" | grep -q '8KB超の肥大 0件' && ok "## で始まる次のエントリを直前に飲み込まない（5KB＋5KB を 10KB の1件と数えない）" || ng "## のエントリを飲み込んで8KB超と数えた"
grep -q 'kaizen.py' "$PROJ/bin/ledger-watch.py" && ok "見出しの解釈は bin/kaizen.py に1本化（パーサを2つ持たない）" || ng "ledger-watch が独自に見出しを解釈している"

echo "── §5 --json と snapshot"
run report --json | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['accumulators'] and d['mailbox']; print('')" >/dev/null 2>&1 \
  && ok "--json が妥当な JSON を返す" || ng "--json が壊れている"
run snapshot >/dev/null
L="$R/data/overseer/ledger-watch.jsonl"
[ -f "$L" ] && ok "ledger-watch.jsonl を作る" || ng "snapshot がファイルを作らない"
run snapshot >/dev/null
[ "$(wc -l < "$L")" = "2" ] && ok "2回目は1行だけ追記する" || ng "追記行数が合わない"
python3 -c "import sys,json;[json.loads(l) for l in open(sys.argv[1])];print('')" "$L" >/dev/null 2>&1 \
  && ok "追記した行が JSON として読める" || ng "壊れた行を書いている"

echo "── §7 窓口の最終利用（放置されている領域の合図）"
S2="$TMP/sessions2"; mkdir -p "$S2"
mkdesk() { printf '{"type":"user","message":{"role":"user","content":"<command-name>/%s</command-name>"}}\n' "$1" > "$S2/$1.jsonl"; touch -d "$2 days ago" "$S2/$1.jsonl"; }
mkdesk board 1
mkdesk triage 20
mkdesk hp-loop 0      # cron のモードは窓口として数えない
out="$(LEDGER_WATCH_ROOT="$R" LEDGER_WATCH_SESSIONS="$S2" python3 "$TOOL" report 2>&1)"
printf '%s' "$out" | grep -qE '/board .*1日' && ok "最後に開いた日を出す" || ng "board の経過日数が合わない"
printf '%s' "$out" | grep -q '/hp-loop' && ng "cron のモードを窓口として数えている" || ok "cron のモード（hp-loop 等）は窓口に含めない"
printf '%s' "$out" | grep -qE '/finance .*一度もなし' && ok "一度も開いていない窓口を出す" || ng "未使用の窓口が出ない"
first="$(printf '%s' "$out" | awk '/^【3】/{f=1} f&&/^  \//{print; exit}')"
printf '%s' "$first" | grep -q '一度もなし' \
  && ok "「一度もなし」を先頭に置く（0日扱いで沈めない）" || ng "並び順が放置の重い順になっていない: $first"
printf '%s' "$out" | grep -qE '/triage .*20日' && ok "長く開いていない窓口の日数を出す" || ng "triage の経過日数が合わない"

echo "── §6 異常系"
rm -f "$R/data/overseer/system-health.jsonl"
out="$(run report)"; [ -n "$out" ] && ok "履歴が無くても落ちない" || ng "履歴不在で落ちる"
rm -f "$R/bin/system-health.py"
out="$(run report)"
printf '%s' "$out" | grep -q '閾値を読み込めません\|system-health.py を読み込めません' \
  && ok "閾値を読めないときは黙らず申告する" || ng "閾値不在を黙って素通りする"

echo
echo "合計: 合格 ${PASS} ／ 不合格 ${FAIL}"
[ "$FAIL" -eq 0 ]
