#!/usr/bin/env bash
# ルール通知の経路（投函専用ロール）の回帰テスト。
#
# 対象は2つ：
#   (1) site/tools/mailbox/index.php ── サーバ側の権限判定。**本番の mailbox API 本体**なので、
#       ここを触って既存の agent／admin の挙動が変わっていないことを毎回機械で示す
#       （解析↔開発のやり取り 7 経路が乗っている）。
#   (2) bin/rule-reporter.py ── 発行・失効・一覧。状態（トークン表）を書き、判定（番号採番・
#       重複拒否・失効）を持つ＝testing.md §2 の「テスト必須」に当たる。
#
# 守りたい不変条件：
#   - reporter は rule-kaizen 宛の send しかできない（inbox / done / 他宛先は 403）
#   - revoked / expires_at が効く＝ホワイトリストから取り消せる
#   - 未知ロールは reporter に倒れる（最小権限）
#   - agent / admin の既存挙動は変わっていない
#   - 台帳にトークン値が載らない（台帳を見せても漏れない）
#
# ⚠️ 本番の data/secrets/・data/mailbox/ には触れない：/tmp に偽プロジェクトを組み、
#    index.php の実物をコピーして php -S で動かす。トークンは架空の値だけを使う。
# 触ったら必ず流すこと：bash bin/test-rule-reporter.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/site/tools/mailbox/index.php" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }
command -v php >/dev/null || { echo "❌ php が見つかりません" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
SRV_PID=""
cleanup(){ [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$T/site/tools/mailbox" "$T/site/tools/lib" "$T/data/mailbox/new" "$T/data/mailbox/cur" "$T/data/mailbox/hold" "$T/data/secrets"
cp "$PROJ/site/tools/mailbox/index.php" "$T/site/tools/mailbox/index.php"
cp "$PROJ/site/tools/lib/token-auth.php" "$T/site/tools/lib/token-auth.php"   # 認証・失効・期限の正（共有）

TODAY="$(date +%F)"
PAST="$(date -d '-1 day' +%F)"
FUTURE="$(date -d '+30 day' +%F)"

# 架空トークンのみ（本番の値は読まない・使わない）
cat > "$T/data/secrets/mailbox-tokens.json" <<JSONEOF
{
  "tk-agent":    { "agent_id": "dev-x",       "role": "agent" },
  "tk-peer":     { "agent_id": "analysis-y",  "role": "agent" },
  "tk-admin":    { "agent_id": "boss",        "role": "admin" },
  "tk-sink":     { "agent_id": "rule-kaizen", "role": "reporter" },
  "tk-rep":      { "agent_id": "rr-proj",     "role": "reporter", "reporter_id": "RR-001", "expires_at": "$FUTURE" },
  "tk-rep-norev":{ "agent_id": "rr-proj2",    "role": "reporter", "reporter_id": "RR-002" },
  "tk-revoked":  { "agent_id": "rr-old",      "role": "reporter", "reporter_id": "RR-003", "revoked": true },
  "tk-expired":  { "agent_id": "rr-dead",     "role": "reporter", "reporter_id": "RR-004", "expires_at": "$PAST" },
  "tk-badexp":   { "agent_id": "rr-bad",      "role": "reporter", "expires_at": "ちょっと先" },
  "tk-exp-today":{ "agent_id": "rr-today",    "role": "reporter", "expires_at": "$TODAY" },
  "tk-weird":    { "agent_id": "rr-weird",    "role": "superuser" }
}
JSONEOF

# --- php -S を空きポートで起動 ---
PORT=0
for try in 1 2 3 4 5; do
  P_TRY=$(( 18000 + RANDOM % 2000 ))
  php -S "127.0.0.1:$P_TRY" -t "$T/site" >"$T/php.log" 2>&1 &
  SRV_PID=$!
  for i in $(seq 1 40); do
    if curl -s -o /dev/null "http://127.0.0.1:$P_TRY/tools/mailbox/index.php" 2>/dev/null; then PORT=$P_TRY; break; fi
    kill -0 "$SRV_PID" 2>/dev/null || break
    sleep 0.1
  done
  [ "$PORT" != 0 ] && break
  kill "$SRV_PID" 2>/dev/null; SRV_PID=""
done
[ "$PORT" != 0 ] || { echo "❌ php -S を起動できませんでした"; cat "$T/php.log"; exit 2; }
URL="http://127.0.0.1:$PORT/tools/mailbox/index.php"

P=0; N=0
say_ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
say_ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      → %s\n' "$2"; fi; }
has(){ case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; else say_ok "$3"; fi; }
want_eq(){     if [ "$1" = "$2" ]; then say_ok "$3"; else say_ng "$3" "実際=[$1] 期待=[$2]"; fi; }

# GET/POST ヘルパ（CODE に HTTP ステータス・OUT に本文）
req(){ # req <token> <method> <query> [body]
  local tok="$1" m="$2" q="$3" body="${4:-}"
  local args=(-s -o "$T/out" -w '%{http_code}' -X "$m" -H "Authorization: Bearer $tok" "$URL?$q")
  [ -n "$body" ] && args+=(--data-binary "$body")
  CODE="$(curl "${args[@]}")"; OUT="$(cat "$T/out")"
}
noauth(){ CODE="$(curl -s -o "$T/out" -w '%{http_code}' "$URL?$1")"; OUT="$(cat "$T/out")"; }
newcount(){ ls -1 "$T/data/mailbox/new" 2>/dev/null | wc -l | tr -d ' '; }
holdcount(){ ls -1 "$T/data/mailbox/hold" 2>/dev/null | wc -l | tr -d ' '; }

echo "▼ 認証（既存挙動）"
noauth "action=inbox";                               want_eq "$CODE" "401" "Bearer 無しは 401"
req "tk-nope" GET "action=inbox";                    want_eq "$CODE" "403" "表に無いトークンは 403"
req "tk-nope" GET "action=inbox";                    want_in "invalid_token" "$OUT" "エラーは invalid_token"

echo "▼ agent / admin の既存挙動が変わっていないこと"
req "tk-agent" GET "action=inbox";                   want_eq "$CODE" "200" "agent は inbox を読める"
req "tk-agent" GET "action=inbox";                   want_in '"inbox_of": "dev-x"' "$OUT" "自分の箱が返る"
req "tk-agent" POST "action=send" '{"to":"analysis-y","subject":"s","body":"b"}'
                                                     want_eq "$CODE" "200" "agent は他エージェントへ送れる"
want_in '"from": "dev-x"'   "$OUT" "from はトークン由来（詐称不可）"
MID="$(python3 -c "import json,sys;print(json.load(open('$T/out'))['id'])")"
req "tk-peer" POST "action=done&id=$MID";            want_eq "$CODE" "200" "宛先本人は done できる"
req "tk-admin" GET "action=inbox&to=dev-x";          want_in '"inbox_of": "dev-x"' "$OUT" "admin は他人の箱を読める"
req "tk-agent" GET "action=inbox&to=analysis-y";     want_in '"inbox_of": "dev-x"' "$OUT" "agent は他人の箱を指定しても自分の箱に戻される"
req "tk-agent" POST "action=send" '{"to":"nobody","subject":"s"}'
                                                     want_in "unknown_recipient" "$OUT" "表に無い宛先は unknown_recipient"
req "tk-agent" POST "action=send" '{"to":"rr-proj","subject":"s","body":"b"}'
want_in "unknown_recipient" "$OUT" "発行済みの投函専用トークンは宛先にならない（誰も読まない new/ を溜めない）"
req "tk-agent" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "200" "受信専用の sink は権限が reporter でも宛先として残る"

echo "▼ reporter は投函専用"
BEFORE="$(newcount)"
req "tk-rep" POST "action=send" '{"to":"rule-kaizen","subject":"[website@x] test","body":"b"}'
want_eq "$CODE" "200" "reporter は rule-kaizen へ送れる"
want_in '"from": "rr-proj"' "$OUT" "from に案件が入る（どこから来たか分かる）"
want_eq "$(newcount)" "$((BEFORE+1))" "new/ に1件増える"
req "tk-rep" POST "action=send" '{"to":"analysis-y","subject":"s","body":"b"}'
want_eq "$CODE" "403" "reporter は他の宛先へ送れない"
want_in "recipient_not_allowed" "$OUT" "エラーは recipient_not_allowed"
req "tk-rep" GET "action=inbox";                     want_eq "$CODE" "403" "reporter は受信箱を持たない"
want_in "forbidden_for_role" "$OUT" "エラーは forbidden_for_role"
req "tk-rep" POST "action=done&id=$MID";             want_eq "$CODE" "403" "reporter は done できない"
req "tk-rep" GET "action=inbox&to=rule-kaizen";      want_eq "$CODE" "403" "reporter は目安箱の中身も読めない"

HB="$(holdcount)"
req "tk-rep" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b","needs_approval":true}'
want_eq "$CODE" "200" "reporter の needs_approval 付きも通る"
want_eq "$(holdcount)" "$HB" "hold/ には入らない（承認待ちに埋もれさせない）"

echo "▼ ホワイトリストの取り消し（失効・期限）"
req "tk-revoked" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "403" "revoked は 403"
want_in "token_revoked" "$OUT" "エラーは token_revoked"
want_not_in "reason" "$OUT" "失効理由は外に返さない"
req "tk-expired" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "403" "期限切れは 403"
want_in "token_expired" "$OUT" "エラーは token_expired"
req "tk-rep-norev" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "200" "expires_at 無しは期限なしとして通る"
req "tk-exp-today" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "200" "期限が今日のトークンはその日の終わりまで有効"
req "tk-badexp" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "500" "読めない期限は通さない（fail-closed）"
req "tk-weird" GET "action=inbox";                   want_eq "$CODE" "403" "未知ロールは reporter に倒れる（inbox 不可）"
req "tk-weird" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "200" "未知ロールでも目安箱へは投函できる"

echo "▼ 最終使用の記録（漏れに気づくための材料）"
SEEN="$T/data/mailbox/.state/seen-rr-proj.json"
if [ -f "$SEEN" ]; then say_ok "seen-<agent>.json が作られる"; else say_ng "seen-<agent>.json が作られる"; fi
want_in '"last_ip"' "$(cat "$SEEN" 2>/dev/null)" "接続元IPが記録される"
want_in '"last_seen"' "$(cat "$SEEN" 2>/dev/null)" "最終使用日時が記録される"
want_in '"agent_id": "rr-proj"' "$(cat "$SEEN" 2>/dev/null)" "どのトークンか分かる"
if [ -f "$T/data/mailbox/.state/seen-dev-x.json" ]; then say_ok "agent ロールの使用も記録される"; else say_ng "agent ロールの使用も記録される"; fi

echo "▼ 投函上限（漏洩時の被害を抑える保険）"
python3 - "$SEEN" "$TODAY" <<'PYEOF'
import json, sys
p, today = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d.update({"day": today, "today": 50}); json.dump(d, open(p, "w"))
PYEOF
req "tk-rep" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "429" "上限を超えたら 429"
want_in "daily_quota_exceeded" "$OUT" "エラーは daily_quota_exceeded"
want_eq "$(python3 -c "import json;print(json.load(open('$SEEN'))['today'])")" "50" \
        "上限で弾いたぶんは加算しない（超過中に叩かれても通算が汚れない）"
req "tk-rep" GET "action=inbox";                     want_eq "$CODE" "403" "上限に達しても投函以外の判定は変わらない"
req "tk-agent" POST "action=send" '{"to":"analysis-y","subject":"s","body":"b"}'
want_eq "$CODE" "200" "上限は agent ロールには掛からない"

echo "▼ 発行・失効（bin/rule-reporter.py）"
export RULE_REPORTER_TOKENS="$T/data/secrets/mailbox-tokens.json"
export RULE_REPORTER_LEDGER="$T/data/rule-reporters.md"
export RULE_REPORTER_STATE="$T/data/mailbox/.state"
rr(){ python3 "$PROJ/bin/rule-reporter.py" "$@" 2>&1; }

OUT="$(rr issue "テスト案件A" --template website)";   want_in "英数字以外が含まれます" "$OUT" "日本語の案件名は --id なしでは弾く（意味のない識別子を黙って作らない）"
OUT="$(rr issue "テスト案件A" --id "Test_Proj" --template website)"; want_in "英小文字・数字・ハイフン" "$OUT" "不正な --id は弾く"
OUT="$(rr issue "テスト案件A" --id test-proj)";        want_in "--template" "$OUT" "テンプレの指定は必須（取りに来られる範囲が決まる）"
OUT="$(rr issue "テスト案件A" --id test-proj --template website)"; want_in "RR-005" "$OUT" "既存の最大番号の次を採番する"
want_in "rr-test-proj" "$OUT" "--id が agent_id になる"
want_in "RULE_REPORT_TOKEN=rr_" "$OUT" "配布用の .env を出す"
want_in "RULE_UPDATE_URL" "$OUT" "更新の受け口も .env に入れさせる（同じトークンで取りに来る）"
TOKV="$(printf '%s' "$OUT" | sed -n 's/.*RULE_REPORT_TOKEN=//p')"
want_in "rr-" "$(python3 -c "
import json;d=json.load(open('$RULE_REPORTER_TOKENS'));print(d['$TOKV']['agent_id'])")" "トークン表に agent_id が入る"
want_eq "$(python3 -c "
import json;d=json.load(open('$RULE_REPORTER_TOKENS'));print(d['$TOKV']['role'])")" "reporter" "ロールは reporter"
want_eq "$(python3 -c "
import json;d=json.load(open('$RULE_REPORTER_TOKENS'));print(d['$TOKV']['template'])")" "website" "紐づけたテンプレが表に入る"
want_in "website" "$(grep '^| RR-005' "$RULE_REPORTER_LEDGER")" "台帳にテンプレが載る"
want_in "| RR-005 |" "$(cat "$RULE_REPORTER_LEDGER")" "台帳に行が増える"
want_not_in "$TOKV" "$(cat "$RULE_REPORTER_LEDGER")" "台帳にトークン値が載らない"
want_eq "$(stat -c '%a' "$RULE_REPORTER_TOKENS")" "600" "トークン表の権限は 600 のまま"

# 発行したトークンが実際に投函でき、失効させると弾かれる（表→API の結線確認）
req "$TOKV" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "200" "発行したトークンで投函できる"
OUT="$(rr issue "テスト案件A" --id test-proj --template website)"; want_in "すでにあります" "$OUT" "同じ案件の二重発行を拒む"
OUT="$(rr revoke RR-005 --reason "テスト")";          want_in "失効" "$OUT" "番号で失効できる"
req "$TOKV" POST "action=send" '{"to":"rule-kaizen","subject":"s","body":"b"}'
want_eq "$CODE" "403" "失効後は 403 で弾かれる"
want_in "| RR-005 |" "$(cat "$RULE_REPORTER_LEDGER")" "失効しても台帳から行は消えない"
want_in "失効" "$(cat "$RULE_REPORTER_LEDGER")" "台帳の状態が失効になる"
want_in "テスト" "$(cat "$RULE_REPORTER_LEDGER")" "失効理由が台帳に残る"
OUT="$(rr revoke RR-005 --reason "再")";              want_in "すでに失効" "$OUT" "二重失効は知らせるだけ"
OUT="$(rr revoke RR-999 --reason "x")";               want_in "該当する発行がありません" "$OUT" "無い番号は拒否"
OUT="$(rr revoke rr-test-proj --reason "agent_id で")"; want_in "すでに失効" "$OUT" "agent_id でも引ける"
OUT="$(rr revoke test-proj --reason "識別子で")";      want_in "すでに失効" "$OUT" "識別子（接頭辞なし）でも引ける"
OUT="$(rr list)";                                     want_in "RR-005" "$OUT" "一覧に出る"
want_in "有効" "$(printf '%s' "$OUT" | grep '^RR-002')" "期限なしを期限切と誤表示しない"
want_in "期限切" "$(printf '%s' "$OUT" | grep '^RR-004')" "期限を過ぎたものは期限切と出る"
want_not_in "rule-kaizen" "$OUT" "受信専用の sink は一覧に出ない（発行物ではない）"
want_not_in "rule-kaizen" "$(grep '^| RR-' "$RULE_REPORTER_LEDGER")" "受信専用の sink は台帳の行に出ない（本文の説明文は別）"
want_in "失効" "$OUT" "一覧に状態が出る"
want_not_in "$TOKV" "$OUT" "一覧にトークン値を出さない"
OUT="$(rr issue "テスト案件A" --id test-proj --template websystem)"; want_in "RR-006" "$OUT" "失効後は同じ案件に再発行できる"
OUT="$(rr revoke "テスト案件A" --reason "表示名で引けるか")"; want_in "RR-006" "$OUT" "同名が複数でも有効なほうを失効できる"
OUT="$(rr revoke "テスト案件A" --reason "全部失効済み")";     want_in "複数一致" "$OUT" "全部失効済みで絞れなければ番号を求める"

echo
echo "────────────────────────────────"
printf '成功 %d / 失敗 %d\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
