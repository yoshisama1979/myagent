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
open(os.path.join(d, "tb.py"), "w", encoding="utf-8").write(src)
PY
grep -q 'STATE = "' "$T/tb.py" || { echo "❌ 差し替え失敗（状態ファイル）" >&2; exit 2; }
grep -q 'API = "'   "$T/tb.py" || { echo "❌ 差し替え失敗（API）" >&2; exit 2; }

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
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
