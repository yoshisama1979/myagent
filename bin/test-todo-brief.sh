#!/usr/bin/env bash
# todo-brief.py（担当別の進行管理・材料出し）の回帰テスト。
#
# rules/testing.md §2 の必須3条件すべてに該当する：
#   ①無人ループから呼ばれる予定 ②状態ファイルを書く ③判定ロジック（消化率→次回件数）を持つ
#
# ★偽API自体を先に検証する★
#   2026-08-24、手動確認で「全部片付いても件数が増えない」という結果が出た。原因は本体ではなく
#   **テストの偽APIが引数を取り違えて常に同じ応答を返していた**こと。嘘をつくテストは、
#   テストが無いより悪い（緑を根拠に間違った実装を通す）。よって偽物の挙動を最初に固定する。
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJ/bin/todo-brief.py"
[ -f "$SRC" ] || { echo "❌ todo-brief.py が無い: $SRC" >&2; exit 2; }

P=0; N=0
ok() { P=$((P+1)); echo "  ✅ $1"; }
ng() { N=$((N+1)); echo "  ❌ $1"; [ $# -ge 2 ] && echo "      → $2"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- 本体を、状態ファイルと API だけ差し替えて持ち込む（ロジックは書き写さない）---
python3 - "$SRC" "$T" <<'PY'
import sys, json, os
src = open(sys.argv[1], encoding="utf-8").read()
d = sys.argv[2]
src = src.replace('STATE = os.path.join(ROOT, "data", "todo-manager", "state.json")',
                  'STATE = %s' % json.dumps(os.path.join(d, "state.json")))
src = src.replace('API = os.path.join(ROOT, "bin", "hana-api.sh")',
                  'API = %s' % json.dumps(os.path.join(d, "api.sh")))
src = src.replace('CLIENTS_CACHE = os.path.join(ROOT, "data", "clients-cache.json")',
                  'CLIENTS_CACHE = %s' % json.dumps(os.path.join(d, "clients.json")))
src = src.replace('LEDGER = os.path.join(ROOT, "data", "comms", "chatwork", "ledger.md")',
                  'LEDGER = %s' % json.dumps(os.path.join(d, "ledger.md")))
open(os.path.join(d, "tb.py"), "w", encoding="utf-8").write(src)
PY
grep -q 'STATE = "' "$T/tb.py" || { echo "❌ 差し替え失敗（状態ファイル）" >&2; exit 2; }
grep -q 'LEDGER = "' "$T/tb.py" || { echo "❌ 差し替え失敗（台帳）＝本物の台帳を読むテストになる" >&2; exit 2; }
grep -q 'API = "'   "$T/tb.py" || { echo "❌ 差し替え失敗（API）" >&2; exit 2; }
grep -q 'CLIENTS_CACHE = "' "$T/tb.py" || { echo "❌ 差し替え失敗（クライアント一覧）" >&2; exit 2; }

cat > "$T/members.json" <<'M'
{"hana_user_ids": {"president": 34, "agent": 39, "staff": [37]}}
M
python3 - "$T" <<'PY'
import sys, io, os
d = sys.argv[1]
src = io.open(os.path.join(d, "tb.py"), encoding="utf-8").read()
src = src.replace('os.path.join(ROOT, "config", "comms-members.json")',
                  '%r' % os.path.join(d, "members.json"))
io.open(os.path.join(d, "tb.py"), "w", encoding="utf-8").write(src)
PY

# 偽 hana-api：引数なし=全件（完了含む）／--status=incomplete=未完了だけ
cat > "$T/api.sh" <<'FAKE'
#!/bin/bash
# ★本物と同じ意地悪さを再現する（2026-08-25 変異テストで判明）：
#   本物の hana-api.sh は「担当未指定なら .env の既定ユーザー(34)を自動で入れる」ため、
#   担当を指定し忘れると社長ぶんしか返らない。偽物が親切に全件を返すと、
#   まさにその見落とし（2026-08-24 の実害）をテストで踏めない。
#   また null は「作成者が担当」の正規化値なので、34 で引くと null のものも返る。
# FAKE_ERR が指定されていれば、その中身をそのまま返す（認証切れ等の再現用）
if [ -n "${FAKE_ERR:-}" ]; then printf '%s' "$FAKE_ERR"; exit 0; fi
U=""; ST="all"
for a in "$@"; do
  case "$a" in
    --assignee_user_id=*) U="${a#*=}";;
    --status=*)           ST="${a#*=}";;
  esac
done
[ -z "$U" ] && U=34
python3 -c "
import json,sys
u=int(sys.argv[1]); st=sys.argv[2]
a=json.load(open(sys.argv[3]))
def owns(x):
    v=x.get('assignee_user_id')
    return v==u or (v is None and u==34)
a=[x for x in a if owns(x)]
if st=='incomplete': a=[x for x in a if not x.get('completed_at')]
print(json.dumps(a))" "$U" "$ST" "$FAKE_ALL"
FAKE
chmod +x "$T/api.sh"
tb() { TODO_BRIEF_TODAY="$1" FAKE_ALL="$T/all.json" FAKE_OPEN="$T/open.json" \
       python3 "$T/tb.py" "${@:2}" 2>&1; }
setj() { printf '%s' "$1" > "$T/all.json"; printf '%s' "$2" > "$T/open.json"; }

OPEN3='[{"id":1,"assignee_user_id":null,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"A","work_id":9},
        {"id":2,"assignee_user_id":null,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"B","work_id":9},
        {"id":3,"assignee_user_id":null,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"C","work_id":9}]'
done_of() { python3 -c "
import json,sys
n=int(sys.argv[1]); a=json.loads(sys.argv[2])
for i,x in enumerate(a):
    if i<n: x['completed_at']='2026-08-24T10:00'
print(json.dumps(a))" "$1" "$OPEN3"; }
open_after() { python3 -c "
import json,sys
n=int(sys.argv[1]); print(json.dumps(json.loads(sys.argv[2])[n:]))" "$1" "$OPEN3"; }

echo "=== ★偽API自体が正しいか（ここが嘘だと以降すべてが嘘になる）==="
setj "$(done_of 2)" "$(open_after 2)"
c_all=$(FAKE_ALL="$T/all.json" FAKE_OPEN="$T/open.json" bash "$T/api.sh" todos | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
c_open=$(FAKE_ALL="$T/all.json" FAKE_OPEN="$T/open.json" bash "$T/api.sh" todos --status=incomplete | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
[ "$c_all" = 3 ] && ok "引数なし＝全件を返す（3件）" || ng "全件が返らない" "$c_all"
[ "$c_open" = 1 ] && ok "--status=incomplete＝未完了だけ返す（1件）" || ng "未完了が返らない" "$c_open"

echo
echo "=== 候補出し（選定はしない・事実だけ）==="
setj "$OPEN3" "$OPEN3"
out=$(tb 2026-08-24 candidates)
echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin); c=d['candidates']
assert d['count']==3, d['count']
assert c[0]['overdue_days']==23, c[0]['overdue_days']
assert c[0]['stale_days']==23, c[0]['stale_days']
" && ok "超過日数・停滞日数を基準日から機械的に計算する" || ng "日数の計算が違う" "$out"
echo "$out" | grep -q '"content"' && ok "内容を材料として渡す（選ぶのは呼び出し側）" || ng "内容が無い"
echo "$out" | grep -qE '"priority"|"score"|"recommend"' \
  && ng "★ツールが優先度を決めている（判断はモードの仕事・基準が二重になる）" \
  || ok "★ツールは優先度を決めない（判断と計算を分けている）"

echo
echo "=== 担当で絞る ==="
MIX='[{"id":1,"assignee_user_id":null,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"社長ぶん"},
      {"id":2,"assignee_user_id":37,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"担当Bぶん"}]'
setj "$MIX" "$MIX"
[ "$(tb 2026-08-24 candidates | python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])')" = 1 ] \
  && ok "担当未指定＝割り当ての無いもの（作成者ぶん）だけ" || ng "既定の絞り込みが違う"
[ "$(tb 2026-08-24 candidates --assignee 37 | python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])')" = 1 ] \
  && ok "担当を指定するとその人のぶんだけ" || ng "担当指定が効かない"
tb 2026-08-24 candidates --assignee 37 | grep -q '担当Bぶん' && ok "指定した担当の中身が返る" || ng "中身が違う"

echo "=== ★保険値が実行状況で動く（社長ご指示「多すぎず少なすぎず」）==="
# ⚠️ これは上限ではなく**保険**。今日出す理由があるものはこの値を超えて出してよい
#    （2026-08-25 社長ご指摘で設計変更＝件数で絞ると、急ぎが多い日に取りこぼす）。
setj "$OPEN3" "$OPEN3"
rm -f "$T/state.json"
[ "$(tb 2026-08-24 review | python3 -c 'import json,sys;print(json.load(sys.stdin)["next_cap"])')" = 8 ] \
  && ok "初回の保険値は8" || ng "初回の保険値が違う"
tb 2026-08-24 record --ids 1,2,3 >/dev/null
nc() { setj "$(done_of "$1")" "$(open_after "$1")"; tb 2026-08-25 review | python3 -c 'import json,sys;print(json.load(sys.stdin)["next_cap"])'; }
[ "$(nc 3)" = 10 ] && ok "★全部片付いた→保険をゆるめる（8→10）" || ng "ゆるまない" "$(nc 3)"
[ "$(nc 2)" = 8 ]  && ok "半分以上片付いた→据え置き（8→8）" || ng "据え置かない" "$(nc 2)"
[ "$(nc 1)" = 6 ]  && ok "★捌けていない→保険を締める（8→6）" || ng "締まらない" "$(nc 1)"
[ "$(nc 0)" = 6 ]  && ok "1件も片付かなくても急に0にはしない" || ng "0件時の挙動が違う" "$(nc 0)"

echo
echo "=== ★完了の確認は全担当ぶんで行う（担当が付け替わっても見失わない）==="
# 提案した相手とは別の人が引き取って完了させることがある。自分の担当ぶんだけを見ていると
# 「まだ終わっていない」と誤判定し、翌日また同じものを突く（＝終わった仕事を催促する）。
rm -f "$T/state.json"
MOVED='[{"id":1,"assignee_user_id":37,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"X"},
        {"id":2,"assignee_user_id":37,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"Y"}]'
setj "$MOVED" "$MOVED"
tb 2026-08-24 record --assignee 37 --ids 1,2 >/dev/null
# 1番は「別の担当(34)へ移されたうえで完了」した状態にする
# ★移す先は「既定ユーザー(34)以外」にする：34 へ移すと、担当を絞らない取得でも
#   たまたま見つかってしまい、この検査が素通りする（2026-08-25 変異テストで実際に素通りした）。
MOVED_DONE='[{"id":1,"assignee_user_id":39,"completed_at":"2026-08-24T10:00","due_date":"2026-08-01","updated_at":"2026-08-01","content":"X"},
             {"id":2,"assignee_user_id":37,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"Y"}]'
setj "$MOVED_DONE" "$MOVED_DONE"
r=$(tb 2026-08-25 review --assignee 37)
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert d['completed']==1, d
" && ok "★担当が付け替えられて完了したものも「片付いた」と数える" || ng "付け替え後の完了を見失う" "$r"
r2=$(tb 2026-08-27 stale --assignee 37)
echo "$r2" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert [i['id'] for i in d['items']]==[2], d
" && ok "★完了したものは催促しない（終わった仕事を突かない）" || ng "完了済みを催促する" "$r2"
rm -f "$T/state.json"

echo "=== 保険値の上下限（暴走も停止もしない）==="
rm -f "$T/state.json"; setj "$OPEN3" "$OPEN3"
python3 - "$T/state.json" <<'PYA'
import json,sys
json.dump({"self":{"history":[{"date":"2026-08-24","proposed":[1,2,3],"cap":12}]}}, open(sys.argv[1],"w"))
PYA
setj "$(done_of 3)" "$(open_after 3)"
[ "$(tb 2026-08-25 review | python3 -c 'import json,sys;print(json.load(sys.stdin)["next_cap"])')" = 12 ] \
  && ok "★保険値は12を超えない（際限なく増えない）" || ng "上限が効かない"
python3 - "$T/state.json" <<'PYB'
import json,sys
json.dump({"self":{"history":[{"date":"2026-08-26","proposed":[1],"cap":1}]}}, open(sys.argv[1],"w"))
PYB
setj "$OPEN3" "$OPEN3"
[ "$(tb 2026-08-27 review | python3 -c 'import json,sys;print(json.load(sys.stdin)["next_cap"])')" = 1 ] \
  && ok "★保険値は1を下回らない（督促が途切れない）" || ng "下限が効かない"
rm -f "$T/state.json"

echo
echo "=== ★完了漏れの見張り（社長ご指示「終わったらTODO消してもらう」）==="
setj "$OPEN3" "$OPEN3"
rm -f "$T/state.json"; tb 2026-08-24 record --ids 1,2,3 >/dev/null
[ "$(tb 2026-08-26 stale | python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])')" = 0 ] \
  && ok "提案から3日未満は聞かない（急かしすぎない）" || ng "早すぎる催促"
[ "$(tb 2026-08-27 stale | python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])')" = 3 ] \
  && ok "★3日過ぎて未完了なら「終わっていませんか」の材料に出す" || ng "完了漏れを拾えない"
setj "$(done_of 3)" "$(open_after 3)"
[ "$(tb 2026-08-27 stale | python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])')" = 0 ] \
  && ok "完了済みは聞かない（終わった仕事を突かない）" || ng "完了済みを催促する"

echo
echo "=== 黙って壊れない ==="
setj "$OPEN3" "$OPEN3"
printf 'これはJSONではない' > "$T/state.json"
tb 2026-08-24 review >/dev/null 2>&1 && ng "★状態ファイルが壊れていても素通りする（履歴が消えて消化率が測れなくなる）" \
  || ok "★状態ファイルの破損は黙って捨てず止まる"
rm -f "$T/state.json"
printf 'not json' > "$T/open.json"; printf 'not json' > "$T/all.json"
tb 2026-08-24 candidates >/dev/null 2>&1 && ng "APIが壊れた応答でも成功扱い＝候補ゼロに化ける" \
  || ok "APIの応答が読めなければ止まる（黙って「対象なし」にしない）"

echo
echo "=== 状態ファイルに中身を持ち込まない（git に入っても安全か）==="
setj "$OPEN3" "$OPEN3"; rm -f "$T/state.json"
tb 2026-08-24 record --ids 1,2,3 >/dev/null
grep -qE '"A"|"B"|"C"|content|description' "$T/state.json" \
  && ng "★状態ファイルに用件の中身が入っている（クライアント名が git へ漏れる）" \
  || ok "★状態ファイルは ID と日付だけ（中身・クライアント名を持たない）"
python3 -c "
import json,sys
s=json.load(open('$T/state.json'))
h=s['self']['history']
assert len(h)==1 and h[0]['proposed']==[1,2,3], h
" && ok "提案した ID と日付を記録する" || ng "記録の形が違う"
tb 2026-08-24 record --ids 1,2 >/dev/null
python3 -c "
import json
h=json.load(open('$T/state.json'))['self']['history']
assert len(h)==1 and h[0]['proposed']==[1,2], h
" && ok "同じ日に2回記録しても履歴は1件（二重計上しない）" || ng "同日が二重に積まれる"

echo
echo "=== ★重複防止（2026-08-24 実害の再発防止）==="
# 実際に起きたこと：担当を指定せずに取得した結果を「全ToDo」と思い込み、
# 別担当の既存ToDoを見落として同じ用件を二重に起票した。しかも既存にはタグが無かったため
# タグ照合だけでは検知できなかった。両方を固定する。
MIX2='[{"id":1,"assignee_user_id":null,"content":"社長のタスク","due_date":"2026-08-01","updated_at":"2026-08-01"},
       {"id":2,"assignee_user_id":37,"content":"ゼータ社サイトのリニューアル対応","due_date":"2026-08-01","updated_at":"2026-08-01"},
       {"id":3,"assignee_user_id":37,"content":"別件の作業 [C-999]","due_date":"2026-08-01","updated_at":"2026-08-01"}]'
setj "$MIX2" "$MIX2"
r=$(tb 2026-08-24 check --tag C-999 --title "別件の作業")
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert d['scanned']==3, d['scanned']
assert [x['id'] for x in d['exact']]==[3], d['exact']
assert d['safe_to_create'] is False
" && ok "★タグが一致する既存があれば起票しない" || ng "タグ重複を検知しない" "$r"
r=$(tb 2026-08-24 check --tag C-007 --title "ゼータ社サイト リニューアル")
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert not d['exact'], d['exact']
assert any(x['id']==2 for x in d['similar']), d['similar']
assert d['safe_to_create'] is False
" && ok "★タグが無い既存でも、語の重なりで気づける（昨日すり抜けた形）" || ng "語の重なりを拾えない" "$r"
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin); assert d['scanned']==3, d['scanned']
" && ok "★全担当ぶんを照合する（自分の担当ぶんだけを全体と思い込まない）" || ng "照合範囲が狭い"
# ★タグは角括弧つきで照合する：`C-01` が `[C-010]` に部分一致すると、
#   無関係な用件の起票を止めてしまう（業務が止まる側の誤検知）。
BOUND='[{"id":1,"assignee_user_id":37,"content":"別の用件 [C-010]","due_date":"2026-08-01","updated_at":"2026-08-01"}]'
setj "$BOUND" "$BOUND"
r=$(tb 2026-08-24 check --tag C-01 --title "まったく別の用件")
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert not d['exact'], ('C-01 が [C-010] に部分一致している', d['exact'])
" && ok "★タグは角括弧つきで照合する（C-01 が [C-010] に当たらない）" || ng "部分一致で誤検知する" "$r"
r=$(tb 2026-08-24 check --tag C-010 --title "別の用件")
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert [x['id'] for x in d['exact']]==[1], d['exact']
" && ok "正しいタグはきちんと一致する" || ng "本来の一致まで落ちる" "$r"

# ★人が作ったToDoは件名が短く、詳細が説明欄にあることが多い。件名だけ見ると重複を見逃す。
echo "=== ★別の台帳タグが付いた既存は「似ている」に数えない（兄弟で潰し合わない）==="
# 機械が付けた [C-XXX] は定義上べつの台帳行。似ていても重複ではない。
# これを数えると、同じ客先の兄弟を作った直後に次の行が永久に起票できなくなる
# （2026-09-04 実害＝24件を一度に作った回で2件が落ちた。部分失敗のあとは次回以降も落ち続ける）。
SIB='[{"id":1,"assignee_user_id":37,"content":"ゼータ社サイトのリニューアル対応 [C-100]","due_date":"2026-08-01","updated_at":"2026-08-01"},
      {"id":2,"assignee_user_id":37,"content":"ゼータ社サイトのリニューアル対応","due_date":"2026-08-01","updated_at":"2026-08-01"}]'
setj "$SIB" "$SIB"
r=$(tb 2026-08-24 check --tag C-101 --title "ゼータ社サイト リニューアル")
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert [x['id'] for x in d['similar']]==[2], d['similar']
" && ok "★別タグ [C-100] は除外し、タグの無い人作成ToDo(2)だけを似ていると出す" || ng "兄弟を重複扱いしている" "$r"

echo "=== ★タグの無い既存は今までどおり語の重なりで拾う（非回帰・二重起票の防波堤）==="
SIB2='[{"id":1,"assignee_user_id":37,"content":"ゼータ社サイトのリニューアル対応 [C-100]","due_date":"2026-08-01","updated_at":"2026-08-01"}]'
setj "$SIB2" "$SIB2"
r=$(tb 2026-08-24 check --tag C-101 --title "ゼータ社サイト リニューアル")
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert d['safe_to_create'] is True, d
" && ok "別タグしか無ければ起票してよいと判定する" || ng "別タグで起票を止めている" "$r"

echo "=== ★check-batch は1回の取得で全行ぶんを返す（判定は check と同じ実装）==="
setj "$MIX2" "$MIX2"
r=$(printf '%s' '[{"tag":"C-999","title":"別件の作業"},{"tag":"C-500","title":"まったく新しい用件"}]' | tb 2026-08-24 check-batch)
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert sorted(d)==['C-500','C-999'], sorted(d)
assert d['C-999']['safe_to_create'] is False, d['C-999']
assert d['C-500']['safe_to_create'] is True, d['C-500']
" && ok "★全行ぶんを返し、判定は check と一致する" || ng "check-batch の結果が違う" "$r"

DESC='[{"id":1,"assignee_user_id":37,"content":"対応する","description":"ゼータ社サイトのリニューアル対応の件","due_date":"2026-08-01","updated_at":"2026-08-01"}]'
setj "$DESC" "$DESC"
r=$(tb 2026-08-24 check --tag C-007 --title "ゼータ社サイト リニューアル")
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert any(x['id']==1 for x in d['similar']), ('説明欄の語を見ていない', d)
assert d['safe_to_create'] is False
" && ok "★件名が短くても説明欄の語で重複に気づく" || ng "説明欄を見ていない" "$r"

setj "$MIX2" "$MIX2"
r=$(tb 2026-08-24 check --tag C-500 --title "まったく新しい用件")
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin); assert d['safe_to_create'] is True, d
" && ok "重複が無ければ起票してよいと答える（通すべきものは通す）" || ng "新規まで止める" "$r"
rm -f "$T/members.json"; tb 2026-08-24 check --tag C-1 --title x >/dev/null 2>&1   && ng "★担当名簿が無くても照合したふりをする（見落としの温床）"   || ok "★担当名簿が読めなければ止まる（誰のぶんを見たか不明なまま判定しない）"
cat > "$T/members.json" <<'M'
{"hana_user_ids": {"president": 34, "agent": 39, "staff": [37]}}
M

echo
echo "=== ★確認列（起票しなかったものを社長へ回す）==="
setj "$MIX2" "$MIX2"; rm -f "$T/state.json"
tb 2026-08-24 hold --add C-042 --reason no-work >/dev/null
tb 2026-08-24 hold --add C-012 --reason work-ambiguous >/dev/null
r=$(tb 2026-08-27 hold)
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert d['count']==2, d
assert all(i['reason'] for i in d['items']), d
assert any(i['days']==3 for i in d['items']), d
" && ok "★起票しなかったものを理由つきで積み、放置日数が分かる" || ng "確認列が機能しない" "$r"
tb 2026-08-24 hold --add C-999 >/dev/null 2>&1   && ng "理由なしでも積める（理由の無い保留は溜まるだけ）" || ok "理由が無ければ積ませない"
tb 2026-08-27 hold --resolve C-042 >/dev/null
[ "$(tb 2026-08-27 hold | python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])')" = 1 ]   && ok "解決したら確認列から外せる" || ng "外せない"
tb 2026-08-27 hold --resolve C-777 >/dev/null 2>&1   && ng "存在しないものを外せてしまう" || ok "存在しないものの解決は拒否する"

echo
echo "=== ★取得の失敗を「0件」に化けさせない（2026-08-25 実害の再発防止）==="
# 実際に起きたこと：hana-tools は認証切れでも HTTP 的には成功し {"success":false} を返す。
# それを「ToDo 0件」と読み、重複チェックが safe_to_create:true を返していた
# ＝**認証が切れた日に全件を二重起票する**。認証は定期的に切れる（8/19に14時間切れた）。
setj "$MIX2" "$MIX2"
for body in '{"success":false,"message":"認証切れ"}' '{"success":true}' 'not json' '[]'; do
  FAKE_ERR="$body" tb 2026-08-24 check --tag C-1 --title x >/dev/null 2>&1 \
    && ng "★異常応答を通してしまう（重複起票につながる）: $body" \
    || ok "異常応答で止まる: $body"
done
FAKE_ERR="" tb 2026-08-24 check --tag C-500 --title "新しい用件" >/dev/null 2>&1 \
  && ok "正常時は通す（通すべきものは通す）" || ng "正常時まで止める"

echo
echo "=== ★保険値は提案数に引きずられない（2026-08-25 実害の再発防止）==="
# 以前は「前回いくつ出したか」を基準に増減していたため、13件出した翌日は13件が基準になり、
# 設計上の上限がまったく効いていなかった（実データが反例だった）。
rm -f "$T/state.json"; setj "$MIX2" "$MIX2"
tb 2026-08-24 record --assignee 37 --ids 1,2,3,4,5,6,7,8,9,10,11,12,13 >/dev/null
r=$(tb 2026-08-25 review --assignee 37)
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert d['proposed']==13, d
assert d['prev_cap']<=12, d          # 保険値は提案数(13)ではなく保険の系列から来る
assert d['next_cap']<=12, d
" && ok "★13件出しても保険値は提案数に引きずられない" || ng "提案数が基準になっている" "$r"
echo "$r" | grep -q '上限ではなく保険' && ok "「上限ではない」と明示して渡す（理由があれば超えてよい）" || ng "誤解を招く"

echo
echo "=== ★件数でなく理由で絞る（社長ご指示・2026-08-25）==="
DUE='[{"id":1,"assignee_user_id":37,"due_date":"2026-08-20","updated_at":"2026-08-20","content":"期限切れ"},
      {"id":2,"assignee_user_id":37,"due_date":"2026-08-25","updated_at":"2026-08-20","content":"今日が期限"},
      {"id":3,"assignee_user_id":37,"due_date":"2026-09-30","updated_at":"2026-08-20","content":"まだ先"},
      {"id":4,"assignee_user_id":37,"updated_at":"2026-08-20","content":"期限なし"}]'
setj "$DUE" "$DUE"
r=$(tb 2026-08-25 candidates --assignee 37)
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
m={c['id']:c['due_reason'] for c in d['candidates']}
assert m[1]=='期限超過', m
assert m[2]=='期限が今日・明日', m
assert m[3] is None and m[4] is None, m
assert d['with_due_reason']==2, d
" && ok "★日付から「今日出す理由」を機械的に付ける（超過・今日明日）" || ng "理由が付かない" "$r"
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin); assert d['count']==4, d
" && ok "★理由が無いものも捨てずに渡す（本文から別の理由を見つけられるように）" || ng "捨てている"
echo "$r" | grep -q '件数で切っていません' && ok "件数で切らないことを明示して渡す" || ng "明示がない"

echo
echo "=== ★完了漏れの見張り：3つの穴（2026-08-25 Codexレビュー）==="
rm -f "$T/state.json"
S1='[{"id":1,"assignee_user_id":37,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"動いていない"},
     {"id":2,"assignee_user_id":37,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"あとで更新される"},
     {"id":3,"assignee_user_id":37,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"あとで担当が変わる"}]'
setj "$S1" "$S1"
tb 2026-08-10 record --assignee 37 --ids 1,2,3 >/dev/null
tb 2026-08-24 record --assignee 37 --ids 1 >/dev/null      # 1 だけ昨日 再提案
S2='[{"id":1,"assignee_user_id":37,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"動いていない"},
     {"id":2,"assignee_user_id":37,"due_date":"2026-08-01","updated_at":"2026-08-24","content":"あとで更新される"},
     {"id":3,"assignee_user_id":39,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"あとで担当が変わる"}]'
setj "$S2" "$S2"
r=$(tb 2026-08-25 stale --assignee 37)
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
ids=[i['id'] for i in d['items']]
assert 1 not in ids, ('昨日 再提案したものを「15日動いていない」と催促している', d)
assert 2 not in ids, ('提案後に更新があるのに催促している', d)
assert 3 in ids, ('担当を移された未完了を見失っている', d)
" && ok "★①再提案で時計が戻る ②動きがあれば聞かない ③担当を移されても見失わない" || ng "staleの穴が残っている" "$r"
rm -f "$T/state.json"

echo
echo "=== ★状態ファイルに固有名詞を書かせない ==="
setj "$MIX2" "$MIX2"
tb 2026-08-24 hold --add C-042 --reason "架空イベントの案件が無い" >/dev/null 2>&1 \
  && ng "★自由文の理由を受け付ける（クライアント名が git 追跡下に漏れる）" \
  || ok "★自由文の理由は拒否する（区分から選ばせる）"
tb 2026-08-24 hold --add C-042 --reason no-work >/dev/null
python3 -c "
import json,sys
s=json.load(open('$T/state.json'))
t=json.dumps(s, ensure_ascii=False)
import re
assert not re.search(r'[ぁ-んァ-ヶ一-龠]', t), ('状態ファイルに日本語が入っている', t[:200])
" && ok "★状態ファイルに日本語（＝固有名詞が入りうる文字）が1文字も無い" || ng "日本語が入っている"

echo
echo "=== ★日付は JST として読む（2026-08-25 partner セッションの指摘）==="
# hana-tools は日付を「JSTの0時」を UTC で表した形で返す：
#   投げた値 2026-08-28 → 返る値 2026-08-27T15:00:00.000000Z
# 先頭10文字を切ると1日前倒しになり、**督促が全件1日早く鳴る**（期限当日を「昨日が期限」と言う）。
TZ_CASE='[{"id":1,"assignee_user_id":37,"due_date":"2026-08-27T15:00:00.000000Z","updated_at":"2026-08-01","content":"JST では8/28が期限"},
          {"id":2,"assignee_user_id":37,"due_date":"2026-08-25","updated_at":"2026-08-01","content":"素の日付は そのまま"}]'
setj "$TZ_CASE" "$TZ_CASE"
r=$(tb 2026-08-28 candidates --assignee 37)
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
m={c['id']:c for c in d['candidates']}
assert m[1]['due']=='2026-08-28', ('UTC のまま切って1日ずれている', m[1]['due'])
assert m[1]['overdue_days']==0, ('期限当日なのに超過扱い', m[1])
assert m[1]['due_reason']=='期限が今日・明日', m[1]
" && ok "★UTC表記の期限を JST の日付として読む（1日早く鳴らない）" || ng "1日ずれる" "$r"
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
m={c['id']:c for c in d['candidates']}
assert m[2]['due']=='2026-08-25' and m[2]['overdue_days']==3, m[2]
" && ok "タイムゾーンの無い素の日付はそのまま JST として扱う" || ng "素の日付が壊れる" "$r"
r=$(tb 2026-08-29 candidates --assignee 37)
echo "$r" | python3 -c "
import json,sys; d=json.load(sys.stdin)
m={c['id']:c for c in d['candidates']}
assert m[1]['overdue_days']==1, ('翌日になって初めて1日超過のはず', m[1])
" && ok "★期限の翌日に初めて「1日超過」になる（境界がずれない）" || ng "境界がずれている" "$r"

echo
echo "=== ★確認列：積み直しても滞留日数が0に戻らない（2026-09-03 追加）==="
jq_() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
python3 "$T/tb.py" hold --add C-777 --reason no-fields >/dev/null 2>&1
python3 - "$T/state.json" <<'PY3'
import json, sys
p = sys.argv[1]
s = json.load(open(p, encoding="utf-8"))
s["_hold"]["C-777"]["since"] = "2026-08-24"   # 10日前に積まれたことにする
json.dump(s, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PY3
python3 "$T/tb.py" hold --add C-777 --reason no-fields >/dev/null 2>&1
h=$(python3 "$T/tb.py" hold)
echo "$h" | jq_ "[x['since'] for x in d['items'] if x['tag']=='C-777']==['2026-08-24']" | grep -q True \
  && ok "★2回目の --add で since を上書きしない（10日放置が見え続ける）" || ng "since が今日に戻っている" "$h"
echo "$h" | jq_ "[x['days'] for x in d['items'] if x['tag']=='C-777']!=[0]" | grep -q True \
  && ok "★滞留日数が 0 に戻らない" || ng "滞留日数が 0 に戻った" "$h"

echo "=== ★todo-post.py が出す区分をすべて受け付ける ==="
miss=""
for rr in assignee-unclear no-fields work-ambiguous duplicate-suspect due-needs-human other; do
  python3 "$T/tb.py" hold --add "C-88" --reason "$rr" >/dev/null 2>&1 || miss="$miss $rr"
done
[ -z "$miss" ] \
  && ok "★6区分すべてが HOLD_REASONS にある（弾かれると確認列に載らない）" || ng "受け付けない区分がある:$miss"

# ===========================================================================
# outside＝「外に約束があるか」で分ける（2026-09-11 社長ご指摘で新設／同日 Codex レビューで補強）
#
# ★この節が守っているもの★
#   2026-09-11、社長より「なぜこれを日々の提案で出してくれなかったんですか」とご指摘。
#   `candidates` は超過日数だけで並べるため、105日超の社内開発が上位を埋め、**4日超の
#   「よしだ歯科」（LINE で来たご依頼・社長ご自身が「月曜に作業します」と宣言して流れたもの）
#   が下に沈み、毎日見落とされていた**。区分が日数に負けたら、この見落としがそのまま再発する。
#
# ★初版のテストは弱かった（同日 Codex 指摘＋変異で実証）★
#   ①各区分の fixture が1件ずつだったため `items[:1]` に切る変異が素通りした
#   ②区分順を全体で固定していなかったため、2つの区分を入れ替える変異が素通りした
#   ③クライアント一覧を消すと顧客案件が消えるのに合格した＝**見落とす変異を仕様として固定**していた
#   よって以下は「各区分2件以上・全IDの集合・区分順の配列・保存則」で固定する。
# ===========================================================================
echo
echo "=== outside：区分が日数に勝つ（本件の再発防止）==="
cat > "$T/clients.json" <<'CL'
{"clients":[{"client_name":"よしだ歯科"},{"client_name":"株式会社アースレイズ"},
            {"client_name":"株式会社未来舎"},{"client_name":"辻村"},
            {"client_name":"株式会社はなさか"},{"client_name":"YCOM"},{"client_name":"AI"}]}
CL
# 長い説明欄（300文字超）の末尾に「LINE」を置く＝表示用の切り詰めで判定が死んでいないか
LONGDESC="$(python3 -c "print('経緯の記録。'*60 + 'LINEにて先方よりご依頼。')")"
OUT=$(python3 -c "
import json,sys
long=sys.argv[1]
print(json.dumps([
 # --- 社内（期限超過だが外への約束なし）＝下に沈むべき側。**古い**ほど区分に勝ってはいけない
 {'id':901,'assignee_user_id':None,'due_date':'2026-05-01','updated_at':'2026-05-01',
  'content':'AIチャットのダッシュボードに deploy-prod エイリアスを設定する','description':''},
 {'id':911,'assignee_user_id':None,'due_date':'2026-05-02','updated_at':'2026-05-02',
  'content':'ONLINE説明会ページの deadline を pipeline に載せる','description':''},
 # --- ①社長ご自身の期日つきの言葉（2件）
 {'id':902,'assignee_user_id':None,'due_date':'2026-09-09','updated_at':'2026-09-09',
  'content':'よしだ歯科 トップページ 診療一覧の対応',
  'description':'2026-09-04 社長ご指示「来週やるべきこと。月曜日に作業します」。'},
 {'id':912,'assignee_user_id':None,'due_date':'2026-09-10','updated_at':'2026-09-10',
  'content':'あいぼっくす 請求','description':'2026/9/8 社長ご決定）金額は4万円。'},
 # --- ②見えない経路（2件・うち1件は説明欄が300文字超で末尾に LINE）
 {'id':903,'assignee_user_id':None,'due_date':'2026-09-11','updated_at':'2026-09-11',
  'content':'よしだ歯科 HP修正指示書 対応','description':long},
 {'id':913,'assignee_user_id':None,'due_date':'2026-09-11','updated_at':'2026-09-11',
  'content':'新規のお客様からのお電話を取り次ぎ','description':''},
 # --- ③外のお客様（2件・うち1件は法人格つきの短い通称「未来舎」だけで書かれている）
 {'id':904,'assignee_user_id':None,'due_date':'2026-09-11','updated_at':'2026-09-11',
  'content':'【アースレイズHP】トップページ コーディング着手','description':''},
 {'id':914,'assignee_user_id':None,'due_date':'2026-09-11','updated_at':'2026-09-11',
  'content':'未来舎さんへサブページのデザイン依頼','description':''},
 # --- ④期日は来ているが区分が付かない（2件）＝**社内と同じ箱に入れてはいけない**
 {'id':905,'assignee_user_id':None,'due_date':'2026-09-11','updated_at':'2026-09-11',
  'content':'HANAチャットWeb広告の見直し（撤退ライン設定）','description':'受注ゼロで広告費のみ発生。'},
 {'id':915,'assignee_user_id':None,'due_date':'2026-09-11','updated_at':'2026-09-11',
  'content':'はなさか社内の YCOM ドメイン整理','description':'2026-09-04 社長に確認したい件。'},
 # --- 辻村＝法人格が無い2文字＝採らない（本文のどこにでも当たるため）
 {'id':916,'assignee_user_id':None,'due_date':'2026-09-11','updated_at':'2026-09-11',
  'content':'辻村さんの件','description':''},
 # --- 期限がまだ先＝今日の材料ではない
 {'id':906,'assignee_user_id':None,'due_date':'2026-12-01','updated_at':'2026-09-01',
  'content':'よしだ歯科 来期の相談','description':''}]))" "$LONGDESC")
setj "$OUT" "$OUT"
o=$(tb 2026-09-11 outside)

tier_ids() { echo "$1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(' '.join(sorted(str(r['id']) for t in d['tiers'] if t['tier']==sys.argv[1] for r in t['items'])))" "$2"; }

# --- ★全IDの集合で固定する（1件に切る変異・取りこぼす変異を両方つかまえる）---
[ "$(tier_ids "$o" promise-slipped)" = "902 912" ] \
  && ok "★社長ご自身の期日つきの言葉を<u>全件</u>立てる（#902 #912・件数を切らない）" \
  || ng "promise-slipped が違う" "$(tier_ids "$o" promise-slipped)"
[ "$(tier_ids "$o" invisible-channel)" = "903 913" ] \
  && ok "★見えない経路を全件立てる（#903 LINE／#913 電話）" \
  || ng "invisible-channel が違う" "$(tier_ids "$o" invisible-channel)"
[ "$(tier_ids "$o" client-facing)" = "904 914" ] \
  && ok "★お客様を待たせているものを全件立てる（#904 アースレイズ／#914 未来舎）" \
  || ng "client-facing が違う" "$(tier_ids "$o" client-facing)"
# ★901・911 は「130日超の社内開発」だが、ツールから見れば<u>区分が付かなかった期日つき</u>
#   ＝社内だと決めつけずに本文を返す。実データでも47件がここに入る（棚卸しの対象が見える）。
[ "$(tier_ids "$o" unclassified-due)" = "901 905 911 915 916" ] \
  && ok "★区分が付かない期日つきを<u>本文ごと</u>返す（#901 #905 #911 #915 #916＝見落としの隠れ場所）" \
  || ng "unclassified-due が違う" "$(tier_ids "$o" unclassified-due)"

# --- ★区分の順そのものを配列で固定（2つを入れ替える変異をつかまえる）---
echo "$o" | python3 -c "
import json,sys
d=json.load(sys.stdin)
got=[t['tier'] for t in d['tiers']]
want=['promise-slipped','invisible-channel','client-facing','unclassified-due']
assert got==want, got
assert 'internal' not in got, got
" && ok "★区分の並び順を配列全体で固定する（入れ替え変異をつかまえる）" \
  || ng "★区分順が変わっている" "$o"

echo "$o" | python3 -c "
import json,sys
d=json.load(sys.stdin)
first=d['tiers'][0]['items'][0]['id']
assert first==902, first          # 902 は5日超、901/911 は130日超
assert 901 in d['internal_ids'] or 901 in [r['id'] for t in d['tiers'] for r in t['items']]
" && ok "★130日超の社内タスクより 5日超の #902 が先に出る（日数で並べない）" \
  || ng "★日数が区分に勝っている＝本件がそのまま再発する" "$o"

# --- ★保存則：どの行も必ずどこか1つの箱に入る（どこにも入らない行＝静かな見落とし）---
echo "$o" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ids=[r['id'] for t in d['tiers'] for r in t['items']]+d['internal_ids']
assert len(ids)==len(set(ids)), '同じ行が2つの箱に入っている'
assert len(ids)==d['count']==d['accounted'], (len(ids), d['count'], d['accounted'])
" && ok "★保存則＝入力の全件がどこか1つの箱に入る（重複なし・取りこぼしなし）" \
  || ng "★行が消えている／重複している" "$o"

echo "=== outside：判定の取りこぼしと誤爆 ==="
echo "$o" | python3 -c "
import json,sys
d=json.load(sys.stdin)
inv=[r['id'] for t in d['tiers'] if t['tier']=='invisible-channel' for r in t['items']]
assert 903 in inv, '説明欄が300文字を超えると判定が死ぬ'
" && ok "★説明欄が300文字を超えても末尾の「LINE」を拾う（表示用の切り詰めで判定しない）" \
  || ng "★300文字で切った文字列で判定している" "$o"

echo "$o" | python3 -c "
import json,sys
d=json.load(sys.stdin)
inv=[r['id'] for t in d['tiers'] if t['tier']=='invisible-channel' for r in t['items']]
assert 905 not in inv, '撤退ラインが LINE として拾われた'
assert 911 not in inv, 'ONLINE/deadline/pipeline が LINE として拾われた'
" && ok "★『撤退ライン』『ONLINE』『deadline』を LINE と誤検知しない" \
  || ng "★LINE の誤検知がある" "$o"

echo "$o" | python3 -c "
import json,sys
d=json.load(sys.stdin)
pro=[r['id'] for t in d['tiers'] if t['tier']=='promise-slipped' for r in t['items']]
assert 912 in pro, 'スラッシュ区切りの日付（2026/9/8）を取りこぼした'
assert 915 not in pro, '「社長に確認」を宣言として拾った'
" && ok "★日付は 2026/9/8 形式も拾い、「社長に<u>確認</u>」は宣言として拾わない" \
  || ng "★PROMISE の判定が違う" "$o"

echo "$o" | python3 -c "
import json,sys
d=json.load(sys.stdin)
cli=[r['id'] for t in d['tiers'] if t['tier']=='client-facing' for r in t['items']]
assert 915 not in cli, '自社名（はなさか・YCOM）をクライアントとして拾った'
assert 916 not in cli, '法人格の無い2文字（辻村）を拾った'
assert 901 not in cli, '短い社名（AI）を拾った'
" && ok "★自社名（はなさか・YCOM）・法人格の無い2文字・短い社名を拾わない" \
  || ng "★クライアント判定が広すぎる" "$o"

echo "$o" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 906 in d['internal_ids'], '期限が先のものが今日の材料に混ざった'
assert d['warnings']==[], d['warnings']
" && ok "期限がまだ先のもの（#906）は外の名前が付いていても今日は立てない" \
  || ng "期限が先のものが立っている" "$o"

echo "$o" | grep -qE '"priority"|"score"|"recommend"' \
  && ng "★ツールが優先度を決めている（判断はモードの仕事）" \
  || ok "★ツールは『今日どれをやるか』を選ばない（candidates と同じ規律）"

echo "=== outside：クライアント一覧が壊れても<u>黙って</u>見落とさない ==="
rm -f "$T/clients.json"
o2=$(tb 2026-09-11 outside)
echo "$o2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['client_aliases_loaded']==0
assert d['warnings'], '一覧が読めないのに警告が無い＝静かに全件見落とす'
unc=[r['id'] for t in d['tiers'] if t['tier']=='unclassified-due' for r in t['items']]
assert 904 in unc and 914 in unc, ('顧客案件が消えた', unc)
pro=[r['id'] for t in d['tiers'] if t['tier']=='promise-slipped' for r in t['items']]
inv=[r['id'] for t in d['tiers'] if t['tier']=='invisible-channel' for r in t['items']]
assert 902 in pro and 903 in inv
" && ok "★一覧が読めないとき＝警告を出し、顧客案件は unclassified-due に<u>本文ごと</u>出す（消さない）" \
  || ng "★一覧欠損で顧客案件が静かに消える（fail-open）" "$o2"

echo
echo "=== outside：次の作業日（next_work_date）の区分（2026-10-07 社長ご承認・足すだけ）==="
# 契機＝朝のブリーフが due_date しか読まないため、**数日かかる作業が期日の当日まで上がらない**。
#   #459（期日 10/10）の中の雇用保険の届出が 10/5〜10/7 の朝に出ず、社長がたまたま思い出された。
#   社長「作業は1日で終わるものではないので、期日にいきなり言われても困る」。
# ★守りたい不変条件★
#   (1) 既存の区分（tiers）の順・中身・保存則を1つも動かさない＝**足すだけ**
#   (2) 日付は JST で読む（15:00Z は翌日）＝[:10] で切ると1日早く読む（2度実害のある型）
#   (3) next_work_date が空のものを「今日」「過ぎた」に数えない
#   (4) completed 済みは数えない
#   (5) 期日が来ていない行（internal 落ち）も**数える**＝ここを落とすと本件の目的が達成できない
#   (6) 件数は全件・本文だけ top 件（古い値の棚卸しが済むまで外の行を押し出さないため）
NWD='[{"id":701,"assignee_user_id":null,"content":"今日が作業日","updated_at":"2026-10-08",
       "next_work_date":"2026-10-07T15:00:00.000000Z"},
      {"id":702,"assignee_user_id":null,"content":"作業日を過ぎた","updated_at":"2026-10-08",
       "next_work_date":"2026-10-04T15:00:00.000000Z"},
      {"id":703,"assignee_user_id":null,"content":"作業日はまだ先","updated_at":"2026-10-08",
       "next_work_date":"2026-10-12T15:00:00.000000Z"},
      {"id":704,"assignee_user_id":null,"content":"作業日なし・期日が3日後","updated_at":"2026-10-08",
       "due_date":"2026-10-10T15:00:00.000000Z"},
      {"id":705,"assignee_user_id":null,"content":"作業日なし・期日が30日後","updated_at":"2026-10-08",
       "due_date":"2026-11-07T15:00:00.000000Z"},
      {"id":706,"assignee_user_id":null,"content":"作業日なし・期日が過ぎている","updated_at":"2026-10-08",
       "due_date":"2026-10-01T15:00:00.000000Z"},
      {"id":707,"assignee_user_id":null,"content":"作業日も期日もなし","updated_at":"2026-10-08"},
      {"id":708,"assignee_user_id":null,"content":"完了済み・今日が作業日","updated_at":"2026-10-08",
       "completed_at":"2026-10-08T01:00:00.000000Z","next_work_date":"2026-10-07T15:00:00.000000Z"},
      {"id":709,"assignee_user_id":null,"content":"開始日だけある（着手の予定として読まない）",
       "updated_at":"2026-10-08","start_date":"2026-10-01T15:00:00.000000Z"}]'
setj "$NWD" "$NWD"
on=$(tb 2026-10-08 outside)
blk() { printf '%s' "$2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=next(x for x in d['work_dates']['blocks'] if x['kind']==sys.argv[1])
print(' '.join(str(r['id']) for r in b['items']))" "$1"; }
cnt() { printf '%s' "$2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=next(x for x in d['work_dates']['blocks'] if x['kind']==sys.argv[1])
print(b['count'])" "$1"; }

[ "$(blk work-today "$on")" = "701" ] \
  && ok "★今日が次の作業日＝701だけ（15:00Z を JST で読む＝10-07T15:00Z は 10-08）" \
  || ng "work-today が違う" "$(blk work-today "$on")"
[ "$(blk work-slipped "$on")" = "702" ] \
  && ok "★次の作業日を過ぎて未完了＝702だけ" || ng "work-slipped が違う" "$(blk work-slipped "$on")"
[ "$(blk work-undated "$on")" = "704" ] \
  && ok "★期日7日以内で作業日が空＝704だけ（30日後の705・期日なしの707は入らない）" \
  || ng "work-undated が違う" "$(blk work-undated "$on")"

printf '%s' "$on" | python3 -c "
import json,sys
d=json.load(sys.stdin); w=d['work_dates']
ids=[r['id'] for b in w['blocks'] for r in b['items']]
assert 708 not in ids, ('完了済みを数えている', ids)
assert 703 not in ids, ('作業日がまだ先のものを数えている', ids)
assert 707 not in ids, ('作業日も期日も無いものを数えている', ids)
assert 709 not in ids, ('start_date を着手の予定として読んでいる', ids)
" && ok "★完了済み・まだ先・日付なし・start_date だけ＝いずれも数えない" \
  || ng "★数えてはいけないものを数えている" "$on"

[ "$(printf '%s' "$on" | python3 -c "
import json,sys;print(json.load(sys.stdin)['work_dates']['overdue_without_work_date'])")" = "1" ] \
  && ok "★期限超過かつ作業日が空＝件数で返す（706・本文の列には混ぜない）" \
  || ng "overdue_without_work_date が違う" "$on"

# ★過ぎた日数を付ける（社長ご依頼の「過ぎた日数つき」）＝10-04T15:00Z は JST 10-05 → 3日
[ "$(printf '%s' "$on" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=next(x for x in d['work_dates']['blocks'] if x['kind']=='work-slipped')
print(b['items'][0]['next_work_over_days'])")" = "3" ] \
  && ok "★過ぎた日数を JST で数える（10-04T15:00Z＝JST 10-05 から 3日）" \
  || ng "過ぎた日数が違う（[:10] で切ると 4 になる）" "$on"

# ★期日が来ていない行も数える＝tiers の internal に落ちた行を拾えているか
#   703/705/707 は internal 落ち。701 は「期日なし」なので internal だが work-today に出る。
printf '%s' "$on" | python3 -c "
import json,sys
d=json.load(sys.stdin)
shown=[r['id'] for t in d['tiers'] for r in t['items']]
assert 701 not in shown, '701 は期日が無いので tiers には出ない前提が崩れた'
ids=[r['id'] for b in d['work_dates']['blocks'] for r in b['items']]
assert 701 in ids, '★internal に落ちた行を work_dates が拾えていない（本件の目的そのもの）'
" && ok "★期日が来ていない行（internal 落ち）も次の作業日では拾う" \
  || ng "★internal 落ちを拾えていない＝数日かかる作業が期日まで上がらない" "$on"

# ★既存の区分を1つも動かしていない（保存則＋ラベルの並び）
printf '%s' "$on" | python3 -c "
import json,sys
d=json.load(sys.stdin)
want=['promise-slipped','invisible-channel','client-facing','unclassified-due']
assert [t['tier'] for t in d['tiers']]==want, [t['tier'] for t in d['tiers']]
ids=[r['id'] for t in d['tiers'] for r in t['items']]+d['internal_ids']
assert len(ids)==d['count']==d['accounted'], (len(ids), d['count'], d['accounted'])
assert '実行順ではありません' in d['note'], '既存の note が書き換わった'
" && ok "★既存の区分の順・保存則・note を動かしていない（足すだけ）" \
  || ng "★既存の区分を動かした" "$on"

# ★件数は全件・本文は top 件（古い値が多い間、外の行を押し出さない）
MANY=$(python3 -c "
import json
print(json.dumps([{'id':800+i,'assignee_user_id':None,'content':'x','updated_at':'2026-10-08',
                   'next_work_date':'2026-10-04T15:00:00.000000Z'} for i in range(15)]))")
setj "$MANY" "$MANY"
om=$(tb 2026-10-08 outside --work-date-top 3)
[ "$(cnt work-slipped "$om")" = "15" ] && ok "★件数は全件返す（15件）" || ng "件数が絞られている" "$(cnt work-slipped "$om")"
[ "$(printf '%s' "$om" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=next(x for x in d['work_dates']['blocks'] if x['kind']=='work-slipped')
print(len(b['items']), b['shown'])")" = "3 3" ] \
  && ok "★本文は top 件だけ（--work-date-top 3 で3件・shown に明示）" || ng "top が効かない" "$om"

echo "=== ★ルールの追随：CLAUDE.md に『動作』が残っているか ==="
# 2026-09-11 の見落としの真因は、自動ロードされる CLAUDE.md 側の項目3が「期日を見る」という
# <u>動作</u>を落として JST 補正の注意書きだけになっていたこと。main.md に「消すな」と書いても
# 機械では防げないので、ここで固定する（同日 Codex 指摘）。
CL_MD="$PROJ/CLAUDE.md"
# 2026-09-14：窓口＝セッション。CLAUDE.md は全セッションに載るので窓口別の手順は書かない。
# 守る事故は同じ（2026-09-11＝自動で読まれる側から「期日を見る」動作が消え、実行されなくなった）＝
# 着火の連鎖「CLAUDE.md の whoami → 対応表の management.rule → そのルールの outside・期日を見る」を固定する。
grep -q 'session-desk.py whoami' "$CL_MD" \
  && ok "★CLAUDE.md に窓口の着火（session-desk.py whoami）がある（自動ロードされる唯一のファイル）" \
  || ng "★CLAUDE.md から着火が消えた＝どの窓口も自分の手順を読まなくなる"
MG_RULE="$(python3 -c "import json;print(json.load(open('$PROJ/config/session-desks.json'))['desks']['management']['rule'])" 2>/dev/null)"
[ -n "$MG_RULE" ] && [ -f "$PROJ/$MG_RULE" ] \
  && ok "★対応表の management が実在するルールを指している（連鎖が切れていない）" \
  || ng "★対応表の management.rule が無い／存在しない＝マネジメントの期日確認に届かない"
grep -q 'todo-brief.py outside' "$PROJ/${MG_RULE:-rules/modes/management.md}" \
  && ok "★マネジメントのルールに outside の呼び出しがある" \
  || ng "★マネジメントのルールからコマンドが消えた＝毎朝の期日確認が実行されなくなる"
grep -q '期日を見る' "$PROJ/${MG_RULE:-rules/modes/management.md}" \
  && ok "★マネジメントのルールに『期日を見る』という<u>動作</u>が残っている（注意書きで置き換えない）" \
  || ng "★動作が注意書きに置き換わった＝2026-09-11 と同じ事故"

echo
echo "=== 期限なし×作業日なし（2026-11-02 マネジメント依頼・社長ご承認）==="
# ★実データを使わない★ 台帳は git 外＝テスト環境に無いこともある。固有名詞は架空名のみ。
cat > "$T/ledger.md" <<'LG'
# Chatwork・メール 整理台帳（テスト用の架空データ）
## 🔴 未解決
C-001 | 🔴 | 💬 架空商事（1対1） | 🆕💰**11/01 見積のご依頼** | 残＝**①見積を出す** | 件名: 【架空商事】見積 |
C-002 | 🔴 | 💬 架空工業（グループ） | 🆕**10/28 仕様のご質問** | 残＝**①回答する** | 件名: 【架空工業】仕様 |
C-003 | 🟢 | 📧 架空印刷 | 💰**10/20 入金の確認が済みました** | 残＝**無し** | 件名: 【架空印刷】入金 |
## 🟢 解決済み
C-002 | 🟢 | 💬 架空工業（古い行・過去の節に残っているもの） | 済み | 残＝**無し** |
LG
# id 1=期限あり / 2=🔴💰 / 3=🔴 / 4=🟢(🔴の節にある行) / 5=台帳に無いタグ / 6,10,11=タグなし
# 7=作業日が JST で「今日」/ 8=作業日が未来 / 9=説明の300文字より後ろにタグ
LONG=$(python3 -c "print('あ'*320)")
python3 - "$T" "$LONG" <<'PY'
import json, sys, os
d, long_desc = sys.argv[1], sys.argv[2]
rows = [
 {"id":1,"assignee_user_id":None,"due_date":"2026-08-01","updated_at":"2026-08-01","content":"期限あり [C-001]"},
 {"id":2,"assignee_user_id":None,"due_date":None,"updated_at":"2026-10-20","content":"【架空商事】見積 [C-001]"},
 {"id":3,"assignee_user_id":None,"due_date":None,"updated_at":"2026-10-20","content":"【架空工業】仕様 [C-002]"},
 {"id":4,"assignee_user_id":None,"due_date":None,"next_work_date":"2026-11-01","updated_at":"2026-11-01","content":"【架空印刷】入金 [C-003]"},
 {"id":5,"assignee_user_id":None,"due_date":None,"updated_at":"2026-10-20","content":"台帳に無いタグ [C-999]"},
 {"id":6,"assignee_user_id":None,"due_date":None,"updated_at":"2026-10-01","content":"手で作った ToDo（タグなし・古い）"},
 {"id":7,"assignee_user_id":None,"due_date":None,"next_work_date":"2026-11-03T15:00:00.000000Z","updated_at":"2026-11-03","content":"作業日が JST で今日"},
 {"id":8,"assignee_user_id":None,"due_date":None,"next_work_date":"2026-12-01","updated_at":"2026-11-03","content":"作業日が未来"},
 {"id":9,"assignee_user_id":None,"due_date":None,"updated_at":"2026-10-20","content":"説明の末尾にタグ","description":long_desc+" [C-001]"},
 {"id":10,"assignee_user_id":None,"due_date":None,"updated_at":"2026-11-03","content":"手で作った ToDo（タグなし・新しい）"},
 {"id":11,"assignee_user_id":None,"due_date":None,"next_work_date":"2026-10-20","updated_at":"2026-10-25","content":"手で作った ToDo（作業日を過ぎた）"},
]
json.dump(rows, open(os.path.join(d,"all.json"),"w",encoding="utf-8"), ensure_ascii=False)
json.dump(rows, open(os.path.join(d,"open.json"),"w",encoding="utf-8"), ensure_ascii=False)
PY
U=$(tb 2026-11-04 undated)
jq1() { printf '%s' "$U" | python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }

[ "$(jq1 'print(d["target_count"])')" = 8 ] \
  && ok "対象は「期限が空 × 作業日が空か過去」だけ（11件中8件＝期限あり・作業日が今日・未来を除く）" || ng "対象の条件が違う" "$(jq1 'print(d["target_count"])')"
printf '%s' "$U" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ids={r['id'] for b in d['blocks'] for r in b['items']}
assert 1 not in ids, '期限のある行が入っている'
assert 8 not in ids, '作業日が未来の行が入っている'
" && ok "期限がある行・作業日が未来の行は入らない（既存の区分が鳴らす／予定済み）" || ng "除外が効いていない"

# ★JST★ 作業日 2026-11-03T15:00:00Z は JST では 11/04＝今日。[:10] で切ると 11/03＝過去になり誤って出る
printf '%s' "$U" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ids={r['id'] for b in d['blocks'] for r in b['items']}
assert 7 not in ids, 'JST 補正が効いていない（UTC の 15:00 を前日と読んでいる）'
" && ok "★作業日を JST で読む（UTC 15:00＝翌日の0時。[:10] で切ると1日早く読む＝2度実害）" \
  || ng "★JST 補正が効いていない＝作業日が今日の行を『過ぎた』と言う"

blk() { printf '%s' "$U" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=[x for x in d['blocks'] if x['kind']==sys.argv[1]][0]
print(','.join(str(r['id']) for r in b['items']))" "$1"; }
[ "$(blk red-money)" = "2,9" ] && ok "台帳🔴＋💰 の箱（💰は台帳が付けた印を読む・本文から推測しない）" || ng "red-money が違う" "$(blk red-money)"
[ "$(blk red)" = "3" ] && ok "台帳🔴（💰なし）の箱" || ng "red が違う" "$(blk red)"
[ "$(blk other-tagged)" = "4" ] \
  && ok "★状態は行の2番目の欄から読む（🔴 の節にある 🟢 の行を 🔴 と言わない）" \
  || ng "★節の見出しで状態を判定している＝閉じた用件を社長の列に積む" "$(blk other-tagged)"
[ "$(blk tag-not-in-ledger)" = "5" ] && ok "タグはあるが台帳に無い行を別の箱にする（archive へ移った等）" || ng "tag-not-in-ledger が違う" "$(blk tag-not-in-ledger)"
[ "$(blk untagged)" = "11,6,10" ] \
  && ok "★タグが無い行も落とさない＝きっかけの #578 型（人が作った ToDo）が消えない" \
  || ng "★タグなしの行が落ちている／並び順が違う" "$(blk untagged)"
printf '%s' "$U" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=[x for x in d['blocks'] if x['kind']=='red-money'][0]
assert [r['id'] for r in b['items']][0]==2, b['items']
" && ok "説明の300文字より後ろにあるタグも拾う（生データで突合・切った文字列で判定しない）" \
  || ng "表示用に切った説明でタグを探している＝長い経過の行が沈む"

# ★保存則と排他★ 2026-11-03 の実装中、箱ごとに全行を filter したため 🔴💰 が red にも入り
#   42件が二重計上された。「他に N 件あり」に使う数字なので、二重は判断材料を直接壊す。
printf '%s' "$U" | python3 -c "
import json,sys
from collections import Counter
d=json.load(sys.stdin)
assert d['accounted']==d['target_count'], (d['accounted'], d['target_count'])
assert sum(b['count'] for b in d['blocks'])==d['target_count']
c=Counter(r['id'] for b in d['blocks'] for r in b['items'])
dup=[i for i,n in c.items() if n>1]
assert not dup, f'2つの箱に入っている: {dup}'
" && ok "★1行は必ず1箱＝件数が二重にならない（保存則の検算つき）" \
  || ng "★箱が排他になっていない＝件数が二重に増える"

# 件数は全件・本文だけ絞る（一覧の「他に N 件あり」に使う）
printf '%s' "$(tb 2026-11-04 undated --top 1)" | python3 -c "
import json,sys
d=json.load(sys.stdin)
rm=[b for b in d['blocks'] if b['kind']=='red-money'][0]
assert rm['count']==2 and rm['shown']==1, rm
assert d['target_count']==8, d['target_count']
" && ok "★--top は本文だけ絞る＝count は全件返す（「他に N 件あり」の元）" || ng "★top が件数まで削っている"

printf '%s' "$U" | grep -qE '"priority"|"score"|"recommend"' \
  && ng "★ツールが優先度を決めている（判断はモードの仕事）" \
  || ok "★ツールは優先度を決めない＝台帳の印で並べるだけ"
printf '%s' "$U" | python3 -c "
import json,sys
d=json.load(sys.stdin); assert d['warnings']==[], d['warnings']
assert d['ledger']['rows']==3 and d['ledger']['red']==2, d['ledger']
" && ok "台帳の読み取り件数を返す（同じ C-NNN は新しい行を正とする＝C-002 は🔴のまま）" || ng "台帳の集計が違う"

# ★台帳が無い環境★ git 外なので存在しないことがある。並べ替えができないだけで、行は隠さない。
mv "$T/ledger.md" "$T/ledger.off"
printf '%s' "$(tb 2026-11-04 undated)" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['warnings'], '警告が出ていない'
assert d['target_count']==8, d['target_count']
assert d['accounted']==8, d['accounted']   # 1件も消えない（どの箱に入るかは別問題）
assert d['ledger']=={'rows':0,'red':0}, d['ledger']
# 印で絞れない2つの箱（タグなし／台帳で見つからない）に全件が落ちる＝🔴 の並べ替えだけが失われる
blind=sum(b['count'] for b in d['blocks'] if b['kind'] in ('untagged','tag-not-in-ledger'))
assert blind==8, blind
" && ok "★台帳が読めなくても行は全件返す＋警告を立てる（隠すと見落としが見えない）" \
  || ng "★台帳が無いと行が消える／警告が出ない"
mv "$T/ledger.off" "$T/ledger.md"

# ルール側との連鎖（マネジメントが実際に呼ぶ形で書かれているか）
# ★ルール側との連鎖★「見ろ」だけでは動かない＝一覧の<u>作り方</u>が名指しされていること
#   （undated でも、手作業の逃げ道＝hana-api.sh todos で全件を引く形でもよい）。
#   ⚠️ 条件そのもの（項目5）はマネジメント窓口のルールに入る予定のもので、2026-11-03 時点では
#      まだコミットされていない。**他の窓口の未コミットのファイルに依存して赤にしない**
#      （この検査でコミットを止めない＝判断は人間・check-onboarding-sync.py と同じ扱い）。
MG_FILE="$PROJ/${MG_RULE:-rules/modes/management.md}"
if grep -qE '作業日が空か過去' "$MG_FILE"; then
  grep -qE 'todo-brief\.py undated|hana-api\.sh todos' "$MG_FILE" \
    && ok "★ルールに一覧の作り方が名指しされている（undated か全件取得）" \
    || ng "★条件はあるのに作り方が書かれていない＝毎朝この一覧が作られない"
else
  echo "  ⚠️ マネジメントのルールにまだ項目5（期限が空の ToDo も見る）が入っていません"
  echo "     ＝連鎖の検査は保留。入ったらこの検査が自動で効きます"
fi

# ★🔴 と 💰 は同じ行に付いていること（2026-11-03 Codex 指摘）★
# 1件の ToDo に複数の C-NNN が付く。別々の行の 🔴 と 💰 を足して「お金が動く用件」と言わない。
cat > "$T/ledger.md" <<'LG2'
## 🔴 未解決
C-021 | 🔴 | 💬 架空商事 | 経緯（お金の印なし） | 残＝**①回答する** |
C-022 | 🟢 | 📧 架空印刷 | 💰**入金の確認** | 残＝**無し** |
LG2
python3 - "$T" <<'PY'
import json, os, sys
d=sys.argv[1]
rows=[{"id":21,"assignee_user_id":None,"due_date":None,"updated_at":"2026-10-20",
       "content":"2つのタグが付いた行 [C-021] [C-022]"}]
json.dump(rows, open(os.path.join(d,"all.json"),"w",encoding="utf-8"), ensure_ascii=False)
json.dump(rows, open(os.path.join(d,"open.json"),"w",encoding="utf-8"), ensure_ascii=False)
PY
printf '%s' "$(tb 2026-11-04 undated)" | python3 -c "
import json,sys
d=json.load(sys.stdin)
got={b['kind']:[r['id'] for r in b['items']] for b in d['blocks'] if b['count']}
assert got=={'red':[21]}, got
" && ok "★🔴 と 💰 が別の行なら red-money に入れない（見出しと実態を食い違わせない）" \
  || ng "★別々の行の 🔴 と 💰 を足して『お金が動く用件』と言っている" "$(tb 2026-11-04 undated | head -40)"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
