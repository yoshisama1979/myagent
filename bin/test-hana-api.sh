#!/usr/bin/env bash
# bin/hana-api.sh（hana-tools API ラッパー・進行管理の一次情報）の回帰テスト。
#
# 契機＝2026-08-11、testing.md §7「無人ループが実行するツール 21本のうちテストが無い 13本」を
# 減らす作業の6本目。§2 の条件①③に当たる＝無人ループが読み取りで叩き、書き込み系は社長合意。
# 守りたい不変条件：
#   (1) **無人実行では書き込み系サブコマンドを物理的に拒否する**（automation.md の暴発防止）
#   (2) ID は数値だけ（URL パス/クエリへの注入防止）
#   (3) ユーザーフィルタ未指定時の既定 assignee_user_id が効く（null=作成者担当の正規化を拾うため）
#   (4) 検索キーワードを**コードへ文字列展開しない**
#       🔴 2026-08-11 検出：`php -r "echo rawurlencode('$keyword');"` は `'` 一つで
#          任意 PHP／シェル実行になっていた（環境変数経由へ修正済み。下のケースで固定）
#
# ⚠️ 実 API へは出ない（curl はスタブ）。トークンは架空の値だけを一時 .env に書く。
#    本番 .env・本番 API を触らないため、一時ディレクトリに偽プロジェクトを組んで実物をコピーする。
# 触ったら必ず流すこと：bash bin/test-hana-api.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/hana-api.sh" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fakebin" "$T/rec"
cp "$PROJ/bin/hana-api.sh" "$T/bin/hana-api.sh"

FAKE_TOKEN="hana-TESTONLY-token-0123"     # 架空
REC="$T/rec"; export REC
ACTIVE_FILE="$T/active.json"; export ACTIVE_FILE

# curl のスタブ：実 API へ出ない。argv と標準入力を記録し、それらしい JSON を返す。
cat > "$T/fakebin/curl" <<'CURLEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/argv"
# ★呼び出しを積む★＝1コマンドが2回 curl を呼ぶ経路（timer-stop＝実行中一覧→停止）で
#   「先に確認してから叩いたか」を見るため。argv は従来どおり**最後の1回**（既存テストは不変）。
printf '%s\n' "$*" >> "$REC/calls"
case " $* " in *" @- "*|*"--data-binary"*|*" -d "*) cat > "$REC/stdin" ;; esac
# timers/active だけは一覧の形で返す（FAKE_ACTIVE で差し替え可）。それ以外は従来どおり。
case " $* " in
  *timers/active*) if [ -n "${FAKE_ACTIVE:-}" ]; then printf '%s' "$FAKE_ACTIVE"; else cat "$ACTIVE_FILE"; fi ;;
  *) echo '{"success":true}' ;;
esac
CURLEOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# timers/active の既定の応答（FAKE_ACTIVE が無いときに使う）。既定ユーザー 7 のタイマー1本。
cat > "$T/active.json" <<'ACTEOF'
{"success":true,"data":[{"id":501,"user":{"id":7,"name":"テスト担当"},"work":{"id":3,"name":"案件A"},"running":true,"elapsed_minutes":12}]}
ACTEOF

P=0; N=0
say_ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
say_ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      → %s\n' "$2"; fi; }
has(){ case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-220)"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-220)"; else say_ok "$3"; fi; }
want_eq(){     if [ "$1" = "$2" ]; then say_ok "$3"; else say_ng "$3" "実際=[$1] 期待=[$2]"; fi; }

mk_env(){ printf '%s\n' "$@" > "$T/.env"; }
run(){ rm -f "$REC"/*; OUT="$(bash "$T/bin/hana-api.sh" "$@" 2>&1 </dev/null)"; RC=$?; }
argv(){ cat "$REC/argv" 2>/dev/null; }
url(){ argv | grep -E '^https?://' | head -1; }
calls(){ cat "$REC/calls" 2>/dev/null; }
ncalls(){ calls | grep -c . ; }

mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN" "HANA_TOOLS_BASE_URL=https://stg.example.test" \
       "HANA_TOOLS_DEFAULT_USER_ID=7"

echo "=== 起動前提 ==="
mv "$T/.env" "$T/.env.bak"; run clients
if [ "$RC" -ne 0 ]; then want_in ".env" "$OUT" ".env が無ければ JSON でエラーを返して止まる"; else say_ng ".env が無ければ止まる" "rc=$RC"; fi
mv "$T/.env.bak" "$T/.env"
mk_env "HANA_TOOLS_API_TOKEN="; run clients
if [ "$RC" -ne 0 ]; then say_ok "トークン未設定なら止まる"; else say_ng "トークン未設定なら止まる" "rc=$RC"; fi
mk_env "HANA_TOOLS_API_TOKEN=your-token-here"; run clients
if [ "$RC" -ne 0 ]; then say_ok "雛形のままのトークンを本物として使わない"; else say_ng "雛形トークンを弾く" "rc=$RC"; fi
mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN"
run clients
want_in "https://stg.hana-tools.com/api/external/clients" "$(url)" "BASE_URL 未設定なら既定を使う"
run nosuchcommand
want_eq "$RC" "1" "不明なコマンドは使い方を出して終了コード1"
want_in "hana-tools APIラッパー" "$OUT" "使い方を出す"

echo
echo "=== .env の読み取り（source しない・必要キーだけ）==="
mk_env "HANA_TOOLS_API_TOKEN=\"$FAKE_TOKEN\"" "HANA_TOOLS_BASE_URL='https://q.example.test'"
run clients
want_in "https://q.example.test/api/external/clients" "$(url)" "単引用符を外して読む"
want_in "X-API-TOKEN: $FAKE_TOKEN" "$(argv)" "二重引用符を外して読む"
printf 'HANA_TOOLS_API_TOKEN=%s\r\nHANA_TOOLS_BASE_URL=https://cr.example.test\r\n' "$FAKE_TOKEN" > "$T/.env"
run clients
want_in "https://cr.example.test/api/external/clients" "$(url)" "CRLF の末尾 CR を落とす"
mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN" "HANA_TOOLS_API_TOKEN=second-token"
run clients
want_in "X-API-TOKEN: $FAKE_TOKEN" "$(argv)" "重複キーは最初の1つを使う"
mk_env "  HANA_TOOLS_API_TOKEN=$FAKE_TOKEN"
run clients
want_in "X-API-TOKEN: $FAKE_TOKEN" "$(argv)" "行頭の空白があっても読める"
mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN" "HANA_TOOLS_BASE_URL=https://stg.example.test" \
       "HANA_TOOLS_DEFAULT_USER_ID=7"

echo
echo "=== ID の検証（URL への注入防止）==="
for c in "project abc" "project 1;rm" "project ../3" "project １" "project 1e3" "project -1"; do
  run $c
  if [ "$RC" -ne 0 ]; then say_ok "project $(echo "$c" | cut -d' ' -f2-) を弾く"; else say_ng "project の不正IDを弾く" "$c rc=$RC"; fi
done
run project
if [ "$RC" -ne 0 ]; then say_ok "project の ID 省略を弾く"; else say_ng "project の ID 省略を弾く"; fi
run project 42
want_in "/api/external/projects/42" "$(url)" "正しい ID は通る"
run projects --client_id=abc
if [ "$RC" -ne 0 ]; then say_ok "--client_id が数値でなければ弾く"; else say_ng "--client_id の検証" "rc=$RC"; fi
run projects --client_id=1 --client_id=2
if [ "$RC" -ne 0 ]; then say_ok "--client_id の二重指定を弾く（どちらが効いたか分からない状態を作らない）"; else say_ng "--client_id 二重指定" "rc=$RC"; fi
run notes 5 --user_id=abc
if [ "$RC" -ne 0 ]; then say_ok "notes の --user_id を検証する"; else say_ng "notes の --user_id 検証" "rc=$RC"; fi
run notes 5 --user_id=1 --user_id=2
if [ "$RC" -ne 0 ]; then say_ok "notes の --user_id 二重指定を弾く"; else say_ng "notes の --user_id 二重指定" "rc=$RC"; fi
run notes 5 --user_id=9
want_in "/api/external/projects/5/notes?user_id=9" "$(url)" "notes は shared＋個人メモを引ける"

echo
echo "=== ToDo の既定フィルタ（null=作成者担当の正規化を取りこぼさない）==="
run todos
want_in "assignee_user_id=7" "$(url)" "ユーザー系フィルタ未指定なら既定ユーザーを assignee に適用"
run todos --user_id=3
want_in "user_id=3" "$(url)" "--user_id 指定はそのまま使う"
want_not_in "assignee_user_id=7" "$(url)" "★明示指定があるときに既定を上書きで足さない"
run todos --assignee_user_id=3
want_not_in "assignee_user_id=7" "$(url)" "--assignee_user_id 指定時も既定を足さない"
run todos --work_id=9 --status=completed
want_in "work_id=9" "$(url)" "案件と状態で絞れる"
want_in "assignee_user_id=7" "$(url)" "案件フィルタだけならユーザー既定は効く"
u="$(url)"
if printf '%s' "$u" | grep -qE '\?[^?]*$' && ! printf '%s' "$u" | grep -q '?&'; then
  say_ok "クエリは先頭 ? で残りを & で繋ぐ（?& にならない）"; else say_ng "クエリ組み立て" "$u"; fi
mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN" "HANA_TOOLS_BASE_URL=https://stg.example.test"
run todos
want_not_in "assignee_user_id" "$(url)" "既定ユーザー未設定なら勝手に絞らない"
mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN" "HANA_TOOLS_BASE_URL=https://stg.example.test" \
       "HANA_TOOLS_DEFAULT_USER_ID=7"

echo
echo "=== 検索キーワード（★コマンドインジェクション）==="
run search
if [ "$RC" -ne 0 ]; then say_ok "キーワード省略を弾く"; else say_ng "キーワード省略を弾く" "rc=$RC"; fi
run search "はなさか"
want_in "clients/search?q=%E3%81%AF%E3%81%AA%E3%81%95%E3%81%8B" "$(url)" "日本語を rawurlencode する"
# 🔴→🟢 2026-08-11：`'` でコードから抜け出せていた（`php -r "…'$keyword'…"`）。
# 修正後は「引用符もただの文字」として素直にエンコードされるだけであること。
run search "x'); echo INJECTEDMARK; //"
want_not_in "INJECTEDMARK" "$OUT" "★注入コードが実行されない（標準出力に痕跡が出ない）"
want_in "%27" "$(url)" "★単引用符はエンコードされて値の一部として渡る"
want_in "clients/search?q=x%27%29%3B" "$(url)" "先頭からそのままエンコードされる"
run search "\$(touch $T/pwned)"
if [ -e "$T/pwned" ]; then say_ng "★コマンド置換が実行されない"; else say_ok "★コマンド置換が実行されない"; fi
run search 'a,b'
want_in "q=a%2Cb" "$(url)" "カンマ区切り（OR検索）も値としてエンコード"

echo
echo "=== 無人実行での書き込み拒否（automation.md）==="
for c in create-todo update-todo update-note chatwork work-billing timer-start timer-stop; do
  rm -f "$REC"/*
  OUT="$(MYAGENT_UNATTENDED=1 bash "$T/bin/hana-api.sh" "$c" 1 '{"a":1}' 2>&1 </dev/null)"; RC=$?
  if [ "$RC" -eq 2 ] && [ ! -f "$REC/argv" ]; then
    say_ok "無人実行では $c を拒否する（API を叩かない）"
  else say_ng "無人実行では $c を拒否する" "rc=$RC argv=$(argv | head -1)"; fi
done
rm -f "$REC"/*
OUT="$(MYAGENT_UNATTENDED=1 bash "$T/bin/hana-api.sh" clients 2>&1 </dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$REC/argv" ]; then say_ok "無人実行でも読み取りは通す"; else say_ng "無人実行でも読み取りは通す" "rc=$RC"; fi

echo
echo "=== 書き込み系の引数チェック（有人時）==="
run create-todo
if [ "$RC" -ne 0 ]; then say_ok "create-todo は JSON 必須"; else say_ng "create-todo は JSON 必須" "rc=$RC"; fi
run update-todo 5
if [ "$RC" -ne 0 ]; then say_ok "update-todo は id と JSON の両方が必要"; else say_ng "update-todo の引数チェック" "rc=$RC"; fi
run update-todo abc '{"x":1}'
if [ "$RC" -ne 0 ]; then say_ok "update-todo の id を検証する"; else say_ng "update-todo の id 検証" "rc=$RC"; fi
run update-note 5
if [ "$RC" -ne 0 ]; then say_ok "update-note は project_id と JSON の両方が必要"; else say_ng "update-note の引数チェック" "rc=$RC"; fi
SQ="$(printf '\047')"                     # 単引用符（本文に混ざっても壊れないことを見る）
JSON_BODY="$(printf '{"content":"日本語の%s内容"}' "$SQ")"
run update-todo 5 "$JSON_BODY"
want_eq "$(cat "$REC/stdin" 2>/dev/null)" "$JSON_BODY" "JSON 本文を改変せず標準入力で渡す"
want_in "PUT" "$(argv)" "update-todo は PUT"
run create-todo '{"work_id":3}'
want_in "POST" "$(argv)" "create-todo は POST"
want_in "Content-Type: application/json" "$(argv)" "JSON として送る"

echo
echo "=== 秘密の扱い ==="
run clients
want_not_in "$FAKE_TOKEN" "$OUT" "トークンを標準出力・エラー出力に出さない"
# 注：本ツールはトークンを -H でコマンドライン引数に載せる（mailbox.sh の --config 方式と違い
#     ps / /proc から見え得る）。挙動を変える判断は社長案件のため、ここでは固定せず起票する。

echo
echo "=== 通信の安全（証明書の検証）==="
# 🔴 2026-08-17 検出：全12箇所の curl が `-k`（--insecure）付きで、TLS 証明書の検証を
#    切ったまま **API トークンを載せて** 送っていた＝経路上の偽サーバにトークンを渡し得る。
#    「1本直しても他11本が残る」形なので、①実行時の argv ②ソース全体 の両方で固定する。
#    ⚠️ ここを緑に保つ条件＝証明書が実際に検証を通ること（2026-08-17 実測：通る）。
#    将来 `-k` を戻したくなったら、それは証明書側の異常であり、隠さず直すこと。
#
# ⚠️ 初版（同日・Codex クロスレビューで否決）は2点とも緩く、mutation が素通りした：
#   (a) 実行時の検査を `grep -qxE -- '-k|--insecure'`（行の完全一致）でやったため
#       **`curl -sk` / `-ks` のような結合フラグを取りこぼす**（curl は結合形を受理する）
#   (b) ソース検査を行単位の grep でやったため、**行継続で分けて書かれた `-k` を取りこぼす**
#         curl -s \
#           -k -X GET "$BASE_URL/..." \
#   (c) さらに実行させていたのが `clients` 1本だけで、**残り11経路は誰も見ていなかった**
#     ＝「1本直せば残り11本も直っている」という、まさに今回の穴と同じ思い込み。
#   → いずれも実測で再現済み（ヒット0）。下の形に組み直した。
# 「証明書の検証を切るフラグ」の定義は **1箇所だけ** 持つ（実行時検査とソース検査で
# 別々に書くと必ず片方だけ腐る＝このリポジトリで繰り返した失敗の型）。
# 標準入力は1行1トークン。該当が1つでもあれば 0 を返す。
insecure_arg() {
  awk '$0=="--insecure" || $0 ~ /^-[a-zA-Z]*k[a-zA-Z]*$/ { found=1 } END { exit found?0:1 }'
}
assert_secure() {  # 1経路ぶん実行し、curl に渡った argv を検査する
  local label="$1"; shift
  run "$@"
  if argv | insecure_arg; then
    say_ng "証明書の検証を切らない：$label" "$(argv | tr '\n' ' ' | cut -c1-200)"
  else
    say_ok "証明書の検証を切らない：$label"
  fi
}
# 読み取り系・書き込み系の**全20サブコマンド**を実際に走らせる
# （run は MYAGENT_UNATTENDED を立てない＝有人扱いなので、書き込み系もここでは通る）
assert_secure "clients"       clients
assert_secure "search"        search "テスト"
assert_secure "outsources"    outsources
assert_secure "office-status" office-status
assert_secure "todos"         todos
assert_secure "projects"      projects
assert_secure "project"       project 1
assert_secure "notes"         notes 1
assert_secure "create-todo"   create-todo '{"content":"x"}'
assert_secure "update-todo"   update-todo 1 '{"content":"x"}'
assert_secure "update-note"   update-note 1 '{"note":"x"}'
assert_secure "chatwork"      chatwork '{"body":"x"}'
assert_secure "create-project" create-project '{"project_name":"x","client_id":1}'
assert_secure "create-work"    create-work '{"name":"x","project_id":1}'
assert_secure "unbilled"      unbilled
assert_secure "work-billing"  work-billing 1 '{"billing_status":"billed"}'
assert_secure "docs"          docs
assert_secure "timers"        timers
assert_secure "timer-start"   timer-start --work_id=3
assert_secure "timer-stop"    timer-stop 501

# ソース検査：**行継続をつないでから**、curl を含む行を空白で割ってトークン単位で見る。
#   ・つながないと `curl -s \` / `  -k -X GET …` のように**分けて書かれた -k** を逃す
#   ・トークンに割らないと `-X POST ".../chatwork/…"` の k を誤検知する（初版で実際に踏んだ）
curl_flags() {
  sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}' "$PROJ/bin/hana-api.sh" \
    | grep -F 'curl' | tr -s ' \t' '\n\n'
}
if curl_flags | insecure_arg; then
  say_ng "ソース全体に curl の証明書検証オフが1つも残っていない" \
         "$(curl_flags | awk '$0=="--insecure" || $0 ~ /^-[a-zA-Z]*k[a-zA-Z]*$/' | head -3 | tr '\n' ' ')"
else
  say_ok "ソース全体に curl の証明書検証オフが1つも残っていない"
fi

# 平文 HTTP も同じ穴（-k を消してもトークンは平文で流れる）＝BASE_URL は https のみ通す
mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN" "HANA_TOOLS_BASE_URL=http://stg.example.test" \
       "HANA_TOOLS_DEFAULT_USER_ID=7"
run clients
if [ "$RC" -ne 0 ] && [ -z "$(url)" ]; then
  say_ok "BASE_URL が http:// なら API を叩かずに落とす（トークンの平文送信を防ぐ）"
else
  say_ng "BASE_URL が http:// なら API を叩かずに落とす" "rc=$RC url=$(url)"
fi
want_not_in "$FAKE_TOKEN" "$OUT" "http:// で落とすときもトークンを出力しない"
mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN" "HANA_TOOLS_BASE_URL=https://stg.example.test" \
       "HANA_TOOLS_DEFAULT_USER_ID=7"

# --- create-project / create-work（2026-08-20 追加） --------------------------
# ★ここを守りたい★＝どちらも「類似名があれば登録せず requires_confirmation を返す」API。
#   200 で success:false が返るので、**成功扱いにも失敗リトライにもしない**のが要点。
#   ラッパー側でできるのは (a) 引数が無いときに叩かない (b) 本文をそのまま渡す (c) 送り先が正しい。
echo
echo "--- create-project / create-work ---"

run create-project
want_eq "$RC" "1" "create-project：JSON 無しで叩かない"
want_in "使い方: create-project" "$OUT" "create-project：使い方を示す"
want_eq "$(url)" "" "create-project：JSON 無しのとき API を叩かない"

run create-work
want_eq "$RC" "1" "create-work：JSON 無しで叩かない"
want_in "使い方: create-work" "$OUT" "create-work：使い方を示す"
want_eq "$(url)" "" "create-work：JSON 無しのとき API を叩かない"

run create-project '{"project_name":"テスト","client_id":1}'
want_in "/api/external/projects" "$(url)" "create-project：projects へ POST する"
want_in "POST" "$(argv | tr '\n' ' ')" "create-project：メソッドは POST"
want_in '"project_name":"テスト"' "$(cat "$REC/stdin" 2>/dev/null)" "create-project：本文をそのまま送る"

run create-work '{"name":"テスト案件","project_id":12}'
want_in "/api/external/works" "$(url)" "create-work：works へ POST する"
want_in "POST" "$(argv | tr '\n' ' ')" "create-work：メソッドは POST"
want_in '"project_id":12' "$(cat "$REC/stdin" 2>/dev/null)" "create-work：本文をそのまま送る"

# 本文は --data-binary で渡す＝`-d` は改行を落とすため、note や message の改行が壊れる
want_in "data-binary" "$(argv | tr '\n' ' ')" "create-work：本文は --data-binary で渡す（改行を壊さない）"

# --- 請求チェック（2026-10-07 追加・社長指示でエンドポイント新設） ---------------
# ★ここを守りたい★＝`billing_status` は **一度書くと未記録(null)へ戻せない**。
#   取り返しがつかない書き込みなので、ラッパーで固定できることを全部固定する：
#   (a) 無人実行では叩かない（上の拒否ループで確認済み）
#   (b) work_id は数値だけ（URL パスへの注入防止）
#   (c) **トップレベルの billing_status が3値でなければ API を叩かない**（叩いてから 422 ではない）
#   (d) 本文を改変せずそのまま送る（billing_note の文字が落ちない）
#   (e) 未請求一覧は読み取りで、余計なクエリを付けない
#
# ⚠️ (c) は初版で**正規表現の包含検査にしていて、2通りの危険な入力を通していた**
#    （2026-10-07 コミット前 Codex レビュー🔴）＝重複キーとネスト。どちらも
#    「**検査した値と実際に書かれる値が違う**」形で、この項目では最悪の壊れ方になる。
#    下の「構造の反例」はその再発防止なので、**JSON パーサを介さない実装に戻したら必ず落ちる**。
API="https://stg.example.test/api/external"
want_argv(){ if argv | grep -Fxq -- "$1"; then say_ok "$2"; else say_ng "$2" "$(argv | tr '\n' ' ' | cut -c1-200)"; fi; }
# 「API を叩く前に落ちた」＝非0終了かつ curl が一度も呼ばれていないこと。この節で10回使う判定。
# $2 を渡すと不合格時のラベルだけ差し替える（合格時のラベルは $1 のまま＝項目名を変えない）。
want_rejected(){ if [ "$RC" -ne 0 ] && [ -z "$(url)" ]; then say_ok "$1"; else say_ng "${2:-$1}" "rc=$RC url=$(url)"; fi; }

echo
echo "--- 請求チェック（unbilled / work-billing） ---"

run unbilled
want_eq "$(url)" "$API/works/unbilled" "unbilled：works/unbilled を叩く（URL 完全一致・余計なクエリもパスも足さない）"
want_argv "GET" "unbilled：メソッドは GET（完全一致）"

run work-billing
want_eq "$RC" "1" "work-billing：引数なしで叩かない"
want_in "使い方: work-billing" "$OUT" "work-billing：使い方を示す"
want_eq "$(url)" "" "work-billing：引数なしのとき API を叩かない"

run work-billing 5
want_eq "$RC" "1" "work-billing：work_id だけでは叩かない（JSON 必須）"
want_eq "$(url)" "" "work-billing：JSON 無しのとき API を叩かない"

for bad in abc "1;rm" "../3" "１" "1e3" "-1"; do
  run work-billing "$bad" '{"billing_status":"billed"}'
  want_rejected "work-billing：work_id=$bad を弾く（API を叩かない）" "work-billing：work_id の検証"
done

# ★取り返しがつかない値なので、3値以外は手元で落とす（叩いてから 422 ではない）
for bad in '{"billing_status":"paid"}' '{"billing_status":"Billed"}' '{"billing_status":""}' \
           '{"billing_status":null}' '{"billed_on":"2026-10-07"}' '{}' ; do
  run work-billing 5 "$bad"
  want_rejected "work-billing：$bad を手元で落とす（API を叩かない）" "work-billing：3値以外を落とす"
done
want_in "unbilled / billed / not_required" "$OUT" "work-billing：受け付ける3値をメッセージに出す"
want_in "戻せません" "$OUT" "work-billing：null に戻せないことをメッセージで知らせる"

# ★★ 構造の反例（🔴 の再発防止）★★
# 正規表現の包含検査に戻すと、下の1〜2番目は「通ってしまう」＝検査した値と書かれる値が食い違う。
echo "  （構造の反例＝正規表現の包含検査では守れないもの）"
run work-billing 5 '{"billing_status":"unbilled","billing_status":"billed"}'
want_rejected "★重複キーを落とす（先頭を検査して後勝ちで書かれる事故を防ぐ）" "★重複キーを落とす"
want_in "同じ項目が2回" "$OUT" "★重複キーだと分かるメッセージを出す"

run work-billing 5 '{"billing_status":"billed","billing_status":"paid"}'
want_rejected "★重複キー（許可値→不正値の順）も落とす" "★重複キー（許可値→不正値の順）"

run work-billing 5 '{"billing_status":"paid","meta":{"billing_status":"billed"}}'
want_rejected "★入れ子の中の billing_status をトップレベルと読み違えない" "★入れ子を読み違えない"

run work-billing 5 '{"meta":{"billing_status":"billed"}}'
want_rejected "★入れ子だけに billing_status がある本文を通さない" "★入れ子だけの本文を通さない"

run work-billing 5 '{"billing_note":"\"billing_status\":\"billed\""}'
want_rejected "★billing_note の中の文字列を値と読み違えない" "★billing_note の中の文字列を読み違えない"

run work-billing 5 '{"billing_status":"billed"'
want_rejected "★壊れた JSON を叩く前に落とす" "★壊れた JSON を落とす"
want_in "JSON として読めません" "$OUT" "★壊れた JSON だと分かるメッセージを出す"

run work-billing 5 '[{"billing_status":"billed"}]'
want_rejected "★ルートが配列の本文を落とす"
# 理由まで固定する＝ルート検査を外しても「billing_status が無い」側で偶然落ちるため、
# 落ちたことだけ見ると検査を外した変異が素通りする（mutation で実際に素通りした）
want_in "JSON オブジェクト" "$OUT" "★ルートが配列なら『オブジェクトで渡して』と言う（理由まで固定）"

run work-billing 5 '{"billing_status":["billed"]}'
want_rejected "★値が文字列でない（配列）本文を落とす" "★値が文字列でない本文を落とす"

# ★正当な本文は通る（禁止の検証と対で「通すべきものが通る」を必ず持つ＝testing.md §7）
for good in unbilled billed not_required; do
  run work-billing 5 "{\"billing_status\":\"$good\"}"
  want_eq "$(url)" "$API/works/5/billing" "work-billing：$good は通る（URL 完全一致）"
done
want_argv "PUT" "work-billing：メソッドは PUT（完全一致）"
want_argv "--data-binary" "work-billing：本文は --data-binary で渡す（完全一致）"

# 空白入りの整形済み JSON でも通る（手で書いた本文を無駄に弾かない）
run work-billing 5 '{ "billing_status" : "not_required" , "billing_note" : "先方都合で無償対応" }'
want_eq "$(url)" "$API/works/5/billing" "work-billing：空白入りの JSON でも通す"

# 本文は改変せず渡す（billing_note の日本語・単引用符が落ちない）
BILL_BODY="$(printf '{"billing_status":"not_required","billing_note":"%s無償対応%s"}' "$SQ" "$SQ")"
run work-billing 7 "$BILL_BODY"
want_eq "$(cat "$REC/stdin" 2>/dev/null)" "$BILL_BODY" "work-billing：JSON 本文を改変せず標準入力で渡す"
want_eq "$(url)" "$API/works/7/billing" "work-billing：work_id が URL に入る"

# 読み取りは無人でも通す（未請求の棚卸しは読むだけなら安全）
rm -f "$REC"/*
OUT="$(MYAGENT_UNATTENDED=1 bash "$T/bin/hana-api.sh" unbilled 2>&1 </dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$REC/argv" ]; then say_ok "無人実行でも unbilled（読み取り）は通す"
else say_ng "無人実行でも unbilled は通す" "rc=$RC"; fi

# ヘルプに「null は未請求ではない」が書かれていること（誤報の型を文書で止める）
run nosuchcommand
want_in "unbilled" "$OUT" "使い方に unbilled が載っている"
want_in "work-billing" "$OUT" "使い方に work-billing が載っている"
want_in "null（記録なし）は未請求ではない" "$OUT" "★使い方に「null は未請求ではない」注意がある"
want_in "戻せません" "$OUT" "★使い方に「null には戻せない」注意がある"

# --- 作業タイマー（2026-10-08 追加・仕様＝docs §21）---------------------------
# ★ここを守りたい★＝**記録した時間はそのまま実績（損益計算・見積の根拠）に入る**。
#   しかも仕様上 **停止には所有者チェックが無い**（トークンがあれば誰のタイマーでも止められる）。
#   ＝「取り違えて他人のタイマーを止める」「持ち主を誤って他人の実績に時間を積む」が
#   APIの側では防がれていないので、**ラッパーで落とせるものは全部落とす**。
#   実測の背景＝10/05 から2本が止め忘れで動き続け、70時間を超えていた（合計の88%が止め忘れ由来）。
echo
echo "--- 作業タイマー（timers / timer-start / timer-stop） ---"

run timers
want_eq "$(url)" "$API/timers/active" "timers：timers/active を叩く（URL 完全一致）"
want_argv "GET" "timers：メソッドは GET（完全一致）"

run timers --user_id=9
want_eq "$(url)" "$API/timers/active?user_id=9" "timers：--user_id で絞れる"
for bad in abc "9;rm" "-1" "１"; do
  run timers "--user_id=$bad"
  if [ "$RC" -ne 0 ] && [ -z "$(url)" ]; then say_ok "timers：--user_id=$bad を弾く（API を叩かない）"
  else say_ng "timers：--user_id の検証" "$bad rc=$RC url=$(url)"; fi
done
run timers --user_id=1 --user_id=2
want_rejected "timers：--user_id の二重指定を弾く"
run timers --nosuch=1
want_rejected "timers：知らないオプションを黙って無視しない"

echo "  （timer-start＝持ち主と案件の取り違えを手元で落とす）"
run timer-start
want_rejected "timer-start：--work_id なしで叩かない"
want_in "案件 work 単位" "$OUT" "timer-start：案件単位だと分かるメッセージを出す"
for bad in abc "3;rm" "../3" "1e3" "-1" "３"; do
  run timer-start "--work_id=$bad"
  want_rejected "timer-start：--work_id=$bad を弾く（API を叩かない）" "timer-start：--work_id の検証"
done
run timer-start --work_id=3 --user_id=abc
want_rejected "timer-start：--user_id が数値でなければ弾く"
# 理由まで固定する＝require_int を外しても python の int() で落ちるので、
# 落ちたことだけ見ると「検証を外す」変異が素通りする（mutation で実際に素通りした）
want_in "数値で指定してください" "$OUT" "★timer-start：--user_id は手元の検証で落とす（例外任せにしない）"
run timer-start --work_id=3 --nosuch=x
want_rejected "timer-start：知らないオプションを黙って無視しない"

run timer-start --work_id=3
want_eq "$(url)" "$API/timers/start" "timer-start：timers/start へ送る（URL 完全一致）"
want_argv "POST" "timer-start：メソッドは POST（完全一致）"
want_argv "--data-binary" "timer-start：本文は --data-binary で渡す（完全一致）"
# ★既定ユーザー（.env の HANA_TOOLS_DEFAULT_USER_ID=7）が入る＝持ち主なしで投げない
printf '%s' "$(cat "$REC/stdin" 2>/dev/null)" | python3 -c '
import json,sys
b=json.load(sys.stdin)
assert b=={"user_id":7,"work_id":3}, b
' && say_ok "★timer-start：user_id は .env の既定・値は整数・余計な項目を入れない" \
  || say_ng "★timer-start の本文が違う" "$(cat "$REC/stdin" 2>/dev/null)"

run timer-start --work_id=3 --user_id=12
printf '%s' "$(cat "$REC/stdin" 2>/dev/null)" | python3 -c '
import json,sys
b=json.load(sys.stdin); assert b["user_id"]==12, b
' && say_ok "timer-start：--user_id を明示すればそちらを使う" || say_ng "--user_id が効かない"

# ★description は JSON として組み立てる＝引用符・改行・日本語で壊れない
#   （文字列結合で作ると `"` 一つで本文が壊れ、422 の理由が分からなくなる）
DESC="$(printf '【A社】"大至急"の件\n2行目 %s' "$SQ")"
run timer-start --work_id=3 "--description=$DESC"
printf '%s' "$(cat "$REC/stdin" 2>/dev/null)" | HANA_T_EXP="$DESC" python3 -c '
import json,sys,os
b=json.load(sys.stdin)
assert b["description"]==os.environ["HANA_T_EXP"], (b.get("description"), os.environ["HANA_T_EXP"])
' && say_ok "★timer-start：description の引用符・改行・日本語をそのまま運ぶ（JSON で組む）" \
  || say_ng "★description が壊れている" "$(cat "$REC/stdin" 2>/dev/null)"
run timer-start --work_id=3
printf '%s' "$(cat "$REC/stdin" 2>/dev/null)" | python3 -c '
import json,sys
assert "description" not in json.load(sys.stdin)
' && say_ok "timer-start：description を渡さなければ項目を作らない" || say_ng "空の description を送っている"

# 既定ユーザーが無い環境では**持ち主なしで叩かない**（他人の実績に積む事故を防ぐ）
mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN" "HANA_TOOLS_BASE_URL=https://stg.example.test"
run timer-start --work_id=3
want_rejected "★timer-start：既定ユーザーが無ければ叩かない（持ち主を誤ると他人の実績になる）"
want_in "他人の実績" "$OUT" "★なぜ止めたかを言う（持ち主の取り違えの危険）"
mk_env "HANA_TOOLS_API_TOKEN=$FAKE_TOKEN" "HANA_TOOLS_BASE_URL=https://stg.example.test" \
       "HANA_TOOLS_DEFAULT_USER_ID=7"

echo "  （timer-stop＝停止に所有者チェックが無いAPIを、手元の確認で補う）"
run timer-stop
want_rejected "timer-stop：id なしで叩かない"
for bad in abc "501;rm" "-1"; do
  run timer-stop "$bad"
  want_rejected "timer-stop：id=$bad を弾く（API を叩かない）" "timer-stop：id の検証"
done

# ★正常系：実行中一覧で持ち主を確かめてから停止する（2回呼ぶ・順序も固定）
run timer-stop 501
want_eq "$(url)" "$API/timers/501/stop" "timer-stop：timers/{id}/stop へ送る（URL 完全一致）"
want_argv "POST" "timer-stop：メソッドは POST（完全一致）"
want_eq "$(ncalls)" "2" "★timer-stop：確認と停止で2回呼ぶ（確認を省かない）"
calls | head -1 | grep -q 'timers/active' \
  && say_ok "★timer-stop：**先に**実行中一覧で持ち主を確かめる（仕様書が呼び出し側の責務とする手順）" \
  || say_ng "★確認より先に停止を叩いている" "$(calls | head -2 | tr '\n' ' ' | cut -c1-200)"

# ★実行中に無い id は停止を叩かない（停止済み・存在しない＝API では 400/404）
run timer-stop 999
if [ "$RC" -ne 0 ] && [ "$(calls | grep -c 'timers/999/stop')" = "0" ]; then
  say_ok "★timer-stop：実行中に無い id は停止を叩かない（既に停止済み／存在しない）"
else say_ng "★実行中に無い id で停止を叩いた" "rc=$RC calls=$(calls | tr '\n' ' ' | cut -c1-200)"; fi
want_in "実行中の一覧にありません" "$OUT" "timer-stop：理由を言う（timers で確かめる案内つき）"

# ★他人のタイマーは明示がなければ止めない（仕様上 API は止められてしまう）
rm -f "$REC"/*
OUT="$(FAKE_ACTIVE='{"success":true,"data":[{"id":501,"user":{"id":99,"name":"別の担当"},"work":{"id":3,"name":"案件A"},"running":true,"elapsed_minutes":5}]}' \
       bash "$T/bin/hana-api.sh" timer-stop 501 2>&1 </dev/null)"; RC=$?
if [ "$RC" -ne 0 ] && [ "$(calls | grep -c '501/stop')" = "0" ]; then
  say_ok "★timer-stop：持ち主が違うタイマーは停止を叩かない（取り違えを手元で落とす）"
else say_ng "★他人のタイマーを止めた" "rc=$RC calls=$(calls | tr '\n' ' ' | cut -c1-200)"; fi
case "$OUT" in *"--user_id=99"*) say_ok "★持ち主の user_id を示して、明示すれば止められると案内する" ;;
  *) say_ng "★持ち主の案内が無い" "$OUT" ;; esac
rm -f "$REC"/*
OUT="$(FAKE_ACTIVE='{"success":true,"data":[{"id":501,"user":{"id":99,"name":"別の担当"},"work":{"id":3,"name":"案件A"},"running":true,"elapsed_minutes":5}]}' \
       bash "$T/bin/hana-api.sh" timer-stop 501 --user_id=99 2>&1 </dev/null)"; RC=$?
[ "$(calls | grep -c '501/stop')" = "1" ] \
  && say_ok "★--user_id を明示すれば他の方のタイマーも止められる（通すべきものは通す）" \
  || say_ng "★明示しても止められない" "rc=$RC calls=$(calls | tr '\n' ' ' | cut -c1-200)"

# ★一覧が読めないときは停止しない（fail-closed）＝持ち主を確かめられないまま実績を確定させない
rm -f "$REC"/*
OUT="$(FAKE_ACTIVE='これはJSONではない' bash "$T/bin/hana-api.sh" timer-stop 501 2>&1 </dev/null)"; RC=$?
if [ "$RC" -ne 0 ] && [ "$(calls | grep -c '501/stop')" = "0" ]; then
  say_ok "★timer-stop：一覧が読めなければ停止しない（確かめられないまま実績を確定させない）"
else say_ng "★一覧が読めないのに停止した（fail-open）" "rc=$RC calls=$(calls | tr '\n' ' ' | cut -c1-200)"; fi
rm -f "$REC"/*
OUT="$(FAKE_ACTIVE='{"success":false,"message":"認証エラー"}' bash "$T/bin/hana-api.sh" timer-stop 501 2>&1 </dev/null)"; RC=$?
if [ "$RC" -ne 0 ] && [ "$(calls | grep -c '501/stop')" = "0" ]; then
  say_ok "★timer-stop：一覧が success:false なら停止しない（認証切れを『実行中なし』と読まない）"
else say_ng "★success:false を無視して停止した" "rc=$RC"; fi
# 理由まで固定する＝形の検査を外しても d["data"] の KeyError で落ちるため、
# 落ちたことだけ見ると変異が素通りする（mutation で実際に素通りした）。
# 例外任せにすると、応答の形が変わった日に「なぜ止まったか」が読めなくなる。
want_in "持ち主を確かめられない" "$OUT" "★timer-stop：止めた理由を言う（例外任せにしない）"

# 読み取りは無人でも通す／書き込みは通さない（上の拒否ループと対）
rm -f "$REC"/*
OUT="$(MYAGENT_UNATTENDED=1 bash "$T/bin/hana-api.sh" timers 2>&1 </dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$REC/argv" ]; then say_ok "無人実行でも timers（読み取り）は通す"
else say_ng "無人実行でも timers は通す" "rc=$RC"; fi

# 使い方に「実績に入る」警告が出ている（文書を消したらテストが落ちる）
run nosuchcommand
want_in "timer-start" "$OUT" "使い方に timer-start が載っている"
want_in "timer-stop" "$OUT" "使い方に timer-stop が載っている"
want_in "timers" "$OUT" "使い方に timers が載っている"
want_in "実績（損益計算・見積の根拠）" "$OUT" "★使い方に『時間はそのまま実績に入る』警告がある"
want_in "所有者チェックが無い" "$OUT" "★使い方に『停止に所有者チェックが無い』注意がある"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
