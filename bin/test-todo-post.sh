#!/usr/bin/env bash
# todo-post.py（会話台帳 → hana-tools 起票・LLMを使わない）の回帰テスト。
#
# rules/testing.md §2 の必須3条件に該当（無人ループから呼ばれる／外部システムへ書く／判定を持つ）。
# ★このツールの価値は「判断しないこと」＝台帳に書いていないことを補わない。
#   テストの主眼も「補ってしまわないか」に置く。
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJ/bin/todo-post.py"
[ -f "$SRC" ] || { echo "❌ todo-post.py が無い" >&2; exit 2; }
P=0; N=0
ok() { P=$((P+1)); echo "  ✅ $1"; }
ng() { N=$((N+1)); echo "  ❌ $1"; [ $# -ge 2 ] && echo "      → $2"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/data/comms/chatwork" "$T/config"

# 本体を、ROOT と重複チェックだけ差し替えて持ち込む（ロジックは書き写さない）
python3 - "$SRC" "$T" <<'PY'
import sys, io, os, json
src = io.open(sys.argv[1], encoding="utf-8").read()
d = sys.argv[2]
src = src.replace('ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))',
                  'ROOT = %s' % json.dumps(d))
src = src.replace('BRIEF = os.path.join(ROOT, "bin", "todo-brief.py")',
                  'BRIEF = os.environ["FAKE_BRIEF"]')
src = src.replace('API = os.path.join(ROOT, "bin", "hana-api.sh")',
                  'API = os.environ["FAKE_API"]')
io.open(os.path.join(d, "tp.py"), "w", encoding="utf-8").write(src)
PY
grep -q 'ROOT = "' "$T/tp.py" || { echo "❌ 差し替え失敗（ROOT）" >&2; exit 2; }

echo '{"hana_user_ids":{"agent":39}}' > "$T/config/comms-members.json"
echo '{"by_name":{"担当A":37,"社長":34}}' > "$T/data/comms/hana-users.json"
# 重複チェックの偽物（DUP=1 で「重複あり」を返す）
# ★hold は偽物にしない＝本物の todo-brief.py へ委譲する。
#   理由コードの検証（HOLD_REASONS に無い区分を弾く）は本物側にあり、
#   偽物で通すと「積んだつもりで弾かれていた」を見逃す（今回まさにそれが起きていた）。
python3 - "$PROJ/bin/todo-brief.py" "$T" <<'PY2'
import sys, json, os
src = open(sys.argv[1], encoding="utf-8").read()
d = sys.argv[2]
src = src.replace('STATE = os.path.join(ROOT, "data", "todo-manager", "state.json")',
                  'STATE = %s' % json.dumps(os.path.join(d, "hold-state.json")))
open(os.path.join(d, "tb_real.py"), "w", encoding="utf-8").write(src)
PY2
grep -q 'STATE = "' "$T/tb_real.py" || { echo "❌ 差し替え失敗（hold用STATE）" >&2; exit 2; }
cat > "$T/brief.py" <<'FAKE'
import json, os, subprocess, sys
if sys.argv[1:2] == ["hold"]:
    sys.exit(subprocess.run([sys.executable, os.environ["REAL_BRIEF"]] + sys.argv[1:]).returncode)
def verdict():
    if os.environ.get("DUP") == "1":
        return {"safe_to_create": False, "exact": [{"id": 99}], "similar": []}
    return {"safe_to_create": True, "exact": [], "similar": []}
if sys.argv[1:2] == ["check-batch"]:
    # ★1回の呼び出しで全行ぶんを返す（本物と同じ契約）。呼ばれた回数を記録する。
    if os.environ.get("FAKE_ORDER"):
        open(os.environ["FAKE_ORDER"], "a").write("CHECK\n")
    items = json.loads(sys.stdin.read() or "[]")
    if os.environ.get("DROP_ONE") == "1":      # 結果を1件わざと欠かす（黙って二重起票しないか）
        items = items[1:]
    print(json.dumps({i["tag"]: verdict() for i in items}))
    sys.exit(0)
if os.environ.get("FAKE_ORDER"):
    open(os.environ["FAKE_ORDER"], "a").write("CHECK\n")
print(json.dumps(verdict()))
FAKE
# 起票APIの偽物（渡された JSON をそのまま返し、呼び出しを記録する）
# ★引数の位置を本物に合わせる：呼び出しは [bash, API, "create-todo", JSON] なので
#   このスクリプトから見て $1=create-todo / $2=JSON（$3 ではない）。
#   ここがずれると「postが動かない」という嘘の失敗が出る（2026-08-25 実際に出した）。
cat > "$T/api.sh" <<'FAKE'
#!/bin/bash
echo "$2" >> "$FAKE_CALLS"
[ -n "${FAKE_ORDER:-}" ] && echo "CREATE" >> "$FAKE_ORDER"
python3 -c "
import json,sys
p=json.loads(sys.argv[1]); p['id']=999
print(json.dumps({'success':True,'data':p}))" "$2"
FAKE
chmod +x "$T/api.sh"
export FAKE_BRIEF="$T/brief.py" FAKE_API="$T/api.sh" FAKE_CALLS="$T/calls.txt"
export FAKE_ORDER="$T/order.txt"
export REAL_BRIEF="$T/tb_real.py"
: > "$FAKE_CALLS"
led() { printf '%s\n' "$@" > "$T/data/comms/chatwork/ledger.md"; }
tp() { python3 "$T/tp.py" "$@" 2>&1; }
jq_() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

echo "=== ★台帳に書いていないことを補わない（このツールの存在理由）==="
led "C-901 | 👥 | 💬 R〔A→B〕 | 用件 | 次の一歩 | 担当: 担当A | 最終: 08/25 | cw: 1-2"
r=$(tp plan)
echo "$r" | jq_ "len(d['would_create'])==0 and d['skipped'][0]['reason']=='no-fields'" | grep -q True \
  && ok "★案件・期日の欄が無い行は起票しない（欄が無いことと『不明』は違う）" || ng "欄が無くても起票する" "$r"

echo
echo "=== 起票の条件（rules/modes/comms.md v1.0/v1.1）==="
led "C-901 | 👥 | 💬 R〔A→B〕 | 明示の期限 | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-09-05 | 根拠: 明示 | 最終: 08/25 | cw: 1-2" \
    "C-902 | 👥 | 💬 R〔A→B〕 | 逆算の期限 | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-09-09 | 根拠: 逆算 | 最終: 08/25 | cw: 1-3" \
    "C-903 | 👥 | 💬 R〔A→B〕 | 至急のみ   | 次 | 担当: 担当A | 案件: 不明 | 期日: 無し | 根拠: 強度 | 最終: 08/25 | cw: 1-4" \
    "C-904 | 👥 | 💬 R〔A→B〕 | 担当不明   | 次 | 担当: 不明   | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-5" \
    "C-905 | 🟢 | 💬 R〔A→B〕 | 相手ボール | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-6"
r=$(tp plan)
echo "$r" | jq_ "sorted(x['tag'] for x in d['would_create'])==['C-901','C-902','C-903']" | grep -q True \
  && ok "👥かつ担当確定のものだけ起票する（🟢と担当不明は除く）" || ng "対象の選び方が違う" "$r"
echo "$r" | jq_ "[x['due_date'] for x in d['would_create'] if x['tag']=='C-901']==['2026-09-05']" | grep -q True \
  && ok "根拠が『明示』なら期日を入れる" || ng "明示の期日が入らない" "$r"
echo "$r" | jq_ "[x['due_date'] for x in d['would_create'] if x['tag']=='C-902']==[None]" | grep -q True \
  && ok "★根拠が『逆算』なら期日を入れない（外部の予定日を期限にしない）" || ng "逆算の日付を入れている" "$r"
echo "$r" | jq_ "[x['due_date'] for x in d['would_create'] if x['tag']=='C-903']==[None]" | grep -q True \
  && ok "★根拠が『強度』なら期日を入れない（至急を今日と読み替えない）" || ng "強度から日付を作っている" "$r"
echo "$r" | jq_ "[x['reason'] for x in d['skipped'] if x['tag']=='C-902'][0].startswith('due-needs-human')" | grep -q True \
  && ok "★逆算・強度は確認列へ回す（人が日付を決める）" || ng "確認列に回らない" "$r"
echo "$r" | jq_ "[x['work_id'] for x in d['would_create'] if x['tag']=='C-903']==[199]" | grep -q True \
  && ok "案件が『不明』ならマイエージェント(199)へ入れる" || ng "落とし先が違う" "$r"
echo "$r" | jq_ "'案件マスター' in [x['description'] for x in d['would_create'] if x['tag']=='C-903'][0] and '案件を作成' in [x['description'] for x in d['would_create'] if x['tag']=='C-903'][0]" | grep -q True \
  && ok "★マイエージェント行きには案件作成を促す文面を添える（社長ご指示）" || ng "促していない" "$r"

echo
echo "=== ★名義（社長の保有件数を増やさない）==="
echo "$r" | jq_ "all(x['user_id']==39 for x in d['would_create'])" | grep -q True \
  && ok "★作成者は HANAエージェント(39)＝社長名義で作らない" || ng "名義が違う" "$r"
echo "$r" | jq_ "all(x['assignee_user_id']==37 for x in d['would_create'])" | grep -q True \
  && ok "担当は台帳の『担当:』から引いた user_id" || ng "担当が違う" "$r"

echo
echo "=== ★推測しない（対応が無ければ起票しない）==="
led "C-901 | 👥 | 💬 R〔A→B〕 | 用件 | 次 | 担当: 知らない人 | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-2"
r=$(tp plan)
echo "$r" | jq_ "len(d['would_create'])==0 and d['skipped'][0]['reason']=='assignee-unclear'" | grep -q True \
  && ok "★対応表に無い担当名は起票しない（似た名前に寄せない）" || ng "知らない名前で起票する" "$r"
led "C-901 | 👥 | 💬 R〔A→B〕 | 用件 | 次 | 担当: 担当A | 案件: にしぶ | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-2"
r=$(tp plan)
echo "$r" | jq_ "len(d['would_create'])==0 and d['skipped'][0]['reason']=='work-ambiguous'" | grep -q True \
  && ok "★案件が数値でなければ起票しない（名前から案件を探しに行かない）" || ng "案件を推測している" "$r"

echo
echo "=== 重複は起票しない ==="
led "C-901 | 👥 | 💬 R〔A→B〕 | 用件 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-2"
r=$(DUP=1 tp plan)
echo "$r" | jq_ "len(d['would_create'])==0 and d['skipped'][0]['reason'].startswith('duplicate-suspect')" | grep -q True \
  && ok "既存ToDoと重なるものは起票しない" || ng "重複を作る" "$r"

echo
echo "=== ★重複チェックが失敗したら起票しない（認証切れの日に全件二重起票しない）==="
cat > "$T/brief_ng.py" <<'FAKE'
import sys
sys.exit("ERROR: hana-tools から取れません")
FAKE
FAKE_BRIEF="$T/brief_ng.py" tp plan >/dev/null 2>&1 \
  && ng "★重複チェックが失敗しても起票を続ける（重複の温床）" \
  || ok "★重複チェックが失敗したら止まる（黙って『重複なし』と読まない）"

echo
echo "=== 実際の書き込み（post）==="
: > "$FAKE_CALLS"
led "C-901 | 👥 | 💬 R〔A→B〕 | 用件 | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-09-05 | 根拠: 明示 | 最終: 08/25 | cw: 1-2"
r=$(tp post)
echo "$r" | jq_ "d['mode']=='post' and len(d['created'])==1 and d['created'][0]['id']==999" | grep -q True \
  && ok "post で実際に起票し、結果のIDを返す" || ng "postが機能しない" "$r"
python3 -c "
import json,sys
p=json.loads(open('$FAKE_CALLS').read().strip())
assert p['user_id']==39 and p['assignee_user_id']==37 and p['work_id']==131, p
assert p['due_date']=='2026-09-05', p
assert '[C-901]' in p['content'], p
" && ok "★APIへ渡す中身が台帳のとおり（勝手に足さない・変えない）" || ng "渡す中身が違う" "$(cat "$FAKE_CALLS")"
: > "$FAKE_CALLS"
tp post --dry-run >/dev/null
[ ! -s "$FAKE_CALLS" ] && ok "--dry-run では1件も書き込まない" || ng "dry-runで書き込んだ"
: > "$FAKE_CALLS"
tp plan >/dev/null
[ ! -s "$FAKE_CALLS" ] && ok "plan では1件も書き込まない" || ng "planで書き込んだ"

echo
echo "=== ★サーバが担当を書き換えたら失敗として扱う ==="
# hana-tools は assignee_user_id を null に正規化することがある（作成者＝担当とみなす仕様）。
# 意図と違う担当で保存されたのに成功と記録すると、**その仕事は誰にも届かないまま
# 「起票済み」になる**。2026-08-24 の疎通テストで、この正規化が実在することを確認済み。
cat > "$T/api_bad.sh" <<'FAKE'
#!/bin/bash
echo "$2" >> "$FAKE_CALLS"
[ -n "${FAKE_ORDER:-}" ] && echo "CREATE" >> "$FAKE_ORDER"
python3 -c "
import json,sys
p=json.loads(sys.argv[1]); p['id']=999; p['assignee_user_id']=None
print(json.dumps({'success':True,'data':p}))" "$2"
FAKE
chmod +x "$T/api_bad.sh"
led "C-901 | 👥 | 💬 R〔A→B〕 | 用件 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-2"
FAKE_API="$T/api_bad.sh" tp post >/dev/null 2>&1 \
  && ng "★担当が null に戻されても成功扱いする（誰にも届かないToDoができる）" \
  || ok "★担当が意図と違えば失敗として止まる"

echo
echo "=== 黙って壊れない ==="
rm -f "$T/data/comms/hana-users.json"
tp plan >/dev/null 2>&1 && ng "担当の対応表が無くても続行する" || ok "担当の対応表が無ければ止まる"
echo '{"by_name":{"担当A":37,"社長":34}}' > "$T/data/comms/hana-users.json"
echo '{}' > "$T/config/comms-members.json"
tp plan >/dev/null 2>&1 && ng "起票名義が不明でも続行する" || ok "起票名義が不明なら止まる"
echo '{"hana_user_ids":{"agent":39}}' > "$T/config/comms-members.json"
rm -f "$T/data/comms/chatwork/ledger.md"
tp plan >/dev/null 2>&1 && ng "台帳が無くても続行する" || ok "台帳が無ければ止まる"

echo
echo "=== LLM を使っていない（このツールの前提）==="
# ★コメント・説明文の「LLM」という語に反応させない（設計を説明している箇所で必ず出てくる）。
#   見るのは**呼び出し**＝claude 実行・API キー・HTTP クライアントの取り込み。
if grep -vE '^\s*#' "$SRC" | grep -qiE 'claude -p|anthropic|openai|import requests|urllib\.request|httpx'; then
  ng "★LLM・外部APIを呼んでいる（外部入力を読む役と書く役の分離が崩れる）"
else
  ok "★LLM を一切呼ばない（台帳の値をそのまま渡すだけ）"
fi

echo
echo "=== ★見送りは確認列へ積む（2026-09-03 追加・8/25 導入時に実装されていなかった）==="
rm -f "$T/hold-state.json"; : > "$FAKE_CALLS"
led "C-901 | 👥 | 💬 R〔A→B〕 | 欄が無い | 次 | 担当: 担当A | 最終: 08/25 | cw: 1-2" \
    "C-902 | 👥 | 💬 R〔A→B〕 | 担当不明 | 次 | 担当: 不明   | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-3" \
    "C-903 | 👥 | 💬 R〔A→B〕 | 案件が語 | 次 | 担当: 担当A | 案件: あれ | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-4"
r=$(tp hold-sync)
echo "$r" | jq_ "sorted((x['tag'],x['reason']) for x in d['added'])==[('C-901','no-fields'),('C-902','assignee-unclear'),('C-903','work-ambiguous')]" | grep -q True \
  && ok "★見送り3件が確認列に積まれる（理由つき）" || ng "確認列に積まれない" "$r"
h=$(python3 "$T/tb_real.py" hold)
echo "$h" | jq_ "d['count']==3" | grep -q True \
  && ok "★本物の todo-brief.py 側でも3件見える（理由コードが弾かれていない）" || ng "本物側に残っていない" "$h"
[ ! -s "$FAKE_CALLS" ] \
  && ok "★hold-sync は hana-tools を一度も呼ばない（外部書き込みと分離）" || ng "外部APIを呼んでいる" "$(cat "$FAKE_CALLS")"

echo "$r" | jq_ "d['hold_total']==3" | grep -q True \
  && ok "積んだ合計を報告する" || ng "合計が合わない" "$r"

r2=$(tp hold-sync)
echo "$r2" | jq_ "d['added']==[]" | grep -q True \
  && ok "★2回目は積み直さない（2時間おきに走っても滞留日数が0に戻らない）" || ng "毎回積み直している" "$r2"

echo "=== ★確認列は機械が消さない（人が積んだ分を黙って消さないため）==="
led "C-999 | 👥 | 💬 R〔A→B〕 | 別件 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-9"
r3=$(tp hold-sync)
echo "$r3" | jq_ "sorted(d['no_longer_held'])==['C-901','C-902','C-903'] and d['hold_total']==3" | grep -q True \
  && ok "★対象でなくなった行は『見せる』だけで消さない" || ng "自動で消している" "$r3"

echo "=== ★理由の装飾を落として固定コードにする（状態ファイルに固有名詞・IDを残さない）==="
rm -f "$T/hold-state.json"
led "C-901 | 👥 | 💬 R〔A→B〕 | 重複する | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-2"
r4=$(DUP=1 tp hold-sync)
echo "$r4" | jq_ "d['added']==[{'tag':'C-901','reason':'duplicate-suspect'}]" | grep -q True \
  && ok "★duplicate-suspect(既存 [99]) → 固定コードだけを積む" || ng "装飾つきのまま積んでいる" "$r4"
python3 -c "
import json,sys,re
s=open('$T/hold-state.json',encoding='utf-8').read()
sys.exit(0 if not re.search(r'[0-9]{2,}\\]|既存', s) else 1)" \
  && ok "★状態ファイルに ToDo の ID が残らない" || ng "IDが状態ファイルに漏れている" "$(cat "$T/hold-state.json")"

echo "=== ★dry-run は積まない ==="
rm -f "$T/hold-state.json"
led "C-901 | 👥 | 💬 R〔A→B〕 | 欄が無い | 次 | 担当: 担当A | 最終: 08/25 | cw: 1-2"
r5=$(tp hold-sync --dry-run)
echo "$r5" | jq_ "len(d['added'])==1" | grep -q True \
  && ok "dry-run でも『何を積むか』は見せる" || ng "dry-run の表示が出ない" "$r5"
[ ! -f "$T/hold-state.json" ] \
  && ok "★dry-run は状態ファイルを作らない" || ng "dry-run なのに書いている" "$(cat "$T/hold-state.json")"

echo "=== ★重い理由を優先する（1行に複数の理由が付くとき）==="
rm -f "$T/hold-state.json"; : > "$FAKE_CALLS"
led "C-901 | 👥 | 💬 R〔A→B〕 | 逆算かつ重複 | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-09-09 | 根拠: 逆算 | 最終: 08/25 | cw: 1-2"
r6=$(DUP=1 tp hold-sync)
echo "$r6" | jq_ "d['added']==[{'tag':'C-901','reason':'duplicate-suspect'}]" | grep -q True \
  && ok "逆算＋重複の行は duplicate-suspect で積まれる" || ng "軽い理由で積んでいる" "$r6"
# ★台帳経由では duplicate が必ず最後に来るため、順序を入れ替えた場合を突けない。
#   ここだけ関数を直接呼んで「後勝ちにしていないか」を見る（変異で落ちないテストは無いのと同じ）。
u=$(cd "$T" && python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('tp', '$T/tp.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
now, add, gone = m.hold_plan([('C-901', 'assignee-unclear'), ('C-901', 'due-needs-human(逆算)')])
print(now['C-901'])" 2>&1)
[ "$u" = "assignee-unclear" ] \
  && ok "★重い理由が先に来ても、軽い理由で上書きしない（後勝ちにしない）" || ng "後勝ちになっている" "$u"

echo "=== ★知らない区分でも捨てない（黙って落とすと確認列から消える）==="
u2=$(cd "$T" && python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('tp', '$T/tp.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
now, add, gone = m.hold_plan([('C-901', 'brand-new-reason')])
print(now.get('C-901'))" 2>&1)
[ "$u2" = "other" ] \
  && ok "★HOLD_REASONS に無い区分は other にして残す（捨てない）" || ng "知らない区分を捨てている" "$u2"

echo "=== ★post も確認列を同期する ==="
rm -f "$T/hold-state.json"; : > "$FAKE_CALLS"
led "C-901 | 👥 | 💬 R〔A→B〕 | 起票できる | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-2" \
    "C-902 | 👥 | 💬 R〔A→B〕 | 欄が無い   | 次 | 担当: 担当A | 最終: 08/25 | cw: 1-3"
r7=$(tp post)
echo "$r7" | jq_ "len(d['created'])==1 and d['hold_added']==[{'tag':'C-902','reason':'no-fields'}]" | grep -q True \
  && ok "起票と同時に、見送りを確認列へ回すと報告する" || ng "post で確認列が同期されない" "$r7"
# ★報告だけで実際に積んでいない、を見逃さない（出力は同期の有無に関係なく出る）
h7=$(python3 "$T/tb_real.py" hold)
echo "$h7" | jq_ "[x['tag'] for x in d['items']]==['C-902']" | grep -q True \
  && ok "★post のあと、確認列に実際に入っている（報告だけで終わらない）" || ng "報告だけで積んでいない" "$h7"

echo "=== ★台帳が実際に書いている形（装飾つき）を読める（仕様例の素の形だけでは足りない）==="
# comms は人が読む前提で `期日: **2026-09-05** ／ 根拠: 明示（理由） ※注記` と書く。
# 素の値しか読めない実装だと **全行の期日が落ちる**（2026-09-03 実測＝👥22行すべて None）。
led "C-901 | 👥 | 💬 R〔A→B〕 | 装飾つき明示 | 次 | 担当: 担当A | 案件: **131** | 最終: 08/25 | cw: 1-2 | 期日: **2026-09-05** ／ 根拠: 明示（**理由**） ※注記" \
    "C-902 | 👥 | 💬 R〔A→B〕 | 装飾つき強度 | 次 | 担当: 担当A | 案件: 不明 | 最終: 08/25 | cw: 1-3 | 期日: **無し** ／ 根拠: 強度（「早めに」／⚠️<u>30日</u>） ※注記" \
    "C-903 | 👥 | 💬 R〔A→B〕 | 装飾つき無し | 次 | 担当: 担当A | 案件: \`67\` | 最終: 08/25 | cw: 1-4 | 期日: **無し** ／ 根拠: 無し ※<u>注記</u>" \
    "C-904 | 👥 | 💬 R〔A→B〕 | 括弧なし注記 | 次 | 担当: 担当A | 案件: 131 | 最終: 08/25 | cw: 1-5 | 期日: **2026-09-06** ／ 根拠: 明示 ※🎯<u>注記だけが続く形</u>"
r8=$(tp plan)
echo "$r8" | jq_ "[x['due_date'] for x in d['would_create'] if x['tag']=='C-901']==['2026-09-05']" | grep -q True \
  && ok "★装飾（**）と続く『／ 根拠:』を落として期日を読む" || ng "装飾つきの期日が落ちている" "$r8"
echo "$r8" | jq_ "[x['work_id'] for x in d['would_create'] if x['tag']=='C-901']==[131]" | grep -q True \
  && ok "★装飾つきの案件番号を読む" || ng "装飾つきの案件が読めない" "$r8"
echo "$r8" | jq_ "[x['work_id'] for x in d['would_create'] if x['tag']=='C-903']==[67]" | grep -q True \
  && ok "★バッククォート付きの案件番号を読む" || ng "コード表記の案件が読めない" "$r8"
echo "$r8" | jq_ "'due-needs-human(強度)' in [x['reason'] for x in d['skipped'] if x['tag']=='C-902']" | grep -q True \
  && ok "★根拠に理由書き（括弧・注記）が続いても『強度』と読む＝確認列へ回る" || ng "根拠が読めず確認列に回らない" "$r8"
echo "$r8" | jq_ "[x['due_date'] for x in d['would_create'] if x['tag']=='C-902']==[None]" | grep -q True \
  && ok "★『期日: 無し』を日付と読み違えない" || ng "無しを日付にしている" "$r8"

echo "$r8" | jq_ "[x['due_date'] for x in d['would_create'] if x['tag']=='C-904']==['2026-09-06']" | grep -q True \
  && ok "★根拠のうしろに注記（※）だけが続く形でも『明示』と読む" || ng "※注記で根拠が読めなくなる" "$r8"

echo "=== ★🔴（社長ボール）も起票する（2026-09-04 社長ご指示）==="
# それまで対象は 👥 だけ＝🔴 は構造的に永久に起票されなかった（小磯様 C-122 で発覚）。
led "C-901 | 🔴 | 💬 R〔A→B〕 | 社長ボール | 次 | 担当: 社長   | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-2" \
    "C-902 | 👥 | 💬 R〔A→B〕 | 社内ボール | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-3" \
    "C-903 | 🟢 | 💬 R〔A→B〕 | 相手ボール | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-4" \
    "C-904 | 📌 | 💬 R〔A→B〕 | 確定記録   | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-5"
ra=$(tp plan)
echo "$ra" | jq_ "sorted(x['tag'] for x in d['would_create'])==['C-901','C-902']" | grep -q True \
  && ok "★🔴 と 👥 を起票し、🟢・📌 は対象外にする" || ng "対象の状態が違う" "$ra"
echo "$ra" | jq_ "[x['assignee_user_id'] for x in d['would_create'] if x['tag']=='C-901']==[34]" | grep -q True \
  && ok "★🔴 の担当は台帳の『担当: 社長』から引く（34）" || ng "社長の user_id が引けていない" "$ra"

echo "=== ★状態は「列」で判定する（行のどこかに絵文字があるか、ではない）==="
# 注記に「※👥対象外」と書いた 🔴 の行が、行全体の検索をすり抜けて混ざっていた（実測 C-039・C-125）。
led "C-901 | 🟢 | 💬 R〔A→B〕 | 相手ボール | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-2 ※👥対象外（人事・労務）"
rb=$(tp plan)
echo "$rb" | jq_ "len(d['would_create'])==0 and len(d['skipped'])==0" | grep -q True \
  && ok "★注記に 👥 と書いてあっても、状態列が 🟢 なら対象外" || ng "注記の絵文字を状態と読んだ" "$rb"

echo "=== ★重複チェックは1回の問い合わせで全行ぶん（行ごとに全件取得しない）==="
# 行ごとに聞くと、対象54行なら54回ToDo全件を取り直す＝遅いだけでなく
# **行ごとに違うスナップショットで判定する**ことになる（2026-09-04 Codexレビュー指摘）。
rm -f "$FAKE_ORDER"
led "C-901 | 👥 | 💬 R〔A→B〕 | 用件1 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 09/04 | cw: 1-2" \
    "C-902 | 👥 | 💬 R〔A→B〕 | 用件2 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 09/04 | cw: 1-3" \
    "C-903 | 👥 | 💬 R〔A→B〕 | 用件3 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 09/04 | cw: 1-4"
rq=$(tp plan)
echo "$rq" | jq_ "len(d['would_create'])==3" | grep -q True \
  && ok "3行とも起票候補になる" || ng "起票候補の数が違う" "$rq"
[ "$(grep -c CHECK "$FAKE_ORDER")" = "1" ] \
  && ok "★3行でも重複チェックの問い合わせは1回" || ng "行ごとに問い合わせている（$(grep -c CHECK "$FAKE_ORDER") 回）"

echo "=== ★結果が返ってこない行を「重複なし」と読まない ==="
rj=$(DROP_ONE=1 tp plan 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$rj" | grep -q "含まれない行があります" \
  && ok "★判定が欠けたら止まる（黙って二重起票しない）" || ng "欠けた行を素通りさせる" "$rj"

echo "=== ★本文に引用された『／ 担当: ○○』を欄と読まない（別人へ起票しない）==="
# 欄の列かどうかを見ずに区切りの直後だけで判定すると、本文の引用を欄と読む
# （2026-09-04 Codexレビュー指摘。実データでの発生は0件だが、静かに別人へ渡る種類）。
led "C-901 | 👥 | 💬 R〔A→B〕 | 先方が「案件: 999 で」／ 担当: 知らない人 とのこと | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 09/04 | cw: 1-2"
rk=$(tp plan)
echo "$rk" | jq_ "[x['assignee_user_id'] for x in d['would_create']]==[37]" | grep -q True \
  && ok "★本文の『／ 担当: 知らない人』でなく、欄の『担当: 担当A』を読む" || ng "本文を欄と読んで別人に割り当てた" "$rk"
echo "$rk" | jq_ "[x['work_id'] for x in d['would_create']]==[131]" | grep -q True \
  && ok "本文の『案件: 999』も拾わない" || ng "本文の案件を拾った" "$rk"

echo "=== ★『明示』なのに日付として読めないものを黙って通さない ==="
# 黙って期日なしで起票すると、約束した期限が消えたまま督促に乗らない。
led "C-901 | 👥 | 💬 R〔A→B〕 | 暦に無い日 | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-02-31 | 根拠: 明示 | 最終: 09/04 | cw: 1-2" \
    "C-902 | 👥 | 💬 R〔A→B〕 | 書式が違う | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-9-5    | 根拠: 明示 | 最終: 09/04 | cw: 1-3" \
    "C-903 | 👥 | 💬 R〔A→B〕 | 正しい日   | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-09-05 | 根拠: 明示 | 最終: 09/04 | cw: 1-4"
rl=$(tp plan)
echo "$rl" | jq_ "[x['due_date'] for x in d['would_create'] if x['tag']=='C-901']==[None]" | grep -q True \
  && ok "★暦に存在しない日付（2026-02-31）を期日にしない" || ng "存在しない日付をAPIへ送る" "$rl"
echo "$rl" | jq_ "sorted(x['tag'] for x in d['skipped'] if '読めない' in x['reason'])==['C-901','C-902']" | grep -q True \
  && ok "★『明示だが日付として読めない』を確認列へ回す（黙って期日を消さない）" || ng "黙って期日なしにしている" "$rl"
echo "$rl" | jq_ "[x['due_date'] for x in d['would_create'] if x['tag']=='C-903']==['2026-09-05']" | grep -q True \
  && ok "正しい明示の期日はそのまま入る（非回帰）" || ng "正しい期日が入らない" "$rl"

echo "=== ★『案件: 対象外』は起票も確認列も対象外（2026-09-04 社長ご指示）==="
# 人事・労務など「ToDo にしないと決めた行」。`不明`（分からない）と違い**決めた結果**なので、
# 確認列に積むと「まだ決まっていない件」に紛れて永遠に消えない。
led "C-901 | 🔴 | 💬 R〔A→B〕 | 労務の件 | 次 | 担当: 社長 | 案件: 対象外 | 期日: 無し | 根拠: 無し | 最終: 09/04 | cw: 1-2" \
    "C-902 | 🔴 | 💬 R〔A→B〕 | 案件が無い | 次 | 担当: 社長 | 案件: 不明   | 期日: 無し | 根拠: 無し | 最終: 09/04 | cw: 1-3"
rd=$(tp plan)
echo "$rd" | jq_ "[x['tag'] for x in d['would_create']]==['C-902']" | grep -q True \
  && ok "★『対象外』は起票しない" || ng "対象外を起票した" "$rd"
echo "$rd" | jq_ "not any(x['tag']=='C-901' for x in d['skipped'])" | grep -q True \
  && ok "★『対象外』は確認列にも積まない（決めたことを溜めない）" || ng "対象外を確認列に積んだ" "$rd"

echo "=== ★案件が無い用件は「案件を作ってください」として社長に上げる ==="
echo "$rd" | jq_ "[x['reason'] for x in d['skipped'] if x['tag']=='C-902']==['work-missing']" | grep -q True \
  && ok "★『不明』は work-missing として確認列に立てる（本文に埋もれさせない）" || ng "案件作成のお願いが上がらない" "$rd"
echo "$rd" | jq_ "[x['work_id'] for x in d['would_create']]==[199] and '案件を作成' in d['would_create'][0]['description']" | grep -q True \
  && ok "同時に 199 へ起票はする（用件そのものは落とさない）" || ng "用件を落としている" "$rd"
echo "$rd" | jq_ "d['hold_would_add']==[{'tag':'C-902','reason':'work-missing'}]" | grep -q True \
  && ok "★確認列へ積む差分にも現れる" || ng "確認列の差分に出ない" "$rd"

echo "=== ★重複判定を全件終えてから作る（自分が作ったものに当てない）==="
# 作りながら調べると、同じ実行で作った兄弟が次の行の重複判定に当たって落ちる
# （2026-09-04 実害＝24件を作った回で C-131・C-132 が落ちた）。
rm -f "$T/hold-state.json" "$FAKE_ORDER"; : > "$FAKE_CALLS"
led "C-901 | 👥 | 💬 R〔A→B〕 | 用件1 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 09/04 | cw: 1-2" \
    "C-902 | 👥 | 💬 R〔A→B〕 | 用件2 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 09/04 | cw: 1-3" \
    "C-903 | 👥 | 💬 R〔A→B〕 | 用件3 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 09/04 | cw: 1-4"
re_=$(tp post)
echo "$re_" | jq_ "len(d['created'])==3" | grep -q True \
  && ok "3件とも起票された" || ng "起票数が違う" "$re_"
od=$(tr -d ' ' < "$FAKE_ORDER" | tr '\n' ' ')
[ "$od" = "CHECK CREATE CREATE CREATE " ] \
  && ok "★判定（1回のバッチ）が終わってから作成3回（作りながら調べない）" || ng "判定と作成が交互になっている" "$od"

echo "=== ★本文に紛れた同名の語を欄と読み違えない ==="
led "C-901 | 👥 | 💬 R〔A→B〕 | 先方が「案件: 999 で」とおっしゃった件 | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 08/25 | cw: 1-2"
r9=$(tp plan)
echo "$r9" | jq_ "[x['work_id'] for x in d['would_create']]==[131]" | grep -q True \
  && ok "★本文中の『案件: 999』でなく、列の『案件: 131』を読む" || ng "本文を欄と読み違えた" "$r9"

echo
echo "=== 自動起票には必ず作業日を入れる（2026-11-03 社長ご決定＝翌営業日・土日は月曜へ）==="
led "C-910 | 👥 | 💬 R〔A→B〕 | 期日なし | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 11/03 | cw: 1-9" \
    "C-911 | 👥 | 💬 R〔A→B〕 | 明示の期限（先） | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-11-20 | 根拠: 明示 | 最終: 11/03 | cw: 1-10" \
    "C-912 | 👥 | 💬 R〔A→B〕 | 明示の期限（今日） | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-11-03 | 根拠: 明示 | 最終: 11/03 | cw: 1-11" \
    "C-913 | 👥 | 💬 R〔A→B〕 | 逆算 | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-11-10 | 根拠: 逆算 | 最終: 11/03 | cw: 1-12"
wd() { printf '%s' "$1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print([x.get('next_work_date') for x in d['would_create'] if x['tag']==sys.argv[1]][0])" "$2"; }
r=$(TODO_POST_TODAY=2026-11-03 tp plan)   # 2026-11-03 は火曜
[ "$(wd "$r" C-910)" = "2026-11-04" ] \
  && ok "★期日が無い行にも作業日が入る（翌日）＝これが空だと朝の一覧に一度も出ない" \
  || ng "★作業日が入っていない（本件の実害そのもの）" "$(wd "$r" C-910)"
[ "$(wd "$r" C-911)" = "2026-11-04" ] && ok "期日が先にあっても作業日は翌営業日（期日の直前まで待たない）" || ng "期日から逆算してしまっている" "$(wd "$r" C-911)"
[ "$(wd "$r" C-912)" = "2026-11-03" ] \
  && ok "★期日を追い越さない（期日が翌営業日より前なら期日の当日）" || ng "★約束の日より後ろに作業日が来ている" "$(wd "$r" C-912)"
[ "$(wd "$r" C-913)" = "2026-11-04" ] \
  && ok "★根拠が『逆算』でも作業日は入る（期日は入れない＝線は従来どおり）" || ng "逆算の行に作業日が入らない" "$(wd "$r" C-913)"
printf '%s' "$r" | jq_ "[x['due_date'] for x in d['would_create'] if x['tag']=='C-913']==[None]" | grep -q True \
  && ok "★作業日を足しても『逆算の期日は入れない』が守られている" || ng "逆算から期日を作ってしまった" "$r"

# ★土日は月曜へ寄せる（社長ご決定）★ 2026-11-06 は金曜＝翌日は土曜
r2=$(TODO_POST_TODAY=2026-11-06 tp plan)
[ "$(wd "$r2" C-910)" = "2026-11-09" ] \
  && ok "★金曜に起票した分は月曜へ寄せる（土日を予定日にしない＝「過ぎた」の山を増やさない）" \
  || ng "★土日に寄せていない" "$(wd "$r2" C-910)"
r3=$(TODO_POST_TODAY=2026-11-07 tp plan)   # 土曜に起票＝翌日も日曜
[ "$(wd "$r3" C-910)" = "2026-11-09" ] && ok "土曜に起票した分も月曜（日曜を飛ばす）" || ng "日曜を飛ばしていない" "$(wd "$r3" C-910)"
# 期日が土曜なら土曜のまま＝相手との約束はこちらの休みで動かさない
led "C-914 | 👥 | 💬 R〔A→B〕 | 期日が土曜 | 次 | 担当: 担当A | 案件: 131 | 期日: 2026-11-07 | 根拠: 明示 | 最終: 11/03 | cw: 1-13"
r4=$(TODO_POST_TODAY=2026-11-06 tp plan)
[ "$(wd "$r4" C-914)" = "2026-11-07" ] \
  && ok "★期日が土曜なら作業日も土曜のまま（約束の日はこちらの休みで動かさない）" \
  || ng "★約束の日を月曜へずらしている" "$(wd "$r4" C-914)"

echo
echo "=== 作業日が本当に保存されたかを応答で確かめる ==="
led "C-910 | 👥 | 💬 R〔A→B〕 | 期日なし | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 11/03 | cw: 1-9"
: > "$FAKE_CALLS"
TODO_POST_TODAY=2026-11-03 tp post >/dev/null
grep -q '"next_work_date": "2026-11-04"' "$FAKE_CALLS" \
  && ok "★起票の送信内容に作業日が入っている（payload の許可リストに入れ忘れていない）" \
  || ng "★送信していない＝ツールの中だけで決めて API に渡していない" "$(cat "$FAKE_CALLS")"
# ★API が作業日を落としたら黙らない★（受けていないのに「入れたつもり」で進むと本件が再発する）
cat > "$T/api-drop.sh" <<'DROP'
#!/bin/bash
echo "$2" >> "$FAKE_CALLS"
python3 -c "
import json,sys
p=json.loads(sys.argv[1]); p['id']=999; p.pop('next_work_date',None)
print(json.dumps({'success':True,'data':p}))" "$2"
DROP
chmod +x "$T/api-drop.sh"
rp=$(FAKE_API="$T/api-drop.sh" TODO_POST_TODAY=2026-11-03 tp post)
printf '%s' "$rp" | jq_ "len(d['warnings'])==1 and '作業日が保存されませんでした' in d['warnings'][0]" | grep -q True \
  && ok "★応答に作業日が無ければ警告を出す（API が受けていないことを黙って見逃さない）" \
  || ng "★作業日が落ちても黙って成功にしている" "$rp"
rp2=$(TODO_POST_TODAY=2026-11-03 tp post)
printf '%s' "$rp2" | jq_ "d['warnings']==[]" | grep -q True \
  && ok "保存されていれば警告は出さない（鳴りっぱなしにしない）" || ng "正常でも警告が出ている" "$rp2"

# ★基準日は JST 固定（2026-11-03 Codex 指摘）★ ホストの TZ に依存すると移設で1日ずれる
TZ=UTC python3 -c "
import importlib.util, datetime, sys
spec=importlib.util.spec_from_file_location('tp', sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
jst=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).date()
assert m.today()==jst, (m.today(), jst)
" "$T/tp.py" && ok "★基準日は JST 固定（TZ=UTC のホストでも JST の今日）" \
  || ng "★date.today() を使っている＝ホストの TZ で1日ずれる"

# ★作業日が保存されなかったら確認列に積む（画面の警告だけでは宿題が残らない）★
led "C-910 | 👥 | 💬 R〔A→B〕 | 期日なし | 次 | 担当: 担当A | 案件: 131 | 期日: 無し | 根拠: 無し | 最終: 11/03 | cw: 1-9"
rm -f "$T/hold-state.json"
rh=$(FAKE_API="$T/api-drop.sh" TODO_POST_TODAY=2026-11-03 tp post)
printf '%s' "$rh" | jq_ "any(x['reason']=='work-date-not-set' for x in d['hold_added'])" | grep -q True \
  && ok "★作業日が落ちたら確認列に積む（無人サイクルはログに流して終わるので画面だけでは消える）" \
  || ng "★確認列に積んでいない＝宿題が残らない" "$rh"
python3 "$T/tb_real.py" hold | jq_ "any(x['tag']=='C-910' and x['reason']=='work-date-not-set' for x in d['items'])" | grep -q True \
  && ok "★確認列に実際に載っている（区分が未登録だと弾かれて『積んだつもり』になる）" \
  || ng "★確認列に載っていない" "$(python3 "$T/tb_real.py" hold)"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
