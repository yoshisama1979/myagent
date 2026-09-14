#!/usr/bin/env bash
# test-mailbox-local.sh ── mailbox.sh の local-inbox / local-done の回帰テスト
#
# なぜ要るか（rules/testing.md §2：状態を書き込むツールは回帰テスト必須）：
#   local-done は new/ → cur/ へファイルを動かす＝取り返しのつく操作だが、
#   「他人宛を消費してしまう」と、その相手の起動理由を横から消すことになる（無言の取りこぼし）。
#   身元判定と宛先照合が本体。
#
# スプールは本番を汚さないよう、一時ディレクトリに repo を模した構造を作って検証する。
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/data/mailbox/new" "$TMP/data/mailbox/cur" "$TMP/bin"
cp "$PROJ/bin/mailbox.sh" "$TMP/bin/mailbox.sh"
[ -f "$PROJ/bin/session-desk.py" ] && cp "$PROJ/bin/session-desk.py" "$TMP/bin/session-desk.py"
# .env は読ませない（HTTP 系の必須キー検査に引っかからないよう local-* だけを叩く）
: > "$TMP/.env"
printf 'MAILBOX_URL=http://127.0.0.1/none/\nMAILBOX_TOKEN=dummy\n' > "$TMP/.env"

mkmsg() { # mkmsg <id> <to> [from]
  cat > "$TMP/data/mailbox/new/$1.json" <<JSON
{ "id": "$1", "thread": "", "from": "${3:-web-hanasaka}", "to": "$2",
  "type": "report", "needs_approval": false, "ts": "2026-09-01T00:00:00+09:00",
  "subject": "テスト件名", "body": "テスト本文" }
JSON
}
# CLAUDE_CODE_SESSION_ID は本物のセッションから漏れ込むので必ず外す（テストで明示したときだけ効かせる）。
# stdin は /dev/null＝local-send が本文待ちで止まらないように。
run() { ( cd "$TMP" && env -u CLAUDE_CODE_SESSION_ID SESSION_DESK_SESSIONS="$TMP/sessions" "$@" bash bin/mailbox.sh "${RUNARGS[@]}" 2>&1 </dev/null ); }
cnt() { python3 -c 'import sys,json; print(json.load(sys.stdin)["count"])' 2>/dev/null; }

echo "── §1 local-inbox：自分宛だけを見る"
mkmsg M-20260901T000001-web-hanasaka-aaa hp-loop-ycom
mkmsg M-20260901T000002-web-hanasaka-bbb hp-loop-ycom
mkmsg M-20260901T000003-shigatoyota-dev-ccc hp-loop-shigatoyota shigatoyota-dev
mkmsg M-20260901T000004-hp-loop-ycom-ddd web-hanasaka hp-loop-ycom
RUNARGS=(local-inbox)
n="$(run MYAGENT_AGENT=hp-loop-ycom | cnt)"
[ "$n" = "2" ] && ok "自分宛2件だけを返す（他レーン宛・自分が送った分は数えない）" || ng "自分宛の件数が 2 でなく $n"
n="$(run MYAGENT_AGENT=hp-loop-shigatoyota | cnt)"
[ "$n" = "1" ] && ok "別レーンは別レーンの1件だけを見る" || ng "shigatoyota が 1 でなく $n"
n="$(run MYAGENT_AGENT=hp-loop-rally | cnt)"
[ "$n" = "0" ] && ok "宛先が無いレーンは 0 件（空で正常終了）" || ng "rally が 0 でなく $n"
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '"inbox_of": "hp-loop-ycom"' \
  && ok "inbox_of に自分の名が入る（HTTP 版の総称名と取り違えない）" || ng "inbox_of が自分の名でない"
printf '%s' "$out" | grep -q '"source": "spool"' \
  && ok "スプール直読みであることが出力から分かる" || ng "source が spool でない"

echo "── §2 身元：無人では他人を名乗れない"
RUNARGS=(local-inbox --as hp-loop-shigatoyota)
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '無人実行では --as は自分' \
  && ok "MYAGENT_AGENT と違う --as を拒否する" || ng "他人の名を名乗れてしまう"
RUNARGS=(local-inbox --as hp-loop-ycom)
n="$(run MYAGENT_AGENT=hp-loop-ycom | cnt)"
[ "$n" = "2" ] && ok "--as が自分と同じなら通る" || ng "自分と同じ --as が通らない"
n="$(run MYAGENT_X=1 | cnt)"
[ "$n" = "2" ] && ok "有人（MYAGENT_AGENT 無し）は --as で名乗れる" || ng "有人の --as が効かない"
RUNARGS=(local-inbox)
out="$(run MYAGENT_X=1)"
printf '%s' "$out" | grep -q '名乗る相手が決まりません' \
  && ok "身元が決まらなければ黙って0件にせずエラーにする" || ng "身元不明でも動いてしまう"
RUNARGS=(local-inbox --as "../etc")
out="$(run MYAGENT_X=1)"
printf '%s' "$out" | grep -q '英数字' && ok "識別子以外の文字を弾く（パストラバーサル対策）" || ng "不正な名を受け付ける"

echo "── §3 取りこぼしを黙らない"
printf 'これは JSON ではない' > "$TMP/data/mailbox/new/M-20260901T000009-broken-zzz.json"
RUNARGS=(local-inbox)
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '"unreadable": 1' \
  && ok "読めなかったメッセージを件数として申告する" || ng "壊れたメッセージを黙って捨てている"
[ "$(printf '%s' "$out" | cnt)" = "2" ] && ok "壊れた1件があっても正常な2件は返る" || ng "壊れた1件で全体が壊れる"
rm -f "$TMP/data/mailbox/new/M-20260901T000009-broken-zzz.json"

echo "── §4 local-done：自分宛だけを消費する"
RUNARGS=(local-done M-20260901T000003-shigatoyota-dev-ccc)
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '自分(hp-loop-ycom)宛ではありません' \
  && ok "他人宛を消費しない（相手の起動理由を横から消さない）" || ng "他人宛を消費できてしまう"
[ -f "$TMP/data/mailbox/new/M-20260901T000003-shigatoyota-dev-ccc.json" ] \
  && ok "拒否したときファイルは動いていない" || ng "拒否したのにファイルが動いた"
RUNARGS=(local-done M-20260901T000001-web-hanasaka-aaa)
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '"ok": true' && ok "自分宛は cur/ へ移せる" || ng "自分宛を移せない"
[ -f "$TMP/data/mailbox/cur/M-20260901T000001-web-hanasaka-aaa.json" ] \
  && ok "cur/ に実在する" || ng "cur/ に無い"
[ ! -f "$TMP/data/mailbox/new/M-20260901T000001-web-hanasaka-aaa.json" ] \
  && ok "new/ から消えている（＝次の tick で再起動の理由にならない）" || ng "new/ に残っている"
grep -q 'テスト本文' "$TMP/data/mailbox/cur/M-20260901T000001-web-hanasaka-aaa.json" \
  && ok "本文を書き換えていない（履歴を消さない）" || ng "本文が変わった"
RUNARGS=(local-inbox)
n="$(run MYAGENT_AGENT=hp-loop-ycom | cnt)"
[ "$n" = "1" ] && ok "消費後は受信箱が1件減る" || ng "消費後の件数が 1 でなく $n"

echo "── §5 local-done の異常系"
RUNARGS=(local-done M-20260901T000001-web-hanasaka-aaa)
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q 'new/ に見つかりません' \
  && ok "二度目の消費はエラーにする（冪等に見せて黙らない）" || ng "存在しない id を黙って成功にする"
RUNARGS=(local-done "../../../etc/passwd")
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '不正な id' && ok "パストラバーサルの id を弾く" || ng "不正な id を受け付ける"
RUNARGS=(local-done "M-;rm -rf /")
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '不正な id' && ok "記号入りの id を弾く" || ng "記号入りの id を受け付ける"
RUNARGS=(local-done)
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q 'id は必須' && ok "id 無しはエラー" || ng "id 無しが通る"

echo "── §5b 引数の並び（help の書式どおりに打てること）"
mkmsg M-20260901T000021-web-hanasaka-eee hp-loop-ycom
RUNARGS=(local-done M-20260901T000021-web-hanasaka-eee --as hp-loop-ycom)
out="$(run MYAGENT_X=1)"
printf '%s' "$out" | grep -q '"ok": true' \
  && ok "local-done <id> --as <agent>（help の書式＝--as が後ろ）が通る" || ng "help の書式で打つと通らない"
mkmsg M-20260901T000022-web-hanasaka-fff hp-loop-ycom
RUNARGS=(local-done --as hp-loop-ycom M-20260901T000022-web-hanasaka-fff)
out="$(run MYAGENT_X=1)"
printf '%s' "$out" | grep -q '"ok": true' && ok "--as が前でも通る" || ng "--as が前だと通らない"
RUNARGS=(local-done --bogus x)
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '不明なオプション' && ok "未知のオプションを黙って無視しない" || ng "未知のオプションが素通りする"
RUNARGS=(local-done aaa bbb)
out="$(run MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '引数が多すぎます' && ok "余分な引数を黙って捨てない" || ng "余分な引数が素通りする"

echo "── §7 窓口＝セッションID（2026-09-14 triage 依頼・Red 先行）"
mkdir -p "$TMP/config" "$TMP/sessions"
SID_T=aaaaaaaa-1111-4111-8111-111111111111
SID_N=dddddddd-4444-4444-8444-444444444444
cat > "$TMP/config/session-desks.json" <<JSON
{"desks": {"triage": {"label": "社長との窓口", "rule": "rules/modes/triage.md"},
           "board": {"label": "経営会議", "rule": "rules/modes/board.md"}},
 "sessions": {"$SID_T": "triage"}}
JSON
printf '{"type":"user","message":{"content":"hi"}}\n' > "$TMP/sessions/$SID_T.jsonl"
printf '{"type":"user","message":{"content":"read the full transcript at: /x/%s.jsonl"}}\n' "$SID_T" > "$TMP/sessions/$SID_N.jsonl"
touch -d "3 days ago" "$TMP/sessions/$SID_N.jsonl"   # 前身の検出に使う旧ID（いまは動いていない状態で置く）
mkmsg M-20260914T000001-overseer-t01 triage overseer
mkmsg M-20260914T000002-overseer-t02 triage overseer
RUNARGS=(local-inbox)
out="$(run CLAUDE_CODE_SESSION_ID=$SID_T)"
printf '%s' "$out" | grep -q '"inbox_of": "triage"' && [ "$(printf '%s' "$out" | cnt)" = "2" ] \
  && ok "--as 無しの有人セッションは、対応表で自分の宛名を名乗る" || ng "対応表で名乗れていない"
out="$(run CLAUDE_CODE_SESSION_ID=$SID_N)"
printf '%s' "$out" | grep -q '未登録' && printf '%s' "$out" | grep -q 'triage' && ! printf '%s' "$out" | grep -q '"ok": true' \
  && ok "未登録は黙って既定の宛名にせず「前身は triage」と出して止まる" || ng "未登録の扱いが違う"
RUNARGS=(local-inbox --as board)
out="$(run CLAUDE_CODE_SESSION_ID=$SID_T)"
printf '%s' "$out" | grep -q '対応表では triage' && ok "登録済みのセッションは --as で他の窓口を名乗れない（取り合いの再発防止）" || ng "他の窓口を名乗れてしまう"
RUNARGS=(local-inbox)
out="$(run CLAUDE_CODE_SESSION_ID=$SID_T MYAGENT_AGENT=hp-loop-ycom)"
printf '%s' "$out" | grep -q '"inbox_of": "hp-loop-ycom"' && ok "無人（MYAGENT_AGENT）の既存挙動は変えない" || ng "無人の身元が変わった"
RUNARGS=(local-done M-20260914T000001-overseer-t01)
out="$(run CLAUDE_CODE_SESSION_ID=$SID_T)"
printf '%s' "$out" | grep -q '"ok": true' && ok "local-done も対応表で名乗って自分宛を消費できる" || ng "local-done が対応表で名乗れない"
RUNARGS=(local-send --to board --subject 件名テスト 本文テスト)
run CLAUDE_CODE_SESSION_ID=$SID_T >/dev/null
f="$(ls -t "$TMP"/data/mailbox/new/M-*-triage-*.json 2>/dev/null | head -1)"
[ -n "$f" ] && grep -q '"from": "triage"' "$f" && ok "local-send も --from 無しなら対応表の宛名で出す" || ng "local-send が対応表で名乗れない"
RUNARGS=(local-send --from board --to triage --subject 件名 本文)
out="$(run CLAUDE_CODE_SESSION_ID=$SID_T)"
printf '%s' "$out" | grep -q '対応表では triage' && ok "登録済みは --from で他の窓口を騙れない" || ng "--from で騙れてしまう"
touch "$TMP/sessions/$SID_N.jsonl"      # 同じ窓口の続きが「いま動いている」状態にする
out="$( cd "$TMP" && env -u CLAUDE_CODE_SESSION_ID SESSION_DESK_SESSIONS="$TMP/sessions" CLAUDE_CODE_SESSION_ID=$SID_T bash bin/mailbox.sh local-inbox 2>"$TMP/sib.err" </dev/null )"
printf '%s' "$out" | cnt >/dev/null && grep -q '⚠️' "$TMP/sib.err" \
  && ok "同じ窓口の続きが並行して動いていたら ⚠️ を stderr に出す（stdout の JSON は壊さない）" || ng "取り合いの警告が出ない／JSON が壊れた"
touch -d "3 days ago" "$TMP/sessions/$SID_N.jsonl"

echo "── §8 local-send が未知の -- フラグを本文に飲み込まない（O-081・空便14通の実績）"
before="$(ls "$TMP"/data/mailbox/new | wc -l)"
RUNARGS=(local-send --from overseer --to triage --subject 件名 --body-file data/x.txt)
out="$(run MYAGENT_X=1)"
printf '%s' "$out" | grep -q '不明なオプション' && printf '%s' "$out" | grep -q '標準入力' \
  && ok "--body-file 等の未知フラグは弾き、本文は標準入力で渡すよう案内する" || ng "未知フラグが本文に入る"
[ "$(ls "$TMP"/data/mailbox/new | wc -l)" = "$before" ] && ok "弾いたときは1通も投函しない（空便を作らない）" || ng "弾いたのに投函された"
RUNARGS=(local-send --from overseer --to triage --subject 件名 -- "--で始まる本文")
run MYAGENT_X=1 >/dev/null
f="$(ls -t "$TMP"/data/mailbox/new/M-*-overseer-*.json 2>/dev/null | head -1)"
[ -n "$f" ] && grep -q '"body": "--で始まる本文"' "$f" && ok "-- の後ろは -- で始まっていても本文として通す" || ng "-- 以降の本文が通らない"
( cd "$TMP" && printf '標準入力の本文' | env -u CLAUDE_CODE_SESSION_ID SESSION_DESK_SESSIONS="$TMP/sessions" MYAGENT_X=1 bash bin/mailbox.sh local-send --from overseer --to board --subject 標準入力 >/dev/null 2>&1 )
f="$(ls -t "$TMP"/data/mailbox/new/M-*-overseer-*.json 2>/dev/null | head -1)"
[ -n "$f" ] && grep -q '"body": "標準入力の本文"' "$f" && ok "本文は標準入力から渡せる（案内どおりの渡し方が動く）" || ng "標準入力の本文が入らない"
if python3 - "$PROJ/bin/mailbox.sh" <<'PYX'
import re,sys
s=open(sys.argv[1],encoding="utf-8").read()
for n in ("SENDERS","RECIPIENTS"):
    m=re.search(n+r"\s*=\s*\{(.*?)\}", s, re.S); ids=set(re.findall(r'"([A-Za-z0-9_-]+)"', m.group(1)))
    assert {"triage","board","management","dev"} <= ids, n
PYX
then ok "triage・board・management・dev を送信者・宛先の許可リストに持つ"; else ng "許可リストに窓口の宛名が無い"; fi

echo "── §6 許可リスト（bin/ と bash bin/ の両形が要る＝実害の前例あり）"
SET="$PROJ/.claude/settings.local.json"
for form in "Bash(bin/mailbox.sh local-inbox" "Bash(bash bin/mailbox.sh local-inbox" \
            "Bash(bin/mailbox.sh local-done" "Bash(bash bin/mailbox.sh local-done"; do
  grep -qF "$form" "$SET" && ok "許可リストに $form…がある" \
    || ng "許可リストに $form…が無い（無人ループで無言停止する）"
done

echo
echo "合計: 合格 ${PASS} ／ 不合格 ${FAIL}"
[ "$FAIL" -eq 0 ]
