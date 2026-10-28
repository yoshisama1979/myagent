#!/usr/bin/env bash
# ルールの「取りに来させる」経路の回帰テスト。
#
# 対象は3つ：
#   (1) bin/rules-publish.py          配ってよい版を公開する（配布物・版・変更点を作る）
#   (2) site/tools/rules/index.php    受け口（読み取り専用・テンプレはトークンに紐づく）
#   (3) claude-rules/*/bin/rules-update.sh  現場が取りに来て適用する
#
# 守りたい不変条件：
#   - **案件の記録を消さない**（documents/・project-config.md・.claude/rules/private.md 等）
#   - 人の確認なしに書き換わらない（既定は確認だけ・--apply で初めて書く）
#   - 上書きで未コミットの変更を黙って消さない（git があれば止める・退避は必ず作る）
#   - 失効・期限・紐づけたテンプレ以外は 403（投函側と同じホワイトリストが効く）
#   - 壊れた取得を適用しない（SHA256 照合）
#   - 両テンプレの rules-update.sh が同一（片方だけ直すとズレる）
#   - 配布後に現場で書き足した配布ファイルを、上書きで黙って消さない（控えと比べて名指し・--apply は止まる）
#
# ⚠️ 本番の data/secrets/・data/cache/ には触れない：/tmp に偽プロジェクトを組み、
#    スクリプトと index.php の実物をコピーして流す。トークンは架空の値だけを使う。
# 触ったら必ず流すこと：bash bin/test-rules-update.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/rules-publish.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }
command -v php >/dev/null || { echo "❌ php が見つかりません" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
SRV_PID=""
cleanup(){ [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

P=0; N=0
say_ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
say_ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      → %s\n' "$2"; fi; }
has(){ case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; else say_ok "$3"; fi; }
want_eq(){     if [ "$1" = "$2" ]; then say_ok "$3"; else say_ng "$3" "実際=[$1] 期待=[$2]"; fi; }

# ── 偽の myagent（配る側）を組む ─────────────────────────────────────────
mkdir -p "$T/bin" "$T/site/tools/rules" "$T/site/tools/lib" "$T/data/secrets" "$T/data/mailbox/.state"
cp "$PROJ/bin/rules-publish.py" "$PROJ/bin/distribute-rules.py" "$T/bin/"
cp "$PROJ/site/tools/rules/index.php" "$T/site/tools/rules/index.php"
cp "$PROJ/site/tools/lib/token-auth.php" "$T/site/tools/lib/token-auth.php"

mk_template(){  # $1=テンプレ名 $2=CLAUDE.md の中身
  mkdir -p "$T/claude-rules/$1/rules/modes" "$T/claude-rules/$1/documents" \
           "$T/claude-rules/$1/.claude/rules" "$T/claude-rules/$1/bin"
  printf '%s\n' "$2" > "$T/claude-rules/$1/CLAUDE.md"
  printf 'ルール層（上書きされる）\n'      > "$T/claude-rules/$1/rules/modes/developer.md"
  printf '引き継ぎの雛形\n'                > "$T/claude-rules/$1/documents/handoff.md"
  printf '案件固有の設定（雛形）\n'        > "$T/claude-rules/$1/project-config.md"
  printf '環境の癖（雛形）\n'              > "$T/claude-rules/$1/.claude/rules/private.md"
  printf '設計の雛形\n'                    > "$T/claude-rules/$1/Design.sample.md"
}
# 共通層。現場スクリプトは common に1本だけ置く（面レイヤーにコピーを作らない＝本物と同じ形）
mk_common(){
  mkdir -p "$T/claude-rules/common/bin" "$T/claude-rules/common/rules/modes"
  cp "$PROJ/claude-rules/common/bin/rules-update.sh" "$T/claude-rules/common/bin/rules-update.sh"
  printf '共通のルール（上書きされる）\n' > "$T/claude-rules/common/rules/modes/rules-update.md"
}
mk_template website  "ルール第1版"
mk_template websystem "システム側 第1版"
mk_common
# 配る単位（プロファイル＝層の組み合わせ）の定義。**本物をそのまま使う**＝偽リポジトリで
# 別の一覧を作ると、本物の定義が壊れていてもこのテストは通ってしまう。
cp "$PROJ/claude-rules/profiles.json" "$T/claude-rules/profiles.json"

git -C "$T" init -q 2>/dev/null
git -C "$T" config user.email t@example.com; git -C "$T" config user.name t
git -C "$T" add -A >/dev/null; git -C "$T" commit -qm "初版のルール" >/dev/null

echo "── 公開（bin/rules-publish.py）"
OUT="$(cd "$T" && python3 bin/rules-publish.py status 2>&1)"
want_in "未公開" "$OUT" "公開前は「未公開」と出る"

printf 'ルール第1版（未コミットの加筆）\n' >> "$T/claude-rules/website/CLAUDE.md"
OUT="$(cd "$T" && python3 bin/rules-publish.py publish website 2>&1)"; RC=$?
want_eq "$RC" "1" "未コミットの変更があると公開しない"
want_in "未コミット" "$OUT" "止まった理由を言う"
git -C "$T" checkout -- claude-rules/website/CLAUDE.md

# 🚨 profiles.json（層の組み合わせの定義）も配布物の中身を決める。層を1つ足した・順序を変えた
# のに版が進まないと、受け取り側が「自分の版より後の変更」を辿れず判定が嘘になる。
# 2026-10-28 の Codex レビューで、版の対象集合が層ディレクトリだけだったことが判明した。
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p,encoding="utf-8")); d["profiles"]["website"]=["common","website"]; json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)' "$T/claude-rules/profiles.json"
OUT="$(cd "$T" && python3 bin/rules-publish.py publish website 2>&1)"; RC=$?
want_eq "$RC" "1" "profiles.json だけを変えても「未コミット」で止まる（層の構成も版の一部）"
want_in "profiles.json" "$OUT" "止まった理由に profiles.json が出る"
git -C "$T" checkout -- claude-rules/profiles.json

OUT="$(cd "$T" && python3 bin/rules-publish.py publish website 2>&1)"
want_in "配信する版を更新しました" "$OUT" "公開できる"
V1="$(cd "$T" && python3 -c 'import json;print(json.load(open("data/cache/rules-release/website/meta.json"))["version"])')"
want_in "website@" "$V1" "版に版番号が入る"
[ -f "$T/data/cache/rules-release/website/package.tar.gz" ] && say_ok "配布物ができる" || say_ng "配布物ができる"
[ -s "$T/data/cache/rules-release/website/changelog.tsv" ] && say_ok "変更点の一覧ができる" || say_ng "変更点の一覧ができる"

INSIDE="$(tar tzf "$T/data/cache/rules-release/website/package.tar.gz")"
want_in "website/.claude/rules-version" "$INSIDE" "配布物に版が刻まれている"
want_in "website/.claude/rules-keep" "$INSIDE" "配布物に「守るファイル」の一覧が入る"
KEEP="$(tar xzf "$T/data/cache/rules-release/website/package.tar.gz" -O website/.claude/rules-keep)"
want_in "documents/" "$KEEP" "守るファイルに案件の記録が入る"

ACT="$(sha256sum "$T/data/cache/rules-release/website/package.tar.gz" | cut -d' ' -f1)"
EXP="$(cd "$T" && python3 -c 'import json;print(json.load(open("data/cache/rules-release/website/meta.json"))["sha256"])')"
want_eq "$ACT" "$EXP" "meta の SHA256 が実物と一致する"

OUT="$(cd "$T" && python3 bin/rules-publish.py status 2>&1)"
want_in "$V1" "$OUT" "status に公開中の版が出る"

# ── 受け口（php -S） ─────────────────────────────────────────────────────
FUTURE="$(date -d '+30 day' +%F)"; PAST="$(date -d '-1 day' +%F)"
cat > "$T/data/secrets/mailbox-tokens.json" <<JSONEOF
{
  "tk-web":     { "agent_id": "rr-web",  "role": "reporter", "reporter_id": "RR-001", "template": "website" },
  "tk-sys":     { "agent_id": "rr-sys",  "role": "reporter", "reporter_id": "RR-002", "template": "websystem" },
  "tk-notpl":   { "agent_id": "rr-no",   "role": "reporter", "reporter_id": "RR-003" },
  "tk-revoked": { "agent_id": "rr-rev",  "role": "reporter", "reporter_id": "RR-004", "template": "website", "revoked": true },
  "tk-expired": { "agent_id": "rr-exp",  "role": "reporter", "reporter_id": "RR-005", "template": "website", "expires_at": "$PAST" },
  "tk-admin":   { "agent_id": "boss",    "role": "admin" }
}
JSONEOF

PORT=0
for try in 1 2 3 4 5; do
  P_TRY=$(( 18000 + RANDOM % 2000 ))
  php -S "127.0.0.1:$P_TRY" -t "$T/site" >"$T/php.log" 2>&1 &
  SRV_PID=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    if curl -s -o /dev/null "http://127.0.0.1:$P_TRY/tools/rules/index.php" 2>/dev/null; then PORT=$P_TRY; break; fi
  done
  [ "$PORT" != 0 ] && break
  kill "$SRV_PID" 2>/dev/null; SRV_PID=""
done
[ "$PORT" != 0 ] || { echo "❌ php -S を起動できませんでした"; cat "$T/php.log"; exit 2; }
URL="http://127.0.0.1:$PORT/tools/rules/index.php"

echo
echo "── 受け口（site/tools/rules/index.php）"
api(){ CODE="$(curl -s -o "$T/out" -w '%{http_code}' -H "Authorization: Bearer $1" "$URL?$2")"; OUT="$(cat "$T/out")"; }

api tk-web "action=version"
want_eq "$CODE" "200" "紐づいたテンプレの版は取れる"
want_in "$V1" "$OUT" "版が返る"
api tk-notpl "action=version"
want_eq "$CODE" "403" "テンプレ未紐づけは 403"
want_in "template_not_assigned" "$OUT" "理由が分かる"
api tk-web "action=version&template=websystem"
want_eq "$CODE" "403" "自分のテンプレ以外は取れない"
api tk-revoked "action=version"
want_eq "$CODE" "403" "失効トークンは弾かれる"
want_in "token_revoked" "$OUT" "失効と分かる"
api tk-expired "action=version"
want_eq "$CODE" "403" "期限切れトークンは弾かれる"
api tk-sys "action=version"
want_eq "$CODE" "503" "未公開のテンプレは 503"
want_in "not_published" "$OUT" "未公開と分かる"
api tk-admin "action=version&template=website"
want_eq "$CODE" "200" "admin はテンプレを指定して確認できる"
touch "$T/data/cache/rules-release/website/.publishing"
api tk-web "action=version"
want_eq "$CODE" "503" "公開の最中は配らない（版と実体がズレた瞬間を見せない）"
rm -f "$T/data/cache/rules-release/website/.publishing"
# 許可リストの正は claude-rules/profiles.json。読めないときに空の許可リストで続けると、
# 設定の不具合が「そのテンプレは無い（400 unknown_template）」に化けて原因が追えなくなる。
mv "$T/claude-rules/profiles.json" "$T/claude-rules/profiles.json.bak"
api tk-web "action=version"
want_eq "$CODE" "500" "プロファイルの定義が読めないときは 500 で止まる（空の許可リストで続けない）"
want_in "profiles_unreadable" "$OUT" "設定の不具合だと分かる名前で返す"
mv "$T/claude-rules/profiles.json.bak" "$T/claude-rules/profiles.json"
api tk-web "action=version"
want_eq "$CODE" "200" "定義を戻せば配信も戻る"
api tk-web "action=changelog"
want_eq "$CODE" "200" "変更点の一覧が取れる"
want_in "初版のルール" "$OUT" "変更点に件名が入る"
api tk-web "action=nosuch"
want_eq "$CODE" "400" "知らない action は 400"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer tk-web" "$URL?action=version")"
want_eq "$CODE" "405" "書き込み系メソッドは受けない（読み取り専用）"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$URL?action=version")"
want_eq "$CODE" "401" "トークン無しは 401"

curl -s -o "$T/pkg.tar.gz" -H "Authorization: Bearer tk-web" "$URL?action=fetch"
want_eq "$(sha256sum "$T/pkg.tar.gz" | cut -d' ' -f1)" "$EXP" "取得した配布物が壊れていない"

STATE="$T/data/mailbox/.state/seen-rr-web.json"
[ -f "$STATE" ] && want_in "$V1" "$(cat "$STATE")" "取りに来た版が記録される（誰が何版を持っているか）" \
  || say_ng "取りに来た版が記録される"
want_in "last_ip" "$(cat "$STATE" 2>/dev/null)" "接続元も記録される"

# ── 現場側（bin/rules-update.sh） ────────────────────────────────────────
echo
echo "── 現場（claude-rules/*/bin/rules-update.sh）"
# 以前は両テンプレのコピーが同一かを見ていた。common に1本化したのでズレようがない＝
# ここで見るのは「面レイヤーにコピーが戻っていないか」。
want_file "$PROJ/claude-rules/common/bin/rules-update.sh" "現場スクリプトは common に1本"
if [ -e "$PROJ/claude-rules/website/bin/rules-update.sh" ] \
   || [ -e "$PROJ/claude-rules/websystem/bin/rules-update.sh" ]; then
  say_ng "面レイヤーに現場スクリプトのコピーが無い" "二重になると片方だけ直される"
else
  say_ok "面レイヤーに現場スクリプトのコピーが無い"
fi

# 配布先は macOS（bash 3.2 ＋ BSD の find/xargs）のことがある。ここで動いても現場で落ちる
# 書き方を機械で弾く＝2026-09-13 に実際に踏んだ（$VAR の直後が日本語／find -printf／xargs -d）。
NG_VAR=""; NG_GNU=""
for f in "$PROJ"/claude-rules/*/bin/*.sh; do
  # 見るのはコード行だけ（「-printf は使わない」と書いた説明文を自分で拾わないため）
  CODE="$(LC_ALL=C grep -vE '^[[:space:]]*#' "$f")"
  # 変数の直後が非ASCII だと、bash 3.2 は多バイト文字まで変数名として読む（unbound variable）
  printf '%s' "$CODE" | LC_ALL=C grep -qE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' && NG_VAR="$NG_VAR ${f##*/}"
  # GNU 専用のオプション・bash 4 専用の構文
  printf '%s' "$CODE" | LC_ALL=C grep -qE 'find [^|]*-printf|xargs +-[da] |stat +-c|date +-d |sed +-i |grep +-P|declare +-A|mapfile|readarray' \
    && NG_GNU="$NG_GNU ${f##*/}"
done
[ -z "$NG_VAR" ] && say_ok "変数の直後に日本語を置いていない（bash 3.2 で unbound variable になる）" \
                 || say_ng "変数の直後に日本語を置いていない" "$NG_VAR"
[ -z "$NG_GNU" ] && say_ok "GNU 専用のオプションを使っていない（BSD の find/xargs でも動く）" \
                 || say_ng "GNU 専用のオプションを使っていない" "$NG_GNU"

# 第1版を受け取った案件を作る（＝配布直後の状態）
SITE="$T/proj"
mkdir -p "$SITE"
mkdir -p "$T/x1"
tar xzf "$T/data/cache/rules-release/website/package.tar.gz" -C "$T/x1"
cp -r "$T/x1/website/." "$SITE/"
printf 'RULE_UPDATE_URL=%s\nRULE_REPORT_TOKEN=tk-web\n' "$URL" > "$SITE/.env"
printf 'この案件で育てた引き継ぎ\n' > "$SITE/documents/handoff.md"
printf 'この案件のパス設定\n'       > "$SITE/project-config.md"
git -C "$SITE" init -q; git -C "$SITE" config user.email t@example.com; git -C "$SITE" config user.name t
git -C "$SITE" add -A >/dev/null; git -C "$SITE" commit -qm init >/dev/null

run_up(){ OUT="$(cd "$SITE" && bash bin/rules-update.sh "$@" 2>&1)"; RC=$?; }
# 案件のツリー全体（種別と中身）。退避の置き場と .git は除く＝「元に戻ったか」を部分でなく全体で見る
snap(){ (cd "$SITE" && find . \( -path ./.git -o -path ./.claude/rules-backup \) -prune -o \( -type f -o -type d \) -print \
  | LC_ALL=C sort | while IFS= read -r f; do
      if [ -d "$f" ]; then echo "d $f"; else echo "f $f $(sha256sum < "$f" | cut -c1-16)"; fi
    done); }

run_up
want_eq "$RC" "0" "最新なら終了コード 0"
want_in "最新です" "$OUT" "最新だと分かる"
want_in "--apply  で作れます" "$OUT" "控えが無ければ、最新のうちに作れると案内する"
[ -f "$SITE/.claude/rules-base.tar.gz" ] && say_ng "確認だけでは控えも書かない" || say_ok "確認だけでは控えも書かない"

# 控えが無くても、最新なら配信中の配布物と比べて書き足しを名指しできる（この仕組みより前に配られた案件）
printf '| /mine | この案件だけのコマンド |\n' >> "$SITE/CLAUDE.md"
git -C "$SITE" commit -qam "控えより前に書き足した" >/dev/null
run_up
want_in "- CLAUDE.md" "$OUT" "控えが無くても、最新なら書き足しを名指しする"
git -C "$SITE" checkout -q HEAD~1 -- CLAUDE.md; git -C "$SITE" commit -qam "戻す" >/dev/null

run_up --apply
want_eq "$RC" "0" "最新のまま --apply すると控えだけ作る"
want_in "控えを作りました" "$OUT" "控えを作ったと言う"
[ -f "$SITE/.claude/rules-base.tar.gz" ] && say_ok "控えができる" || say_ng "控えができる"
want_eq "$(cat "$SITE/CLAUDE.md")" "ルール第1版" "控えを作るだけではルールを書き換えない"
git -C "$SITE" add -A >/dev/null; git -C "$SITE" commit -qm "控え" >/dev/null

# 第2版を公開する
printf 'ルール第2版\n' > "$T/claude-rules/website/CLAUDE.md"
printf 'ルール層（第2版）\n' > "$T/claude-rules/website/rules/modes/developer.md"
printf '新しく足したルール\n' > "$T/claude-rules/website/rules/modes/new-rule.md"
git -C "$T" add -A -- claude-rules >/dev/null; git -C "$T" commit -qm "共有ファイルの所有者表を追加" >/dev/null
(cd "$T" && python3 bin/rules-publish.py publish website >/dev/null 2>&1)
V2="$(cd "$T" && python3 -c 'import json;print(json.load(open("data/cache/rules-release/website/meta.json"))["version"])')"

run_up
want_eq "$RC" "10" "更新があると終了コード 10（人に確認する合図）"
want_in "共有ファイルの所有者表を追加" "$OUT" "何が変わるかを見せる"
want_in "人の確認が必要" "$OUT" "勝手に適用しないと明示する"
want_eq "$(cat "$SITE/CLAUDE.md")" "ルール第1版" "確認だけでは1文字も書き換えない"
BEFORE="$(snap)"; mkdir -p "$T/tmpchk"
OUT="$(cd "$SITE" && TMPDIR="$T/tmpchk" bash bin/rules-update.sh 2>&1)"
want_eq "$(snap)" "$BEFORE" "確認だけでは案件のツリーに何も残さない（控え・一時ファイルを含めて）"
want_eq "$(ls -A "$T/tmpchk")" "" "確認のあと、作業用の一時ファイルも残さない"

# 未コミットの変更があるときは止まる
printf '作業中の加筆\n' >> "$SITE/CLAUDE.md"
run_up --apply
want_eq "$RC" "1" "上書き対象に未コミットがあると適用しない"
want_in "未コミット" "$OUT" "止まった理由を言う"
want_in "--force" "$OUT" "承知のうえで進む方法を示す"
git -C "$SITE" checkout -- CLAUDE.md

# 控えが無い（壊れた・消えた）まま新しい版を適用しようとしたら止まる＝書き足しを調べずに上書きしない
mv "$SITE/.claude/rules-base.tar.gz" "$T/base-aside.tar.gz"
run_up --apply
want_eq "$RC" "1" "控えが無いまま新しい版は適用しない"
want_in "見つけられない" "$OUT" "止まった理由を言う"
want_eq "$(cat "$SITE/CLAUDE.md")" "ルール第1版" "止まったときに書き換えていない"
printf 'こわれた控え' > "$SITE/.claude/rules-base.tar.gz"
run_up --apply
want_eq "$RC" "1" "控えが読めないときも適用しない"
mv "$T/base-aside.tar.gz" "$SITE/.claude/rules-base.tar.gz"

run_up --apply
want_eq "$RC" "0" "適用できる"
want_eq "$(cat "$SITE/CLAUDE.md")" "ルール第2版" "ルール層は上書きされる"
want_eq "$(cat "$SITE/documents/handoff.md")" "この案件で育てた引き継ぎ" "案件の記録（documents/）は消えない"
want_eq "$(cat "$SITE/project-config.md")" "この案件のパス設定" "案件の記録（project-config.md）は消えない"
[ -f "$SITE/rules/modes/new-rule.md" ] && say_ok "新しいファイルが置かれる" || say_ng "新しいファイルが置かれる"
want_eq "$(head -1 "$SITE/.claude/rules-version")" "$V2" "版が書き換わる"
ls "$SITE/.claude/rules-backup/"*.tar.gz >/dev/null 2>&1 && say_ok "上書き前の退避ができる" || say_ng "上書き前の退避ができる"
BK="$(ls "$SITE/.claude/rules-backup/"*.tar.gz | head -1)"
want_in "CLAUDE.md" "$(tar tzf "$BK")" "退避に上書きしたファイルが入っている"

run_up
want_eq "$RC" "0" "適用後は最新になる"

mkdir -p "$T/nopy3"
printf '#!/bin/sh\nexit 1\n' > "$T/nopy3/python3"; chmod +x "$T/nopy3/python3"   # python3 は在るが動かない環境
ln -sf "$(command -v python3)" "$T/nopy3/python"
OUT="$(cd "$SITE" && PATH="$T/nopy3:$PATH" bash bin/rules-update.sh 2>&1)"; RC=$?
want_in "最新です" "$OUT" "python3 が使えない環境でも python で動く"

# 控え（前回適用した配布物）で「配布後に書き足した配布ファイル」を見つける（2026-09-13 現場実例：
# CLAUDE.md のコマンド表に足した1行が更新で黙って消えた）
[ -f "$SITE/.claude/rules-base.tar.gz" ] && say_ok "適用すると控えが残る" || say_ng "適用すると控えが残る"
want_in "CLAUDE.md" "$(tar tzf "$SITE/.claude/rules-base.tar.gz" 2>/dev/null)" "控えに配布ファイルが入っている"
want_not_in "編集された配布ファイル" "$OUT" "何も書き足していなければ警告しない"
printf '| /mine | この案件だけのコマンド |\n' >> "$SITE/CLAUDE.md"
printf 'この案件のパス設定（追記）\n' >> "$SITE/project-config.md"
python3 -c "import sys;p=sys.argv[1];b=open(p,'rb').read();open(p,'wb').write(b.replace(b'\n',b'\r\n'))" "$SITE/rules/modes/developer.md"
git -C "$SITE" add -A >/dev/null; git -C "$SITE" commit -qm "現場で書き足した" >/dev/null
run_up
want_eq "$RC" "0" "最新なら書き足しがあっても終了コードは 0 のまま"
want_in "編集された配布ファイル" "$OUT" "コミット済みの書き足しでも、最新のうちから名指しする（次の更新で消えるため）"
want_in "- CLAUDE.md" "$OUT" "書き足したファイルを名指しする"
want_in "固有の追加" "$OUT" "移し先（project-config.md「固有の追加」）を示す"
want_not_in "- project-config.md" "$OUT" "案件の記録（project-config.md）は比べない"
want_not_in "- rules/modes/developer.md" "$OUT" "改行コードだけの違いは書き足しと数えない"


# 以降は「更新がある」状態で、書き込みの安全装置を見る
printf 'ルール第3版\n' > "$T/claude-rules/website/CLAUDE.md"
git -C "$T" add -A -- claude-rules >/dev/null; git -C "$T" commit -qm "三版" >/dev/null
(cd "$T" && python3 bin/rules-publish.py publish website >/dev/null 2>&1)

run_up
want_eq "$RC" "10" "書き足しがあっても確認は 10（更新あり）"
want_in "- CLAUDE.md" "$OUT" "確認の段階で、消えるファイルを名指しする"
run_up --apply
want_eq "$RC" "1" "書き足した配布ファイルを上書きする適用は止まる（コミット済みでも）"
want_in "書き足した分が消えます" "$OUT" "止まった理由を言う"
want_in "--force" "$OUT" "承知のうえで進む方法を示す"
want_in "この案件だけのコマンド" "$(cat "$SITE/CLAUDE.md")" "止まったときに書き足しが残っている"
want_eq "$(head -1 "$SITE/.claude/rules-version")" "$V2" "止まったときに版を進めない"
printf 'ルール第2版\n' > "$SITE/CLAUDE.md"
printf 'ルール層（第2版）\n' > "$SITE/rules/modes/developer.md"
git -C "$SITE" add -A >/dev/null; git -C "$SITE" commit -qm "書き足しを project-config.md へ移した" >/dev/null
run_up
want_not_in "編集された配布ファイル" "$OUT" "配布時の中身に戻せば警告は消える"

# 書いている最中に止まったら、理由を問わず書いた分を戻す。失敗は cp の代わりを置いて確実に起こす
# （chmod では root で失敗しない）。戻ったかは適用前後でツリー全体を突き合わせる＝一部だけ戻る欠陥も落とす
mkdir -p "$T/claude-rules/website/rules/newdir/deep"
printf 'テンプレートの新しい階層\n' > "$T/claude-rules/website/rules/newdir/deep/added.md"
git -C "$T" add -A -- claude-rules >/dev/null; git -C "$T" commit -qm "新しい階層" >/dev/null
(cd "$T" && python3 bin/rules-publish.py publish website >/dev/null 2>&1)
REALCP="$(command -v cp)"
mkdir -p "$T/fakecp"
cat > "$T/fakecp/cp" <<FAKECP
#!/bin/sh
# 宛先が FAKECP_ON で終わる cp だけ失敗させる。FAKECP_MODE=term なら先に呼び出し元へ TERM を送る
for a in "\$@"; do
  case "\$a" in
    *"\${FAKECP_ON:-//none//}")
      if [ "\${FAKECP_MODE:-}" = term ]; then kill -TERM "\$PPID"; sleep 1; fi
      exit 1 ;;
  esac
done
exec "$REALCP" "\$@"
FAKECP
chmod +x "$T/fakecp/cp"
run_fail(){ OUT="$(cd "$SITE" && PATH="$T/fakecp:$PATH" FAKECP_ON="$1" FAKECP_MODE="${2:-}" bash bin/rules-update.sh --apply --force 2>&1)"; RC=$?; }

BEFORE="$(snap)"
run_fail ".claude/rules-version"     # 全ファイル（上書き・新規・新しい階層）を書いた後、版で失敗
want_eq "$RC" "1" "最後（版）で書けなくなったら止まる"
want_in "元に戻しました" "$OUT" "戻したと言う"
want_eq "$(snap)" "$BEFORE" "上書きした分・新しく置いたファイル・作ったディレクトリまで、適用前と同じに戻る"
run_fail "rules/modes/developer.md" term
[ "$RC" -ne 0 ] && say_ok "kill（TERM）で止められたら成功扱いにしない" || say_ng "kill（TERM）で止められたら成功扱いにしない" "RC=$RC"
want_eq "$(snap)" "$BEFORE" "kill（TERM）で止められても、書いた分を元に戻す"
run_up
want_not_in "編集された配布ファイル" "$OUT" "戻したあとは「書き足し」と誤検知しない（止まり続けない）"

# 上書き先が同じ名前のディレクトリだと、cp はその中に書いて「成功」してしまう＝書く前に止める
git -C "$SITE" rm -q rules/modes/new-rule.md
mkdir -p "$SITE/rules/modes/new-rule.md"; printf '案件のファイル\n' > "$SITE/rules/modes/new-rule.md/keep.txt"
git -C "$SITE" add -A >/dev/null; git -C "$SITE" commit -qm "同じ名前のディレクトリ" >/dev/null
BEFORE="$(snap)"
run_up --apply --force
want_eq "$RC" "1" "上書き先がディレクトリなら適用しない（--force でも）"
want_in "通常のファイルではありません" "$OUT" "止まった理由を言う"
want_eq "$(snap)" "$BEFORE" "止まったときに何も書き換えていない"
rm -rf "$SITE/rules/modes/new-rule.md"; git -C "$SITE" checkout -q HEAD~1 -- rules/modes/new-rule.md
git -C "$SITE" add -A >/dev/null; git -C "$SITE" commit -qm "戻す" >/dev/null
ls "$SITE/.claude/"rules-base.tar.gz.* >/dev/null 2>&1 && say_ng "控えの一時ファイルを残さない" || say_ok "控えの一時ファイルを残さない"

# テンプレートに新しく入ったファイルと同じ名前のファイルが、既にこの案件にある（コミット済み）
printf 'この案件で作った固有のルール\n' > "$SITE/rules/modes/mine.md"
git -C "$SITE" add -A >/dev/null; git -C "$SITE" commit -qm "固有のルール" >/dev/null
printf 'テンプレートの新しいルール\n' > "$T/claude-rules/website/rules/modes/mine.md"
git -C "$T" add -A -- claude-rules >/dev/null; git -C "$T" commit -qm "mine を新設" >/dev/null
(cd "$T" && python3 bin/rules-publish.py publish website >/dev/null 2>&1)
run_up --apply
want_eq "$RC" "1" "同じ名前のファイルがあると適用しない"
want_in "同じ名前" "$OUT" "止まった理由を言う"
want_in "rules/modes/mine.md" "$OUT" "ぶつかったファイルを名指しする"
want_eq "$(cat "$SITE/rules/modes/mine.md")" "この案件で作った固有のルール" "案件のファイルが残っている"
git -C "$SITE" rm -q rules/modes/mine.md; git -C "$SITE" commit -qm "固有のルールを rules/local へ" >/dev/null

# 書き込み先の途中がリンクなら、辿った先を壊さずに止まる（mkdir も cp もリンクを辿るため）
OUTSIDE="$T/outside"; mkdir -p "$OUTSIDE"
cp -r "$SITE/rules/modes" "$OUTSIDE/modes"
rm -rf "$SITE/rules/modes"; ln -s "$OUTSIDE/modes" "$SITE/rules/modes"
run_up --apply --force
want_eq "$RC" "1" "書き込み先の途中がシンボリックリンクなら適用しない"
want_in "シンボリックリンク" "$OUT" "止まった理由を言う"
want_eq "$(cat "$OUTSIDE/modes/developer.md")" "ルール層（第2版）" "リンクの先（プロジェクト外）を書き換えていない"
want_eq "$(cat "$SITE/CLAUDE.md")" "ルール第2版" "止まったときに1ファイルも書き換えていない（半端な適用を残さない）"
want_eq "$(head -1 "$SITE/.claude/rules-version")" "$V2" "止まったときに版を進めない（「最新です」と嘘をつかせない）"
rm -f "$SITE/rules/modes"; cp -r "$OUTSIDE/modes" "$SITE/rules/modes"
git -C "$SITE" add -A >/dev/null; git -C "$SITE" commit -qm restore >/dev/null

# 危険なパスを含む配布物は展開しない（SHA256 は合わせたうえで検査される）
REL="$T/data/cache/rules-release/website"
python3 - "$REL" <<'PYIN'
# 展開先の外を指すメンバー（../danger）を含む配布物を作り、meta の SHA256 も合わせる
# ＝「照合を通ったあとの展開」で守れているかを見る
import hashlib, io, json, pathlib, sys, tarfile, time
rel = pathlib.Path(sys.argv[1])
pkg = rel / "package.tar.gz"
with tarfile.open(pkg, "w:gz") as tf:
    for name, body in (("website/.claude/rules-keep", "documents/\n"), ("../danger", "y\n")):
        data = body.encode()
        info = tarfile.TarInfo(name); info.size = len(data); info.mtime = int(time.time())
        tf.addfile(info, io.BytesIO(data))
m = json.loads((rel / "meta.json").read_text())
m["sha256"] = hashlib.sha256(pkg.read_bytes()).hexdigest()
(rel / "meta.json").write_text(json.dumps(m, ensure_ascii=False, indent=2))
PYIN
run_up --apply
want_eq "$RC" "1" "親ディレクトリを指すパスを含む配布物は展開しない"
want_in "危険なパス" "$OUT" "危険なパスだと分かる"
[ -f "$T/danger" ] && say_ng "展開先の外にファイルを作っていない" || say_ok "展開先の外にファイルを作っていない"

# 壊れた配布物は適用しない
(cd "$T" && python3 bin/rules-publish.py publish website >/dev/null 2>&1)
printf 'こわれた中身' > "$T/data/cache/rules-release/website/package.tar.gz"
run_up --apply
want_eq "$RC" "1" "取得が壊れていたら適用しない"
want_in "SHA256" "$OUT" "壊れていると分かる"
want_eq "$(cat "$SITE/CLAUDE.md")" "ルール第2版" "壊れた取得で中身が変わっていない"

# 書き足しで止まっても、人が判断すれば --force で進める。進めたら控えは新しい版になり、以後は名指ししない
(cd "$T" && python3 bin/rules-publish.py publish website >/dev/null 2>&1)
printf '| /mine | この案件だけのコマンド |\n' >> "$SITE/CLAUDE.md"
git -C "$SITE" commit -qam "また書き足した" >/dev/null
run_up --apply
want_eq "$RC" "1" "書き足しがあると止まる（--force 前）"
run_up --apply --force
want_eq "$RC" "0" "--force なら書き足しがあっても適用できる"
want_eq "$(cat "$SITE/CLAUDE.md")" "ルール第3版" "--force で配布の中身になる"
git -C "$SITE" add -A >/dev/null; git -C "$SITE" commit -qm "更新" >/dev/null
run_up
want_eq "$RC" "0" "--force のあとは最新"
want_not_in "編集された配布ファイル" "$OUT" "--force のあとは控えが新しい版になり、名指ししない"

# 設定不足・失効
printf 'RULE_UPDATE_URL=%s\nRULE_REPORT_TOKEN=tk-revoked\n' "$URL" > "$SITE/.env"
run_up
want_eq "$RC" "1" "失効トークンでは更新できない"
want_in "失効" "$OUT" "失効だと分かる案内が出る"
printf 'RULE_REPORT_URL=%s\n' "${URL%/tools/rules/index.php}/tools/mailbox/index.php" > "$SITE/.env"
printf 'RULE_REPORT_TOKEN=tk-web\n' >> "$SITE/.env"
run_up
want_in "最新の版" "$OUT" "投函用の設定しか無い .env（index.php 付き）からでも受け口を導ける"
: > "$SITE/.env"
run_up
want_eq "$RC" "1" "設定が空なら止まる"

echo
echo "────────────────────────────────"
echo "成功 $P / 失敗 $N"
# 規定形の1行（rules/testing.md §6-5）。これが無いと bin/test-all.sh が項目数を0と数える。
printf '合計: 合格 %d ／ 不合格 %d\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
