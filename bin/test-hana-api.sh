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

# curl のスタブ：実 API へ出ない。argv と標準入力を記録し、それらしい JSON を返す。
cat > "$T/fakebin/curl" <<'CURLEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/argv"
case " $* " in *" @- "*|*"--data-binary"*|*" -d "*) cat > "$REC/stdin" ;; esac
echo '{"success":true}'
CURLEOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

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
for c in create-todo update-todo update-note chatwork; do
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
# 読み取り系・書き込み系の**全14サブコマンド**を実際に走らせる
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

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
