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
run() { ( cd "$TMP" && env "$@" bash bin/mailbox.sh "${RUNARGS[@]}" 2>&1 ); }
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
