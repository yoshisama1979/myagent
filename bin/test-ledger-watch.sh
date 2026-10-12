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
