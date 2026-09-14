#!/usr/bin/env bash
# test-session-desk.sh ── bin/session-desk.py の回帰テスト（Red 先行・2026-09-14 triage 依頼）
#
# なぜ要るか（rules/testing.md §2）：受信箱の「身元」を決める判定ロジックで、UserPromptSubmit フックから
# 社長の発言ごとに呼ばれる。固定する実害＝2026-09-13、triage とマネジメントが --as の自己申告で同じ
# hanasaka-main を読み、マネジメント宛の統括返信を triage が既読にした。
# 本番のセッションログ・対応表・受信箱は使わない（SESSION_DESK_* で一時ツリーへ向ける）。
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$PROJ/bin/session-desk.py"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
S="$TMP/sessions"; R="$TMP/root"; TAB="$TMP/session-desks.json"
mkdir -p "$S" "$R/data/mailbox/new" "$R/data/mailbox/cur"
TRI=aaaaaaaa-1111-4111-8111-111111111111
MGT=bbbbbbbb-2222-4222-8222-222222222222
KID=cccccccc-3333-4333-8333-333333333333   # MGT の続きとして生まれた（未登録）
GRK=dddddddd-4444-4444-8444-444444444444   # KID の続き（孫・未登録）
LONE=eeeeeeee-5555-4555-8555-555555555555  # 系譜なし・未登録
cat > "$TAB" <<JSON
{"desks": {"triage": {"label": "社長との窓口", "rule": "rules/modes/triage.md"},
           "management": {"label": "日々のタスク管理", "rule": "rules/modes/management.md"}},
 "sessions": {"$TRI": "triage", "$MGT": "management"}}
JSON
# mkses <id> [前身id] [何分前] … /compact の自己参照行も必ず入れる（系譜と取り違えないことを見る）
mkses() {
  local f="$S/$1.jsonl"
  { printf '{"type":"user","message":{"content":"こんにちは"}}\n'
    if [ -n "${2:-}" ]; then printf '{"type":"user","message":{"content":"read the full transcript at: /home/u/.claude/projects/p/%s.jsonl"}}\n' "$2"; fi
    printf '{"type":"user","message":{"content":"read the full transcript at: /home/u/.claude/projects/p/%s.jsonl"}}\n' "$1"
  } > "$f"
  touch -d "${3:-1} minutes ago" "$f"
}
mkses "$TRI"; mkses "$MGT"; mkses "$KID" "$MGT" 3000; mkses "$GRK" "$KID" 3000; mkses "$LONE"
r()  { env -u CLAUDE_CODE_SESSION_ID SESSION_DESK_TABLE="$TAB" SESSION_DESK_SESSIONS="$S" SESSION_DESK_ROOT="$R" python3 "$TOOL" "$@" 2>&1; }
rs() { local sid="$1"; shift; env CLAUDE_CODE_SESSION_ID="$sid" SESSION_DESK_TABLE="$TAB" SESSION_DESK_SESSIONS="$S" SESSION_DESK_ROOT="$R" python3 "$TOOL" "$@" 2>&1; }
jq1() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

echo "── §1 登録済みのセッションは表の宛名を名乗る"
[ "$(r resolve --session "$TRI" | jq1 'd["desk"]')" = "triage" ] && ok "セッションIDから宛名を引ける" || ng "宛名を引けない"
[ "$(r resolve --session "$TRI" | jq1 'd["rule"]')" = "rules/modes/triage.md" ] && ok "読むべきルールも表から返す（着火点を1箇所にする）" || ng "ルールを返さない"
[ "$(rs "$MGT" resolve | jq1 'd["desk"]')" = "management" ] && ok "--session 無しなら CLAUDE_CODE_SESSION_ID を使う" || ng "環境変数のIDを使っていない"
[ "$(r resolve --session "$TRI" | jq1 'd["predecessor"]')" = "None" ] && ok "/compact の自己参照を前身と取り違えない" || ng "自己参照を前身扱いした"

echo "── §2 未登録は黙って既定の宛名にしない"
out="$(r resolve --session "$KID")"
[ "$(printf '%s' "$out" | jq1 'd["registered"]')" = "False" ] && ok "表に無いIDは registered=false" || ng "未登録を登録済みと言った: $out"
[ "$(printf '%s' "$out" | jq1 'd["predecessor"]["desk"]')" = "management" ] && ok "前身の窓口（management）を示す" || ng "前身を示さない: $out"
[ "$(r resolve --session "$GRK" | jq1 'd["predecessor"]["desk"]')" = "management" ] && ok "孫の代でも登録済みの祖先までたどる" || ng "祖先までたどれない"
out="$(r whoami --session "$KID")"; rc=$?
[ "$rc" -ne 0 ] && ok "whoami は未登録なら非0で止まる" || ng "whoami が未登録でも 0"
printf '%s' "$out" | grep -q '未登録' && printf '%s' "$out" | grep -q 'management' && ok "「未登録です。前身は◯◯（宛名 △△）」と出す" || ng "未登録の案内が無い: $out"
[ "$(r resolve --session "$LONE" | jq1 'd["predecessor"]')" = "None" ] && ok "系譜の無い新規は前身なし" || ng "系譜の無いIDに前身を作った"

echo "── §3 1つの宛名に動いているIDが2つ付いたら警告"
touch -d "5 minutes ago" "$S/$KID.jsonl"
sib="$(r resolve --session "$MGT" | jq1 '",".join(d["siblings"])')"
printf '%s' "$sib" | grep -q "$KID" && ok "同じ窓口の続きが並行して動いていたら siblings に出す" || ng "siblings=$sib"
r whoami --session "$MGT" | grep -q '⚠️' && ok "whoami で警告する" || ng "whoami が警告しない"
touch -d "3 days ago" "$S/$KID.jsonl" "$S/$GRK.jsonl"
[ -z "$(r resolve --session "$MGT" | jq1 '",".join(d["siblings"])')" ] && ok "止まった旧ID（24時間以上動いていない）では警告しない" || ng "止まったIDで警告した"

echo "── §4 未読の知らせ（UserPromptSubmit フック）"
mkmail() { printf '{"id":"%s","to":"%s","from":"overseer","type":"report","ts":"2026-09-14T10:00:00+09:00","subject":"件名だよ","body":"本文だよ"}\n' "$1" "$2" > "$R/data/mailbox/new/$1.json"; }
mkmail M-1 management; mkmail M-2 management; mkmail M-3 triage
out="$(printf '{"session_id":"%s","prompt":"x"}' "$MGT" | r hook)"; rc=$?
[ "$rc" = "0" ] && ok "フックは exit 0" || ng "フックが非0: $rc"
[ "$(printf '%s\n' "$out" | grep -c .)" = "1" ] && printf '%s' "$out" | grep -q '未読 2通' && ok "登録済みには「あなた宛の未読 N通」を1行だけ出す" || ng "out=$out"
printf '%s' "$out" | grep -q '件名だよ\|本文だよ' && ng "件名・本文を会話に注入している" || ok "件名・本文は出さない（件数だけ）"
printf '{"session_id":"%s"}' "$TRI" | r hook | grep -q '未読 1通' && ok "宛名ごとに数える（他の窓口の便を数えない）" || ng "他の窓口の便まで数えた"
[ -z "$(printf '{"session_id":"%s"}' "$LONE" | r hook)" ] && ok "未登録のセッションには何も出さない" || ng "未登録に何か出した"
rm -f "$R"/data/mailbox/new/M-3.json
[ -z "$(printf '{"session_id":"%s"}' "$TRI" | r hook)" ] && ok "未読0なら何も出さない（鳴りっぱなしにしない）" || ng "未読0でも出した"
out="$(printf 'こわれた' | r hook)"; rc=$?
[ "$rc" = "0" ] && [ -z "$out" ] && ok "壊れた入力でも黙って exit 0（本作業を止めない）" || ng "rc=$rc out=$out"
out="$(printf '{"session_id":"%s"}' "$MGT" | env -u CLAUDE_CODE_SESSION_ID SESSION_DESK_TABLE="$TMP/none.json" SESSION_DESK_SESSIONS="$S" SESSION_DESK_ROOT="$R" python3 "$TOOL" hook 2>&1)"; rc=$?
[ "$rc" = "0" ] && [ -z "$out" ] && ok "対応表が無くてもフックは黙る" || ng "対応表不在でフックが喋った/落ちた: rc=$rc"

echo "── §5 異常系"
out="$(r resolve --session '../../etc/passwd')"; rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q Traceback && ok "セッションIDの形を検査する（パス混入を弾く）" || ng "不正なIDを通した: $out"
printf '{broken' > "$TMP/broken.json"
out="$(env -u CLAUDE_CODE_SESSION_ID SESSION_DESK_TABLE="$TMP/broken.json" SESSION_DESK_SESSIONS="$S" SESSION_DESK_ROOT="$R" python3 "$TOOL" resolve --session "$TRI" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '対応表' && ! printf '%s' "$out" | grep -q Traceback && ok "対応表が壊れていたら黙らず申告する" || ng "壊れた対応表の扱い: $out"

echo
echo "合計: 合格 ${PASS} ／ 不合格 ${FAIL}"
[ "$FAIL" -eq 0 ]
