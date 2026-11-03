#!/usr/bin/env bash
# comms-rotate.py（整理台帳の退避を機械で行う）の回帰テスト。
#
# rules/testing.md §2 の必須3条件すべてに該当する：
#   ①有人から呼ばれるが**共有ファイルへ書く** ②状態（台帳・archive）を書き換える ③判定を持つ
#
# ★このツールで一番怖いのは「移してはいけない行を移すこと」★
#   移動は原文無改変なので失われはしないが、生きている用件が台帳から消えると
#   **誰も追えなくなる**（＝整理のために追跡を壊す）。だからテストの主眼は
#   「残すべき行が残るか」に置く。削減量より先にそれを固定する。
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJ/bin/comms-rotate.py"
[ -f "$SRC" ] || { echo "❌ comms-rotate.py が無い: $SRC" >&2; exit 2; }
P=0; N=0
ok() { P=$((P+1)); echo "  ✅ $1"; }
ng() { N=$((N+1)); echo "  ❌ $1"; [ $# -ge 2 ] && echo "      → $2"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- 本体を、ファイルの置き場と ToDo の取得元だけ差し替えて持ち込む（ロジックは書き写さない）---
python3 - "$SRC" "$T" <<'PY'
import sys, json, os, io
src = io.open(sys.argv[1], encoding="utf-8").read()
d = sys.argv[2]
for name, fn in (("LEDGER","ledger.md"), ("ARCHIVE","archive.md"), ("LOCK",".rotate.lock"),
                 ("TICK_LOCK",".tick.lock")):
    old = [l for l in src.split("\n") if l.startswith(name + " = os.path.join")][0]
    src = src.replace(old, "%s = %s" % (name, json.dumps(os.path.join(d, fn))))
src = src.replace('BRIEF = os.path.join(ROOT, "bin", "todo-brief.py")',
                  'BRIEF = os.environ["FAKE_BRIEF"]')
io.open(os.path.join(d, "cr.py"), "w", encoding="utf-8").write(src)
PY
grep -q 'LEDGER = "' "$T/cr.py"  || { echo "❌ 差し替え失敗（台帳）＝本物の台帳を書き換えるテストになる" >&2; exit 2; }
grep -q 'ARCHIVE = "' "$T/cr.py" || { echo "❌ 差し替え失敗（archive）" >&2; exit 2; }
grep -q 'LOCK = "' "$T/cr.py"    || { echo "❌ 差し替え失敗（施錠）" >&2; exit 2; }
grep -q 'TICK_LOCK = "' "$T/cr.py" || { echo "❌ 差し替え失敗（無人サイクルの錠）＝本番の錠を掴むテストになる" >&2; exit 2; }

# --- ToDo の取得は**本物の todo-brief.py**に通す（API だけ偽物）---
#   偽の取得関数に差し替えると、JST 補正や「0件は取得失敗」の柵を通らないテストになる。
python3 - "$PROJ/bin/todo-brief.py" "$T" <<'PY'
import sys, json, os, io
src = io.open(sys.argv[1], encoding="utf-8").read()
d = sys.argv[2]
src = src.replace('STATE = os.path.join(ROOT, "data", "todo-manager", "state.json")',
                  'STATE = %s' % json.dumps(os.path.join(d, "state.json")))
src = src.replace('API = os.path.join(ROOT, "bin", "hana-api.sh")',
                  'API = %s' % json.dumps(os.path.join(d, "api.sh")))
src = src.replace('os.path.join(ROOT, "config", "comms-members.json")',
                  '%r' % os.path.join(d, "members.json"))
io.open(os.path.join(d, "tb.py"), "w", encoding="utf-8").write(src)
PY
echo '{"hana_user_ids": {"president": 34, "staff": 37}}' > "$T/members.json"
# ★本物と同じ意地悪さを再現する★ hana-api.sh は担当を指定しないと .env の既定ユーザー（34）を
#   自動で入れる＝**担当を渡さないと社長ぶんしか返らない**。偽物が親切に全件を返すと、
#   「全担当ぶんを取れているか」をテストで踏めない（2026-11-03 Codex 指摘の欠陥がまさにこれ）。
cat > "$T/api.sh" <<'FAKE'
#!/bin/bash
U=""
for a in "$@"; do case "$a" in --assignee_user_id=*) U="${a#*=}";; esac; done
[ -z "$U" ] && U=34
python3 -c "
import json,sys
u=int(sys.argv[1]); a=json.load(open(sys.argv[2]))
def owns(x):
    v=x.get('assignee_user_id')
    return v==u or (v is None and u==34)
print(json.dumps({'success':True,'data':[x for x in a if owns(x)]}))" "$U" "$FAKE_TODOS"
FAKE
chmod +x "$T/api.sh"
export FAKE_BRIEF="$T/tb.py" FAKE_TODOS="$T/todos.json"
cr() { COMMS_ROTATE_TODAY="$1" python3 "$T/cr.py" "${@:2}" 2>&1; }
jq_() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

# 架空のデータだけを使う（実在の取引先名・実名は書かない＝rules/modes/comms.md の規律）
mk_ledger() { cat > "$T/ledger.md" <<'LG'
# Chatwork・メール 整理台帳（テスト用の架空データ）

## 器の規律

## 🔴 自分ボール
C-001 | 🔴 | 💬 架空商事 | 経緯A | 残＝**①回答する** | 担当: 社長 | 最終: 10/20 |  
C-002 | 🔴 | 💬 架空工業 | 経緯B | 残＝**①まだ作業中** | 担当: 社長 | 最終: 10/20 |
C-003 | 🔴 | 💬 架空印刷 | 経緯C | 残＝**①ToDoが無い行** | 担当: 社長 | 最終: 10/20 |
C-004 | 🔴 | 💬 架空建設 | 経緯D | 残＝**①完了後に先方から新しい問い** | 担当: 社長 | 最終: 10/25 |

## 👥 社内ボール
C-005 | 👥 | 💬 架空設計 | 経緯E | 残＝**①社内** | 担当: 社長 | 最終: 10/20 |

## 🟢 相手ボール
C-006 | 🟢 | 💬 架空運輸 | 経緯F | 残＝**無し** | 担当: 社長 | 最終: 10/20 |

## 📌 確定記録
C-007 | 📌 | 💬 架空食品 | 見積 ¥100,000 | 残＝**無し** | 担当: 社長 | 最終: 10/20 |

## メモ（判定の訂正履歴）

> ※**10/30 の蒸留**＝新しいメモ1
> ※**10/29 の蒸留**＝新しいメモ2
> ※**10/28 の蒸留**＝古いメモ1
> ※**10/27 の蒸留**＝古いメモ2
LG
}
mk_todos() { cat > "$T/todos.json" <<'TD'
[{"id":1,"assignee_user_id":null,"content":"全部完了 [C-001]","completed_at":"2026-10-21T10:00:00.000000Z"},
 {"id":2,"assignee_user_id":null,"content":"未完了あり [C-002]","completed_at":null},
 {"id":3,"assignee_user_id":null,"content":"完了 [C-004]","completed_at":"2026-10-21T10:00:00.000000Z"},
 {"id":4,"assignee_user_id":null,"content":"社内ぶんも完了 [C-005]","completed_at":"2026-10-21T10:00:00.000000Z"},
 {"id":5,"assignee_user_id":null,"content":"相手ボールも完了 [C-006]","completed_at":"2026-10-21T10:00:00.000000Z"},
 {"id":6,"assignee_user_id":null,"content":"確定記録も完了 [C-007]","completed_at":"2026-10-21T10:00:00.000000Z"}]
TD
}
mk_archive() { printf '# Chatwork 整理 archive（テスト用）\n\n> 退避先。\n' > "$T/archive.md"; }
reset() { mk_ledger; mk_todos; mk_archive; }

echo "=== 偽物自体の検査（ここが嘘だと以降すべてが嘘になる）==="
reset
[ "$(FAKE_TODOS="$T/todos.json" bash "$T/api.sh" todos | jq_ "len(d['data'])")" = 6 ] \
  && ok "偽 API が ToDo を6件返す" || ng "偽 API が壊れている"
grep -q 'C-001' "$T/ledger.md" && ok "偽の台帳が置けている" || ng "偽の台帳が無い"

echo
echo "=== ★残すべき行が残る（移動の誤りは追跡を壊す）==="
r=$(cr 2026-11-03 plan)
echo "$r" | jq_ "[x['tag'] for x in d['red']['items']]==['C-001']" | grep -q True \
  && ok "★候補は「ToDo が全完了・完了後に動いていない」1件だけ" || ng "候補の選び方が違う" "$r"
echo "$r" | jq_ "{x['kind']:x['count'] for x in d['kept_back']}=={'no-todo':1,'todo-open':1,'completed-unreadable':0,'last-unreadable':0,'touched-after':1}" | grep -q True \
  && ok "★残した理由を件数で返す（未完了・ToDoなし・完了後に動いた が各1件）" || ng "残した理由の数が違う" "$r"
echo "$r" | jq_ "'C-004' not in json.dumps(d)" | grep -q True \
  && ok "★ToDo 完了後に行が動いている件は候補にしない（先方の新しい問いが積まれている形）" \
  || ng "★完了＝閉じてよいと推測している（マネジメントのご指摘そのもの）" "$r"
echo "$r" | jq_ "'C-005' not in json.dumps(d) and 'C-006' not in json.dumps(d) and 'C-007' not in json.dumps(d)" | grep -q True \
  && ok "★👥・🟢・📌 は ToDo が完了していても触らない（退避の条件に判断が入る＝人の仕事）" \
  || ng "★判断が要る行まで機械で動かしている" "$r"

echo
echo "=== 蒸留メモ（新しい分を残す）==="
echo "$r" | jq_ "d['memo']['count']==0" | grep -q True \
  && ok "既定（新しい10本を残す）では4本しかないので動かさない" || ng "メモの件数が違う" "$r"
r2=$(cr 2026-11-03 plan --keep-memo 2)
echo "$r2" | jq_ "d['memo']['count']==2" | grep -q True \
  && ok "--keep-memo 2 なら古い2本が候補になる" || ng "keep-memo が効かない" "$r2"
cr 2026-11-03 plan --keep-memo 0 | grep -q "1以上" \
  && ok "★--keep-memo 0 は拒む（直近の訂正履歴が消えると次のサイクルが前回の判断を読めない）" \
  || ng "★0 を受け入れている"

echo
echo "=== plan は1バイトも書き換えない ==="
b1=$(md5sum < "$T/ledger.md"); a1=$(md5sum < "$T/archive.md")
cr 2026-11-03 plan >/dev/null; cr 2026-11-03 plan --keep-memo 2 >/dev/null
[ "$b1" = "$(md5sum < "$T/ledger.md")" ] && [ "$a1" = "$(md5sum < "$T/archive.md")" ] \
  && ok "★plan は読むだけ（台帳も archive も変わらない）" || ng "★plan が書き換えている"

echo
echo "=== ★固有名詞を画面に出さない（rules/modes/comms.md の出力規律）==="
cr 2026-11-03 plan --keep-memo 2 | grep -qE "架空商事|架空工業|架空印刷|経緯A|蒸留" \
  && ng "★画面に用件の中身が出ている（C-NNN と数字だけにする）" \
  || ok "★出すのは C-NNN・日付・バイト数だけ（中身は出さない）"

echo
echo "=== apply＝①archive へ追記 →②確認 →③本体から削除 ==="
reset
grep '^C-001 ' "$T/ledger.md" | head -1 | tr -d '\n' > "$T/before-c001.txt"
out=$(cr 2026-11-03 apply --keep-memo 2)
echo "$out" | jq_ "d['applied']['red_moved']==1 and d['applied']['memo_moved']==2" | grep -q True \
  && ok "1件＋メモ2行を動かしたと報告する" || ng "適用の報告が違う" "$out"
grep -q '^C-001 | 🔴' "$T/archive.md" && ok "★archive に原文が入っている" || ng "★archive に入っていない"
grep -q '^C-001 | 🔴' "$T/ledger.md" && ng "★本体から消えていない（二重存在のまま）" || ok "★本体から消えている"
grep -q '^C-002 | 🔴' "$T/ledger.md" && ok "★残すべき行は本体にある" || ng "★残すべき行まで消えた"
# ★期待値を手で書かない★ 適用前の台帳から当該行を取っておき、**バイト一致**で突き合わせる
#   （手書きの期待値では、末尾の空白を落とすような「見えない改変」を見逃す）。
if python3 - "$T" "$T/before-c001.txt" <<'PY'
import sys, io, os
d, keep = sys.argv[1], sys.argv[2]
want = io.open(keep, encoding="utf-8").read()
arc = io.open(os.path.join(d, "archive.md"), encoding="utf-8").read()
assert want and want in arc, "原文が改変されている（末尾の空白などが落ちていないか）"
PY
then ok "★原文無改変（末尾の空白まで含めてバイト一致で移している）"; else ng "★原文が変わっている（加工して移している）"; fi
grep -c '※' "$T/ledger.md" | grep -q '^2$' && ok "台帳に新しいメモ2本が残る" || ng "メモの残り本数が違う" "$(grep -c '※' "$T/ledger.md")"
grep -c '※' "$T/archive.md" | grep -q '^2$' && ok "archive に古いメモ2本が入る" || ng "archive のメモ本数が違う"

echo
echo "=== ★冪等（何度流しても同じ）==="
out2=$(cr 2026-11-03 apply --keep-memo 2)
echo "$out2" | grep -q "動かすものがありません" && ok "2回目は動かすものが無いと言う" || ng "2回目の報告が違う" "$out2"
[ "$(grep -c '^C-001 | 🔴' "$T/archive.md")" = 1 ] && ok "★archive に同じ行が2度入らない" || ng "★二重に入っている"

echo
echo "=== ★archive に書けないときは本体を触らない（欠損させない）==="
reset
chmod 444 "$T/archive.md"
e=$(cr 2026-11-03 apply --keep-memo 2); rc=$?
chmod 644 "$T/archive.md"
[ "$rc" -ne 0 ] && ok "archive に書けなければ異常終了する" || ng "成功扱いになっている" "$e"
grep -q '^C-001 | 🔴' "$T/ledger.md" && ok "★本体はそのまま（移す前に消さない＝順序が守られている）" \
  || ng "★archive に入っていないのに本体から消えた＝欠損"

echo
echo "=== ★読んだあとに台帳が変わったら中止する（comms サイクルとの競合）==="
reset
# 取得のついでに台帳へ追記する偽 brief を使う＝「読んだ後に変わった」を機械で起こす
cat > "$T/tb-racy.py" <<'RACY'
import os, sys, io, importlib.util, datetime
spec = importlib.util.spec_from_file_location("real", os.environ["REAL_BRIEF"])
real = importlib.util.module_from_spec(spec); spec.loader.exec_module(real)
today = real.today
_date = real._date
def fetch_all_todos(status=None):
    # 取得のついでに台帳へ1行足す＝「読んだ後に他のサイクルが書いた」を機械で起こす
    with io.open(os.environ["RACE_LEDGER"], "a", encoding="utf-8") as f:
        f.write("C-999 | 🔴 | 💬 架空商会 | 別のサイクルが足した行 | 最終: 11/03 |\n")
    return real.fetch_all_todos(status=status)
RACY
e=$(REAL_BRIEF="$T/tb.py" RACE_LEDGER="$T/ledger.md" FAKE_BRIEF="$T/tb-racy.py" \
    COMMS_ROTATE_TODAY=2026-11-03 python3 "$T/cr.py" apply --keep-memo 2 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "$e" | grep -q "読み込み後に変わりました" \
  && ok "★読み込み後に台帳が変わっていたら中止する（楽観ロック）" || ng "★競合を検出していない" "$e"
grep -q '^C-001 | 🔴' "$T/ledger.md" \
  && ok "★中止したときは本体を削らない（archive は二重存在で済む＝欠損しない）" \
  || ng "★競合しているのに本体を書き換えた"
grep -q '^C-999' "$T/ledger.md" && ok "別サイクルが足した行は残っている（上書きで消していない）" || ng "他の書き込みを消した"

echo
echo "=== 多重起動を防ぐ ==="
reset
e=$(flock "$T/.rotate.lock" -c "COMMS_ROTATE_TODAY=2026-11-03 python3 '$T/cr.py' plan" 2>&1)
echo "$e" | grep -q "もう1つ" && ok "★施錠中は流さない（2つ流すと同じ行を2度 archive へ入れる）" \
  || ng "★施錠が効いていない" "$(printf '%s' "$e" | head -3)"

echo
echo "=== 年をまたぐ日付の読み（最終: MM/DD に年が無い）==="
python3 - "$T" <<'PY'
import sys, os, importlib.util, datetime
spec = importlib.util.spec_from_file_location("cr", os.path.join(sys.argv[1], "cr.py"))
cr = importlib.util.module_from_spec(spec); spec.loader.exec_module(cr)
ref = datetime.date(2026, 1, 5)
assert cr.last_touched("… | 最終: 12/28 |", ref) == datetime.date(2025, 12, 28), "前年として読めていない"
assert cr.last_touched("… | 最終: 01/04 |", ref) == datetime.date(2026, 1, 4)
assert cr.last_touched("… | 最終: なし |", ref) is None
assert cr.last_touched("… | 最終: 02/30 |", ref) is None   # 暦に無い日
PY
[ $? -eq 0 ] && ok "★年の無い日付を直近1年として読む（12/28 を翌年と読んで見落とさない）" \
  || ng "★年の補完が違う"

echo
echo "=== ★2026-11-03 Codex 指摘ぶん ==="
# 🔴1 全担当ぶんを見ているか＝別の担当に未完了が残っている行を移さない
reset
python3 - "$T" <<'TD2'
import json, os, sys
d=sys.argv[1]
a=json.load(open(os.path.join(d,"todos.json"),encoding="utf-8"))
# C-001：社長ぶんは完了（既存）。**別の担当（37）ぶんが未完了**で残っている
a.append({"id":7,"assignee_user_id":37,"content":"別の担当ぶんが未完了 [C-001]","completed_at":None})
json.dump(a, open(os.path.join(d,"todos.json"),"w",encoding="utf-8"), ensure_ascii=False)
TD2
r=$(cr 2026-11-03 plan)
echo "$r" | jq_ "d['red']['count']==0 and {x['kind']:x['count'] for x in d['kept_back']}['todo-open']==2 and 'C-001' not in json.dumps(d)" | grep -q True \
  && ok "★別の担当に未完了の ToDo が残っている行は移さない（担当未指定だと社長ぶんしか返らない）" \
  || ng "★既定担当ぶんしか見ていない＝生きている行を『全部完了』と誤判定する" "$r"

# 🔴2 完了日が一部でも読めなければ残す
reset
python3 - "$T" <<'TD3'
import json, os, sys
d=sys.argv[1]
a=json.load(open(os.path.join(d,"todos.json"),encoding="utf-8"))
a.append({"id":8,"assignee_user_id":None,"content":"完了日が壊れている [C-001]","completed_at":"いつか"})
json.dump(a, open(os.path.join(d,"todos.json"),"w",encoding="utf-8"), ensure_ascii=False)
TD3
r=$(cr 2026-11-03 plan)
echo "$r" | jq_ "d['red']['count']==0 and {x['kind']:x['count'] for x in d['kept_back']}['completed-unreadable']==1" | grep -q True \
  && ok "★完了日が1件でも読めなければ残す（読めた分だけで『完了後に動いていない』を言わない）" \
  || ng "★一部が読めなくても退避している" "$r"

# 🔴4 中止したあとの再実行で、archive に同じ行が2度入らない
reset
e=$(REAL_BRIEF="$T/tb.py" RACE_LEDGER="$T/ledger.md" FAKE_BRIEF="$T/tb-racy.py" \
    COMMS_ROTATE_TODAY=2026-11-03 python3 "$T/cr.py" apply --keep-memo 2 2>&1)
out=$(cr 2026-11-03 apply --keep-memo 2)
[ "$(grep -c '^C-001 | 🔴' "$T/archive.md")" = 1 ] \
  && ok "★中止 → 再実行でも archive に同じ行が2度入らない（追記済みの行は足さない）" \
  || ng "★二重に追記している" "$(grep -c '^C-001 | 🔴' "$T/archive.md") 回"
echo "$out" | jq_ "d['applied']['already_in_archive']>=1" | grep -q True \
  && ok "すでに archive にあった件数を報告する（何が再開ぶんか分かる）" || ng "再開ぶんの報告が無い" "$out"
grep -q '^C-001 | 🔴' "$T/ledger.md" && ng "★再実行でも本体から消えていない" || ok "★再実行で本体から消える（宿題が残らない）"

# 🟡3 archive の見出しに「実際に残した本数」が書かれる
grep -q '新しい2本を台帳に残した残り' "$T/archive.md" \
  && ok "★見出しに実際の --keep-memo（2本）が記録される（定数の10本と書かない）" \
  || ng "★見出しの本数が実行時の指定と食い違う" "$(grep -o '新しい[0-9]*本[^）]*' "$T/archive.md" | head -2)"

# 🔴3 無人サイクルが動いている間は apply しない（plan は読むだけなのでできる）
reset
e=$(flock "$T/.tick.lock" -c "COMMS_ROTATE_TODAY=2026-11-03 python3 '$T/cr.py' apply" 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "$e" | grep -q "無人サイクル" \
  && ok "★無人サイクルの錠が握られている間は apply しない（書き手と同じ錠を取る）" \
  || ng "★無人サイクルと同時に書き換えようとしている" "$(printf '%s' "$e" | head -2)"
grep -q '^C-001 | 🔴' "$T/ledger.md" && ok "★錠が取れないときは台帳を1バイトも触らない" || ng "★触っている"
e=$(flock "$T/.tick.lock" -c "COMMS_ROTATE_TODAY=2026-11-03 python3 '$T/cr.py' plan" 2>&1)
echo "$e" | jq_ "d['mode']=='plan'" 2>/dev/null | grep -q True \
  && ok "plan は錠を取らない＝サイクル中でも現況は見られる" || ng "plan が錠で止まっている" "$(printf '%s' "$e" | head -2)"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
