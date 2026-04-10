#!/bin/bash
# hana-tools API ラッパースクリプト
# 使い方: bash bin/hana-api.sh <コマンド> [オプション]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# .env読み込み
if [ ! -f "$ENV_FILE" ]; then
  echo '{"success": false, "message": ".envファイルが見つかりません"}' >&2
  exit 1
fi
source "$ENV_FILE"

if [ -z "$HANA_TOOLS_API_TOKEN" ] || [ "$HANA_TOOLS_API_TOKEN" = "your-token-here" ]; then
  echo '{"success": false, "message": ".envにAPIトークンを設定してください"}' >&2
  exit 1
fi

BASE_URL="${HANA_TOOLS_BASE_URL:-https://stg.hana-tools.com}"

# --- API関数 ---

# クライアント一覧取得
get_clients() {
  curl -s -k -X GET "$BASE_URL/api/external/clients" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN"
}

# クライアント検索（部分一致）
# 引数: 検索キーワード（カンマ区切りでOR検索可）
search_clients() {
  local keyword="$1"
  if [ -z "$keyword" ]; then
    echo '{"success": false, "message": "検索キーワードを指定してください"}' >&2
    exit 1
  fi
  # 日本語対応: PHPでURLエンコード
  local encoded=$(php -r "echo rawurlencode('$keyword');")
  curl -s -k -X GET "$BASE_URL/api/external/clients/search?q=$encoded" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN"
}

# 外注先一覧取得
get_outsources() {
  curl -s -k -X GET "$BASE_URL/api/external/outsources" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN"
}

# ToDo一覧取得
# オプション: --user_id=N --work_id=N --status=incomplete|completed|all
get_todos() {
  local params=""
  local user_id_set=false
  for arg in "$@"; do
    case "$arg" in
      --user_id=*)  params="${params}&user_id=${arg#*=}"; user_id_set=true ;;
      --work_id=*)  params="${params}&work_id=${arg#*=}" ;;
      --status=*)   params="${params}&status=${arg#*=}" ;;
    esac
  done
  # user_id未指定時はデフォルト値を使用
  if [ "$user_id_set" = false ] && [ -n "$HANA_TOOLS_DEFAULT_USER_ID" ]; then
    params="${params}&user_id=$HANA_TOOLS_DEFAULT_USER_ID"
  fi
  # 先頭の&を?に置換
  if [ -n "$params" ]; then
    params="?${params:1}"
  fi
  curl -s -k -X GET "$BASE_URL/api/external/todos${params}" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN"
}

# ToDo登録
# 引数: JSON文字列 '{"work_id":3,"user_id":1,"content":"タスク名",...}'
create_todo() {
  local json="$1"
  if [ -z "$json" ]; then
    echo '{"success": false, "message": "JSON引数が必要です"}' >&2
    exit 1
  fi
  echo "$json" | curl -s -k -X POST "$BASE_URL/api/external/todos" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d @-
}

# Chatwork通知送信
# 引数: JSON文字列 '{"room_id":"123","message":"テスト"}'
send_chatwork() {
  local json="${1:-{}}"
  echo "$json" | curl -s -k -X POST "$BASE_URL/api/external/chatwork/send-message" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d @-
}

# --- メイン ---

command="$1"
shift

case "$command" in
  clients)      get_clients ;;
  search)       search_clients "$@" ;;
  outsources)   get_outsources ;;
  todos)        get_todos "$@" ;;
  create-todo)  create_todo "$@" ;;
  chatwork)     send_chatwork "$@" ;;
  *)
    cat <<USAGE
hana-tools APIラッパー

使い方:
  bash bin/hana-api.sh <コマンド> [オプション]

コマンド:
  clients                          クライアント一覧取得
  search "キーワード"              クライアント検索（部分一致、カンマ区切りでOR検索）
  outsources                       外注先一覧取得
  todos [--user_id=N] [--status=S] ToDo一覧取得
  create-todo '{"work_id":N,...}'  ToDo登録
  chatwork '{"message":"..."}'     Chatwork通知送信
USAGE
    exit 1
    ;;
esac
