#!/bin/bash
# Slack 送信ラッパースクリプト（Incoming Webhook）
# 使い方:
#   bash bin/slack.sh "メッセージ"                  # 引数で送信
#   echo "複数行メッセージ" | bash bin/slack.sh       # 標準入力で送信（チェック出力をパイプ）
#   bash bin/slack.sh --raw '{"text":"...","blocks":[...]}'  # 生JSON（検証あり：top-levelは text/blocks のみ）
#   bash bin/slack.sh --dry-run "メッセージ"          # 送信せずペイロードと送信先ラベルだけ表示
#
# 認証情報は .env の SLACK_WEBHOOK_URL を使う（gitignore 済み）。
#   SLACK_DESTINATION_LABEL（任意）を設定しておくと、送信先の取り違え防止のため表示する。
# Webhook の発行: Slack管理画面 → Apps → "Incoming Webhooks" → チャンネル選択 → URL発行
# 安全に作る/回す際の作法は rules/automation.md を参照。

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# --- 依存コマンド確認（cron では PATH が対話シェルと異なるため明示チェック） ---
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 が必要です" >&2; exit 1; }
command -v curl    >/dev/null 2>&1 || { echo "ERROR: curl が必要です" >&2; exit 1; }

# --- .env から必要な値だけを安全に抽出（source しない＝任意コード実行・変数汚染を防ぐ） ---
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env が見つかりません ($ENV_FILE)" >&2
  exit 1
fi

# KEY=value 形式の最後の定義を取り、前後の空白とクォート・CR を除去する
get_env_value() {
  local key="$1" line val
  line="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n1 || true)"
  [ -z "$line" ] && return 0
  val="${line#*=}"
  val="${val%$'\r'}"                      # 末尾CR除去（CRLF対策）
  val="${val#"${val%%[![:space:]]*}"}"    # 先頭空白除去
  val="${val%"${val##*[![:space:]]}"}"    # 末尾空白除去
  # 外側のクォートを1組だけ外す
  case "$val" in
    \"*\") val="${val%\"}"; val="${val#\"}" ;;
    \'*\') val="${val%\'}"; val="${val#\'}" ;;
  esac
  printf '%s' "$val"
}

SLACK_WEBHOOK_URL="$(get_env_value SLACK_WEBHOOK_URL)"
SLACK_DESTINATION_LABEL="$(get_env_value SLACK_DESTINATION_LABEL)"

if [ -z "$SLACK_WEBHOOK_URL" ]; then
  echo "ERROR: .env に SLACK_WEBHOOK_URL を設定してください" >&2
  exit 1
fi

# --- オプション解釈 ---
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

# --- ペイロード組み立て ---
if [ "${1:-}" = "--raw" ]; then
  raw="${2:-}"
  if [ -z "$raw" ]; then
    echo "ERROR: --raw には JSON 文字列が必要です" >&2
    exit 1
  fi
  # JSON 妥当性検証＋top-level キーを text/blocks に制限（誤流入・メンション悪用を防ぐ）
  payload="$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.exit("不正なJSON: %s" % e)
if not isinstance(d, dict):
    sys.exit("top-level は JSON オブジェクトである必要があります")
allowed = {"text", "blocks"}
extra = set(d) - allowed
if extra:
    sys.exit("許可されないキー: %s（text/blocks のみ可）" % ", ".join(sorted(extra)))
print(json.dumps(d, ensure_ascii=False))
')"
else
  # メッセージ本文：引数優先、無ければ標準入力
  if [ -n "${1:-}" ]; then
    message="$1"
  else
    message="$(cat)"
  fi
  if [ -z "$message" ]; then
    echo "ERROR: 送信するメッセージが空です" >&2
    exit 1
  fi
  # 本文は stdin 経由で Python に渡す（環境変数サイズ制限・NULバイト問題を回避）
  payload="$(printf '%s' "$message" | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}, ensure_ascii=False))')"
fi

# --- dry-run：送信せず内容と送信先を表示 ---
if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] 送信先: ${SLACK_DESTINATION_LABEL:-(SLACK_DESTINATION_LABEL 未設定)}"
  echo "[dry-run] payload: $payload"
  exit 0
fi

# --- 送信 ---
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# curl 失敗（DNS/接続/TLS/タイムアウト）でも set -e で即死させず明示処理する
if ! http_code="$(curl -sS -o "$tmp" -w '%{http_code}' \
    --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 1 --retry-all-errors \
    -X POST "$SLACK_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "$payload")"; then
  resp="$(cat "$tmp" 2>/dev/null || true)"
  echo "ERROR: Slack送信失敗（curl エラー）: $resp" >&2
  exit 1
fi
resp="$(cat "$tmp" 2>/dev/null || true)"

if [ "$http_code" = "200" ]; then
  echo "OK: Slack送信成功${SLACK_DESTINATION_LABEL:+（送信先: $SLACK_DESTINATION_LABEL）}"
else
  echo "ERROR: Slack送信失敗 (HTTP $http_code): $resp" >&2
  exit 1
fi
