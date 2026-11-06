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
# 【配布ファイルに書き足していたら】
#   前回適用した配布物を .claude/rules-base.tar.gz に控えておき、控えと違う配布ファイル
#   ＝配布後にこのプロジェクトで編集したものを名指しで出す（上書きで黙って消さない）。
#   --apply はそれがあると止まる。足した行は project-config.md「固有の追加」節へ移してから流す。
#   控えが無ければ、最新のうちに --apply すると作れる（ルールは書き換えない）。控えが無いまま
#   新しい版を適用しようとすると止まる。テンプレートに新しく入ったファイルと同じ名前の
#   ファイルが既にあるときも止まる。どれも人が判断したときだけ --force で進む。
#
# 【戻したくなったら】
#   上書きする前に .claude/rules-backup/<日時>.tar.gz を必ず作る。git 管理下なら
#   `git diff` で差分を読めるし、`git checkout -- <path>` で戻せる。
#
# 【終了コード】0=最新 or 更新成功 / 10=更新あり（確認モード）/ 1=エラー
#
set -euo pipefail

# 🚨 ここから下の全体を main() に入れてある（実体の処理は main の中）。理由：
#   bash はスクリプトを**バイトオフセットで逐次読む**。配布物には **このスクリプト自身**が
#   入っているので、適用の途中で自分が差し替わると、以降の読み取り位置が新しい中身の
#   別の場所を指し、**行の途中から実行される**。現場実測＝版が 288行→583行 に伸びた回に
#   `line 272: =: command not found` / exit 127 で落ち、**「適用は実質終わっているのに
#   版の刻印も控えも無い」**状態が残って以後ずっと --force を要求された
#   （rr-toyopet-lp 2026-09-18・TB-019）。
#   関数定義は**本体をまとめて読んでから**実行されるので、main の中身は最初の1回で
#   メモリに載り、途中でファイルが差し替わっても影響を受けない。
# 🚨 中身を字下げしていないのは意図的。この中には終端が行頭でなければならない
#   ヒアドキュメント（<<'GUIDE' 等）が3つあり、字下げすると壊れる。
# 🚨 末尾の呼び出しは `main "$@"; exit` と**同じ行**に置くこと（別の行にすると、main が
#   返ったあと bash が**差し替わったファイルの古い位置**から次の行を読もうとする）。
main() {

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
VERSION_REL=".claude/rules-version"
VERSION_FILE="$ROOT_DIR/$VERSION_REL"
BASE_REL=".claude/rules-base.tar.gz"
BASE_PKG="$ROOT_DIR/$BASE_REL"
BASE_TMP=""
WRITING=""   # 配布ファイルを書いている最中（この間に終了したら、理由を問わず書いた分を戻す）
BACKUP=""

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
# ⚠️ この検出と下の read_env() は bin/rule-report.sh にも同じものがある（直すときは両方・TB-012）。
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 7) else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
# 3.7 以上を要求する＝下の PY_LF（stdout.reconfigure）が 3.7 から。3.6 以前では Windows で出力に \r が残り、
# SHA256 の照合が必ず外れて更新できない（2026-11-06 Codex レビュー）。黙って壊れるより入口で止める。
[ -n "$PY" ] || die "Python 3.7 以上（python3 または python）が見つかりません。python --version で版を確かめてください"
# 🚨 Windows の Python はテキストで書くと \n を \r\n にする（ファイルにも標準出力にも）。
#    一覧に \r が付くと比較が全部外れ、①全件が「新規と同名」で止まり（誤検知）、②「配布後に書き足した
#    配布ファイル」の判定が常に空になって書き足しが黙って上書きされる（2026-11-05 earthraise_web 報告）。
#    Python の出力は必ずこの前置きを通す。書き込む open() には newline="\n" を付ける。比較の入口でも \r を
#    落とす（csort）＝片方が漏れても壊れない二重の守り。
PY_LF='import sys
if hasattr(sys.stdout, "reconfigure"): sys.stdout.reconfigure(newline="\n")
'
[ -f "$ENV_FILE" ] || die ".env が見つかりません（${ENV_FILE}）"
# .env が git 管理外かを機械で確かめる（2026-09-18 大阪トヨペット報告：.gitignore に入っておらず
# `?? .env` で追跡候補に出ていた＝次の `git add .` でトークンが履歴に入るところだった。.env を置くのは
# 人の作業なので、ルール文で「管理外にする」と書くだけでは誰も気づけない）。止めずに警告だけ出す。
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$ROOT_DIR" ls-files --error-unmatch -- .env >/dev/null 2>&1; then
    # 既に追跡されている＝.gitignore に足しても無視されない（追跡中のファイルは無視の対象外）
    echo "🚨 .env が既に git に入っています（トークンがコミットされています）。人に伝えて、"
    echo "   git rm --cached .env と .gitignore への追記をし、トークンの再発行を頼んでください（rules/modes/rules-update.md §1）。"
    echo
  elif ! git -C "$ROOT_DIR" check-ignore -q -- .env 2>/dev/null; then
    echo "⚠️  .env が git 管理外になっていません（トークンがコミットされる恐れ）。.gitignore に「.env」と「.claude/rules-backup/」を足してください（rules/modes/rules-update.md §1）。"
    echo
  fi
fi

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
# 終了のしかた（エラー・Ctrl+C・kill）を問わず、書いている最中なら書いた分を戻してから片付ける
on_exit() {
  local rc=$?
  if [ -n "$WRITING" ]; then
    WRITING=""
    rc=1
    if rollback; then
      echo "   書き込んだ分を元に戻しました（版は進めていません）。原因を取り除いてから、もう一度実行してください。" >&2
    else
      echo "❌ 元に戻しきれませんでした。退避から手で戻してください:" >&2
      echo "   プロジェクトのルートで  tar xzf ${BACKUP#$ROOT_DIR/}  （このあと新しく置かれたファイルが残っていれば消す）" >&2
    fi
  fi
  rm -f "$CFG"; rm -rf "$TMPDIR_WORK"
  if [ -n "$BASE_TMP" ]; then rm -f "$BASE_TMP"; fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$CFG"
if [ -n "$XTRACE_WAS_ON" ]; then set -x; fi

keep_p() {  # $1=相対パス → 案件の記録（$KEEPFILE に載っている）なら 0
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

# 展開する前に全メンバーを見る。`/` 始まり・`..` を含むパス・リンク・特殊ファイルは、tar の実装や
# メンバーの順番次第で展開先の外へ書きに行く。危ないもの（読めなければその旨）を最大3件出す
unsafe_paths() {
  RU_F="$1" "$PY" -c "$PY_LF"'
import os, tarfile
bad = []
try:
    with tarfile.open(os.environ["RU_F"], "r:gz") as tf:
        for m in tf:
            n = m.name
            if n.startswith("/") or ".." in n.split("/") or not (m.isfile() or m.isdir()):
                bad.append(n)
except Exception:
    bad.append("(読めない配布物)")
print("\n".join(bad[:3]))'
}

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

api() {  # $1=action, $2=出力ファイル。HTTPコードを返す
  curl -sS --max-time 30 --config "$CFG" -o "$2" -w '%{http_code}' "${URL}/?action=$1"
}

sha256_of() {
  RU_F="$1" "$PY" -c "$PY_LF"'
import hashlib, os
h = hashlib.sha256()
with open(os.environ["RU_F"], "rb") as f:
    for c in iter(lambda: f.read(1 << 20), b""):
        h.update(c)
print(h.hexdigest())'
}

open_pkg() {  # $1=配布物 $2=展開先 → 中のテンプレートのディレクトリを出す（開けなければ 1）
  local d
  [ -z "$(unsafe_paths "$1")" ] || return 1
  mkdir -p "$2" && tar xzf "$1" -C "$2" 2>/dev/null || return 1
  d="$(find "$2" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$d" ] && [ -f "$d/.claude/rules-keep" ] || return 1
  echo "$d"
}

# 控えの書き込み先を検査して、中身を入れた一時ファイルを同じディレクトリに用意する（$BASE_TMP）。
# 固定名の一時ファイルは使わない（リンクを置かれていると辿った先を上書きする）
prep_base() {  # $1=控えにする配布物
  check_path "$BASE_REL"
  if [ -L "$BASE_PKG" ]; then die "$BASE_REL はシンボリックリンクです（リンク先を壊すので中断しました）"; fi
  mkdir -p "$(dirname "$BASE_PKG")"
  BASE_TMP="$(mktemp "$BASE_PKG.XXXXXX")" || die "控えの一時ファイルを作れませんでした"
  cp "$1" "$BASE_TMP" || die "控えを用意できませんでした（ルールは書き換えていません）"
}

# ── いまの版と、配信されている版 ─────────────────────────────────────────
if [ -f "$VERSION_FILE" ]; then
  LOCAL_VERSION="$(head -1 "$VERSION_FILE" | tr -d '\r\n')"
else
  LOCAL_VERSION="unknown"
fi
LOCAL_SHA="${LOCAL_VERSION##*/}"

CODE="$(api version "$TMPDIR_WORK/version.json")" || die "サーバに接続できません（${URL}）"
if [ "$CODE" != "200" ]; then
  ERR="$(RU_F="$TMPDIR_WORK/version.json" "$PY" -c "$PY_LF"'
import json, os, sys
try:
    print(json.load(open(os.environ["RU_F"], encoding="utf-8")).get("error", "unknown"))
except Exception:
    print("unreadable_response")')"
  echo "❌ 版を確認できません（HTTP $CODE / ${ERR}）" >&2
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

eval "$(RU_F="$TMPDIR_WORK/version.json" "$PY" -c "$PY_LF"'
import json, os, shlex
d = json.load(open(os.environ["RU_F"], encoding="utf-8"))
for k in ("version", "sha", "published_at", "sha256", "size", "template"):
    print("REMOTE_%s=%s" % (k.upper(), shlex.quote(str(d.get(k, "")))))')"

echo "いまの版 : $LOCAL_VERSION"
echo "最新の版 : ${REMOTE_VERSION}（公開 ${REMOTE_PUBLISHED_AT:0:16})"

# ── 控え（前回適用した配布物）と比べる ───────────────────────────────────
# 控えと中身が違う配布ファイル＝配布後にこのプロジェクトで書き足した・直したもの。上書きすれば
# 黙って消える（2026-09-13 現場実例：CLAUDE.md のコマンド表に足した1行が更新で消え、以後の AI には
# 「無いコマンド」になった）。案件の記録（rules-keep）と版ファイルは比べない。
#   BASE_STATE=ok       控えと比べた
#              current  控えが使えない（無い／読めない／版が合わない）が最新なので、いまの版の配布物を
#                       取ってきて代わりに比べた（--apply で控えにする）
#              none     比べられない（控えが使えず、新しい版が出ている）＝新しい版の --apply は --force が要る
BASE_STATE="none"; BASE_WHY=""; BSRC=""
BASE_X="$TMPDIR_WORK/base"
EDITED="$TMPDIR_WORK/edited.list"; : > "$EDITED"
BASE_LIST="$TMPDIR_WORK/base.list"; : > "$BASE_LIST"
if [ ! -f "$BASE_PKG" ]; then
  BASE_WHY="控え（${BASE_REL}）がありません"
elif ! BSRC="$(open_pkg "$BASE_PKG" "$BASE_X")"; then
  BASE_WHY="控え（${BASE_REL}）を読めません"; BSRC=""
elif [ "$(head -1 "$BSRC/$VERSION_REL" 2>/dev/null | tr -d '\r\n')" != "$LOCAL_VERSION" ]; then
  BASE_WHY="控え（${BASE_REL}）の版が、いまの版と合いません"; BSRC=""
else
  BASE_STATE="ok"
fi
if [ "$BASE_STATE" != "ok" ] && [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
  # いまの版がそのまま配信中なら、取ってくれば控えの代わりになる（書き足しの有無もいま調べられる）
  rm -rf "$BASE_X"
  CUR="$TMPDIR_WORK/current.tar.gz"
  if [ "$(api fetch "$CUR")" = "200" ] && [ "$(sha256_of "$CUR")" = "$REMOTE_SHA256" ] \
     && BSRC="$(open_pkg "$CUR" "$BASE_X")"; then
    BASE_STATE="current"
  else
    BSRC=""
  fi
fi
if [ -n "$BSRC" ]; then
  # 改行コードの違い（CRLF⇔LF。Windows の git が変える）だけなら編集と数えない。単独の CR は数える
  RU_B="$BSRC" RU_R="$ROOT_DIR" RU_V="$VERSION_REL" RU_L="$BASE_LIST" "$PY" -c "$PY_LF"'
import os
base, root, ver = os.environ["RU_B"], os.environ["RU_R"], os.environ["RU_V"]
with open(os.path.join(base, ".claude", "rules-keep"), encoding="utf-8") as f:
    keep = [l.strip("\r\n") for l in f if l.strip("\r\n")]
def kept(p):
    return any(p.startswith(k) if k.endswith("/") else p == k for k in keep)
dist = []
for d, _, fs in os.walk(base):
    for n in fs:
        p = os.path.relpath(os.path.join(d, n), base).replace(os.sep, "/")
        if p != ver and not kept(p):
            dist.append(p)
dist.sort()
with open(os.environ["RU_L"], "w", encoding="utf-8", newline="\n") as o:
    o.write("".join(p + "\n" for p in dist))
for p in dist:
    lp = os.path.join(root, p)
    if not os.path.isfile(lp):
        continue
    with open(os.path.join(base, p), "rb") as f:
        a = f.read()
    with open(lp, "rb") as f:
        b = f.read()
    if a != b and a.replace(b"\r\n", b"\n") != b.replace(b"\r\n", b"\n"):
        print(p)' > "$EDITED"
fi
if [ -s "$EDITED" ]; then
  echo
  echo "⚠️  配布後にこのプロジェクトで編集された配布ファイルがあります（更新すると上書きされ、書き足した分は消えます）:"
  sed 's/^/   - /' "$EDITED"
  cat <<'EDITGUIDE'
   配布ファイルには書き足さない決まりです（CLAUDE.md「配布ファイルに書き足さない」）。
   書き足した行は project-config.md「固有の追加」節へ移し、配布ファイルからは消してから更新してください。
   何を足したかは  git log -p -- <上のパス>  で分かります。
EDITGUIDE
fi

if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
  if [ "$BASE_STATE" = "current" ]; then
    if [ "$APPLY" = "1" ]; then
      prep_base "$CUR"
      mv "$BASE_TMP" "$BASE_PKG" || die "控え（${BASE_REL}）を書けませんでした"
      BASE_TMP=""
      echo "📝 控えを作りました: ${BASE_REL}（ルールは書き換えていません。コミットしておく）"
    else
      echo "📝 ${BASE_WHY}。最新のうちに  bash bin/rules-update.sh --apply  で作れます（ルールは書き換えないので、人の確認は要りません）"
    fi
  elif [ "$BASE_STATE" = "none" ]; then
    echo "⚠️  ${BASE_WHY}。配布後に書き足した配布ファイルを調べられませんでした（異常なしという意味ではありません）"
  fi
  echo "✅ 最新です。更新は要りません。"
  exit 0
fi
if [ "$BASE_STATE" = "none" ]; then
  echo
  echo "⚠️  ${BASE_WHY}。配布後に書き足した配布ファイルを調べられません（異常なしという意味ではありません）。"
  echo "   このまま --apply すると止まります（rules/modes/rules-update.md §4）。"
fi

# ── 自分の版より後に何が変わったか ───────────────────────────────────────
if [ "$(api changelog "$TMPDIR_WORK/changelog.tsv")" = "200" ]; then
  echo
  echo "── この更新で入る変更 ─────────────────────────────"
  RU_F="$TMPDIR_WORK/changelog.tsv" RU_SHA="$LOCAL_SHA" "$PY" -c "$PY_LF"'
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
[ "$(sha256_of "$PKG")" = "$REMOTE_SHA256" ] || die "取得した配布物が壊れています（SHA256 不一致）。もう一度実行してください。"

# 展開する前に中身を見る（配布物が汚染された場合の保険）。
BAD="$(unsafe_paths "$PKG")"
[ -z "$BAD" ] || die "配布物に危険なパスが含まれています（展開しませんでした）: $BAD"
mkdir -p "$TMPDIR_WORK/x"
tar xzf "$PKG" -C "$TMPDIR_WORK/x" || die "配布物を展開できませんでした"
SRC="$(find "$TMPDIR_WORK/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$SRC" ] && [ -d "$SRC" ] || die "配布物の中身が想定と違います"

# 守るファイルの一覧は配布物に同梱されている（こちらで書かない＝足された日にズレない）
KEEPFILE="$SRC/.claude/rules-keep"
[ -f "$KEEPFILE" ] || die "配布物に .claude/rules-keep がありません（古い形式の配布物です）"

# ── 何を上書きするかを決める ─────────────────────────────────────────────
OVER="$TMPDIR_WORK/overwrite.list"; : > "$OVER"
NEW="$TMPDIR_WORK/new.list";       : > "$NEW"
SKIP="$TMPDIR_WORK/skip.list";     : > "$SKIP"
# find の -printf は GNU 専用（macOS の BSD find には無い）ので、先頭の ./ を自分で落とす
( cd "$SRC" && find . -type f ) | sed 's|^\./||' | sort > "$TMPDIR_WORK/all.list"
while IFS= read -r rel; do
  if [ -e "$ROOT_DIR/$rel" ]; then
    if keep_p "$rel"; then echo "$rel" >> "$SKIP"; else echo "$rel" >> "$OVER"; fi
  else
    echo "$rel" >> "$NEW"
  fi
done < "$TMPDIR_WORK/all.list"

# 上書き対象に未コミットの変更があると、それは黙って消える。git があるなら止める。
if [ -s "$OVER" ] && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # xargs の -d/-a も GNU 専用。NUL 区切りなら BSD の xargs でも渡せる
  DIRTY="$(cd "$ROOT_DIR" && tr '\n' '\0' < "$OVER" | xargs -0 git status --porcelain -- 2>/dev/null || true)"
  if [ -n "$DIRTY" ] && [ "$FORCE" != "1" ]; then
    echo "❌ 上書き対象に未コミットの変更があります（消えてしまいます）:" >&2
    printf '%s\n' "$DIRTY" | sed 's/^/   /' >&2
    echo "   先にコミットするか、承知のうえなら --force を付けてください。" >&2
    exit 1
  fi
fi


# ここからは「コミット済みでも消えるもの」を見る。未コミットの確認（上）より後＝止まる理由が1つずつ出る
csort() { tr -d '\r' < "$1" | LC_ALL=C sort -u; }   # \r を落としてから比べる（Windows の Python・上の PY_LF と二重の守り）
if [ "$BASE_STATE" != "ok" ] && [ -s "$OVER" ] && [ "$FORCE" != "1" ]; then
  echo "❌ ${BASE_WHY}。配布後に書き足した配布ファイルがあっても見つけられないので、適用しません。" >&2
  echo "   git log -p で CLAUDE.md・rules/・.claude/ に書き足しが無いことを確かめ、人が判断したら --force を付けてください。" >&2
  echo "   （適用すると控えが作られ、次回からは自動で調べます）" >&2
  exit 1
fi

# 配布後に編集された配布ファイルを上書きすると、書き足した分が黙って消える
LOST=""
if [ -s "$EDITED" ]; then LOST="$(comm -12 <(csort "$OVER") <(csort "$EDITED"))"; fi
if [ -n "$LOST" ] && [ "$FORCE" != "1" ]; then
  echo "❌ 配布後にこのプロジェクトで編集された配布ファイルを上書きしようとしています（書き足した分が消えます）:" >&2
  printf '%s\n' "$LOST" | sed 's/^/   /' >&2
  echo "   書き足した行を project-config.md「固有の追加」節へ移してから、もう一度流してください。" >&2
  echo "   消えて構わないと人が判断したときだけ --force を付けてください。" >&2
  exit 1
fi

# テンプレートに新しく入ったファイルと同じ名前のファイルが、既にこのプロジェクトにある
# （案件で作った固有のコマンド・以前は案件の記録だったもの）。控えの配布一覧に無いのに上書き対象＝衝突
COLLIDE=""
if [ "$BASE_STATE" = "ok" ] && [ -s "$OVER" ]; then
  COLLIDE="$(comm -23 <(csort "$OVER") <(csort "$BASE_LIST") | grep -vFx -e "$VERSION_REL" || true)"
fi
if [ -n "$COLLIDE" ] && [ "$FORCE" != "1" ]; then
  echo "❌ テンプレートに新しく入ったファイルと同じ名前のファイルが、このプロジェクトに既にあります（上書きすると元の中身が消えます）:" >&2
  printf '%s\n' "$COLLIDE" | sed 's/^/   /' >&2
  echo "   このプロジェクトで作ったファイルなら別の名前に移し（project-config.md「固有の追加」の登録も直す）、もう一度流してください。" >&2
  echo "   上書きして構わないと人が判断したときだけ --force を付けてください。" >&2
  exit 1
fi

# ── 書き込む前の検査（ここで止まれば何も書き換えていない） ─────────────────────
# **1文字も書く前に**全部の行き先を検査する。途中で止まると「一部だけ新しい」状態になり、
# しかも版だけ先に書き換わっていると「最新です」と嘘をつくようになる。
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  check_path "$rel"
  dst="$ROOT_DIR/$rel"
  if [ -L "$dst" ]; then die "$rel はシンボリックリンクです（リンク先を壊すので中断しました）"; fi
  # 同じ名前のディレクトリがあると、cp はその中に書いて「成功」する（本来の場所は古いまま）
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then die "$rel が通常のファイルではありません（ディレクトリ等）。中断しました（何も書き換えていません）"; fi
done < <(cat "$OVER" "$NEW")
prep_base "$PKG"   # 控えも書き始める前に用意する（最後に失敗して控えだけ古い、を作らない）

# ── 退避してから書き込む ────────────────────────────────────────────────
BACKUP_DIR="$ROOT_DIR/.claude/rules-backup"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"   # 同じ秒に2回動いても前の退避を潰さない
BACKUP="$BACKUP_DIR/${STAMP}.tar.gz"
if [ -s "$OVER" ]; then
  mkdir -p "$BACKUP_DIR"
  ( cd "$ROOT_DIR" && tar czf "$BACKUP" -T "$OVER" ) \
    || die "退避に失敗したので中断しました（何も書き換えていません）"
fi

# 書いた分を戻す（0=戻せた／1=戻しきれなかった）。上書きしたものは退避から、新しく置いたファイルと
# 作ったディレクトリは消す。一部だけ新しいと、次回は新しいファイルが「配布後に編集された」に見えて止まり続ける
MADE_DIRS="$TMPDIR_WORK/made-dirs.list"; : > "$MADE_DIRS"
rollback() {
  local rel ng=0
  if [ -s "$OVER" ]; then ( cd "$ROOT_DIR" && tar xzf "$BACKUP" ) || ng=1; fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -e "$ROOT_DIR/$rel" ]; then rm -f "$ROOT_DIR/$rel" || ng=1; fi
  done < "$NEW"
  # 深い順に、空のときだけ消す（中に案件のファイルがあれば残す）
  LC_ALL=C sort -r "$MADE_DIRS" | while IFS= read -r rel; do rmdir "$ROOT_DIR/$rel" 2>/dev/null || true; done
  return "$ng"
}

ensure_dir() {  # $1=相対ディレクトリ。無い要素だけ作り、作ったものを MADE_DIRS に記録する
  local cur="" part oldifs="$IFS"
  [ "$1" = "." ] && return 0
  IFS='/'
  set -- $1
  IFS="$oldifs"
  for part in "$@"; do
    cur="${cur:+$cur/}$part"
    if [ ! -d "$ROOT_DIR/$cur" ]; then
      mkdir "$ROOT_DIR/$cur" || return 1
      echo "$cur" >> "$MADE_DIRS"
    fi
  done
}

# 版は控えより前・ファイルより後に書く（途中で失敗したときに「更新済み」と名乗らせない）
WRITING="yes"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ "$rel" = "$VERSION_REL" ] && continue
  if ! { ensure_dir "$(dirname "$rel")" && cp "$SRC/$rel" "$ROOT_DIR/$rel"; }; then
    die "$rel を書き込めませんでした"
  fi
done < <(cat "$OVER" "$NEW")
if [ -f "$SRC/$VERSION_REL" ]; then
  if ! { ensure_dir "$(dirname "$VERSION_REL")" && cp "$SRC/$VERSION_REL" "$ROOT_DIR/$VERSION_REL"; }; then
    die "版（${VERSION_REL}）を書けませんでした"
  fi
fi
WRITING=""
BASE_OK="yes"
if mv "$BASE_TMP" "$BASE_PKG"; then BASE_TMP=""; else BASE_OK=""; fi

count() { wc -l < "$1" | tr -d ' '; }
echo
echo "✅ 更新しました: $REMOTE_VERSION"
echo "   上書き $(count "$OVER") / 新規 $(count "$NEW") / 触らない $(count "$SKIP")（案件の記録）"
if [ -s "$OVER" ]; then echo "   退避   : .claude/rules-backup/${STAMP}.tar.gz（戻すときはここから）"; fi
if [ -n "$BASE_OK" ]; then
  echo "   控え   : ${BASE_REL}（次の更新で「配布後に編集されたファイル」を見つけるのに使う。コミットしておく）"
else
  echo "   ⚠️ 控え（${BASE_REL}）を置き換えられませんでした。ルールの更新は済んでいます。bash bin/rules-update.sh --apply で作り直してください"
fi
cat <<'NEXT'

   次にやること:
     1. CLAUDE.md と rules/ を読み直す（作業中のセッションは前提が変わっています）
     2. 変更点を人に共有する
     3. 使ってみて困ったら bash bin/rule-report.sh で知らせる（版は自動で載ります）
NEXT

}

main "$@"; exit
