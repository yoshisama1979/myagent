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
echo '{"by_name":{"担当A":37}}'       > "$T/data/comms/hana-users.json"
# 重複チェックの偽物（DUP=1 で「重複あり」を返す）
cat > "$T/brief.py" <<'FAKE'
import json, os, sys
if os.environ.get("DUP") == "1":
    print(json.dumps({"safe_to_create": False, "exact": [{"id": 99}], "similar": []}))
else:
    print(json.dumps({"safe_to_create": True, "exact": [], "similar": []}))
FAKE
# 起票APIの偽物（渡された JSON をそのまま返し、呼び出しを記録する）
# ★引数の位置を本物に合わせる：呼び出しは [bash, API, "create-todo", JSON] なので
#   このスクリプトから見て $1=create-todo / $2=JSON（$3 ではない）。
#   ここがずれると「postが動かない」という嘘の失敗が出る（2026-08-25 実際に出した）。
cat > "$T/api.sh" <<'FAKE'
#!/bin/bash
echo "$2" >> "$FAKE_CALLS"
python3 -c "
import json,sys
p=json.loads(sys.argv[1]); p['id']=999
print(json.dumps({'success':True,'data':p}))" "$2"
FAKE
chmod +x "$T/api.sh"
export FAKE_BRIEF="$T/brief.py" FAKE_API="$T/api.sh" FAKE_CALLS="$T/calls.txt"
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
echo '{"by_name":{"担当A":37}}' > "$T/data/comms/hana-users.json"
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
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
