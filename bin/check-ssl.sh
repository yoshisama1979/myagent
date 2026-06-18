#!/bin/bash
# SSL 有効期限チェックスクリプト
# 弊社管理ドメインの SSL 証明書の残り日数を確認し、結果を要約する。
#
# 使い方:
#   bash bin/check-ssl.sh                        # 既定の一覧をチェックして結果を表示（送信しない）
#   bash bin/check-ssl.sh path/to/domains.txt    # 一覧ファイルを指定
#   bash bin/check-ssl.sh --slack                # 結果を Slack に送信（bin/slack.sh 経由）
#   bash bin/check-ssl.sh --slack --only-problems # 警告・異常があるときだけ Slack 送信
#
# しきい値（環境変数で上書き可）:
#   CRIT_DAYS（既定 7）  … これ以下は 🔴 緊急
#   WARN_DAYS（既定 30） … これ以下は 🟡 警告
#
# 通知本文の情報分類: ドメイン名・有効期限・残日数は公開情報。秘密情報は含めない（rules/automation.md §2）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_LIST="$ROOT_DIR/data/ssl-check/domains.txt"

CRIT_DAYS="${CRIT_DAYS:-7}"
WARN_DAYS="${WARN_DAYS:-30}"
TZ_BASE="Asia/Tokyo"

command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl が必要です" >&2; exit 1; }

# --- 引数解釈 ---
SEND_SLACK=0
ONLY_PROBLEMS=0
LIST_FILE=""
for arg in "$@"; do
  case "$arg" in
    --slack)         SEND_SLACK=1 ;;
    --only-problems) ONLY_PROBLEMS=1 ;;
    -*)              echo "ERROR: 不明なオプション: $arg" >&2; exit 1 ;;
    *)               LIST_FILE="$arg" ;;
  esac
done
LIST_FILE="${LIST_FILE:-$DEFAULT_LIST}"

if [ ! -f "$LIST_FILE" ]; then
  echo "ERROR: ドメイン一覧が見つかりません: $LIST_FILE" >&2
  exit 1
fi

# --- 1ドメインの notAfter（GMT文字列）を取得。失敗時は空 ---
get_enddate() {
  local host="$1"
  echo | timeout 15 openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2
}

now_epoch="$(date +%s)"
n_ok=0 n_warn=0 n_crit=0 n_err=0
lines=""        # 1行ごとの結果（残日数昇順に並べ替える）

while IFS= read -r raw || [ -n "$raw" ]; do
  domain="${raw%%#*}"                       # 行内コメント除去
  domain="$(printf '%s' "$domain" | tr -d '[:space:]')"
  [ -z "$domain" ] && continue

  enddate="$(get_enddate "$domain")"
  if [ -z "$enddate" ]; then
    n_err=$((n_err+1))
    # 並べ替えキー 0 で先頭へ
    lines+="$(printf '%012d\t⚠️ ERROR\t%s\t接続/証明書取得に失敗' 0 "$domain")"$'\n'
    continue
  fi

  exp_epoch="$(date -d "$enddate" +%s 2>/dev/null || echo "")"
  if [ -z "$exp_epoch" ]; then
    n_err=$((n_err+1))
    lines+="$(printf '%012d\t⚠️ ERROR\t%s\t日付解釈に失敗(%s)' 0 "$domain" "$enddate")"$'\n'
    continue
  fi

  days=$(( (exp_epoch - now_epoch) / 86400 ))
  exp_jst="$(TZ="$TZ_BASE" date -d "$enddate" '+%Y-%m-%d')"

  if   [ "$days" -le "$CRIT_DAYS" ]; then status="🔴 緊急"; n_crit=$((n_crit+1))
  elif [ "$days" -le "$WARN_DAYS" ]; then status="🟡 警告"; n_warn=$((n_warn+1))
  else                                    status="✅ OK";   n_ok=$((n_ok+1))
  fi

  # 並べ替えキー：残日数（負やERRORが先頭に来るよう 100000 + days のゼロ詰め）
  sortkey=$(printf '%012d' $((100000 + days)))
  lines+="$(printf '%s\t%s\t%s\t残り%d日（%s まで）' "$sortkey" "$status" "$domain" "$days" "$exp_jst")"$'\n'
done < "$LIST_FILE"

total=$((n_ok + n_warn + n_crit + n_err))
checked_at="$(TZ="$TZ_BASE" date '+%Y-%m-%d %H:%M') JST"

# --- 本文組み立て（残日数昇順＝危険なものが上） ---
header="SSL有効期限チェック（${checked_at}）
対象 ${total}件： 🔴緊急 ${n_crit} / 🟡警告 ${n_warn} / ✅OK ${n_ok} / ⚠️ERROR ${n_err}
しきい値：緊急 ≤${CRIT_DAYS}日 / 警告 ≤${WARN_DAYS}日"

body="$(printf '%s' "$lines" | sort | cut -f2-)"

report="${header}

${body}"

echo "$report"

# --- Slack 送信（明示時のみ） ---
has_problem=0
if [ "$n_crit" -gt 0 ] || [ "$n_warn" -gt 0 ] || [ "$n_err" -gt 0 ]; then has_problem=1; fi

if [ "$SEND_SLACK" = "1" ]; then
  if [ "$ONLY_PROBLEMS" = "1" ] && [ "$has_problem" = "0" ]; then
    echo "(--only-problems: 問題なしのため Slack 送信はスキップ)"
  else
    printf '%s' "$report" | bash "$SCRIPT_DIR/slack.sh"
  fi
fi

# 緊急があれば非0終了（cron 等での検知用。警告のみ・OKは0）
if [ "$n_crit" -gt 0 ]; then exit 2; fi
exit 0
