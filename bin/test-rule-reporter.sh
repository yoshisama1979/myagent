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
# 🚨 cut -c はバイトで切るので、日本語の途中で切れると**ログ全体が不正な UTF-8** になり、
#    あとから grep・python で失敗箇所を読めなくなる（2026-11-01 に実際に踏んだ）。文字で切る。
clip(){ printf '%s' "$1" | tr '\n' ' ' | python3 -c 'import sys; print(sys.stdin.read()[:200])'; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(clip "$2")"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(clip "$2")"; else say_ok "$3"; fi; }
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

echo "▼ 1回だけの手当ての記録（migrated・案件からの申告の写し）"
# 🚨 期待値に月を書かない（12月に入ると固定値のテストが落ちる＝2026-11-01 の Codex 指摘）
TOMORROW="$(date -d '+1 day' +%F)"
D1="$(date -d '-1 day' +%F)"
D2="$(date -d '-2 day' +%F)"
OUT="$(rr issue "テスト案件B" --id test-b --template website)"; want_in "RR-007" "$OUT" "手当ての検査用に1件発行する"
ROW(){ grep "^| $1 " "$RULE_REPORTER_LEDGER"; }
COLSET(){ python3 -c "
import io
rows=[l for l in io.open('$RULE_REPORTER_LEDGER',encoding='utf-8') if l.startswith('| RR-')]
print(len({l.count('|') for l in rows}))"; }
want_in " — " "$(ROW RR-007)" "申告が来ていない案件の手当て列は — （空欄にして「済み」に見せない）"
want_eq "$(COLSET)" "1" "全ての行の列数がそろっている"
want_eq "$(python3 -c "
import io
hdr=[l for l in io.open('$RULE_REPORTER_LEDGER',encoding='utf-8') if l.startswith('| 番号')][0]
print(hdr.count('|'))")" "11" "見出しの列数が10列（区切り11本）＝手当ての列が増えている"

OUT="$(rr migrated RR-007)";                          want_in "TB-019" "$OUT" "既定の手当ては TB-019"
want_in "済み" "$OUT" "済みにしたと言う"
want_in "申告を書き写したもの" "$OUT" "🚨 検証していないことを毎回言う（取りに来た記録は証拠にならない）"
want_in "TB-019 $TODAY" "$(ROW RR-007)" "台帳の手当て列に 番号と日付が載る"
want_eq "$(python3 -c "
import json
d=json.load(open('$RULE_REPORTER_TOKENS'))
e=[v for v in d.values() if isinstance(v,dict) and v.get('reporter_id')=='RR-007'][0]
print('recorded_at' in e['migrations']['TB-019'])")" "True" "表には記録した時刻も残る（申告日と記録日は別）"

OUT="$(rr list --item TB-019)";                       want_in "済み 1件" "$OUT" "--item で済みの件数が出る"
want_in "未申告  RR-002" "$OUT" "印の無い案件は「未申告」で名指しされる"
want_not_in "RR-005" "$(printf '%s' "$OUT" | sed -n '/TB-019 の手当て/,$p')" "失効した案件は数えない（配布を受けていない）"
# 🚨 期限切れは数える＝鍵の期限と「移行が済んだか」は別の軸。除くと台帳（行は残る）と食い違う
want_in "未申告  RR-004" "$(printf '%s' "$OUT" | sed -n '/TB-019 の手当て/,$p')" "期限切れも移行の対象として数える"
want_in "（期限切）" "$OUT" "ただし期限切れだと分かるように出す（取りに来られない）"
# 🚨 状態の判定を2箇所で持つと食い違う（台帳が「有効」・一覧が「期限切」の実例があった）
want_in " 期限切 " "$(ROW RR-004)" "台帳の状態も期限を見る（一覧と同じ判定）"
want_in "期限切" "$(printf '%s' "$(rr list)" | grep '^RR-004')" "一覧の状態も同じ"
OUT="$(rr list)";                                     want_in "TB-019 $TODAY" "$OUT" "--item 無しの一覧にも印が出る"
want_in "適用できたことの証拠にはならない" "$OUT" "一覧でも「取りに来た版」と「手当て」を混ぜない"

echo "▼ 済み／未申告／記録破損 を取り違えない"
OUT="$(rr migrated RR-007 --on "$TOMORROW")";         want_in "未来の日付は受けつけません" "$OUT" "未来の日付は打ち間違い＝拒否"
want_in "TB-019 $TODAY" "$(ROW RR-007)" "拒否されたとき台帳は変わらない"
OUT="$(rr migrated RR-007 --on 2026/11/01)";          want_in "YYYY-MM-DD" "$OUT" "区切りが違う日付は形で弾く"
OUT="$(rr migrated RR-007 --on 2026-13-40)";          want_in "そんな日付はありません" "$OUT" "形は合っていても月日の範囲外は弾く"
OUT="$(rr migrated RR-007 --on 2026-02-30)";          want_in "そんな日付はありません" "$OUT" "存在しない日付は弾く"
OUT="$(rr migrated RR-007 --item "ルールの手当て")";   want_in "番号の形で" "$OUT" "手当ての名前は番号の形だけ（自由文を列に入れない）"
OUT="$(rr migrated RR-007 --on "$D1")";               want_in "すでに $TODAY" "$OUT" "二重記録は黙って上書きせず前の値を言う"
OUT="$(rr migrated RR-007 --item TB-021 --on "$D2" --note "申告の控え")"
want_in "TB-021" "$OUT" "手当ては複数持てる（次の機会に作り直さない）"
want_not_in "申告の控え" "$OUT" "🚨 申告の本文は画面に出さない（トークン等を書かれたら端末とログに流れる）"
want_in "メモを表に記録しました" "$OUT" "記録したことだけ言う"
want_in "TB-019 $D1 / TB-021 $D2" "$(ROW RR-007)" "台帳では新しい順に並ぶ（番号順でなく日付順）"
want_not_in "申告の控え" "$(cat "$RULE_REPORTER_LEDGER")" "申告の本文は台帳にも出さない"
OUT="$(rr migrated RR-007 --item TB-021 --undo)";     want_in "取り消しました" "$OUT" "--undo で印を取り消せる（取り違えの直し方が手編集にならない）"
want_in "TB-021 取消（$TODAY）" "$(ROW RR-007)" "🚨 取り消しても痕跡は残る（「一度も申告が来ていない」と見分けられなくなる）"
want_not_in "TB-021 $D2" "$(ROW RR-007)" "済みとしては出さない"
OUT="$(rr list --item TB-021)";                       want_in "取消済  RR-007" "$OUT" "一覧では取消済み（未申告と分ける）"
want_in "済み 0件" "$OUT" "済みには数えない"
want_in "取消済み 1件" "$OUT" "取消済みの件数を出す"
OUT="$(rr migrated RR-007 --item TB-021 --undo)";     want_in "すでに取り消されています" "$OUT" "二重の取り消しは知らせるだけ"
OUT="$(rr migrated RR-007 --item TB-099 --undo)";     want_in "印はありません" "$OUT" "そもそも無い印の取り消しは「ありません」"
OUT="$(rr migrated RR-007 --item TB-021 --on "$TODAY" 2>&1)"
want_in "取り消されていました" "$OUT" "取消済みの上から記録し直せる（別の言い方で言う）"
rr migrated RR-007 --item TB-021 --undo >/dev/null
OUT="$(rr migrated RR-005)";                          want_in "失効しています" "$OUT" "失効した案件には印を付けない"
OUT="$(rr migrated RR-999)";                          want_in "該当する発行がありません" "$OUT" "無い番号は拒否"
OUT="$(rr migrated test-b --item TB-019 --on "$TODAY")"; want_in "RR-007" "$OUT" "識別子でも引ける"

# 期限切れの案件に印を付けられる（弾かない）が、取りに来られないことは言う
OUT="$(rr migrated RR-004 --item TB-019 2>&1)";       want_in "期限切れです" "$OUT" "期限切れには注意を出す（発行し直しが要る）"
OUT="$(rr list --item TB-019)";                       want_in "済み  RR-004" "$OUT" "印を付けた期限切れ案件は済みとして数える（表と一覧が食い違わない）"
OUT="$(rr migrated RR-004 --item TB-019 --undo)";     want_in "取り消しました" "$OUT" "元に戻す"

# 🚨 読める形でない印を「済み」に化けさせない。書くときと同じ検査を読むときにもかける
#    （形だけ見て通すと 2026-99-99 や 2099-01-01 が済みになる＝2026-11-01 の Codex 指摘）
BREAK(){ python3 - "$RULE_REPORTER_TOKENS" "$1" <<'PYEOF2'
import json, sys
p, mig = sys.argv[1], json.loads(sys.argv[2])
d = json.load(open(p, encoding="utf-8"))
for v in d.values():
    if isinstance(v, dict) and v.get("reporter_id") == "RR-007":
        v["migrations"] = mig
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF2
rr rebuild >/dev/null; }

BREAK '{"TB-019": {"at": "2026-99-99"}}'
OUT="$(rr list --item TB-019)";                       want_in "⚠️破損  RR-007" "$OUT" "存在しない日付（2026-99-99）は済みに数えない"
want_in "記録破損 1件" "$OUT" "破損の件数を別に数える"
want_in "⚠ 記録破損" "$(ROW RR-007)" "台帳にも破損として出す（未申告と同じ — にしない）"
BREAK '{"TB-019": {"at": "2099-01-01"}}'
OUT="$(rr list --item TB-019)";                       want_in "⚠️破損  RR-007" "$OUT" "未来の日付も済みに数えない（読むときも未来を弾く）"
BREAK '{"TB-019": {"recorded_at": "x"}, "TB-022": "済んだ", "TB-023": {"at": "きのう"}, "勝手な名前": {"at": "'"$TODAY"'"}}'
OUT="$(rr list --item TB-019)";                       want_in "⚠️破損  RR-007" "$OUT" "日付の無い印は済みに数えない"
want_not_in "未申告  RR-007" "$OUT" "🚨 破損を「申告なし」に混ぜない（直す対象として浮かばなくなる）"
want_in "記録破損" "$(ROW RR-007)" "台帳でも破損と分かる"
want_not_in "きのう" "$(ROW RR-007)" "読めない日付をそのまま表示しない"
want_not_in "勝手な名前 $TODAY" "$(ROW RR-007)" "番号の形でない名前は済みに数えない（読むときも形を見る）"
want_eq "$(COLSET)" "1" "破損の表示が入っても列数は変わらない"
OUT="$(rr list --item TB-022)";                       want_in "記録破損 1件" "$OUT" "dict でない印も破損として数える"
want_in "済み 0件" "$OUT" "破損は済みに数えない"
OUT="$(rr migrated RR-007 --item TB-019 --on "$TODAY" 2>&1)"
want_in "読めない印が入っていました" "$OUT" "読めない印の上書きは「新しく済みにした」と同じ字で言わない"
want_in "TB-019 $TODAY" "$(ROW RR-007)" "記録し直すと台帳に出る"
BREAK '"壊れた形"'
# 印の入れ物そのものが dict でないとき＝「印が1つも無い」と同じ見え方にしない
want_in "⚠ 記録破損" "$(ROW RR-007)" "記録そのものの形が壊れていたら台帳で破損と分かる"
want_not_in " — " "$(ROW RR-007)" "🚨 壊れているのに「申告なし」の — を出さない"
OUT="$(rr list --item TB-019)";                       want_in "⚠️破損  RR-007" "$OUT" "一覧でも破損として数える"
OUT="$(rr migrated RR-007 --item TB-019 --on "$TODAY" 2>&1)"
want_in "読めない形だったので作り直します" "$OUT" "記録そのものが壊れていたら、捨てたことを言う"
want_in "TB-019 $TODAY" "$(ROW RR-007)" "作り直したあとも記録できる"

echo "▼ 正（トークン表）と台帳の食い違いを黙らせない"
# 台帳だけ書けない状態を作る（親をディレクトリに差し替える）＝正は入るが写しが古いまま残る
mkdir -p "$T/data/blocked/rule-reporters.md"
OUT="$(RULE_REPORTER_LEDGER="$T/data/blocked/rule-reporters.md" rr migrated RR-007 --item TB-024 --on "$TODAY" 2>&1)"
want_in "台帳を書けませんでした" "$OUT" "台帳が書けないことを申告する"
want_in "やり直さないでください" "$OUT" "🚨 やり直すと issue ではトークンが二重に出る＝やり直さないと言う"
want_in "rebuild" "$OUT" "直し方（組み直し）を出す"
want_eq "$(python3 -c "
import json
d=json.load(open('$RULE_REPORTER_TOKENS'))
e=[v for v in d.values() if isinstance(v,dict) and v.get('reporter_id')=='RR-007'][0]
print('TB-024' in e.get('migrations', {}))")" "True" "正（トークン表）には入っている（＝失敗と読ませない理由）"
want_not_in "TB-024" "$(ROW RR-007)" "台帳はまだ古い（この食い違いが起きることを固定する）"
OUT="$(rr rebuild)";                                  want_in "組み直しました" "$OUT" "組み直すと追いつく"
want_in "TB-024" "$(ROW RR-007)" "組み直したあとは台帳にも出る"
rr migrated RR-007 --item TB-024 --undo >/dev/null

# 自由文の縦棒・改行で列がずれない（🚨 理由だけでなく案件名も実際に通す）
OUT="$(rr issue "案件|A と B" --id test-pipe --template website)"; want_in "RR-008" "$OUT" "列ずれの検査用に1件発行する"
want_in "案件｜A と B" "$(ROW RR-008)" "案件名の縦棒も全角に置き換える"
OUT="$(rr revoke RR-008 --reason "$(printf 'a|b\nc の都合')")"; want_in "失効" "$OUT" "縦棒と改行を含む理由でも失効できる"
want_eq "$(COLSET)" "1" "縦棒・改行を含む自由文でも列数が変わらない（列がずれると状態の欄に別の値が出る）"
want_in "a｜b c の都合" "$(ROW RR-008)" "改行は空白に畳んで1行に収める"
want_eq "$(grep -c '^| RR-008' "$RULE_REPORTER_LEDGER")" "1" "改行で行が増えない"

echo "▼ 壊れた記録の中身を外に出さない（台帳は git 追跡・ログも残る）"
SECRET="rr_abcdef0123456789abcdef0123456789"
BREAK '{"'"$SECRET"'": {"at": "'"$TODAY"'"}}'
want_not_in "$SECRET" "$(cat "$RULE_REPORTER_LEDGER")" "🚨 読めない名前の中身を台帳に書かない（トークンらしき値が入っていても）"
want_in "名前が読めない項目1件" "$(ROW RR-007)" "件数だけ出す"
OUT="$(rr list --item TB-019 2>&1)";                  want_not_in "$SECRET" "$OUT" "一覧にも中身を出さない"
want_in "⚠️破損  RR-007" "$OUT" "破損としては数える（黙らない）"
OUT="$(rr migrated RR-007 --item TB-019 --on "$TODAY" 2>&1)"; want_not_in "$SECRET" "$OUT" "記録し直すときも中身を出さない"
BREAK '"'"$SECRET"'"'
OUT="$(rr migrated RR-007 --item TB-019 --on "$TODAY" 2>&1)"
want_not_in "$SECRET" "$OUT" "🚨 入れ物ごと壊れていても中身を出さない（型だけ言う）"
want_in "str・内容は表示しません" "$OUT" "何が入っていたかは型だけ言う"

echo "▼ 壊れた入れ物に --undo は「直した」と言わない"
BREAK '"壊れた形"'
RC="$(python3 "$PROJ/bin/rule-reporter.py" migrated RR-007 --item TB-019 --undo >"$T/o" 2>"$T/e"; echo $?)"
want_eq "$RC" "1" "項目ごとの取り消しは拒否する（できないことをできないと言う）"
want_in "項目ごとの取り消しはできません" "$(cat "$T/o" "$T/e")" "理由を出す"
want_in "記録し直してください" "$(cat "$T/o" "$T/e")" "直し方（記録し直す）を出す"
rr rebuild >/dev/null
want_in "⚠ 記録破損" "$(ROW RR-007)" "拒否のあとも台帳は破損のまま（直したように見せない）"
rr migrated RR-007 --item TB-019 --on "$TODAY" >/dev/null 2>&1

echo "▼ 表の型が想定外でも台帳の組み立てで落ちない（落ちると復旧案内が出ない）"
python3 - "$RULE_REPORTER_TOKENS" <<'PYEOF2'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["tk-junk"] = {"agent_id": "rr-junk", "role": "reporter", "reporter_id": 9001,
                "project": "型が壊れた行", "issued_at": 20261101, "expires_at": 20271101}
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF2
RC="$(python3 "$PROJ/bin/rule-reporter.py" rebuild >"$T/o" 2>"$T/e"; echo $?)"
want_eq "$RC" "0" "数値が入った行があっても組み直せる（番号の並べ替え・日付の切り出し・期限の判定）"
want_in "9001" "$(cat "$RULE_REPORTER_LEDGER")" "その行も台帳に出る"
want_in " 期限不明 " "$(ROW 9001)" "数値の期限も「有効」に倒さない（20271101 は YYYY-MM-DD ではない）"
RC="$(python3 "$PROJ/bin/rule-reporter.py" list >"$T/o" 2>"$T/e"; echo $?)"
want_eq "$RC" "0" "一覧も落ちない（並べ替えは台帳と一覧の2箇所にある）"
# 🚨 幅指定（:<18）は文字列以外で落ちる＝配列・辞書を実際に入れて踏む
#    （数値はたまたま落ちないので、数値だけのフィクスチャでは何も検査していない）
python3 - "$RULE_REPORTER_TOKENS" "$RULE_REPORTER_STATE" <<'PYEOF7'
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["tk-junk2"] = {"agent_id": "rr-junk2", "role": "reporter", "reporter_id": "RR-902",
                 "project": ["壊れた案件"], "template": {"x": 1},
                 "issued_at": "2026-10-01", "expires_at": "2027-10-01"}
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
os.makedirs(sys.argv[2], exist_ok=True)
json.dump({"agent_id": "rr-junk2", "last_seen": ["2026-11-01T10:00"], "last_ip": {"v": 1},
           "today": [1], "total": {"n": 2}, "last_rules_version": ["x"], "last_rules_at": [1]},
          open(os.path.join(sys.argv[2], "seen-rr-junk2.json"), "w", encoding="utf-8"))
PYEOF7
RC="$(python3 "$PROJ/bin/rule-reporter.py" list >"$T/o" 2>"$T/e"; echo $?)"
want_eq "$RC" "0" "案件名・接続元・最終使用が配列や辞書でも一覧が落ちない"
want_in "RR-902" "$(cat "$T/o")" "その行も一覧に出る"
RC="$(python3 "$PROJ/bin/rule-reporter.py" list --item TB-019 >"$T/o2" 2>"$T/e2"; echo $?)"
want_eq "$RC" "0" "番号別の一覧も落ちない"
RC="$(python3 "$PROJ/bin/rule-reporter.py" rebuild >/dev/null 2>&1; echo $?)"
want_eq "$RC" "0" "台帳の組み直しも落ちない"
want_eq "$(COLSET)" "1" "配列や辞書が入っていても列数は変わらない"
python3 - "$RULE_REPORTER_TOKENS" <<'PYEOF8'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d.pop("tk-junk2", None)
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF8
want_in "except Exception" "$(cat "$PROJ/bin/rule-reporter.py")" \
        "🚨 台帳の組み立ては OSError 以外も掴む（型を潰し漏れても、正だけ進んだことは必ず伝える）"
python3 - "$RULE_REPORTER_TOKENS" <<'PYEOF3'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d.pop("tk-junk", None)
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF3
rr rebuild >/dev/null

echo "▼ 台帳が書けなかったときの終了コードと出力"
RC="$(RULE_REPORTER_LEDGER="$T/data/blocked/rule-reporters.md" python3 "$PROJ/bin/rule-reporter.py" \
      migrated RR-007 --item TB-025 --on "$TODAY" >"$T/o" 2>"$T/e"; echo $?)"
want_eq "$RC" "3" "終了コードで食い違いを知らせる（0 だと無人で回したとき気づけない）"
want_in "✅" "$(cat "$T/o")" "正には入ったので成功文は出す（やり直させない）"
want_in "台帳を書けませんでした" "$(cat "$T/e")" "台帳の失敗は標準エラーへ"
RC="$(RULE_REPORTER_LEDGER="$T/data/blocked/rule-reporters.md" python3 "$PROJ/bin/rule-reporter.py" \
      issue "テスト案件D" --id test-d --template website >"$T/o" 2>"$T/e"; echo $?)"
want_eq "$RC" "3" "発行でも終了コードは 3"
want_in "RULE_REPORT_TOKEN=rr_" "$(cat "$T/o")" "🚨 台帳が書けなくてもトークンは出し切る（出さないと二度と取れない）"
RC="$(python3 "$PROJ/bin/rule-reporter.py" migrated RR-007 --item TB-025 --undo >"$T/o" 2>"$T/e"; echo $?)"
want_eq "$RC" "0" "台帳が書けるときは 0"
rr rebuild >/dev/null

echo "▼ 再発行で手当ての記録が消えない（印が付くのは案件・トークン行ではない）"
# 🚨 期限切れの更新・識別子の打ち直し（RR-013→RR-014 で実際にあった）で行が変わる。
#    そこで印が消えると、済んだ案件が「未申告」に戻って同じ依頼をもう一度出してしまう。
OUT="$(rr issue "引き継ぎ案件" --id test-carry --template website)"; want_in "を発行しました" "$OUT" "引き継ぎの検査用に発行する"
CARRY="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr migrated "$CARRY" --item TB-019 --on "$D1" >/dev/null
rr migrated "$CARRY" --item TB-030 --on "$D2" >/dev/null
rr revoke "$CARRY" --reason "期限の更新のため再発行" >/dev/null
OUT="$(rr issue "引き継ぎ案件" --id test-carry --template website)"
NEW="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
want_in "引き継ぎました" "$OUT" "引き継いだことを言う（黙って持ってこない）"
want_in "TB-019 $D1" "$OUT" "申告日ごと引き継ぐ（再発行の日に書き換えない）"
want_in "TB-030 $D2" "$OUT" "複数の手当ても引き継ぐ"
want_in "TB-019 $D1" "$(ROW "$NEW")" "新しい行の台帳にも出る"
OUT="$(rr list --item TB-019)";                       want_in "済み  $NEW" "$OUT" "🚨 再発行のあとも済みのまま（未申告に戻らない）"
want_not_in "未申告  $NEW" "$OUT" "未申告に数えない"
# 読めない印は引き継がない（新しい行を壊れた状態で始めない）
BREAK2(){ python3 - "$RULE_REPORTER_TOKENS" "$1" "$2" <<'PYEOF4'
import json, sys
p, rid, mig = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
d = json.load(open(p, encoding="utf-8"))
for v in d.values():
    if isinstance(v, dict) and v.get("reporter_id") == rid:
        v["migrations"] = mig
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF4
rr rebuild >/dev/null; }
# 🚨 前の行が複数あると、古い行に残った読める値が引き継がれて「壊れた印を弾いた」ことの検査に
#    ならない（空振り）。前の行が1本だけの案件で見る。
OUT="$(rr issue "壊れた印の案件" --id test-carry2 --template website)"
C2="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
BREAK2 "$C2" '{"TB-019": {"at": "きのう"}, "TB-031": {"at": "'"$D1"'"}}'
rr revoke "$C2" --reason "壊れた印の引き継ぎを見る" >/dev/null
OUT="$(rr issue "壊れた印の案件" --id test-carry2 --template website)"
LAST="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
want_in "TB-031 $D1" "$OUT" "読める印は引き継ぐ"
want_in "読めない印 1件もそのまま引き継ぎました" "$OUT" "読めない印も運ぶと言う"
want_in "記録し直してください" "$OUT" "直し方を出す"
# 🚨 落とすと、新しい行は「判定不能」ではなく「未申告」になり、判定できなかったことが
#    発行の瞬間の警告だけで消える（あとから台帳を見ても分からない）
want_in "⚠ 記録破損" "$(ROW "$LAST")" "🚨 新しい行でも破損のまま残る（未申告に化けない）"
OUT="$(rr list --item TB-019)";                       want_in "⚠️破損  $LAST" "$OUT" "一覧でも破損のまま"
want_not_in "未申告  $LAST" "$OUT" "未申告に化けない"
OUT="$(rr list --item TB-031)";                       want_in "済み  $LAST" "$OUT" "名前の読める破損は**その番号だけ**の話（ほかの番号を道連れにしない）"
rr revoke "$LAST" --reason "検査おわり" >/dev/null
# 🚨 名前が読めない印と読める済み印が同居しているとき＝その読めない印がこの番号の取消だった
#    可能性を否定できない。再発行の経路でだけ「済み」に確定するのを防ぐ
OUT="$(rr issue "同居の案件" --id test-mix --template website)"
MIX="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
BREAK2 "$MIX" '{"TB-019": {"at": "'"$D1"'"}, "壊れた名前": {"at": "'"$D2"'"}}'
OUT="$(rr list --item TB-019)";                       want_in "⚠️破損  $MIX" "$OUT" "元の行では破損（判定の順は破損→取消→済み）"
rr revoke "$MIX" --reason "再発行して確かめる" >/dev/null
OUT="$(rr issue "同居の案件" --id test-mix --template website)"
MIX2="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
OUT="$(rr list --item TB-019)";                       want_in "⚠️破損  $MIX2" "$OUT" "🚨 再発行しても破損のまま（読めない名前を落として済みに確定させない）"
want_not_in "済み  $MIX2" "$OUT" "済みに確定させない"
want_in "名前が読めない項目1件" "$(ROW "$MIX2")" "台帳でも件数が残る"
rr revoke "$MIX2" --reason "検査おわり" >/dev/null

# 🚨 取り消した印が、古い行に残っている分から復活しないこと（引き継ぎは最新行だけ）
OUT="$(rr issue "取り消しの案件" --id test-undo --template website)"
U1="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr migrated "$U1" --item TB-019 --on "$D2" >/dev/null
rr revoke "$U1" --reason "1回目を畳む" >/dev/null
OUT="$(rr issue "取り消しの案件" --id test-undo --template website)"
U2="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
want_in "TB-019 $D2" "$OUT" "2回目の発行で引き継がれる"
rr migrated "$U2" --item TB-019 --undo >/dev/null
rr revoke "$U2" --reason "2回目を畳む" >/dev/null
OUT="$(rr issue "取り消しの案件" --id test-undo --template website)"
U3="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
want_in "TB-019 取消" "$OUT" "取消済みの痕跡は引き継ぐ（次の行で「未申告」に戻らない）"
want_not_in "TB-019 $D2" "$OUT" "🚨 済みとしては復活しない（取り消しが無かったことにならない）"
want_in "TB-019 取消" "$(ROW "$U3")" "台帳も取消済み"
OUT="$(rr list --item TB-019)";                       want_in "取消済  $U3" "$OUT" "一覧でも取消済み"
want_not_in "済み  $U3" "$OUT" "済みには数えない"
# 同じ番号が複数の過去行にあるときは最新行の値を使う（古い行の日付を拾わない）
rr migrated "$U3" --item TB-019 --on "$D1" >/dev/null
rr revoke "$U3" --reason "3回目を畳む" >/dev/null
OUT="$(rr issue "取り消しの案件" --id test-undo --template website)"
want_in "TB-019 $D1" "$OUT" "最新行の申告日を引き継ぐ"
want_not_in "TB-019 $D2" "$OUT" "古い行の申告日は使わない"
U4="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
# 最新行の印が壊れていたら、古い行に読める値があっても引き継がない（破損を隠さない）
BREAK2 "$U4" '{"TB-019": {"at": "こわれた"}}'
rr revoke "$U4" --reason "壊れた最新行を畳む" >/dev/null
OUT="$(rr issue "取り消しの案件" --id test-undo --template website)"
U5="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
want_not_in "TB-019 $D1" "$OUT" "最新行が壊れていたら古い行へ遡って拾い直さない（破損を隠さない）"
want_in "読めない印 1件もそのまま引き継ぎました" "$OUT" "壊れた状態をそのまま運ぶと言う"
want_in "⚠ 記録破損" "$(ROW "$U5")" "新しい行も破損（古い行の読める値で上書きしない）"
rr migrated "$U5" --item TB-019 --on "$D1" >/dev/null
rr revoke "$U5" --reason "検査おわり" >/dev/null
# 🚨 この仕組みの前に出した行（`migrations` の欄が無い）がいちばん新しいとき、そこを最新行と
#    見なすと印が消える。欄を持つ行だけを候補にしていることを固定する。
python3 - "$RULE_REPORTER_TOKENS" <<'PYEOF9'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["tk-old-style"] = {"agent_id": "rr-test-undo", "role": "reporter", "reporter_id": "RR-903",
                     "project": "取り消しの案件", "issued_at": "2026-12-31",
                     "expires_at": "2027-12-31", "revoked": True}
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF9
OUT="$(rr issue "取り消しの案件" --id test-undo --template website)"
want_in "TB-019 $D1" "$OUT" "印の欄が無い新しい行があっても、欄を持つ最新行から引き継ぐ"
U6="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr revoke "$U6" --reason "検査おわり" >/dev/null

# 🚨 JSON の null＝キーはあるが読めない。`get()` で取るとキーが無いのと同じ形になり、
#    壊れた記録が「申告なし」に化ける（台帳 — ・一覧「未申告」・--undo「印はありません」）
OUT="$(rr issue "null の案件" --id test-null --template website)"
NUL="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
BREAK2 "$NUL" 'null'
want_in "⚠ 記録破損" "$(ROW "$NUL")" "migrations が null なら台帳は破損（— にしない）"
want_not_in " — " "$(ROW "$NUL")" "🚨 null を「申告なし」と同じ字で出さない"
OUT="$(rr list --item TB-019)";                       want_in "⚠️破損  $NUL" "$OUT" "一覧も破損として数える"
want_not_in "未申告  $NUL" "$OUT" "未申告に混ぜない"
RC="$(python3 "$PROJ/bin/rule-reporter.py" migrated "$NUL" --item TB-019 --undo >"$T/o" 2>"$T/e"; echo $?)"
want_eq "$RC" "1" "null への項目ごとの取り消しは拒否する"
want_in "項目ごとの取り消しはできません" "$(cat "$T/o" "$T/e")" "「印はありません」と誤報しない"
OUT="$(rr migrated "$NUL" --item TB-019 --on "$TODAY" 2>&1)"; want_in "読めない形だったので作り直します" "$OUT" "記録し直せる（型だけ言う）"
want_in "TB-019 $TODAY" "$(ROW "$NUL")" "作り直したあとは台帳に出る"

# 🚨 失効した行の誤った印は取り消せないと、次の発行で新しい行に乗り移る
rr migrated "$NUL" --item TB-050 --on "$TODAY" >/dev/null
rr revoke "$NUL" --reason "誤った印の訂正を見る" >/dev/null
OUT="$(rr migrated "$NUL" --item TB-050 2>&1)";       want_in "失効しています" "$OUT" "失効した行に印を足すのは引き続き拒否"
want_in "--undo は失効した行にも使えます" "$OUT" "消す方法は案内する"
OUT="$(rr migrated "$NUL" --item TB-050 --undo 2>&1)"; want_in "取り消しました" "$OUT" "🚨 失効した行の印は取り消せる（訂正の口を残す）"
OUT="$(rr issue "null の案件" --id test-null --template website)"
want_in "TB-050 取消" "$OUT" "取り消した誤った印は「取消」として引き継ぐ"
want_not_in "TB-050 $TODAY" "$OUT" "🚨 済みとして復活しない"
want_in "TB-019 $TODAY" "$OUT" "正しい印は引き継ぐ"
NUL2="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"

# 順番が決まらないときは引き継がず、そう言う
python3 - "$RULE_REPORTER_TOKENS" <<'PYEOF10'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for v in d.values():
    if isinstance(v, dict) and v.get("agent_id") == "rr-test-null" and v.get("revoked"):
        v["issued_at"] = "きのう"        # 日時が読めない行を混ぜる
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF10
rr revoke "$NUL2" --reason "順番が決まらない場合を見る" >/dev/null
OUT="$(rr issue "null の案件" --id test-null --template website)"
want_in "日時か番号が読めないため" "$OUT" "順番が決まらないときは引き継がない理由を言う"
want_not_in "引き継ぎました" "$OUT" "🚨 順番を推測して引き継がない（復活にも取りこぼしにも倒れる）"
want_in "記録し直してください" "$OUT" "直し方を出す"
LASTN="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr revoke "$LASTN" --reason "検査おわり" >/dev/null

# 🚨 日時は秒まで＝続けて発行すると同じ秒の行ができる。そのとき JSON の並び順で結果が
#    変わってはいけない（番号で決着をつける）。古い番号の行をファイルの**後ろ**に置いて見る。
python3 - "$RULE_REPORTER_TOKENS" "$D1" "$D2" <<'PYEOF11'
import json, sys
p, d1, d2 = sys.argv[1:4]
d = json.load(open(p, encoding="utf-8"))
same = "2026-10-15T09:00:00+09:00"
new_rows = {
    "tk-tie-b": {"agent_id": "rr-test-tie", "role": "reporter", "reporter_id": "RR-911",
                 "project": "同時刻の案件", "issued_at": same, "expires_at": "2027-10-15",
                 "revoked": True, "migrations": {"TB-019": {"at": d1}}},
    "tk-tie-a": {"agent_id": "rr-test-tie", "role": "reporter", "reporter_id": "RR-910",
                 "project": "同時刻の案件", "issued_at": same, "expires_at": "2027-10-15",
                 "revoked": True, "migrations": {"TB-019": {"at": d2}}},
}
d.update(new_rows)          # 後ろに tk-tie-a（古い番号）が来る＝並び順では古い行が最後
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF11
OUT="$(rr issue "同時刻の案件" --id test-tie --template website)"
want_in "TB-019 $D1" "$OUT" "同じ日時なら番号の大きい行（あとの発行）を最新とみなす"
want_not_in "TB-019 $D2" "$OUT" "🚨 JSON の並び順で結果が変わらない"
TIE="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr revoke "$TIE" --reason "検査おわり" >/dev/null

# 🚨 「印が1つも無い」という状態も運ぶ。運ばないと新しい行は欄を持たず、**その次の発行で
#    さらに古い行まで遡って**、空にしたはずの状態が古い値で埋まる（取り消しの復活と同じ型）。
OUT="$(rr issue "空を運ぶ案件" --id test-empty --template website)"
E1="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
BREAK2 "$E1" '{}'
rr revoke "$E1" --reason "空の行を畳む" >/dev/null
OUT="$(rr issue "空を運ぶ案件" --id test-empty --template website)"
E2="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr revoke "$E2" --reason "空を運んだ行を畳む" >/dev/null
BREAK2 "$E1" '{"TB-019": {"at": "'"$D2"'"}}'      # さらに古い行に済みの値を置く
OUT="$(rr issue "空を運ぶ案件" --id test-empty --template website)"
E3="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
want_not_in "TB-019 $D2" "$OUT" "🚨 空の状態を運んでいるので、さらに古い行の済みが復活しない"
OUT="$(rr list --item TB-019)";                       want_in "未申告  $E3" "$OUT" "未申告のまま"
want_not_in "済み  $E3" "$OUT" "済みに化けない"
rr revoke "$E3" --reason "検査おわり" >/dev/null

echo "▼ 識別子を打ち直した再発行（agent_id が変わる＝自動では引き継げない）"
# 🚨 実例＝RR-013（rr-rr-… の打ち間違い）→ RR-014。このときコメントが約束していた
#    「識別子の打ち直しでも引き継ぐ」は効いていなかった（2026-11-01 の Codex 指摘）
OUT="$(rr issue "打ち直しの案件" --id old-name --template website)"
OLD="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr migrated "$OLD" --item TB-019 --on "$D1" >/dev/null
rr migrated "$OLD" --item TB-033 --undo >/dev/null 2>&1
rr revoke "$OLD" --reason "識別子を打ち直す" >/dev/null
OUT="$(rr issue "打ち直しの案件" --id new-name --template website)"
NEWID="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
want_not_in "TB-019 $D1" "$OUT" "別の識別子では自動で引き継がない（案件名での推測はしない）"
want_in "同じ案件名の過去の発行が 1件あります" "$OUT" "🚨 黙らずに「引き継がなかった」と言う"
want_in "--carry-from $OLD" "$OUT" "引き継ぐ手段を名指しで案内する"
rr revoke "$NEWID" --reason "やり直す" >/dev/null
OUT="$(rr issue "打ち直しの案件" --id new-name2 --template website --carry-from "$OLD")"
N2="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
want_in "$OLD から" "$OUT" "どの行から引き継いだか言う"
want_in "TB-019 $D1" "$OUT" "指定すれば済みを引き継ぐ"
want_in "TB-019 $D1" "$(ROW "$N2")" "台帳にも出る"
OUT="$(rr list --item TB-019)";                       want_in "済み  $N2" "$OUT" "一覧でも済み（未申告に戻らない）"
OUT="$(rr issue "別の案件" --id other-x --template website --carry-from RR-999 2>&1)"
want_in "該当する発行がありません" "$OUT" "無い番号の --carry-from は拒否"
OUT="$(rr issue "打ち直しの案件" --id other-y --template website --carry-from RR-002 2>&1)"
want_in "案件名が違います" "$OUT" "案件名が違う行は先に拒否する"
# 🚨 別案件の印を持ち込めない（番号の打ち間違いで、やっていない案件が「済み」になるのが
#    いちばん危ない）。拒否のときは行自体も増えない
BEFORE_ROWS="$(grep -c '^| RR-' "$RULE_REPORTER_LEDGER")"
OUT="$(rr issue "別の案件" --id other-x --template website --carry-from "$OLD" 2>&1)"
want_in "案件名が違います" "$OUT" "🚨 別案件の番号を指定したら拒否する"
want_in "$OLD" "$OUT" "どの番号が問題か言う"
want_eq "$(grep -c '^| RR-' "$RULE_REPORTER_LEDGER")" "$BEFORE_ROWS" "拒否したときは行が増えない"
OUT="$(rr list --item TB-019)";                       want_not_in "別の案件" "$OUT" "別案件が済みにならない"
OUT="$(rr issue "別の案件" --id other-x --template website --carry-from "打ち直しの案件" 2>&1)"
want_in "RR-NNN の形で" "$OUT" "番号以外（案件名）での指定は拒否する"
# 記録を持たない行からの引き継ぎも拒否（空を引き継いだと誤解させない）
OUT="$(rr issue "記録なし案件" --id norec --template website)"
NOREC="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr revoke "$NOREC" --reason "記録のない行を作る" >/dev/null
OUT="$(rr issue "記録なし案件" --id norec2 --template website --carry-from "$NOREC" 2>&1)"
want_in "手当ての記録はありません" "$OUT" "記録を持たない行からの引き継ぎは拒否（空を引き継いだと誤解させない）"
# 空の状態を明示的に引き継いだときは、黙らずにそう言う
OUT="$(rr issue "空の引き継ぎ案件" --id carry-empty --template website)"
CE="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
BREAK2 "$CE" '{}'
rr revoke "$CE" --reason "空の行を作る" >/dev/null
OUT="$(rr issue "空の引き継ぎ案件" --id carry-empty2 --template website --carry-from "$CE")"
want_in "読める印は無し" "$OUT" "空を引き継いだときも「引き継いだ」と言う（効かなかったように見せない）"
CE2="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr revoke "$CE2" --reason "検査おわり" >/dev/null
# 旧行を失効せずに別の識別子で出すと、同じ案件が二重に数えられる
OUT="$(rr issue "打ち直しの案件" --id new-name3 --template website)"
N3="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
want_in "同じ案件名で有効な行がほかに" "$OUT" "🚨 同じ案件名の有効な行が複数あることを言う（件数が案件の数にならない）"
want_in "revoke" "$OUT" "直し方（古いほうを失効させる）を出す"
rr revoke "$N3" --reason "候補を2件にする" >/dev/null
rr migrated "$N3" --item TB-019 --on "$D1" >/dev/null
OUT="$(rr issue "打ち直しの案件" --id new-name4 --template website)"
want_in "過去の発行が 2件あります" "$OUT" "同名の候補が複数あることを言う"
want_in "1つ選んでください" "$OUT" "🚨 候補が複数なら番号を選んだコマンドを出さない（推測した番号を打たせない）"
want_not_in "--carry-from $N3" "$OUT" "特定の番号入りのコマンドを出さない"
N4="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
rr revoke "$N4" --reason "検査おわり" >/dev/null
rr revoke "$N3" --reason "検査おわり" >/dev/null
rr revoke "$N2" --reason "検査おわり" >/dev/null

echo "▼ 読めない期限を「有効」に倒さない（API は fail-closed で弾く）"
python3 - "$RULE_REPORTER_TOKENS" <<'PYEOF5'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["tk-badexp2"] = {"agent_id": "rr-badexp", "role": "reporter", "reporter_id": "RR-900",
                   "project": "期限が読めない案件", "issued_at": "2026-10-01",
                   "expires_at": "ちょっと先"}
d["tk-badexp3"] = {"agent_id": "rr-badexp3", "role": "reporter", "reporter_id": "RR-901",
                   "project": "期限の形が違う案件", "issued_at": "2026-10-01",
                   "expires_at": "2099/01/01"}
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF5
rr rebuild >/dev/null
want_in " 期限不明 " "$(ROW RR-900)" "読めない期限は台帳で「期限不明」（有効と書かない）"
want_in " 期限不明 " "$(ROW RR-901)" "区切りが違う日付も期限不明（辞書順の比較で通さない）"
OUT="$(rr list)";                                     want_in "期限不明" "$(printf '%s' "$OUT" | grep '^RR-900')" "一覧も同じ判定"
OUT="$(rr list --item TB-019)";                       want_in "未申告  RR-900" "$OUT" "失効ではないので移行の対象には残す"

echo "▼ 台帳の組み立てが OSError 以外で落ちても復旧案内を出す"
# 🚨 「except Exception と書いてあるか」を見るだけでは、OSError に戻しても通ってしまう（空振り）。
#    write_ledger を実際に RuntimeError にして、終了コードと案内を見る。
cat > "$T/boom.py" <<'PYEOF6'
import importlib.util, sys
from pathlib import Path
src, tokens, ledger, state, today = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("rr_mod", src)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TOKENS, mod.LEDGER, mod.STATE = Path(tokens), Path(ledger), Path(state)
def boom(_d):
    raise RuntimeError("台帳の組み立てで想定外の型に当たった")
mod.write_ledger = boom
sys.exit(mod.main(["migrated", "RR-007", "--item", "TB-040", "--on", today]))
PYEOF6
RC="$(python3 "$T/boom.py" "$PROJ/bin/rule-reporter.py" "$RULE_REPORTER_TOKENS" \
        "$RULE_REPORTER_LEDGER" "$RULE_REPORTER_STATE" "$TODAY" >"$T/o" 2>"$T/e"; echo $?)"
want_eq "$RC" "3" "OSError 以外でも終了コードは 3（正だけ進んだことを知らせる）"
want_in "台帳を書けませんでした" "$(cat "$T/e")" "復旧案内を出す"
want_in "やり直さないでください" "$(cat "$T/e")" "やり直させない"
want_eq "$(python3 -c "
import json
d=json.load(open('$RULE_REPORTER_TOKENS'))
e=[v for v in d.values() if isinstance(v,dict) and v.get('reporter_id')=='RR-007'][0]
print('TB-040' in e.get('migrations', {}))")" "True" "正には入っている"
rr migrated RR-007 --item TB-040 --undo >/dev/null

echo "▼ 取消の日付が読めないときは「済み」に倒さない・読めない印の同居を断定しない"
OUT="$(rr issue "判定順の案件" --id test-order --template website)"
ORD="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
# 🚨 at は正しいが undone_at が読めない＝取消が壊れたのか無効なのか分からない（判定不能）
for BAD in '"こわれた"' 'null' '"2099-01-01"'; do
  BREAK2 "$ORD" '{"TB-019": {"at": "'"$D1"'", "undone_at": '"$BAD"'}}'
  OUT="$(rr list --item TB-019)"
  want_in "⚠️破損  $ORD" "$OUT" "undone_at が $BAD のときは破損（済みに倒さない）"
  want_not_in "済み  $ORD" "$OUT" "済みに数えない"
  want_in "⚠ 記録破損" "$(ROW "$ORD")" "台帳も破損（undone_at=$BAD）"
done
# 🚨 読めない名前の印が同居しているときは、その番号を「済み」と断定しない
#    （その読めない印がこの番号の取消だった可能性を切り捨てられない）
BREAK2 "$ORD" '{"TB-019": {"at": "'"$D1"'"}, "壊れた名前": {"at": "'"$D2"'"}}'
OUT="$(rr list --item TB-019)"
want_in "⚠️破損  $ORD" "$OUT" "🚨 読めない印が同居していたら済みと断定しない（判定の順は破損→取消→済み）"
want_not_in "済み  $ORD" "$OUT" "済みに数えない"
want_in "名前が読めない項目1件" "$(ROW "$ORD")" "台帳では件数だけ出す"
# 印が1つも無い空の dict は未申告（どの番号についても何も言っていない）
BREAK2 "$ORD" '{}'
OUT="$(rr list --item TB-019)";                       want_in "未申告  $ORD" "$OUT" "空の印は未申告（取消は痕跡を残すので、ここに落ちてこない）"
want_in " — " "$(ROW "$ORD")" "台帳は —"
rr revoke "$ORD" --reason "検査おわり" >/dev/null

echo "▼ 自由文に貼られたトークンらしき値は出さない"
FAKE="rr_0123456789abcdef0123456789abcdef0123456789abcdef"
HEXRUN="0123456789abcdef0123456789abcdef"
# 🚨 入口で断る＝識別子は agent_id・メッセージID・ファイル名に入るので、伏字をかけても
#    「名前そのもの」として残り続ける。実測の抜け＝`rr_<hex>` は slug で `rr-<hex>` になり、
#    接頭辞 `rr_` だけを見ていた伏字をすり抜けて agent_id 列（git 追跡）に載った
OUT="$(rr issue "案件 $FAKE メモ" --id test-leak --template website 2>&1)"
want_in "長い16進の並びが含まれます" "$OUT" "🚨 案件名にトークンらしき値があれば発行を断る"
want_not_in "$HEXRUN" "$OUT" "拒否のメッセージにも出さない"
want_not_in "$HEXRUN" "$(cat "$RULE_REPORTER_LEDGER")" "🚨 台帳（git 追跡）に載らない"
OUT="$(rr issue "普通の案件" --id "x-$HEXRUN" --template website 2>&1)"
want_in "長い16進の並びが含まれます" "$OUT" "--id に貼られた分も断る（agent_id に残るため）"

# 自由文（失効理由）は断らず伏字にする＝失効は急ぐ操作なので理由の書き方で止めない
OUT="$(rr issue "伏字の案件" --id test-leak --template website)"
LEAK="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
LEAKTOK="$(printf '%s' "$OUT" | sed -n 's/.*RULE_REPORT_TOKEN=//p')"
OUT="$(rr revoke "$LEAK" --reason "理由に $FAKE を貼ってしまった")"
want_not_in "$HEXRUN" "$OUT" "失効理由に貼られた分は画面に出さない"
want_in "伏字" "$OUT" "伏字にしたと分かる"
want_not_in "$HEXRUN" "$(cat "$RULE_REPORTER_LEDGER")" "失効理由も台帳では伏字"
want_in "伏字" "$(ROW "$LEAK")" "理由自体は残す（失効は止めない）"
# 🚨 形を当てるだけでは別の形のトークンを取りこぼす＝表に実在する値そのものも落とす
OUT="$(rr issue "実トークンの案件" --id test-leak2 --template website)"
L2="$(printf '%s' "$OUT" | sed -n 's/^✅ \(RR-[0-9]*\) .*/\1/p')"
OUT="$(rr revoke "$L2" --reason "発行した値 $LEAKTOK を貼ってしまった")"
want_not_in "$LEAKTOK" "$OUT" "発行した値も伏字にする"
want_not_in "$LEAKTOK" "$(cat "$RULE_REPORTER_LEDGER")" "台帳にも載らない"
# 🚨 16進でない形のトークン＝「形を当てる」伏字では落ちない。表の実値を見る経路だけが効く
#    （番号つきの行はフィクスチャに足すと next_number がずれるので、使う直前に入れる）
OPAQUE="tk-opaque-ZZZZZZZZZZZZZZZZZZ"
python3 - "$RULE_REPORTER_TOKENS" "$OPAQUE" <<'PYEOF12'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d[sys.argv[2]] = {"agent_id": "rr-opaque", "role": "reporter", "reporter_id": "RR-950",
                  "project": "別形式トークンの案件", "issued_at": "2026-10-01",
                  "expires_at": "2027-10-01"}
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF12
rr rebuild >/dev/null
OUT="$(rr revoke RR-950 --reason "別形式の値 $OPAQUE を貼ってしまった")"
want_not_in "$OPAQUE" "$OUT" "🚨 16進でない形のトークンも伏字にする（表に実在する値を落とす）"
want_not_in "$OPAQUE" "$(cat "$RULE_REPORTER_LEDGER")" "台帳にも載らない"
want_in "伏字" "$(ROW RR-950)" "理由自体は残す"
# 日付・番号の拒否メッセージにも伏字
OUT="$(rr migrated "$LEAK" --item "TB-$HEXRUN" 2>&1)";  want_not_in "$HEXRUN" "$OUT" "--item の拒否でも伏字"
OUT="$(rr migrated RR-007 --on "$HEXRUN" 2>&1)";        want_not_in "$HEXRUN" "$OUT" "--on の拒否でも伏字"
OUT="$(rr migrated "$FAKE" 2>&1)";                    want_not_in "$FAKE" "$OUT" "引けなかった鍵も伏字にする（migrated）"
OUT="$(rr revoke "$FAKE" --reason x 2>&1)";           want_not_in "$FAKE" "$OUT" "引けなかった鍵も伏字にする（revoke）"
OUT="$(rr issue "x" --id "$FAKE" --template website 2>&1)"; want_not_in "$FAKE" "$OUT" "--id に貼られた分も伏字にする"

echo "▼ 台帳の組み直し（rebuild）"
TOK_BEFORE="$(python3 -c "
import hashlib,io;print(hashlib.sha256(io.open('$RULE_REPORTER_TOKENS','rb').read()).hexdigest())")"
printf 'これは手で書いた行\n' > "$RULE_REPORTER_LEDGER"
OUT="$(rr rebuild)";                                  want_in "組み直しました" "$OUT" "台帳を組み直せる"
want_in "| RR-007 |" "$(cat "$RULE_REPORTER_LEDGER")" "行が戻る（手で壊しても復旧できる）"
want_in "手当て" "$(cat "$RULE_REPORTER_LEDGER")" "見出しに手当ての列が入る（列を変えても次の発行まで古いまま、にならない）"
want_not_in "これは手で書いた行" "$(cat "$RULE_REPORTER_LEDGER")" "手書きの行は残らない（正はトークン表）"
want_eq "$(python3 -c "
import hashlib,io;print(hashlib.sha256(io.open('$RULE_REPORTER_TOKENS','rb').read()).hexdigest())")" \
        "$TOK_BEFORE" "🚨 トークン表は1バイトも変わらない（組み直しは読むだけ）"
want_not_in "$TOKV" "$(cat "$RULE_REPORTER_LEDGER")" "組み直した台帳にもトークン値は載らない"

echo
echo "────────────────────────────────"
printf '成功 %d / 失敗 %d\n' "$P" "$N"
# 規定形の1行（rules/testing.md §6-5）。これが無いと bin/test-all.sh が項目数を0と数える。
printf '合計: 合格 %d ／ 不合格 %d\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
