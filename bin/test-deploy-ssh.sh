#!/usr/bin/env bash
# claude-rules/common/bin/deploy-ssh.sh の回帰テスト。
#
# testing.md §2 の「テスト必須」に当たる＝①本番のファイルを書き換える ②止めるかどうかの判定を持つ。
# 本物のサーバーには一切つながない：ssh を「ローカルで sh -c するだけ」の偽物に差し替え、
# /tmp の一時フォルダに「本番（公開フォルダ）」「記録置き場」「共有リポジトリ」「作業者2人の手元」を作る。
#
# 確かめること（ルール rules/modes/deploy-ssh.md の約束）：
#   正常な反映／確認番号の不一致で止まる／push 前・リモートより古いと止まる／本番の直接変更で止まる／
#   巻き戻しになる反映で止まる／途中での失敗→undo で元に戻る／排他／人の端末以外では書き込みコマンドが動かない／
#   除外したもの（設定・アップロード・ルール類）に触らない／改行コードだけの変化を名指しする
#
# 触ったら必ず流すこと：bash bin/test-deploy-ssh.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PROJ/claude-rules/common/bin/deploy-ssh.sh"
[ -f "$SCRIPT" ] || { echo "❌ スクリプトが無い: $SCRIPT" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ 作業先が /tmp の外: $T" >&2; exit 2 ;; esac
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

P=0; N=0
ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; [ -z "${2:-}" ] || printf '      → %s\n' "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-300)"; }
want_rc(){ if [ "$1" = "$2" ]; then ok "$3"; else ng "$3 (rc=$1 期待=$2)" "$OUT"; fi; }
want_in(){ case "$OUT" in *"$1"*) ok "$2" ;; *) ng "$2" "$OUT" ;; esac; }
want_file_eq(){ if [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; then ok "$3"; else ng "$3" "$1 = $(cat "$1" 2>/dev/null || echo '(無い)')"; fi; }
want_absent(){ if [ ! -e "$1" ]; then ok "$2"; else ng "$2" "$1 が残っている"; fi; }

# --- 偽の ssh（オプションとホスト名を読み飛ばし、コマンドをローカルで実行する）
mkdir -p "$T/fakebin"
cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case $1 in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
exec sh -c "$1"
EOF
chmod +x "$T/fakebin/ssh"
export DEPLOY_SSH_BIN="$T/fakebin/ssh"
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=t@example.invalid

WWW="$T/srv/www"; STATE="$T/srv/state"
mkdir -p "$WWW/css" "$WWW/uploads"

# --- 共有リポジトリと作業者 A
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/a" 2>/dev/null
A="$T/a"
cd "$A" || exit 2
git checkout -q -b main 2>/dev/null || true
mkdir -p css .deploy bin
printf 'hello v1\n' > index.html
printf 'body{}\n' > css/style.css
printf 'rules\n' > CLAUDE.md
cp "$SCRIPT" bin/deploy-ssh.sh
cat > .deploy/production.conf <<EOF
SSH_HOST=testhost
REMOTE_ROOT=$WWW
STATE_DIR=$STATE
SOURCE_DIR=.
BRANCH=main
REMOTE=origin
BACKUP_KEEP=3
EXCLUDE=uploads/*
EXCLUDE=config.php
EOF
git add -A && git commit -qm "v1" && git push -q origin main 2>/dev/null

# --- FTP 時代の本番（リポジトリと少し違う）
printf 'hello v0\n' > "$WWW/index.html"
printf 'body{}\n' > "$WWW/css/style.css"
printf 'old\n' > "$WWW/old.html"
printf 'SECRET\n' > "$WWW/config.php"
printf 'jpg\n' > "$WWW/uploads/a.jpg"

run(){ OUT=$(cd "$A" && bash bin/deploy-ssh.sh "$@" 2>&1); RC=$?; }
# 人がターミナルで打つ場面：疑似端末（script）の中で動かす。スクリプトに端末確認を外す抜け道は無い。
runh(){ local c; c="cd $(printf '%q' "$A") && bash bin/deploy-ssh.sh$(printf ' %q' "$@")"
        script -qec "$c" /dev/null > "$T/pty.out" 2>&1; RC=$?; OUT=$(tr -d '\r' < "$T/pty.out"); }
tok(){ printf '%s\n' "$OUT" | sed -n 's/^TOKEN: //p' | tail -1; }

echo "■ 準備・初回"
run preflight;              want_rc $RC 0 "preflight が通る"
run preview;                want_rc $RC 2 "記録が無いと preview は止まる"; want_in "baseline" "baseline を案内する"
run baseline;               want_rc $RC 0 "baseline（確認のみ）"
want_in "differ" "本番とリポジトリの違いを出す"; want_in "old.html" "本番にだけあるファイルを名指しする"
B=$(tok)
run baseline "$B";          want_rc $RC 2 "人の端末でないと baseline の記録は止まる"; want_in "terminal" "理由を出す"
runh baseline "$B";         want_rc $RC 0 "baseline を記録"
want_file_eq "$WWW/index.html" "hello v0" "baseline は本番に触らない"

echo "■ 正常な反映"
run preview;                want_rc $RC 0 "preview"
want_in "M  index.html" "変更を一覧に出す"; want_in "D  old.html" "削除を一覧に出す"
case "$OUT" in *CLAUDE.md*) ng "ルール類（*.md）は対象にしない" "$OUT" ;; *) ok "ルール類（*.md）は対象にしない" ;; esac
TK=$(tok)
runh apply 0000000000000000; want_rc $RC 2 "確認番号が違うと止まる"
want_file_eq "$WWW/index.html" "hello v0" "止まったとき本番は変わらない"
runh apply "$TK";           want_rc $RC 0 "apply"
want_file_eq "$WWW/index.html" "hello v1" "本番がコミットの内容になる"
want_absent "$WWW/old.html" "リポジトリに無いファイルは消える"
want_absent "$WWW/CLAUDE.md" "ルール類は上がらない"
want_absent "$WWW/.deploy" "設定ファイルは上がらない"
want_file_eq "$WWW/config.php" "SECRET" "除外した設定ファイルに触らない"
want_file_eq "$WWW/uploads/a.jpg" "jpg" "除外したアップロードに触らない"
want_file_eq "$STATE/deployed" "$(git -C "$A" rev-parse HEAD)" "反映したコミットを記録する"
run preview;                want_rc $RC 0 "反映後の preview"; want_in "Nothing to deploy" "差分なしと言う"

echo "■ push・最新の確認"
printf 'hello v2\n' > "$A/index.html"
run preview;                want_rc $RC 2 "未コミットだと止まる"
printf 'rules 2\n' > "$A/CLAUDE.md"
git -C "$A" add index.html && git -C "$A" commit -qm v2
run preview;                want_rc $RC 2 "push 前だと止まる"; want_in "Push first" "push を案内する"
git -C "$A" checkout -q -- CLAUDE.md
git -C "$A" push -q origin main 2>/dev/null
run preview;                want_rc $RC 0 "push 後は通る（除外ファイルの未コミット変更は妨げない確認も兼ねる）"
git clone -q "$T/origin.git" "$T/b" 2>/dev/null
printf 'from b\n' > "$T/b/b.html"; git -C "$T/b" add b.html; git -C "$T/b" commit -qm "b"; git -C "$T/b" push -q origin main 2>/dev/null
run preview;                want_rc $RC 2 "リモートより古いと止まる"; want_in "behind" "pull を案内する"
git -C "$A" pull -q --ff-only origin main 2>/dev/null

echo "■ 確認の後に内容が変わる"
run preview; TK=$(tok)
printf 'from b 2\n' > "$T/b/b.html"; git -C "$T/b" commit -qam "b2"; git -C "$T/b" push -q origin main 2>/dev/null
git -C "$A" pull -q --ff-only origin main 2>/dev/null
runh apply "$TK";           want_rc $RC 2 "preview の後に変わったら止まる"; want_in "changed since the preview" "理由を出す"
want_file_eq "$WWW/index.html" "hello v1" "止まったとき本番は変わらない"

echo "■ 本番の直接変更"
printf 'edited on server\n' > "$WWW/css/style.css"
run preview;                want_rc $RC 2 "本番の直接変更で止まる"; want_in "changed on server  css/style.css" "変わったファイルを名指しする"
DS=$(printf '%s\n' "$OUT" | sed -n 's/^server copies : //p')
want_file_eq "${DS}css/style.css" "edited on server" "本番の現物を手元に取ってくる（画面に出た場所）"
runh baseline "$(run baseline; tok)"; want_rc $RC 0 "判断の後に baseline を記録し直せる"
run preview;                want_rc $RC 0 "記録し直した後は通る"; want_in "M  css/style.css" "次の反映で上書きされることを見せる"

echo "■ 改行コードだけの変化"
printf 'body{}\r\n' > "$A/css/style.css"; git -C "$A" commit -qam crlf; git -C "$A" push -q origin main 2>/dev/null
printf 'body{}\n' > "$WWW/css/style.css"; runh baseline "$(run baseline; tok)"
run preview;                want_in "LINE ENDINGS ONLY" "改行コードだけの違いを名指しする"
TK=$(tok); runh apply "$TK"; want_rc $RC 0 "apply（改行・b.html）"

echo "■ undo"
PREV=$(cat "$STATE/deployed")
printf 'hello v3\n' > "$A/index.html"; printf 'n\n' > "$A/new file 日本.html"
git -C "$A" add -A . ':!CLAUDE.md' && git -C "$A" commit -qm v3 && git -C "$A" push -q origin main 2>/dev/null
run preview; runh apply "$(tok)"; want_rc $RC 0 "apply（空白・日本語のファイル名）"
want_file_eq "$WWW/new file 日本.html" "n" "空白・日本語のファイル名も上がる"
run undo;                   want_rc $RC 0 "undo（確認のみ）"; want_in "remove   new file" "消すファイルを見せる"
runh undo "$(tok)";         want_rc $RC 0 "undo"
want_file_eq "$WWW/index.html" "hello v2" "上書きしたファイルが戻る（直前の反映で v2 になっていた）"
want_absent "$WWW/new file 日本.html" "新しく作ったファイルも消える"
want_file_eq "$STATE/deployed" "$PREV" "記録も1つ前のコミットに戻る"

echo "■ 途中での失敗"
run preview; TK=$(tok)
chmod 444 "$WWW/index.html"
runh apply "$TK";           want_rc $RC 3 "書き込み途中の失敗は rc=3"; want_in "undo" "undo を案内する"
[ -f "$STATE/in-progress" ] && ok "未完了の印が残る" || ng "未完了の印が残る"
run preview;                want_rc $RC 2 "未完了があると preview は止まる"
chmod 644 "$WWW/index.html"
run undo;                   want_in "(partial)" "未完了の反映を戻す対象にする"
runh undo "$(tok)";         want_rc $RC 0 "途中失敗を undo で戻せる"
want_absent "$WWW/new file 日本.html" "途中で作られたファイルも消える"
want_absent "$STATE/in-progress" "未完了の印が消える"

echo "■ 排他"
mkdir -p "$STATE/lock"; echo "someone pc 20260101T000000Z apply" > "$STATE/lock/info"
run preview; TK=$(tok)
runh apply "$TK";           want_rc $RC 2 "他の人が反映中なら止まる"; want_in "someone" "誰が持っているか出す"
runh unlock;                want_rc $RC 0 "unlock"
runh apply "$TK";           want_rc $RC 0 "解除後は反映できる"
NB=$(ls -1 "$STATE/backups" | wc -l | tr -d ' ')
[ "$NB" -le 3 ] && ok "バックアップは BACKUP_KEEP（3）回分まで（実際 $NB）" || ng "バックアップは BACKUP_KEEP（3）回分まで" "$NB"
grep -lx "new=$(cat "$STATE/deployed")" "$STATE"/backups/*/meta >/dev/null 2>&1 && ok "いま本番にある反映のバックアップは整理で消えない" || ng "いま本番にある反映のバックアップは整理で消えない"

echo "■ 巻き戻しの防止"
git -C "$A" checkout -q -b side; printf 's\n' > "$A/s.html"; git -C "$A" add s.html; git -C "$A" commit -qm side
git -C "$A" rev-parse HEAD > "$STATE/deployed"; git -C "$A" checkout -q main
run preview;                want_rc $RC 2 "main に無いコミットが本番にあると止まる"; want_in "roll it back" "理由を出す"

echo "■ 空のフォルダから始める（新しいサイト）"
mkdir -p "$T/srv/stg"
sed -e "s|^REMOTE_ROOT=.*|REMOTE_ROOT=$T/srv/stg|" -e "s|^STATE_DIR=.*|STATE_DIR=$T/srv/stg-state|" "$A/.deploy/production.conf" > "$A/.deploy/staging.conf"
git -C "$A" add .deploy/staging.conf && git -C "$A" commit -qm stg && git -C "$A" push -q origin main 2>/dev/null
run -t staging baseline;     want_rc $RC 0 "空の反映先でも baseline が出る"
runh -t staging baseline "$(tok)"; want_rc $RC 0 "空の反映先で baseline を記録"
run -t staging preview;      want_rc $RC 0 "空の反映先への preview"; want_in "apply" "次のコマンドに -t を含めて案内する"
case "$OUT" in *"-t staging apply"*) ok "-t staging を案内に含める" ;; *) ng "-t staging を案内に含める" "$OUT" ;; esac
runh -t staging apply "$(tok)"; want_rc $RC 0 "空の反映先へ apply"
want_file_eq "$T/srv/stg/index.html" "hello v3" "新しいサイトに全ファイルが上がる"
STG="$T/srv/stg"; SC="$A/.deploy/staging.conf"
pushc(){ git -C "$A" add -A . ':!CLAUDE.md' && git -C "$A" commit -qm "$1" && git -C "$A" push -q origin main 2>/dev/null; }

echo "■ 同じ PC で別のコマンドを打っても、前の作業ファイルを消さない"
printf 'hello v4\n' > "$A/index.html"; printf 'x\n' > "$A/x.html"; pushc v4
run -t staging preview; D1=$(printf '%s\n' "$OUT" | sed -n 's/^full diff *: \([^ ]*\) .*/\1/p'); TK=$(tok)
run -t staging status
[ -n "$D1" ] && [ -f "$D1" ] && ok "status の後も preview の差分ファイルが残る" || ng "status の後も preview の差分ファイルが残る" "$D1"
runh -t staging apply "$TK"; want_rc $RC 0 "apply（v4）"

echo "■ 除外を足した後の undo"
printf 'EXCLUDE=x.html\n' >> "$SC"
run -t staging undo;         want_rc $RC 2 "戻す対象が現在の除外に当たると止まる"; want_in "now in EXCLUDE" "理由を出す"
git -C "$A" checkout -q -- .deploy/staging.conf

echo "■ undo 自体の途中失敗"
chmod 444 "$STG/index.html"
runh -t staging undo "$(run -t staging undo; tok)"; want_rc $RC 3 "undo の途中失敗は rc=3"
case "$(cat "$T/srv/stg-state/in-progress" 2>/dev/null)" in undo:*) ok "undo の途中の印が残る" ;; *) ng "undo の途中の印が残る" ;; esac
run -t staging preview;      want_rc $RC 2 "undo が途中なら preview は止まる"
chmod 644 "$STG/index.html"
run -t staging undo;         want_in "(partial)" "途中の undo をやり直しの対象にする"
runh -t staging undo "$(tok)"; want_rc $RC 0 "undo をやり直して戻せる"
want_file_eq "$STG/index.html" "hello v3" "上書きしたファイルが戻る"
want_absent "$STG/x.html" "追加したファイルが消える"
want_absent "$T/srv/stg-state/in-progress" "途中の印が消える"

echo "■ ファイルとフォルダの衝突"
printf 'i\n' > "$A/img"; pushc img
run -t staging preview; runh -t staging apply "$(tok)"; want_rc $RC 0 "apply（ファイル img）"
git -C "$A" rm -q img; mkdir -p "$A/img"; printf 'p\n' > "$A/img/a.png"; pushc img-dir
run -t staging preview;      want_rc $RC 2 "本番のファイルをフォルダに替える変更は preview で止まる"; want_in "file on server" "衝突を名指しする"
git -C "$A" rm -rq img && printf 'i\n' > "$A/img" && pushc img-back
mkdir -p "$STG/data"; printf 'keep\n' > "$STG/data/x"
printf 'EXCLUDE=data/*\n' >> "$SC"; pushc exclude-data
run -t staging preview;      want_rc $RC 0 "除外の追加だけなら preview は通る"; want_in "Nothing to deploy" "上げるファイルは無い（除外したフォルダは比べない）"
printf 'f\n' > "$A/data"; pushc data-file
run -t staging preview;      want_rc $RC 0 "除外で見えないフォルダとの衝突は preview では見えない"
runh -t staging apply "$(tok)"; want_rc $RC 2 "書き込み前のサーバー側の確認で止まる"; want_in "CONFLICT" "衝突を名指しする"
want_file_eq "$STG/data/x" "keep" "除外したフォルダの中身はそのまま"
[ -d "$STG/data" ] && ok "フォルダが置き換わっていない" || ng "フォルダが置き換わっていない"
want_absent "$T/srv/stg-state/in-progress" "書き込み前に止まったので途中の印は無い"

echo "■ サーバー上の値を信用しない"
mkdir -p "$T/outside"; ln -s "$T/outside" "$STG/shared"
printf 'EXCLUDE=shared\n' >> "$SC"; git -C "$A" rm -q data; mkdir -p "$A/shared"; printf 'a\n' > "$A/shared/a.txt"; pushc symlink
run -t staging preview;      want_rc $RC 0 "除外したリンクの下のパスは preview では見えない"
runh -t staging apply "$(tok)"; want_rc $RC 2 "途中のフォルダがリンクなら書き込む前に止まる"; want_in "symbolic link" "理由を出す"
want_absent "$T/outside/a.txt" "公開フォルダの外に書き込まない"
cp "$T/srv/stg-state/deployed" "$T/deployed.bak"
printf -- '--output=%s/pwned\n' "$T" > "$T/srv/stg-state/deployed"
run -t staging status;       want_rc $RC 2 "壊れた記録（コミット番号でない値）で止まる"
want_absent "$T/pwned" "記録の値を git のオプションとして使わない"
cp "$T/deployed.bak" "$T/srv/stg-state/deployed"

echo "■ 設定"
sed -i 's|^SSH_HOST=.*|SSH_HOST=CHANGE_ME|' "$A/.deploy/production.conf"
run preview;                want_rc $RC 2 "未記入の設定で止まる"
git -C "$A" checkout -q -- .deploy/production.conf
sed -i "s|^STATE_DIR=.*|STATE_DIR=$WWW/.state|" "$A/.deploy/production.conf"
run preview;                want_rc $RC 2 "記録置き場が公開フォルダの中なら止まる"

echo
echo "結果: ✅ $P / ❌ $N"
[ "$N" -eq 0 ]
