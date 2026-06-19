#!/usr/bin/env bash
# hp-shot.sh — hp-shot.mjs（T-008・読み取り専用スクリーンショット）の起動ラッパ。
# cron/ヘッドレス（agent-tick 経由）では PATH に nvm の node が無いため、ここで node を解決する。
# 使い方：bin/hp-shot.sh <URL> <出力ディレクトリ> [名前]
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
NODE="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE" ]; then
  NODE="$(ls -d /home/vpsuser/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1 || true)"
fi
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  echo "hp-shot.sh: node が見つかりません（nvm/PATH を確認）" >&2
  exit 127
fi
exec "$NODE" "$PROJ/bin/hp-shot.mjs" "$@"
