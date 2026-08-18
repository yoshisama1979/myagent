#!/usr/bin/env bash
# agent-commit.sh — 無人エージェントが「自分のサイクルの成果物」だけをコミットする。
#
# 契機＝2026-08-17 社長判断（O-040 の続き）。無人ループはコミット権を持たず、成果物が git の外に
# 溜まり続けていた（最大 146件・最古47日）。**サイクル末に自分の分だけ**コミットする形にする。
#
# なぜ週1のスイーパーにしないか：
#   ・日次ループには最良のタイミングが既にある＝**自分の1サイクルが終わった瞬間**（何をしたか本人が知っている）
#   ・「コミットだけが仕事」の定期実行を足すと、それが黙って止まったとき誰も気づかない
#     （このリポジトリの事故はすべてこの形＝mailbox 5日停止・許可リスト片形欠け・ローテ不発 O-038）
#   ・週1だと7サイクルが1コミットに固まり、1日単位で巻き戻せない
#
# なぜ **agent-tick.sh から呼ぶ**のか（claude に叩かせない）：
#   許可リスト（.claude/settings.local.json）を経由すると4形の登録が要り、片形でも欠けると
#   **無言停止**する（[[reference_allowlist-bash-prefix-gap]]＝実害5日の前例）。
#   シェルから直に呼べばその経路自体が無い。LLM が忘れることもない（宣言でなく機械＝testing.md §4）。
#
# 使い方: bin/agent-commit.sh <agent名>            # 例: bin/agent-commit.sh hp-loop-ycom
#         bin/agent-commit.sh <agent名> --dry-run  # ステージせず対象だけ出す
#
# 安全：ステージ範囲は precommit-guard.py --paths-for が返す**そのエージェントの許可パスだけ**
#       （表を2箇所に持たない）。未登録エージェントは何もせず 0 で抜ける（＝黙って全部を掴まない）。
#       コミット前に pre-commit フックが秘密値・領域外・破損を再検査する（二重の防御）。
set -uo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$PROJ/bin/precommit-guard.py"
AGENT="${1:-}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1

log() { printf '%s [agent-commit] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[ -n "$AGENT" ] || { log "エージェント名が必要です"; exit 2; }
[ -f "$GUARD" ] || { log "precommit-guard.py が無いので何もしません"; exit 0; }

# --- 許可パスを1箇所（precommit-guard の表）から引く ---
mapfile -t PATHS < <(python3 "$GUARD" --paths-for "$AGENT" 2>/dev/null)
if [ "${#PATHS[@]}" -eq 0 ]; then
  log "$AGENT は許可パス未登録＝自動コミットの対象外（何もしません）"
  exit 0
fi

cd "$PROJ" || exit 0

# 許可パスのうち「まだ存在しないもの」を落とす。
# ⚠️ git add は存在しない pathspec を **エラー**にする（"did not match any files"）＝
#    共有台帳をまだ作っていない新サイトを足した瞬間、そのループのコミットが毎回失敗する。
#    2026-08-18 のサイト別化でテストが検出した。除外指定（":!"）は常に残す（照合対象ではないため）。
KEEP=()
for x in "${PATHS[@]}"; do
  case "$x" in
    :!*) KEEP+=("$x"); continue ;;
  esac
  if [ -e "$x" ] || git ls-files --error-unmatch -- "$x" >/dev/null 2>&1; then KEEP+=("$x"); fi
done
# 実体のある対象が1つも無ければ何もしない（除外指定だけ残った状態でコミットしない）
have=0; for x in "${KEEP[@]:-}"; do case "$x" in :!*) ;; *) have=1 ;; esac; done
if [ "$have" = 0 ]; then
  log "$AGENT: 対象パスがまだ存在しません（何もしません）"
  exit 0
fi
PATHS=("${KEEP[@]}")

# --- 対象に変更があるか（無ければ空コミットを作らない） ---
if git diff --quiet -- "${PATHS[@]}" && git diff --cached --quiet -- "${PATHS[@]}" \
   && [ -z "$(git ls-files --others --exclude-standard -- "${PATHS[@]}")" ]; then
  log "$AGENT: 変更なし"
  exit 0
fi

if [ "$DRY" = 1 ]; then
  log "$AGENT の対象（--dry-run）:"
  git status --porcelain -- "${PATHS[@]}" | sed 's/^/    /'
  exit 0
fi

# --- 共有インデックスを避けて一時インデックスで組む ---
# 有人セッションや他モードが同時にステージしている可能性があるため、共有インデックスには触れない
# （2026-08-17 に実際、別セッションのステージ済み作業と衝突した）。
TMP_INDEX="$(mktemp -t agent-commit-index.XXXXXX)"
trap 'rm -f "$TMP_INDEX"' EXIT
export GIT_INDEX_FILE="$TMP_INDEX"
if ! git read-tree HEAD 2>/dev/null; then
  log "$AGENT: HEAD を読めないため中止（rebase/merge 中の可能性）"
  exit 0
fi
git add -A -- "${PATHS[@]}" || { log "$AGENT: ステージに失敗"; exit 1; }

if git diff --cached --quiet; then
  log "$AGENT: 実質の差分なし（.gitignore 対象のみ等）"
  exit 0
fi

n=$(git diff --cached --name-only | wc -l)
files=$(git diff --cached --name-only | head -3 | sed 's|.*/||' | tr '\n' ' ')
[ "$n" -gt 3 ] && files="$files ほか$((n-3))件"
msg="[auto] $AGENT: サイクルの記録を保存（${n}件: ${files})"

# index.lock の競合（有人セッションと重なったとき）は数回待って再試行する
for i in 1 2 3 4 5; do
  if out=$(git commit -q -m "$msg" 2>&1); then
    # ★共有インデックスを新しい HEAD に揃える。これを忘れると共有インデックスが古いままになり、
    #   次に**別セッションがコミットしたときこのコミットを巻き戻す**（2026-08-17 に手作業で実際に踏んだ）。
    #   自分の許可パスだけを reset する＝相手のステージ済み作業には触れない。
    ( unset GIT_INDEX_FILE; git reset -q -- "${PATHS[@]}" ) 2>/dev/null || true
    log "$AGENT: コミットしました（${n}件）"
    exit 0
  fi
  case "$out" in
    *index.lock*|*"Unable to create"*)
      log "$AGENT: index.lock 競合（${i}/5）。3秒待って再試行"; sleep 3; continue ;;
    *)
      # フックが止めた場合はここに来る＝理由をログに残して次サイクルへ（無理に通さない）
      log "$AGENT: コミットせず（$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)）"
      exit 1 ;;
  esac
done
log "$AGENT: index.lock を取得できずコミット見送り（次サイクルで再試行されます）"
exit 1
