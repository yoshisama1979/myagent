#!/usr/bin/env bash
#
# bin/rules-update.sh ── このプロジェクトのルールファイル群を最新版に更新する。
#
#   bash bin/rules-update.sh            # 確認だけ（何も書き換えない）
#   bash bin/rules-update.sh --apply    # 実際に更新する
#
# 【エージェントへ：勝手に適用しないこと】
#   ルールが変わると、いま進めている作業の前提が変わる。**必ず人に確認してから** --apply する。
#   手順は rules/modes/rules-update.md に書いてある（まずそれを読む）。
#   確認だけの実行は安全なので、区切りのタイミングで気軽に流してよい。
#
# 【何が起きるか】
#   はなさか側で「配ってよい」と決められた版を取ってきて、ルール層のファイルを上書きする。
#   **案件の記録は上書きしない**（documents/・project-config.md・.claude/rules/private.md 等）。
#   守る対象の一覧は配布物に同梱された .claude/rules-keep に入っている＝こちらで書かない。
#
# 【戻したくなったら】
#   上書きする前に .claude/rules-backup/<日時>.tar.gz を必ず作る。git 管理下なら
#   `git diff` で差分を読めるし、`git checkout -- <path>` で戻せる。
#
# 【終了コード】0=最新 or 更新成功 / 10=更新あり（確認モード）/ 1=エラー
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
VERSION_REL=".claude/rules-version"
VERSION_FILE="$ROOT_DIR/$VERSION_REL"

die() { echo "エラー: $*" >&2; exit 1; }

APPLY=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) die "不明なオプション: $1" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl が見つかりません"
command -v tar  >/dev/null 2>&1 || die "tar が見つかりません"
# Python は JSON の読み書きと SHA256 に使う。Windows の Git Bash には python3 が無く
# python しか無いことがあるので両方見る（python2 だと encoding= 付き open で落ちるので弾く）。
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
[ -n "$PY" ] || die "python3（または Python 3 系の python）が見つかりません"
[ -f "$ENV_FILE" ] || die ".env が見つかりません（$ENV_FILE）"

# ここから下はトークンを扱う。bash -x が有効だと展開がそのままログに出るので切る。
XTRACE_WAS_ON=""
case "$-" in *x*) XTRACE_WAS_ON="yes"; set +x ;; esac

# .env から必要なキーだけ抜く（全体を source しない＝他の変数を実行環境に持ち込まない）。
# Windows で書かれた .env（CRLF）・`export` 付き・`=` の周りの空白・引用符に耐える。
read_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" \
    | head -1 | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
URL="$(read_env RULE_UPDATE_URL)"
TOKEN="$(read_env RULE_REPORT_TOKEN)"
if [ -z "$URL" ]; then
  # 古い .env（通知だけ設定してある案件）から導く。受け口は同じサーバの隣にある。
  REPORT_URL="$(read_env RULE_REPORT_URL)"
  REPORT_URL="${REPORT_URL%/index.php}"          # …/tools/mailbox/index.php と書かれていても導ける
  case "$REPORT_URL" in
    */tools/mailbox|*/tools/mailbox/) URL="${REPORT_URL%/}"; URL="${URL%/tools/mailbox}/tools/rules" ;;
  esac
fi
[ -n "$URL" ] && [ -n "$TOKEN" ] || die "RULE_UPDATE_URL / RULE_REPORT_TOKEN が .env にありません。
   このテンプレを配った社長に「ルール更新の受け口を有効にしてほしい」と伝えてください。"
URL="${URL%/}"

# トークンは --config 経由で渡す。-H \"Authorization: Bearer xxx\" だと curl の argv に乗り、
# ps / /proc から同じマシンの他ユーザーに見える。
CFG="$(umask 077; mktemp)" || die "一時ファイル作成に失敗"
TMPDIR_WORK="$(mktemp -d)" || die "作業ディレクトリ作成に失敗"
trap 'rm -f "$CFG"; rm -rf "$TMPDIR_WORK"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$CFG"
if [ -n "$XTRACE_WAS_ON" ]; then set -x; fi

api() {  # $1=action, $2=出力ファイル。HTTPコードを返す
  curl -sS --max-time 30 --config "$CFG" -o "$2" -w '%{http_code}' "${URL}/?action=$1"
}

# ── いまの版と、配信されている版 ─────────────────────────────────────────
if [ -f "$VERSION_FILE" ]; then
  LOCAL_VERSION="$(head -1 "$VERSION_FILE" | tr -d '\r\n')"
else
  LOCAL_VERSION="unknown"
fi
LOCAL_SHA="${LOCAL_VERSION##*/}"

CODE="$(api version "$TMPDIR_WORK/version.json")" || die "サーバに接続できません（$URL）"
if [ "$CODE" != "200" ]; then
  ERR="$(RU_F="$TMPDIR_WORK/version.json" "$PY" -c '
import json, os, sys
try:
    print(json.load(open(os.environ["RU_F"], encoding="utf-8")).get("error", "unknown"))
except Exception:
    print("unreadable_response")')"
  echo "❌ 版を確認できません（HTTP $CODE / $ERR）" >&2
  case "$ERR" in
    token_revoked|token_expired)
      echo "   この案件のトークンが失効／期限切れです。社長に再発行を依頼してください。" >&2 ;;
    template_not_assigned)
      echo "   トークンにテンプレートが紐づいていません。社長に再発行を依頼してください。" >&2 ;;
    not_published)
      echo "   まだ配信されていません（社長が公開すると取れるようになります）。" >&2 ;;
  esac
  exit 1
fi

eval "$(RU_F="$TMPDIR_WORK/version.json" "$PY" -c '
import json, os, shlex
d = json.load(open(os.environ["RU_F"], encoding="utf-8"))
for k in ("version", "sha", "published_at", "sha256", "size", "template"):
    print("REMOTE_%s=%s" % (k.upper(), shlex.quote(str(d.get(k, "")))))')"

echo "いまの版 : $LOCAL_VERSION"
echo "最新の版 : $REMOTE_VERSION（公開 ${REMOTE_PUBLISHED_AT:0:16})"

if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
  echo "✅ 最新です。更新は要りません。"
  exit 0
fi

# ── 自分の版より後に何が変わったか ───────────────────────────────────────
if [ "$(api changelog "$TMPDIR_WORK/changelog.tsv")" = "200" ]; then
  echo
  echo "── この更新で入る変更 ─────────────────────────────"
  RU_F="$TMPDIR_WORK/changelog.tsv" RU_SHA="$LOCAL_SHA" "$PY" -c '
import os
sha = os.environ["RU_SHA"].replace("+dirty", "")
rows = [l.rstrip("\n").split("\t", 2) for l in open(os.environ["RU_F"], encoding="utf-8")]
rows = [r for r in rows if len(r) == 3]
hit = next((i for i, r in enumerate(rows) if r[0].startswith(sha) or sha.startswith(r[0])), None)
if hit is None:
    print("  （いまの版が一覧に無いため、直近の変更だけ表示します）")
    hit = min(10, len(rows))
for sha_, day, subject in rows[:hit]:
    print("  - [%s] %s" % (day, subject[:160]))
if hit == 0:
    print("  （コミット単位の変更はありません＝配布し直しだけの更新です）")'
fi

if [ "$APPLY" != "1" ]; then
  cat <<'GUIDE'

── ここから先は人の確認が必要です ─────────────────────
  上の変更点を人に伝えて、更新してよいか確認してください。
  承認をもらったら:  bash bin/rules-update.sh --apply
GUIDE
  exit 10
fi

# ── 取得 ────────────────────────────────────────────────────────────────
PKG="$TMPDIR_WORK/package.tar.gz"
[ "$(api fetch "$PKG")" = "200" ] || die "配布物を取得できませんでした"
ACTUAL="$(RU_F="$PKG" "$PY" -c '
import hashlib, os
h = hashlib.sha256()
with open(os.environ["RU_F"], "rb") as f:
    for c in iter(lambda: f.read(1 << 20), b""):
        h.update(c)
print(h.hexdigest())')"
[ "$ACTUAL" = "$REMOTE_SHA256" ] || die "取得した配布物が壊れています（SHA256 不一致）。もう一度実行してください。"

# 展開する前に中身を見る。`/` 始まりや `..` を含むパスは、tar の実装次第で
# 展開先の外へ書きに行く（配布物が汚染された場合の保険）。
BAD="$(tar tzf "$PKG" | grep -E '^/|(^|/)\.\.(/|$)' | head -3 || true)"
[ -z "$BAD" ] || die "配布物に危険なパスが含まれています（展開しませんでした）: $BAD"
mkdir -p "$TMPDIR_WORK/x"
tar xzf "$PKG" -C "$TMPDIR_WORK/x" || die "配布物を展開できませんでした"
SRC="$(find "$TMPDIR_WORK/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$SRC" ] && [ -d "$SRC" ] || die "配布物の中身が想定と違います"

# 守るファイルの一覧は配布物に同梱されている（こちらで書かない＝足された日にズレない）
KEEPFILE="$SRC/.claude/rules-keep"
[ -f "$KEEPFILE" ] || die "配布物に .claude/rules-keep がありません（古い形式の配布物です）"

keep_p() {  # $1=相対パス → 案件の記録なら 0
  local rel="$1" k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$k" in
      */) case "$rel" in "$k"*) return 0 ;; esac ;;
      *)  [ "$rel" = "$k" ] && return 0 ;;
    esac
  done < "$KEEPFILE"
  return 1
}

# ── 何を上書きするかを決める ─────────────────────────────────────────────
OVER="$TMPDIR_WORK/overwrite.list"; : > "$OVER"
NEW="$TMPDIR_WORK/new.list";       : > "$NEW"
SKIP="$TMPDIR_WORK/skip.list";     : > "$SKIP"
( cd "$SRC" && find . -type f -printf '%P\n' ) | sort > "$TMPDIR_WORK/all.list"
while IFS= read -r rel; do
  if [ -e "$ROOT_DIR/$rel" ]; then
    if keep_p "$rel"; then echo "$rel" >> "$SKIP"; else echo "$rel" >> "$OVER"; fi
  else
    echo "$rel" >> "$NEW"
  fi
done < "$TMPDIR_WORK/all.list"

# 上書き対象に未コミットの変更があると、それは黙って消える。git があるなら止める。
if [ -s "$OVER" ] && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  DIRTY="$(cd "$ROOT_DIR" && xargs -d '\n' -a "$OVER" git status --porcelain -- 2>/dev/null || true)"
  if [ -n "$DIRTY" ] && [ "$FORCE" != "1" ]; then
    echo "❌ 上書き対象に未コミットの変更があります（消えてしまいます）:" >&2
    printf '%s\n' "$DIRTY" | sed 's/^/   /' >&2
    echo "   先にコミットするか、承知のうえなら --force を付けてください。" >&2
    exit 1
  fi
fi

# ── 退避してから書き込む ────────────────────────────────────────────────
BACKUP_DIR="$ROOT_DIR/.claude/rules-backup"
STAMP="$(date +%Y%m%d-%H%M%S)"
if [ -s "$OVER" ]; then
  mkdir -p "$BACKUP_DIR"
  ( cd "$ROOT_DIR" && tar czf "$BACKUP_DIR/$STAMP.tar.gz" -T "$OVER" ) \
    || die "退避に失敗したので中断しました（何も書き換えていません）"
fi

# 書き込み先が本当にこのプロジェクトの中か。`mkdir -p` も `cp` もリンクを辿るので、
# **作る前に**途中の各要素を見る（辿った先の別のディレクトリを壊さないため）。
check_path() {
  local rel="$1" dir cur="$ROOT_DIR" part oldifs
  dir="$(dirname "$rel")"
  [ "$dir" = "." ] && return 0
  oldifs="$IFS"; IFS='/'
  for part in $dir; do
    cur="$cur/$part"
    if [ -L "$cur" ]; then
      IFS="$oldifs"
      die "配布先の途中がシンボリックリンクです: ${cur#$ROOT_DIR/}（辿った先を壊すので中断しました）"
    fi
  done
  IFS="$oldifs"
}

# **1文字も書く前に**全部の行き先を検査する。途中で止まると「一部だけ新しい」状態になり、
# しかも版だけ先に書き換わっていると「最新です」と嘘をつくようになる。
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  check_path "$rel"
  if [ -L "$ROOT_DIR/$rel" ]; then die "$rel はシンボリックリンクです（リンク先を壊すので中断しました）"; fi
done < <(cat "$OVER" "$NEW")

# 版は最後に書く（途中で失敗したときに「更新済み」と名乗らせない）
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ "$rel" = "$VERSION_REL" ] && continue
  dst="$ROOT_DIR/$rel"
  mkdir -p "$(dirname "$dst")"
  cp "$SRC/$rel" "$dst"
done < <(cat "$OVER" "$NEW")
if [ -f "$SRC/$VERSION_REL" ]; then
  mkdir -p "$(dirname "$ROOT_DIR/$VERSION_REL")"
  cp "$SRC/$VERSION_REL" "$ROOT_DIR/$VERSION_REL"
fi

count() { wc -l < "$1" | tr -d ' '; }
echo
echo "✅ 更新しました: $REMOTE_VERSION"
echo "   上書き $(count "$OVER") / 新規 $(count "$NEW") / 触らない $(count "$SKIP")（案件の記録）"
if [ -s "$OVER" ]; then echo "   退避   : .claude/rules-backup/$STAMP.tar.gz（戻すときはここから）"; fi
cat <<'NEXT'

   次にやること:
     1. CLAUDE.md と rules/ を読み直す（作業中のセッションは前提が変わっています）
     2. 変更点を人に共有する
     3. 使ってみて困ったら bash bin/rule-report.sh で知らせる（版は自動で載ります）
NEXT
