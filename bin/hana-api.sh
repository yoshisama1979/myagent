#!/bin/bash
# hana-tools API ラッパースクリプト
# 使い方: bash bin/hana-api.sh <コマンド> [オプション]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# .env読み込み（source せず、必要キーだけ安全に取り出す＝他行のクオート漏れ/スペースで壊れない）
if [ ! -f "$ENV_FILE" ]; then
  echo '{"success": false, "message": ".envファイルが見つかりません"}' >&2
  exit 1
fi
read_env() {  # $1=KEY を .env から取り出し、前後の引用符と末尾CRを除去（最初の一致のみ）
  local v
  v=$(grep -E "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null | head -n1 | sed -E "s/^[[:space:]]*$1=//")
  v="${v%$'\r'}"
  v="${v#\"}"; v="${v%\"}"
  v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}
HANA_TOOLS_API_TOKEN="$(read_env HANA_TOOLS_API_TOKEN)"
HANA_TOOLS_BASE_URL="$(read_env HANA_TOOLS_BASE_URL)"
HANA_TOOLS_DEFAULT_USER_ID="$(read_env HANA_TOOLS_DEFAULT_USER_ID)"

if [ -z "$HANA_TOOLS_API_TOKEN" ] || [ "$HANA_TOOLS_API_TOKEN" = "your-token-here" ]; then
  echo '{"success": false, "message": ".envにAPIトークンを設定してください"}' >&2
  exit 1
fi

BASE_URL="${HANA_TOOLS_BASE_URL:-https://stg.hana-tools.com}"

# --- 共通ヘルパー ---

# 数値ID検証：^[0-9]+$ 以外は弾く（URL パス/クエリへの注入防止）
require_int() {
  local val="$1" name="$2"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "{\"success\": false, \"message\": \"$name は数値で指定してください\"}" >&2
    exit 1
  fi
}

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
# オプション:
#   --user_id=N           作成者でフィルタ
#   --assignee_user_id=N  実質担当者でフィルタ（null=作成者担当の正規化済みデータも含む）
#   --work_id=N           特定案件のToDoのみ
#   --status=incomplete|completed|all
# user_id / assignee_user_id いずれも未指定の場合は HANA_TOOLS_DEFAULT_USER_ID を assignee_user_id に適用
get_todos() {
  local params=""
  local user_filter_set=false
  for arg in "$@"; do
    case "$arg" in
      --user_id=*)           params="${params}&user_id=${arg#*=}"; user_filter_set=true ;;
      --assignee_user_id=*)  params="${params}&assignee_user_id=${arg#*=}"; user_filter_set=true ;;
      --work_id=*)           params="${params}&work_id=${arg#*=}" ;;
      --status=*)            params="${params}&status=${arg#*=}" ;;
    esac
  done
  # ユーザー系フィルタが未指定時は assignee_user_id にデフォルト値を適用
  # （null=自分が担当の正規化済みデータも含めるため assignee_user_id を優先）
  if [ "$user_filter_set" = false ] && [ -n "$HANA_TOOLS_DEFAULT_USER_ID" ]; then
    params="${params}&assignee_user_id=$HANA_TOOLS_DEFAULT_USER_ID"
  fi
  # 先頭の&を?に置換
  if [ -n "$params" ]; then
    params="?${params:1}"
  fi
  curl -s -k -X GET "$BASE_URL/api/external/todos${params}" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN"
}

# ToDo登録
# 引数: JSON文字列 '{"work_id":3,"user_id":1,"assignee_user_id":2,"content":"タスク名",...}'
# 注: assignee_user_id を user_id と同値で指定するとサーバ側で null に正規化される
#     （「作成者が担当」の意味、未指定時と等価）
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

# ToDo編集（PUT /todos/{id}）
# 引数: <todo_id> <JSON文字列>
# 送信したフィールドのみ部分更新。work_id（案件移動）は変更不可。
# completed_at に日付で完了、null で未完了に戻す。
# assignee_user_id を対象ToDoの作成者と同値 or 未指定なら null（=作成者が担当）に正規化される。
update_todo() {
  local id="$1"; shift
  local json="$1"
  if [ -z "$id" ] || [ -z "$json" ]; then
    echo '{"success": false, "message": "使い方: update-todo <todo_id> <JSON>"}' >&2
    exit 1
  fi
  require_int "$id" "todo_id"
  printf '%s' "$json" | curl -s -k -X PUT "$BASE_URL/api/external/todos/$id" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @-
}

# プロジェクト一覧取得（GET /projects）
# オプション: --client_id=N（特定クライアントのプロジェクトのみ。数値・1つだけ）
# レスポンスは client / works を含み、site_url・gsc_dataset 等のフルフィールド
get_projects() {
  local client_id=""
  for arg in "$@"; do
    case "$arg" in
      --client_id=*)
        if [ -n "$client_id" ]; then
          echo '{"success": false, "message": "--client_id は1つだけ指定してください"}' >&2
          exit 1
        fi
        client_id="${arg#*=}"
        require_int "$client_id" "client_id"
        ;;
    esac
  done
  local params=""
  [ -n "$client_id" ] && params="?client_id=$client_id"
  curl -s -k -X GET "$BASE_URL/api/external/projects${params}" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN"
}

# プロジェクト詳細取得（GET /projects/{id}）
# 引数: <project_id>
get_project() {
  local id="$1"
  if [ -z "$id" ]; then
    echo '{"success": false, "message": "project_id を指定してください"}' >&2
    exit 1
  fi
  require_int "$id" "project_id"
  curl -s -k -X GET "$BASE_URL/api/external/projects/$id" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN"
}

# プロジェクトメモ取得（GET /projects/{id}/notes）
# 引数: <project_id> [--user_id=N]
# shared（全体共有）＋ user_id 指定時は mine（個人メモ）を返す。無ければ null（404ではない）
get_project_notes() {
  local id="$1"; shift
  if [ -z "$id" ]; then
    echo '{"success": false, "message": "project_id を指定してください"}' >&2
    exit 1
  fi
  require_int "$id" "project_id"
  local user_id=""
  for arg in "$@"; do
    case "$arg" in
      --user_id=*)
        if [ -n "$user_id" ]; then
          echo '{"success": false, "message": "--user_id は1つだけ指定してください"}' >&2
          exit 1
        fi
        user_id="${arg#*=}"
        require_int "$user_id" "user_id"
        ;;
    esac
  done
  local params=""
  [ -n "$user_id" ] && params="?user_id=$user_id"
  curl -s -k -X GET "$BASE_URL/api/external/projects/$id/notes${params}" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN"
}

# プロジェクトメモ追加・更新（POST /projects/{id}/notes・upsert）
# 引数: <project_id> <JSON文字列>
# JSON 例: {"visibility":"shared","body":"<p>..</p>"}（private 時は user_id 必須）
#   任意: edit_summary / expected_version（楽観ロック・不一致は409） / edited_by_user_id
# body の HTML はサーバ側で常にサニタイズ（script/on*/javascript: 等は除去）
update_project_note() {
  local id="$1"; shift
  local json="$1"
  if [ -z "$id" ] || [ -z "$json" ]; then
    echo '{"success": false, "message": "使い方: update-note <project_id> <JSON>"}' >&2
    exit 1
  fi
  require_int "$id" "project_id"
  printf '%s' "$json" | curl -s -k -X POST "$BASE_URL/api/external/projects/$id/notes" \
    -H "X-API-TOKEN: $HANA_TOOLS_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @-
}

# --- メイン ---

command="$1"
shift

# 無人実行では書き込み系サブコマンドを物理的に拒否（automation.md：外部送信・共有書込・本番作用は
# 社長合意の上で有人実行する）。ルールの規約だけに頼らず、無人 claude -p からの暴発を塞ぐ。
if [ "${MYAGENT_UNATTENDED:-}" = "1" ]; then
  case "$command" in
    create-todo|update-todo|update-note|chatwork)
      echo "{\"success\": false, \"message\": \"無人実行では書き込み系コマンド($command)は実行できません。実行案を有人セッション/社長合意に回してください。\"}" >&2
      exit 2 ;;
  esac
fi

case "$command" in
  clients)      get_clients ;;
  search)       search_clients "$@" ;;
  outsources)   get_outsources ;;
  todos)        get_todos "$@" ;;
  create-todo)  create_todo "$@" ;;
  update-todo)  update_todo "$@" ;;
  projects)     get_projects "$@" ;;
  project)      get_project "$@" ;;
  notes)        get_project_notes "$@" ;;
  update-note)  update_project_note "$@" ;;
  chatwork)     send_chatwork "$@" ;;
  *)
    cat <<USAGE
hana-tools APIラッパー

使い方:
  bash bin/hana-api.sh <コマンド> [オプション]

コマンド（取得＝読み取り）:
  clients                          クライアント一覧取得
  search "キーワード"              クライアント検索（部分一致、カンマ区切りでOR検索）
  outsources                       外注先一覧取得
  todos [--user_id=N] [--assignee_user_id=N] [--work_id=N] [--status=S]
                                   ToDo一覧取得（フィルタ未指定時は assignee_user_id=デフォルトユーザー）
  projects [--client_id=N]         プロジェクト一覧取得（client/works・site_url・gsc_dataset 含む）
  project <id>                     プロジェクト詳細取得
  notes <project_id> [--user_id=N] プロジェクトメモ取得（shared ＋ user_id 指定で mine）

コマンド（登録・編集＝書き込み。共有システムへの書き込みは社長合意の上で）:
  create-todo '{"work_id":N,...}'  ToDo登録（assignee_user_id 省略 or user_id と同値で「作成者が担当」）
  update-todo <id> '{...}'         ToDo編集（部分更新。work_id変更不可。completed_at で完了/未完了）
  update-note <project_id> '{...}' プロジェクトメモ追加・更新（upsert。visibility=shared|private）
  chatwork '{"message":"..."}'     Chatwork通知送信（外部送信）
USAGE
    exit 1
    ;;
esac
