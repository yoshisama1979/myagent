#!/usr/bin/env bash
# hp-serp.sh — hp-serp.mjs（T-011・読み取り専用・Yahoo!JAPAN SERPから競合URL取得）の起動ラッパ。
# cron/ヘッドレスでは PATH に nvm の node が無いため、ここで node を解決する（hp-shot.sh と同型）。
# 使い方：bin/hp-serp.sh "<検索クエリ>" [--top N] [--exclude ドメイン,…] [--json|--urls]
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
NODE="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE" ]; then
  NODE="$(ls -d /home/vpsuser/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1 || true)"
fi
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  echo "hp-serp.sh: node が見つかりません（nvm/PATH を確認）" >&2
  exit 127
fi
exec "$NODE" "$PROJ/bin/hp-serp.mjs" "$@"
