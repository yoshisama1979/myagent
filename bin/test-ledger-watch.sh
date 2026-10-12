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
# 第2引数＝「何が困るか」。落ちた行だけ見て直せるようにする（他のスイートと同じ形）
ng() { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; [ -n "${2:-}" ] && printf '       → %s\n' "$2"; return 0; }

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

# 分割後＝月別が原文。①差し替えた ROOT の月別を読む（本番を読まない）②ファイルをまたいで本文が混ざらない
mkdir -p "$R/data/hp-improve/kaizen"
cat > "$R/data/hp-improve/kaizen/2026-08.md" <<'MD'
### K-101 月別の1件目
本文
MD
{ head -c 9000 /dev/zero | tr '\0' 'z'; printf '\n\n### K-102 月別の2件目\n本文\n'; } > "$R/data/hp-improve/kaizen/2026-09.md"
out="$(run report)"
printf '%s' "$out" | grep -q '見出し2件' && ok "月別があれば月別を読む（差し替えた ROOT の分＝試験が本番を読まない）" || ng "月別を読んでいない: $(printf '%s' "$out" | grep 'スキル改善提案の未採否')"
printf '%s' "$out" | grep -q '8KB超の肥大 0件' && ok "ファイルをまたいで本文が混ざらない（次のファイルの前文を前の項目に飲み込まない）" || ng "連結して飲み込んだ: $(printf '%s' "$out" | grep 'スキル改善提案の未採否')"
rm -rf "$R/data/hp-improve/kaizen"
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
# ★2026-09-27 の実害（便 b26482）：triage が社長へ「/finance は一度も開かれていません」とお伝えしたが、
#   その1時間前まで社長は finance 窓口で作業しておられた。真因＝2026-09-14 に窓口の正が
#   config/session-desks.json へ移ったのに desks() だけが `<command-name>` の痕跡しか見ていなかった。
#   **登録済みのセッションを `claude -r` で開き直すとき、社長はスラッシュコマンドを打たない**
#   ＝痕跡が無い＝「一度もなし」に見える。登録済みの窓口ほど検知から漏れる＝向きが逆の壊れ方。
#   Red の担保＝「対応表に登録されていて、スラッシュコマンドが無いセッション」を検知できること。
#
# ★この節の検査はすべて「誤報の**向き**」で考える。危ないのは2方向あって、どちらも同じ実害になる：
#   (A) 開いている窓口を「一度もなし」と言う … triage が社長の作業中の領域を手つかずと誘導する
#   (B) 開いていない窓口を「開いた」と言う … 放置が見えなくなる（警報が黙る）
S2="$TMP/sessions2"; mkdir -p "$S2" "$R/config"
# 実測の2つの形（どちらも本物のログにある）＝タグが先頭／`<command-message>` が先
mkcmd()  { printf '{"type":"user","message":{"role":"user","content":"<command-name>/%s</command-name>\\n<command-message>x</command-message>"}}\n' "$2" > "$S2/$1.jsonl"; touch -d "$3 days ago" "$S2/$1.jsonl"; }
mkbare() { printf '{"type":"user","message":{"role":"user","content":"台帳を見せて"}}\n' > "$S2/$1.jsonl"; touch -d "$2 days ago" "$S2/$1.jsonl"; }
# 対応表の正の読み手は bin/session-desk.py＝本物を置いて実際に読ませる（スタブで契約をごまかさない）
cp "$PROJ/bin/session-desk.py" "$R/bin/session-desk.py"
cat > "$R/config/session-desks.json" <<'JSON'
{
  "desks": {
    "triage":     {"label": "この窓口"},
    "management": {"label": "日々のタスク管理"},
    "dev":        {"label": "ツールの実装と修理"},
    "finance":    {"label": "経理・資金"},
    "board":      {"label": "会社の向かう先"},
    "product":    {"label": "サービス改善"},
    "work":       {"label": "ToDo 1件ずつの実作業"}
  },
  "sessions": {
    "11111111-1111-1111-1111-111111111111": "finance",
    "22222222-2222-2222-2222-222222222222": "management",
    "33333333-3333-3333-3333-333333333333": "triage",
    "44444444-4444-4444-4444-444444444444": "dev",
    "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa": "board",
    "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb": "board",
    "cccccccc-cccc-cccc-cccc-cccccccccccc": "product"
  }
}
JSON
mkbare 11111111-1111-1111-1111-111111111111 2            # finance＝登録済み・痕跡なし（実害の形）
mkcmd  22222222-2222-2222-2222-222222222222 do 0         # management＝登録済み・本文に別窓口の /do
mkcmd  33333333-3333-3333-3333-333333333333 triage 1     # triage＝登録済み＋痕跡あり
mkbare aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa 3            # board＝同じ窓口に2本・新しい方（辞書順で先）
mkbare bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb 30           # board＝古い方（辞書順で後）
mkbare cccccccc-cccc-cccc-cccc-cccccccccccc 0            # product＝あとで未来の日時にする
# ★**明日**で見る（400日先だと「1日ぶんの許容」の穴を通す＝実測で -1日 と表示された）。
touch -d "tomorrow" "$S2/cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl"
mkcmd  99999999-9999-9999-9999-999999999999 finance 10   # 未登録セッションで打たれた /finance（古い）
mkcmd  overseer-session overseer 5                       # 対応表に無い窓口＝コマンド痕跡で拾う
mkcmd  cron-session hp-loop 0                            # cron のモードは窓口として数えない
# ★本文で窓口の名前を**話題にしているだけ**の行（この修理を議論したログがまさにこの形）
printf '{"type":"user","message":{"role":"user","content":"直し方の案です。<command-name>/work</command-name> の痕跡を見ています"}}\n' \
  > "$S2/talk-session.jsonl"; touch -d "1 days ago" "$S2/talk-session.jsonl"
# ★冒頭の最初のコマンドが窓口でない（/compact）→ 後ろにある窓口のコマンドを取り落とさない
{ printf '{"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>"}}\n'
  printf '{"type":"user","message":{"role":"user","content":"<command-message>intake</command-message>\\n<command-name>/intake</command-name>"}}\n'
} > "$S2/late-session.jsonl"; touch -d "7 days ago" "$S2/late-session.jsonl"
# ★壊れた行（JSON として完結していない）＝証拠にしない
printf '{"type":"user","message":{"role":"user","content":"<command-name>/do</command-name>"\n' \
  > "$S2/broken-session.jsonl"; touch -d "0 days ago" "$S2/broken-session.jsonl"
# dev（44444444）はログを作らない＝登録済みだがファイル不在

desk_run() { LEDGER_WATCH_ROOT="$R" LEDGER_WATCH_SESSIONS="$S2" python3 "$TOOL" "$@" 2>&1; }
out="$(desk_run report)"
jq_desks() { desk_run report --json | python3 -c "$1"; }

printf '%s' "$out" | grep -qE '/finance .*2日' \
  && ok "★登録済みでスラッシュコマンドが無い窓口の最終利用日を出す（b26482 の実害）" \
  || ng "★登録済みでスラッシュコマンドが無い窓口を検知できない" "(A) 対応表を見ていない＝「一度もなし」と誤報する"
printf '%s' "$out" | grep -qE '/finance .*一度もなし' \
  && ng "稼働中の窓口を「一度もなし」と呼んでいる" "(A) triage が社長の作業中の領域を手つかずと誘導する" \
  || ok "稼働中の窓口を「一度もなし」とは呼ばない"
printf '%s' "$out" | grep -qE '/work .*一度もなし' \
  && ok "対応表にある窓口は、セッション登録が無くても行として出る" \
  || ng "対応表の窓口が1つ消えている" "ハードコードの一覧に無い窓口（management・dev・work・product）が数から漏れる"
printf '%s' "$out" | grep -qE '/management .*0日' \
  && ok "登録済みの窓口は対応表の日付で出る" || ng "登録済みの窓口の日付が出ない" "対応表の経路が効いていない"
# ★登録済みのセッションでは**本文を見ない**。dev の窓口で `/do` を1回打っただけで「do を開いた」と
#   数えると、放置の合図が逆向きに潰れる。
printf '%s' "$out" | grep -qE '/do .*一度もなし' \
  && ok "★登録済みセッションの本文にある別窓口の /コマンド は数えない" \
  || ng "★別窓口の /コマンド を開封と数えている" "(B) dev で /do を1回打つと「do を開いた」に化け、放置が見えなくなる"
printf '%s' "$out" | grep -qE '/dev .*一度もなし' \
  && ok "登録済みだがログが無い窓口は「一度もなし」（落ちない）" || ng "ログ不在の登録窓口を扱えない" "例外か行の欠落"
printf '%s' "$out" | grep -qE '/overseer .*5日' \
  && ok "対応表に無い窓口（セッションを持たない）は従来のコマンド痕跡で拾う" \
  || ng "コマンド痕跡の判定を落としている" "intake・do・overseer が数えられなくなる"
printf '%s' "$out" | grep -q '/hp-loop' \
  && ng "cron のモードを窓口として数えている" || ok "cron のモード（hp-loop 等）は窓口に含めない"
first="$(printf '%s' "$out" | awk '/^【3】/{f=1} f&&/^  \//{print; exit}')"
printf '%s' "$first" | grep -qE '一度もなし|判定不能' \
  && ok "日付が取れていない窓口を先頭に置く（0日扱いで沈めない）" || ng "並び順が放置の重い順になっていない: $first"
printf '%s' "$first" | grep -q '判定不能' \
  && ok "「判定不能」は「一度もなし」より先に置く（道具の故障を放置の合図より上に出す）" \
  || ng "判定不能が一度もなしの後ろに沈んでいる: $first"

# ★同じ窓口に登録IDが2本（実機では triage と board が該当）＝新しい方を採る。
#   新しい方をファイル名の辞書順で**先**に置く＝「最後に見たものが勝つ」実装なら古い方が出る。
jq_desks '
import sys, json
d = {e["desk"]: e for e in json.load(sys.stdin)["desks"]}
assert d["board"]["days"] == 3, d["board"]
assert d["board"]["how"] == "登録セッションの最終更新", d["board"]
print("")' >/dev/null 2>&1 \
  && ok "★同じ窓口に登録IDが2本あるときは新しい方を採る（走査順に依存しない）" \
  || ng "★同じ窓口の複数セッションで古い方を採っている" "(A) 実機の triage・board が該当＝長期放置に見える"

# ★両経路が競合するのは finance（登録済み2日前 vs 未登録の /finance 10日前）。
#   triage で見ると登録済みの経路しか通らないので、この不変条件は証明できない（Codex🟡）。
jq_desks '
import sys, json
d = {e["desk"]: e for e in json.load(sys.stdin)["desks"]}
assert d["finance"]["days"] == 2, d["finance"]
assert d["finance"]["how"] == "登録セッションの最終更新", d["finance"]
assert d["overseer"]["how"] == "コマンド痕跡", d["overseer"]
assert d["dev"]["how"] is None, d["dev"]
print("")' >/dev/null 2>&1 \
  && ok "★両方取れたときは新しい方を採り、出どころ（対応表／コマンド）を --json に出す" \
  || ng "両経路の競合で古い方を採る・出どころが出ていない" "どちらの経路の日付か後から追えない"

# ★同じ日に両方の経路で当たったときの出どころが走査順で変わらないこと（診断の安定）。
#   management は登録済み（0日）＋本文に /do。同じ日に未登録セッションで /management も打つ。
mkcmd  dddddddd-dddd-dddd-dddd-dddddddddddd management 0
out_tie="$(desk_run report --json)"
printf '%s' "$out_tie" | python3 -c '
import sys, json
d = {e["desk"]: e for e in json.load(sys.stdin)["desks"]}
assert d["management"]["how"] == "登録セッションの最終更新", d["management"]
print("")' >/dev/null 2>&1 \
  && ok "同じ日に両経路で当たったら対応表を優先する（出どころが走査順で変わらない）" \
  || ng "同日のタイで出どころが走査順に依存する" "診断の値がファイル名次第で変わる"
rm -f "$S2/dddddddd-dddd-dddd-dddd-dddddddddddd.jsonl"

# ★窓口の集合を**完全一致**で見る。1行だけ存在を見ると、新しい窓口が1つ欠けても緑になる。
jq_desks '
import sys, json
got = sorted(e["desk"] for e in json.load(sys.stdin)["desks"])
want = ["board", "dev", "do", "finance", "intake", "management", "overseer", "product", "triage", "work"]
assert got == want, f"got={got}"
print("")' >/dev/null 2>&1 \
  && ok "★窓口の集合が対応表＋コマンド専用の窓口と完全一致する" \
  || ng "★窓口の集合が合わない" "対応表に足した窓口が黙って数から漏れる"

# ★本文で話題にしているだけの行を証拠にしない（(B) の向き）。形が変わって読めないログは申告する。
printf '%s' "$out" | grep -qE '/work .*一度もなし' \
  && ok "★本文で窓口名を話題にしているだけの行は「開いた」と数えない" \
  || ng "★話題にしただけの行を開封と数えている" "(B) この修理を議論したログ自体が偽の開封になる"
# ★「タグはあるのに記録として読めない」を1本ずつ鳴らすと常時点灯する（実機で2本が恒久的に当たる）。
#   鳴りっぱなしの警告は警告として働かない。**1件も読めなかったときだけ**鳴ることを両方向で見る。
printf '%s' "$out" | grep -q '記録の形が変わった疑い' \
  && ng "形の警告が常時点灯している" "鳴りっぱなしの警告は読まれない（ledger-discipline §2）" \
  || ok "記録として読めているときは形の警告を鳴らさない（常時点灯させない）"
# ★実運用と同じ**混在**で見る：古いログには今の形の記録が残っていて、**新しいログだけ**が
#   読めない形になる。全期間の合算で「1件も読めない」を見ていると、古い分があるので
#   **永久に鳴らない**（Codex🔴 2回目の指摘・コメントと実装が食い違っていた）。
S3="$TMP/sessions3"; mkdir -p "$S3"
printf '{"type":"user","message":{"role":"user","content":"<command-name>/intake</command-name>"}}\n' \
  > "$S3/old-good.jsonl"; touch -d "60 days ago" "$S3/old-good.jsonl"
printf '{"type":"user","message":{"role":"user","content":"x"},"slashCommand":{"name":"/do"},"note":"<command-name>/do</command-name>"}\n' \
  > "$S3/new-shape.jsonl"; touch -d "0 days ago" "$S3/new-shape.jsonl"
out5="$(LEDGER_WATCH_ROOT="$R" LEDGER_WATCH_SESSIONS="$S3" python3 "$TOOL" report 2>&1)"
printf '%s' "$out5" | grep -q '記録の形が変わった疑い' \
  && ok "★古い形の正常ログが残っていても、新しいログが読めなければ申告する（形が変わった日に鳴る）" \
  || ng "★形が変わっても鳴らない" "古いログに記録が残り続けるので合算では永久に 0 にならない"
printf '%s' "$out5" | grep -qE '/intake .*60日' \
  && ok "古いログの記録は日付としてはそのまま使える（鳴らすのと数えるのを混ぜない）" \
  || ng "古いログの日付まで落としている" "見張りの都合で数字を失う"
printf '%s' "$out" | grep -qE '/intake .*7日' \
  && ok "★冒頭の最初のコマンドが窓口でなくても（/compact）後ろの窓口コマンドを拾う" \
  || ng "★最初の1件しか見ていない" "(A) /compact を打った窓口が「一度もなし」に戻る"
printf '%s' "$out" | grep -q 'JSON として読めない行' \
  && ok "タグはあるが読めない行の件数を申告する（黙って捨てない）" \
  || ng "読めない行を黙って捨てている" "取り落としが見えない"

# ★未来の日時は採らない。最大値を採る仕組みなので、1年先の mtime はその窓口を**永久に**
#   「最も新しい」に固定し、正しいセッションの日付が勝てなくなる（Codex🔴）。
printf '%s' "$out" | grep -qE '/product .*(判定不能|一度もなし)' \
  && ok "★未来の日時のログは日付として採らない" \
  || ng "★未来の日時を平常値として採っている" "(B) 復元・時計ずれでその窓口が永久に「開いた」になる"
printf '%s' "$out" | grep -q '未来の日時' \
  && ok "未来の日時のログがあることを申告する" || ng "未来の日時を黙って捨てている" "時計ずれ・復元に気づけない"
printf '%s' "$out" | grep -q -- '-[0-9]日' \
  && ng "負の経過日数を出している" "「-1日 開いていません」と表示される" || ok "負の経過日数を出さない"
desk_run report --json | python3 -c '
import sys, json
d = json.load(sys.stdin)
pr = {e["desk"]: e for e in d["desks"]}["product"]
assert pr["last"] is None and pr["days"] is None and pr["how"] is None, pr
assert d["desks_error"] and "未来" in d["desks_error"], d["desks_error"]
print("")' >/dev/null 2>&1 \
  && ok "未来の日時は last/days/how を空にし、--json にも申告する" \
  || ng "未来の日時の扱いが機械可読に出ていない" "下流が -1日 を平常値として読む"
# ★未来の日時を採らないようにした代わりに、last=None が「一度も開いていない」と**同じ形**に
#   なっていた＝下流が「一度も開いていません」と断定する（Codex🔴 3回目）。
#   「判定できなかった」と「使われていない」を機械可読に分ける。
desk_run report --json | python3 -c '
import sys, json
d = {e["desk"]: e for e in json.load(sys.stdin)["desks"]}
assert d["product"]["status"] == "unknown", d["product"]   # 未来の日時のログしかない
assert d["dev"]["status"] == "never", d["dev"]             # ログそのものが無い
assert d["finance"]["status"] == "ok", d["finance"]
print("")' >/dev/null 2>&1 \
  && ok "★「判定できなかった窓口」と「一度も使っていない窓口」を status で分ける" \
  || ng "★判定不能を未使用と同じ形で出している" "社長がいま使っている窓口へ「一度も開いていません」と誘導する"
printf '%s' "$out" | grep -qE '/product .*判定不能' \
  && ok "★判定できなかった窓口は「判定不能」と書く（「一度もなし」と書かない）" \
  || ng "★判定不能を「一度もなし」と書いている" "道具の故障が放置の合図に化ける"
printf '%s' "$out" | grep -qE '/product .*一度もなし' \
  && ng "判定不能の窓口を「一度もなし」と呼んでいる" "未使用と区別できない" \
  || ok "判定不能の窓口を「一度もなし」とは呼ばない"

# ★環境変数の取り違え：SESSION_DESK_TABLE が外から入っていても、見るのは LEDGER_WATCH_ROOT の表。
out2="$(SESSION_DESK_TABLE=/nonexistent/table.json desk_run report)"
printf '%s' "$out2" | grep -qE '/finance .*2日' \
  && ok "SESSION_DESK_TABLE が外から入っていても LEDGER_WATCH_ROOT の対応表を読む" \
  || ng "外の環境変数に引きずられる" "別の表を読んで数字が入れ替わる"

# ★セッションログの置き場そのものが読めないとき。glob は不在・権限なしでも例外を投げず空を返す
#   ＝全窓口が「一度もなし」に化ける（(A) の向き・実測で確認）。
out4="$(LEDGER_WATCH_ROOT="$R" LEDGER_WATCH_SESSIONS="$TMP/no-such-dir" python3 "$TOOL" report 2>&1)"
printf '%s' "$out4" | grep -q 'セッションログを読めません' \
  && ok "★セッションログの置き場が読めないときは申告する" \
  || ng "★置き場が読めないことを黙っている" "(A) 全窓口が「一度もなし」＝全部放置と誤報する"
printf '%s' "$out4" | grep -qE '^  /[a-z]+ +2026' \
  && ng "置き場が読めないのに日付を出している" "根拠のない値を確定値として出す" \
  || ok "置き場が読めないときは日付を出さない"

# ★対応表が読めないとき：sessions が空になる＝全ログが未登録扱い＝**登録済みセッションの本文まで
#   走査する**。management の窓口にあった /do が「do を開いた」に化ける（手元で再現・Codex🔴）。
#   ＝直した誤報が、対応表が壊れた日に向きを変えて復活する。半分だけ正しい一覧は出さない。
mv "$R/config/session-desks.json" "$R/config/session-desks.json.bak"
out3="$(desk_run report)"
printf '%s' "$out3" | grep -q '対応表' \
  && ok "対応表を読めないときは黙らず申告する" || ng "対応表不在を黙って素通りする"
printf '%s' "$out3" | grep -q '判定できません' \
  && ok "★対応表が読めないときは「判定不能」と言う" \
  || ng "★対応表が読めないのに一覧を出している" "根拠が壊れた値を確定値として出す"
printf '%s' "$out3" | grep -qE '/do .*0日' \
  && ng "★対応表の故障時に登録済みの本文を数えている" "(B) /do が「開いた」に化ける＝この修理が形を変えて復活する" \
  || ok "★対応表が読めないときも登録済みの本文を数えない（誤報が復活しない）"
desk_run report --json | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d["desks"] == [], d["desks"]
assert d["desks_error"], "desks_error が空＝読む側から「合図なし（健全）」と区別できない"
print("")' >/dev/null 2>&1 \
  && ok "★--json にも窓口側のエラーを出す（空の節と健全を区別できる）" \
  || ng "★--json が「窓口0件」と「判定不能」を同じ形で出す" "build-status-page が沈黙を健全として描く"
mv "$R/config/session-desks.json.bak" "$R/config/session-desks.json"

echo "── §7.5 日時そのものが読めないログ（走査中に消えた・権限が落ちた）"
# ★未来の日時と同じく「取れたはずの日付を落とした」形。件数は申告していたが、
#   **どの窓口の分を落としたか**をテストしていなかった（Codex🟡 4回目）。
#   getmtime を直接失敗させるには import して差し替えるのが確実なので、ここだけ python で叩く。
SEC75="$(python3 - "$PROJ" <<'PYS'
import importlib.util, json, os, sys, tempfile
spec = importlib.util.spec_from_file_location("lw", sys.argv[1] + "/bin/ledger-watch.py")
lw = importlib.util.module_from_spec(spec); spec.loader.exec_module(lw)
P = N = 0
def chk(c, m):
    global P, N
    if c: P += 1; print(f"  ok   {m}")
    else: N += 1; print(f"  NG   {m}")

root = tempfile.mkdtemp(); sess = tempfile.mkdtemp()
os.makedirs(root + "/bin"); os.makedirs(root + "/config")
import shutil
shutil.copy(sys.argv[1] + "/bin/session-desk.py", root + "/bin/")
json.dump({"desks": {"finance": {"label": "経理"}, "board": {"label": "方向"}},
           "sessions": {"11111111-1111-1111-1111-111111111111": "finance",
                        "22222222-2222-2222-2222-222222222222": "board"}},
          open(root + "/config/session-desks.json", "w"))
bad = sess + "/11111111-1111-1111-1111-111111111111.jsonl"
open(bad, "w").write("{}\n")
open(sess + "/22222222-2222-2222-2222-222222222222.jsonl", "w").write("{}\n")
lw.ROOT = root; lw.SESSION_DIR = sess
real = os.path.getmtime
os.path.getmtime = lambda q: (_ for _ in ()).throw(OSError("消えた")) if q == bad else real(q)
try:
    rows, err = lw.desks()
finally:
    os.path.getmtime = real
by = {e["desk"]: e for e in rows}
chk(by["finance"]["status"] == "unknown", "★日時を読めなかった窓口は unknown（「一度もなし」にしない）")
chk(by["finance"]["last"] is None and by["finance"]["days"] is None, "日付は空のまま（推定値を入れない）")
chk(by["board"]["status"] == "ok", "他の窓口は普通に取れる（1本の失敗で全部を失わない）")
chk(err and "日時を読めないログ" in err, f"件数を申告する（err={err}）")
print(f"__R__ {P} {N}")
PYS
)"
printf '%s\n' "$SEC75" | grep -v '^__R__'
R75="$(printf '%s\n' "$SEC75" | sed -n 's/^__R__ //p')"
if [ -n "$R75" ]; then
  PASS=$((PASS + ${R75% *})); FAIL=$((FAIL + ${R75#* }))
else
  ng "§7.5 が合計行を出さずに終わった" "例外で落ちると0項目として数えられる（K-952）"
fi

echo "── §6 異常系"
rm -f "$R/data/overseer/system-health.jsonl"
out="$(run report)"; [ -n "$out" ] && ok "履歴が無くても落ちない" || ng "履歴不在で落ちる"
rm -f "$R/bin/system-health.py"
out="$(run report)"
printf '%s' "$out" | grep -q '閾値を読み込めません\|system-health.py を読み込めません' \
  && ok "閾値を読めないときは黙らず申告する" || ng "閾値不在を黙って素通りする"

# ★動的な群（月数・サイト数・モード数で増える器）が壊れても、固定の STATE_FILES の閾値まで消さない。
#   1つの try でまとめていたため、globbed_states が落ちると **全部の器が上限なし**になっていた
#   （申告は出るので気づけるが、一番効く固定分の数字を道連れにしていた）。Codex 指摘 2026-09-23。
mkdir -p "$R/bin"
cat > "$R/bin/system-health.py" <<'SHSTUB'
KB = 1024
STATE_FILES = [("data/partner/ledger.md", 70 * KB, "固定の器")]
def hp_loop_states(): return []
def globbed_states(): raise RuntimeError("壊れた群")
SHSTUB
got="$(LEDGER_WATCH_ROOT="$R" python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("_lw", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
th, err = m.thresholds()
print("keep" if "data/partner/ledger.md" in th else "lost", "|", err)
' "$TOOL")"
printf '%s' "$got" | grep -q '^keep' \
  && ok "動的な群が壊れても固定の閾値は残る" || ng "壊れた群が固定の閾値を道連れにする: $got"
printf '%s' "$got" | grep -q 'globbed_states' \
  && ok "壊れた群の名前を申告する（どこが読めないか分かる）" || ng "壊れた群を名指ししない: $got"

# ── 【2】宛先が最後に取りに来た日（2026-09-27 追加・O-082／⑤の出典）
# 件数だけでは「届いていない」と「届いているのに取りに来ていない」を区別できない。
# 取りに来た時刻は cur/ の **ctime（改名された時刻）**で見る＝mv は mtime を持ち越すため。
echo
echo "── 【2】宛先が最後に取りに来た日"
mkdir -p "$R/data/mailbox/cur"
printf '%s' '{"id":"M-1","to":"alpha-dev","ts":"2026-01-01T00:00:00+09:00"}' > "$R/data/mailbox/cur/M-1.json"
printf '%s' '{"id":"M-2","to":"alpha-dev","ts":"2026-01-02T00:00:00+09:00"}' > "$R/data/mailbox/cur/M-2.json"
printf '%s' '{"id":"M-3","to":"beta-dev","ts":"2026-01-03T00:00:00+09:00"}'  > "$R/data/mailbox/cur/M-3.json"
printf '%s' 'これは JSON ではない' > "$R/data/mailbox/cur/broken.json"
got="$(LEDGER_WATCH_ROOT="$R" python3 -c '
import importlib.util, sys, datetime
spec = importlib.util.spec_from_file_location("_lw", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rows = {e["to"]: e for e in m.pickups()}
today = datetime.datetime.now(m.JST).date().isoformat()
print("宛先数", len(rows))
print("alpha件数", rows.get("alpha-dev", {}).get("count"))
print("beta件数", rows.get("beta-dev", {}).get("count"))
print("alpha最終", rows.get("alpha-dev", {}).get("last"), "今日", today)
print("経過", rows.get("alpha-dev", {}).get("days"))
' "$TOOL")"
printf '%s' "$got" | grep -q '^宛先数 2$'   && ok "宛先ごとに1行にまとめる（壊れた JSON は数えず落ちない）" || ng "宛先の数がおかしい: $got"
printf '%s' "$got" | grep -q '^alpha件数 2$'   && ok "処理済みの件数を宛先ごとに数える" || ng "件数がおかしい: $got"
last="$(printf '%s' "$got" | sed -n 's/^alpha最終 \([0-9-]*\) 今日 \([0-9-]*\)$/\1 \2/p')"
[ -n "$last" ] && [ "${last% *}" = "${last#* }" ]   && ok "取りに来た日は送信時刻（2026-01-01）でなく改名時刻＝今日になる"   || ng "ctime を見ていない（mtime を見ている疑い）: $got"
printf '%s' "$got" | grep -q '^経過 0$'   && ok "経過日数を出せる" || ng "経過日数がおかしい: $got"

# ★実際の経路（new/ → cur/ の os.replace）で確かめる＝テストが「cur/ に直接作る」だけだと
#   mv で mtime が持ち越される問題を踏めない（Codex 指摘 🔴4）。古い mtime を付けてから動かす。
python3 - "$R" <<'PYMOVE'
import os, sys, time
R = sys.argv[1]
os.makedirs(f"{R}/data/mailbox/new", exist_ok=True)
src = f"{R}/data/mailbox/new/M-9.json"
with open(src, "w", encoding="utf-8") as f:
    f.write('{"id":"M-9","to":"gamma-dev","ts":"2026-01-01T00:00:00+09:00"}')
old = time.time() - 60 * 60 * 24 * 40
os.utime(src, (old, old))
os.replace(src, f"{R}/data/mailbox/cur/M-9.json")
PYMOVE
got2="$(LEDGER_WATCH_ROOT="$R" python3 -c '
import importlib.util, sys, datetime
spec = importlib.util.spec_from_file_location("_lw", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = {e["to"]: e for e in m.pickups()}.get("gamma-dev", {})
print(r.get("last"), datetime.datetime.now(m.JST).date().isoformat())
' "$TOOL")"
a2="$(printf '%s' "$got2" | cut -d" " -f1)"; b2="$(printf '%s' "$got2" | cut -d" " -f2)"
if [ "$a2" = "$b2" ]; then ok "new/ → cur/ を実際に動かしても取りに来た日は今日（mtime 40日前に引きずられない）"; else ng "mtime に引きずられている（$got2）"; fi

# ── alerts（前回以降の警報・O-051／triage.md v1.4 の出典）
# ★0件のとき「0件」と言えること／入力が無いときは「0件」と言わず**判定不能**と言えること（Codex 指摘 🔴3）。
# ★cron.log はブロック形式（`# system-health YYYY-MM-DD HH:MM` の下に日付の無い ⚠️ 行が並ぶ）＝
#   行ごとに日付を求めると実データで1件も拾えない（実測ヒット0件・Codex 指摘 🔴1）。
# ── 【2-b】窓口の受信箱の滞留（K-929・2026-10-12）
# 契機＝mailbox 規約 v0.5 が決めたのは「AI が手順を踏むか」なので静的検査が効かない。
# 守られたかは**スプールの実データ**からしか分からない（2026-10-04 実測＝work は cur/ が0通）。
echo
echo "── 【2-b】窓口の受信箱の滞留（人が開く窓口だけ）"
B="$TMP/deskmail"; mkdir -p "$B/bin" "$B/config" "$B/data/mailbox/new" "$B/data/mailbox/hold" "$B/data/mailbox/cur" "$B/data/overseer"
cp "$PROJ/bin/session-desk.py" "$B/bin/"
cat > "$B/config/session-desks.json" <<'JSON'
{
  "desks": {
    "aaa": {"label": "最古が3日以上"},
    "bbb": {"label": "処理済みが0通"},
    "ccc": {"label": "最古が1日"},
    "ddd": {"label": "未読が多い"},
    "eee": {"label": "滞留なし"},
    "fff": {"label": "日時が1通も読めない"}
  },
  "sessions": {}
}
JSON
bmail() { printf '{"id":"%s","to":"%s","ts":"%sT10:00:00+09:00"}' "$1" "$2" "$(DAY "$3")" > "$B/data/mailbox/$4/$1.json"; }
bmail M-a1 aaa 9 new; bmail M-a2 aaa 1 new          # 最古9日 → 🔴
bmail M-b1 bbb 2 new                                 # 1通・最古2日・処理済み0 → 🔴
bmail M-c1 ccc 1 new                                 # 最古1日・処理済みあり → 🟡
for i in 1 2 3 4 5 6; do bmail "M-d$i" ddd 0 new; done   # 6通・最古0日 → 🟡（件数で鳴る）
bmail M-e1 eee 0 new                                 # 1通・最古0日・処理済みあり → ✅
bmail M-z1 hp-loop-ycom 40 new                       # 無人の宛先＝対象外
bmail M-h1 aaa 5 hold                                # hold は別に数える
printf '%s' '{"id":"C-a","to":"aaa"}' > "$B/data/mailbox/cur/C-a.json"
printf '%s' '{"id":"C-c","to":"ccc"}' > "$B/data/mailbox/cur/C-c.json"
printf '%s' '{"id":"C-d","to":"ddd"}' > "$B/data/mailbox/cur/C-d.json"
printf '%s' '{"id":"C-e","to":"eee"}' > "$B/data/mailbox/cur/C-e.json"
cp "$R/bin/system-health.py" "$B/bin/system-health.py"
brun() { LEDGER_WATCH_ROOT="$B" LEDGER_WATCH_SESSIONS="$TMP/sessions-empty" python3 "$TOOL" "$@" 2>&1; }
mkdir -p "$TMP/sessions-empty"
bout="$(brun report)"

printf '%s' "$bout" | grep -q 'hp-loop-ycom' && \
  { printf '%s' "$bout" | sed -n '/【2-b】/,/【3】/p' | grep -q 'hp-loop-ycom' \
    && ng "無人の宛先を窓口として数えている" "hp-loop-* や *-dev は人が開く窓口ではない" \
    || ok "★対象は対応表の窓口だけ（無人の宛先は【2】の表で見る）"; } \
  || ng "検査が成立していない" "無人の宛先が【2】にも出ていない＝仕掛けが効いていない"
printf '%s' "$bout" | grep -qE '🔴aaa .*9 ' && ok "最古が3日以上は 🔴" || ng "最古3日以上を 🔴 にしていない"
printf '%s' "$bout" | grep -qE '🔴bbb .*処理済みが0通' \
  && ok "★処理済みが0通のまま滞留している窓口は、件数が少なくても 🔴（K-929 の核）" \
  || ng "★cur/ が0通の窓口を見ていない" "新設以来一度も処理済みにしていない窓口が緑になる"
printf '%s' "$bout" | grep -qE '🟡ccc ' && ok "最古が1日は 🟡" || ng "最古1日を 🟡 にしていない"
printf '%s' "$bout" | grep -qE '🟡ddd ' && ok "滞留が浅くても未読5通以上は 🟡（件数でも鳴る）" || ng "件数の条件が効いていない"
printf '%s' "$bout" | sed -n '/【2-b】/,/【3】/p' | grep -q 'eee' \
  && ng "滞留なしの窓口を表に出している" "鳴りっぱなしにしない＝省略して件数を言う" \
  || ok "滞留なしの窓口は省略する"
printf '%s' "$bout" | grep -q '滞留なし 2窓口は省略' && ok "省略した件数を言う（黙って消さない）" || ng "省略件数を言っていない"
printf '%s' "$bout" | grep -qE '🔴aaa .* 1 ' && ok "hold/ の件数も出す" || ng "hold/ を数えていない"

# ★推移：履歴が無いときに「横ばい」と言わない（2026-09-12 に踏んだバグ＝履歴の無い器が🟡に化けた）
printf '%s' "$bout" | grep -q '推移は判定不能' && ok "★履歴が無いときは推移を「判定不能」と言う（横ばいにしない）" \
  || ng "★履歴が無いのに推移を言っている" "2026-09-12 のバグ（履歴なしが横ばいに化ける）の再発"
printf '%s' "$bout" | sed -n '/【2-b】/,/【3】/p' | grep -qE '(増|横|減)[-+]' \
  && ng "履歴が無いのに増減を出している" "根拠のない推移" || ok "履歴が無い行の推移欄は「—」"

# ★推移：7日前の記録と比べる
brun snapshot >/dev/null
[ -s "$B/data/overseer/ledger-watch.jsonl" ] && ok "snapshot が窓口の受信箱も記録する" || ng "snapshot に窓口の受信箱が無い"
python3 -c "
import json,sys,datetime
p=sys.argv[1]
rec=json.loads(open(p).read().splitlines()[-1])
assert 'desk_mailbox' in rec, rec.keys()
assert rec['desk_mailbox']['aaa'] == [2, 9, 0], rec['desk_mailbox']['aaa']
" "$B/data/overseer/ledger-watch.jsonl" && ok "記録の中身が実測値（未読・最古）" || ng "snapshot の中身が合わない"
# ★今日の記録しか無いときに推移を言わない。自分で今さっき書いた値と比べれば必ず「横+0通+0日」に
#   なり、**どの窓口も変わっていない**という嘘を毎日出し続ける（履歴なしが横ばいに化けるのと同じ型）。
bout_same="$(brun report)"
printf '%s' "$bout_same" | grep -q '推移は判定不能' \
  && ok "★今日の記録しか無いときは推移を言わない（自分の値と比べて「横」にしない）" \
  || ng "★同日の記録で推移を出している" "毎日「変わっていません」と嘘を言い続ける"

# 8日前の記録を仕込む（aaa は増・ccc は減・ddd は横）
python3 -c "
import json,sys,datetime
p=sys.argv[1]
old={'ts':(datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9)))-datetime.timedelta(days=8)).isoformat(),
     'mailbox':{},'desk_mailbox':{'aaa':[1,2,0],'bbb':[1,2,0],'ccc':[3,9,0],'ddd':[6,0,0],'eee':[1,0,0],'fff':[0,0,0]},'decisions':{}}
lines=open(p).read().splitlines()
open(p,'w').write(json.dumps(old,ensure_ascii=False)+'\n'+'\n'.join(lines)+'\n')
" "$B/data/overseer/ledger-watch.jsonl"
bout2="$(brun report)"
printf '%s' "$bout2" | grep -qE '🔴aaa .*増\+1通\+7日' \
  && ok "★7日前より増えている窓口を「増」として出す（赤の中の悪化中が分かる）" \
  || ng "★推移を出せていない" "全窓口が赤のまま＝どれが悪化中か読めない（鳴りっぱなしの警告）"
printf '%s' "$bout2" | grep -qE '🟡ccc .*減' && ok "減っている窓口は「減」" || ng "減少を出せていない"
printf '%s' "$bout2" | grep -qE '🟡ddd .*横' && ok "変わらない窓口は「横」" || ng "横ばいを出せていない"
printf '%s' "$bout2" | grep -q '8日前比' && ok "何日前と比べたかを明記する（7日と書いて8日前を見ない）" || ng "比較した日数を言っていない"
first_red="$(printf '%s' "$bout2" | sed -n '/【2-b】/,/【3】/p' | grep -m1 '^  🔴')"
printf '%s' "$first_red" | grep -q 'aaa' && ok "★赤の中では悪化中（増）を先頭に置く" \
  || ng "★赤の並び順が悪化中を先にしていない: $first_red"

# ★記号の意味が節で違うことを、その場に書いてあるか（Codex🔴 2026-10-12）。
#   冒頭の凡例は【1】蓄積のもの（🔴＝超過かつ増加中）。キューはしきい値だけで 🔴 にするので、
#   「🔴 … 減-5通-7日」が出る。同じ記号が節で違う意味なら、読む側はその場で知る必要がある。
printf '%s' "$bout2" | sed -n '/【2-b】/,/窓口 /p' | grep -q '滞留のしきい値' \
  && ok "★【2-b】の記号の意味をその節に書く（冒頭の凡例と違うことを明示）" \
  || ng "★節ごとの凡例が無い" "🔴 の意味が節で変わるのに書いていない＝triage が一見で判断できない"
printf '%s' "$bout2" | sed -n '1,3p' | grep -q '【1】の記号' \
  && ok "冒頭の凡例が【1】のものだと明示する" || ng "冒頭の凡例が全節に効くと読める"

# ★混合推移：未読は減ったが最古は増えた＝**悪化**として扱う（古い便が残り続けている）
python3 -c "
import json,sys,datetime
p=sys.argv[1]; ls=open(p).read().splitlines()
old=json.loads(ls[0]); old['desk_mailbox']['aaa']=[9,2,0]   # 未読9→2通に減・最古2→9日に増
ls[0]=json.dumps(old,ensure_ascii=False); open(p,'w').write('\n'.join(ls)+'\n')
" "$B/data/overseer/ledger-watch.jsonl"
bout4="$(brun report)"
printf '%s' "$bout4" | grep -qE '🔴aaa .*増-7通\+7日' \
  && ok "★未読が減っても最古が増えていれば「増」（古い便が残り続けている）" \
  || ng "★混合推移を改善と読んでいる" "件数だけ減って古い便が残る形を見逃す"

# ★日時が読めない便があるときに「減った」「変わらない」と断定しない（Codex🔴 2026-10-12）。
#   最古が「不明」なのに過去値と引き算して「減 -9日」と出していた＝読めない便が実際の最古かも
#   しれない。悪化（増）だけは安全側なので言う。記録は [未読, 最古, 日時不明件数] の3つ組で、
#   3つ目が無い古い記録は「不明かどうか不明」として扱う。
SEC2B="$(python3 - "$PROJ" <<'PYU'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lw", sys.argv[1] + "/bin/ledger-watch.py")
lw = importlib.util.module_from_spec(spec); spec.loader.exec_module(lw)
P = N = 0
def chk(c, m):
    global P, N
    if c: P += 1; print(f"  ok   {m}")
    else: N += 1; print(f"  NG   {m}")

def one(mail, prev):
    return lw.desk_mailbox_health(mail, [], {"x": "t"}, prev)[0]

allbad = [{"box": "new", "to": "x", "count": 1, "oldest": None, "age_unknown": 1}]
good = [{"box": "new", "to": "x", "count": 1, "oldest": 2, "age_unknown": 0}]
r = one(allbad, {"x": [1, 9, 0]})
chk(r["trend"] is None and r["trend_blocked"] == "age_unknown",
    f"★現在の便の日時が全件不明なら改善と断定しない（trend={r['trend']} {r['d_oldest']}）")
r = one(good, {"x": [1, 9, 3]})
chk(r["trend"] is None and r["trend_blocked"] == "age_unknown",
    "★過去の記録に日時不明が混ざっていたら改善と断定しない")
r = one(good, {"x": [1, 9]})
chk(r["trend"] is None and r["trend_blocked"] == "age_unknown",
    "★3つ目が無い古い記録は「不明かどうか不明」として扱う（改善と言わない）")
r = one(good, {"x": [1, 9, 0]})
chk(r["trend"] == "減", "両方とも確かなら「減」と言う（伏せすぎない）")
r = one([{"box": "new", "to": "x", "count": 5, "oldest": None, "age_unknown": 1}], {"x": [1, 9, 0]})
chk(r["trend"] == "増", "★不明が混ざっていても悪化（増）だけは言う（安全側）")
r = one(good, {"x": ["こわれた", None]})
chk(r["trend"] is None and r["trend_blocked"] == "bad_past", "過去の記録が壊れていたら理由を立てる")
# ★最古の「増」は、過去に日時不明が無いときだけ言える（Codex🔴 3回目）。
#   過去 [1,2,3]＝最古2日だが不明が3通 → その3通が実は20日前なら、見かけの増加は実は改善。
# ★ここは現在の最古が**過去より大きい**形でないと検査にならない（good は最古2日＝過去と同じで
#   差が0になり、条件を外しても同じ答えになる＝別の理由で緑になる。2026-10-12 変異で検出）。
older = [{"box": "new", "to": "x", "count": 1, "oldest": 9, "age_unknown": 0}]
r = one(older, {"x": [1, 2, 3]})
chk(r["trend"] is None and r["trend_blocked"] == "age_unknown",
    f"★過去に日時不明があるとき、最古が増えただけでは「増」と断定しない（trend={r['trend']} {r['d_oldest']}）")
r = one(older, {"x": [1, 2, 0]})
chk(r["trend"] == "増", "過去に日時不明が無ければ最古の増加で「増」と言う（伏せすぎない）")
r = one([{"box": "new", "to": "x", "count": 5, "oldest": 9, "age_unknown": 0}], {"x": [1, 2, 3]})
chk(r["trend"] == "増", "未読の増加は日時の読めなさに左右されない（件数は確か）＝「増」と言う")
# ★「—」の理由を必ず立てる（黙る形を残さない）
chk(one(good, {})["trend_blocked"] == "no_past", "★過去の記録が空のときも理由を立てる（黙らない）")
chk(one(good, {"x": "こわれた"})["trend_blocked"] == "bad_past", "★過去値が文字列でも理由を立てる")
chk(one(good, {"x": [1]})["trend_blocked"] == "bad_past", "★過去値が1要素でも理由を立てる")
# ★dict（記録の形を {"unread": N} 等に変えた日）は添字で KeyError になり、例外ハンドラでは
#   掴めない＝**この関数ごと落ちる**。形の検査が要る（2026-10-12 変異テストで気づいた）。
chk(one(good, {"x": {"unread": 1, "oldest": 2}})["trend_blocked"] == "bad_past",
    "★過去値が dict でも落ちずに理由を立てる")
chk(one(good, None)["trend_blocked"] is None, "比べる気が無い呼び出し（snapshot 側）では理由を立てない")
print(f"__R__ {P} {N}")
PYU
)"
printf '%s\n' "$SEC2B" | grep -v '^__R__'
R2B="$(printf '%s\n' "$SEC2B" | sed -n 's/^__R__ //p')"
if [ -n "$R2B" ]; then
  PASS=$((PASS + ${R2B% *})); FAIL=$((FAIL + ${R2B#* }))
else
  ng "推移の断定の節が合計行を出さずに終わった" "例外で落ちると0項目として数えられる（K-952）"
fi

# ★同日に snapshot が2件あって中身が違うと落ちる（タプルの2番目の dict を比べる）
#   中身が同じだと等価比較で済んで落ちないため、**件数が動いた日にだけ**落ちた（手元で再現）。
python3 -c "
import json,sys
p=sys.argv[1]; ls=open(p).read().splitlines()
r=json.loads(ls[-1]); r['desk_mailbox']['aaa']=[99,99,0]
open(p,'w').write('\n'.join(ls)+'\n'+json.dumps(r,ensure_ascii=False)+'\n')
" "$B/data/overseer/ledger-watch.jsonl"
bout5="$(brun report 2>&1)"; brc=$?
[ "$brc" = "0" ] && printf '%s' "$bout5" | grep -q '【2-b】' \
  && ok "★同日の記録が2件あって中身が違っても落ちない（dict を比べない）" \
  || ng "★同日2件で例外停止する" "cron＋手動実行や cron の再実行で普通に起きる: $(printf '%s' "$bout5" | tail -2)"
python3 -c "
import json,sys
p=sys.argv[1]; ls=open(p).read().splitlines()
open(p,'w').write('\n'.join(ls[:-1])+'\n')
" "$B/data/overseer/ledger-watch.jsonl"

# ★過去の記録に無い窓口（あとから足した窓口）＝推移欄が「—」になる理由を言う
python3 -c "
import json,sys
p=sys.argv[1]; ls=open(p).read().splitlines()
old=json.loads(ls[0]); old['desk_mailbox'].pop('bbb',None)
ls[0]=json.dumps(old,ensure_ascii=False); open(p,'w').write('\n'.join(ls)+'\n')
" "$B/data/overseer/ledger-watch.jsonl"
bout6="$(brun report)"
printf '%s' "$bout6" | grep -q '推移を言い切れない窓口' \
  && ok "★過去の記録に無い窓口は、推移が「—」である理由を言う" \
  || ng "★比べられない窓口を黙って「—」にしている" "履歴があるのに空欄＝故障と区別できない"

# ★便の日時が読めない／未来のとき、0日（＝滞留なし）に丸めて ✅ で省略しない。
#   `mailbox_queues()` は読めない日時を**黙って飛ばして**いたので、他に新しい便が1通あるだけで
#   最古が 0日になり「滞留なし」に化けた（＝不明が健全に見える・Codex🟡 2026-10-12）。
# (A) その窓口の便が**1通も読めない**＝最古そのものが言えない
printf '%s' '{"id":"M-f1","to":"fff","ts":"こわれた日付"}' > "$B/data/mailbox/new/M-f1.json"
bout7="$(brun report)"
printf '%s' "$bout7" | grep -qE '🔴fff .*便の日時が読めません' \
  && ok "★便の日時が1通も読めない窓口は 🔴（不明を「滞留なし」に化けさせない）" \
  || ng "★日時が読めない便を 0日として扱っている" "不明が健全に化けて表から省かれる"
printf '%s' "$bout7" | sed -n '/【2-b】/,/【3】/p' | grep -qE '^  🔴fff .*不明' \
  && ok "最古の欄は「不明」と書く（0 と書かない）" || ng "不明を 0 と書いている"
# (B) 読める便もある＝最古は出せるが「言い切れない」ことを添える
printf '%s' '{"id":"M-x1","to":"eee","ts":"こわれた日付"}' > "$B/data/mailbox/new/M-x1.json"
printf '%s' "$(brun report)" | grep -qE '🔴eee .*日時が読めない便 1通' \
  && ok "★読める便と混ざっているときは最古を出しつつ「言い切れない」と添える" \
  || ng "★一部が読めない便を黙って捨てている" "新しい便が1通あるだけで滞留なしに見える"
rm -f "$B/data/mailbox/new/M-x1.json"
# (C) 未来の日時＝負の滞留日数は使えない（「新しい便」として健全に見える）
printf '%s' '{"id":"M-x2","to":"eee","ts":"2099-01-01T10:00:00+09:00"}' > "$B/data/mailbox/new/M-x2.json"
printf '%s' "$(brun report)" | grep -qE '🔴eee .*日時が読めない便 1通' \
  && ok "★未来の日時の便も「読めない」として数える（負の滞留日数を平常値にしない）" \
  || ng "★未来の日時を平常値として扱っている" "負の日数が「新しい」として健全に見える"
rm -f "$B/data/mailbox/new/M-x2.json"
# 【2】の表にも出す（最古の列に入っていない便があることを隠さない）
printf '%s' "$bout7" | grep -q '日時が読めない便（最古の列に入っていません）' \
  && ok "【2】の宛先別の表でも、日時が読めない便の件数を名指しする" \
  || ng "【2】で日時が読めない便を黙っている" "宛先別の最古も同じ穴を持つ"
rm -f "$B/data/mailbox/new/M-f1.json"

# ★--json の契約（読む側＝triage・ダッシュボードが分岐できる形）
brun report --json | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert isinstance(d["desk_mailbox"], list) and d["desk_mailbox"], "desk_mailbox が空"
assert d["desk_mailbox_error"] is None, d["desk_mailbox_error"]
assert d["desk_mailbox_span"] and d["desk_mailbox_span"] > 0, d["desk_mailbox_span"]
one = {e["desk"]: e for e in d["desk_mailbox"]}["aaa"]
for k in ("flag", "why", "unread", "oldest", "hold", "done", "last", "trend", "d_unread", "d_oldest", "age_unknown"):
    assert k in one, f"{k} が無い: {one}"
print("")' >/dev/null 2>&1 \
  && ok "--json に窓口の受信箱・エラー・比較した日数を出す（読む側が分岐できる）" \
  || ng "--json の契約が足りない" "triage とダッシュボードが機械で読めない"
mv "$B/config/session-desks.json" "$B/config/y.json"
brun report --json | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d["desk_mailbox"] == [], d["desk_mailbox"]
assert d["desk_mailbox_error"], "対象が分からないのに error が空"
print("")' >/dev/null 2>&1 \
  && ok "対応表が読めないときは --json も空＋エラーを出す（0窓口＝健全にしない）" \
  || ng "--json が「0窓口」と「対象不明」を同じ形で出す" "読む側が健全として描く"
mv "$B/config/y.json" "$B/config/session-desks.json"

# 対応表が読めないときは「対象が分からない」と言う（鳴らない・緑にもしない）
mv "$B/config/session-desks.json" "$B/config/x.json"
bout3="$(brun report)"
printf '%s' "$bout3" | grep -q '対象の窓口が分かりません' \
  && ok "対応表が読めないときは対象不明と言う（0窓口＝健全にしない）" \
  || ng "対応表が読めないのに黙っている" "窓口が0件＝滞留なしとして描かれる"
mv "$B/config/x.json" "$B/config/session-desks.json"

echo
echo "── alerts（前回以降の警報）"
mkdir -p "$R/data/overseer"
: > "$R/data/overseer/failures.jsonl"
out="$(LEDGER_WATCH_ROOT="$R" python3 "$TOOL" alerts --days 7 2>&1)"
printf '%s' "$out" | grep -q '判定不能' \
  && ok "出典が1つでも無いときは「0件」と言わず判定不能と言う" || ng "欠けた出典を0件にした: $out"
printf '%s' "$out" | grep -q 'cron.log が ありません' \
  && ok "どの出典が欠けたかを名指しする" || ng "欠けた出典を名指ししない: $out"

today="$(date +%Y-%m-%d)"; old="$(date -d '30 days ago' +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
printf '# system-health %s 01:15\n- ⚠️ 器が太い（毎晩同じ顔で並ぶ＝ここでは拾わない）\n' "$today" \
  > "$R/data/overseer/cron.log"
out="$(LEDGER_WATCH_ROOT="$R" python3 "$TOOL" alerts --days 7 2>&1)"
printf '%s' "$out" | grep -q '前回以降の警報 0件' \
  && ok "警報が無いとき「0件」と明記する（黙って省かない）" || ng "0件を言わない: $out"
printf '%s' "$out" | grep -q '器が太い' \
  && ng "毎晩の器サイズ警告まで拾っている（263件の鳴りっぱなしに戻る）: $out" \
  || ok "毎晩の器サイズ警告は拾わない（ledger-watch【1】と重複させない）"

{
  printf '{"ts":"%sT01:00:00+09:00","fail":"partner-timeout"}\n' "$today"
  printf '{"ts":"%sT01:00:00+09:00","fail":"古すぎる分"}\n' "$old"
  printf 'これは JSON ではない\n'
} > "$R/data/overseer/failures.jsonl"
printf '# system-health %s 01:15\n- メモリ: OOM kill 18回（前回から +2）\n' "$today" \
  > "$R/data/overseer/cron.log"
out="$(LEDGER_WATCH_ROOT="$R" python3 "$TOOL" alerts --days 7 2>&1)"
printf '%s' "$out" | grep -q 'partner-timeout' \
  && ok "窓の中の警報を出す" || ng "窓の中の警報が出ない: $out"
if printf '%s' "$out" | grep -q '古すぎる分'; then ng "古い分まで出している: $out"; else ok "窓より古い警報は出さない"; fi
printf '%s' "$out" | grep -q '読めない行 1件' \
  && ok "壊れた行は「読めない行」として申告する（黙って捨てない）" || ng "壊れた行を黙って捨てた: $out"
printf '%s' "$out" | grep -q 'OOM kill が前回から +2' \
  && ok "cron.log のブロックから OOM の増加を拾う（日付はブロック見出しから取る）" || ng "OOM を拾えない: $out"
printf '%s' "$out" | grep -q '直近7日' \
  && ok "どの窓で数えたかを明記する" || ng "窓の根拠を言わない: $out"

# 毎晩の監視そのものが止まっていることを言えるか（2026-09-20〜27 に7日間 実在した）
printf '# system-health %s 01:15\n- メモリ: OOM kill 18回（前回から +0）\n' "$old" \
  > "$R/data/overseer/cron.log"
out="$(LEDGER_WATCH_ROOT="$R" python3 "$TOOL" alerts --days 60 2>&1)"
printf '%s' "$out" | grep -q '監視の無言停止' \
  && ok "毎晩の監視が出ていないこと自体を警報にする" || ng "監視の無言停止を言わない: $out"

# 省略件数を隠さない
python3 - "$R" <<'PYGEN'
import sys, datetime
R = sys.argv[1]
today = datetime.date.today().isoformat()
with open(f"{R}/data/overseer/failures.jsonl", "w", encoding="utf-8") as f:
    for i in range(20):
        f.write('{"ts":"%sT0%d:00:00+09:00","fail":"件%d"}\n' % (today, i % 10, i))
PYGEN
out="$(LEDGER_WATCH_ROOT="$R" python3 "$TOOL" alerts --days 7 2>&1)"
printf '%s' "$out" | grep -q '件は省略' \
  && ok "全件より少なく表示するときは省略件数を言う" || ng "省略を黙っている: $out"

echo
echo "合計: 合格 ${PASS} ／ 不合格 ${FAIL}"
[ "$FAIL" -eq 0 ]
