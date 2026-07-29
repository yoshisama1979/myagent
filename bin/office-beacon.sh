#!/usr/bin/env bash
# office-beacon.sh — 3Dオフィスの「在席ビーコン」（見た目専用・本作業に影響しない）
#
#   start <id> [task] [from] [key] : data/office/live/<id>/<key>.json を書く（点灯）。
#                                    働いている間は何度呼んでもよい＝mtime が更新され TTL が延びる。
#   stop  <id> [key]               : 自分のリースだけ削除（消灯）。他セッションのリースは触らない。
#
# リース方式（Codexレビュー 2026-07-29 🔴反映）：
#   同じ id（例 finance）へ2セッションが同時に委任しても、リース＝<key>.json が別ファイルなので
#   先に終わった側の stop が相手のビーコンを消さない。status.php は「有効なリースが1件でもあれば働き中」。
#   key の既定は "manual"（手動テスト用）。フック等の自動化からは必ずセッション固有のキーを渡すこと。
#
# フェイルセーフ設計：TTL=600秒。セッションが落ちて stop できなくても、
# 更新が絶えれば status.php 側が期限切れとして無視する＝机が光りっぱなしにならない。
# 期限切れの残骸ファイルは start 時に掃除する（60分超＝どのTTLでも失効済みのものだけ）。
# 演出は実データのみ＝このビーコンは「実際に動いた者」だけが自分で灯す。
#
# <id> は status.php の台帳（$VPS_AGENTS の id）と同じもの（例: finance, hanasaka-main, partner）。
# 台帳に無い id を灯しても status.php 側は台帳の既知 id しか読まないので画面に出ない（安全側）。
#
# ⚠️ task に渡してよいのは短い固定ラベルだけ（例:「経費集計」「HP解析の深掘り」）。
#    生のプロンプト・依頼文・Bashコマンド・クライアント実名を渡さない（Codexレビュー 2026-07-29 🟡＝
#    task/from はそのままダッシュボードAPIに載る。フック自動化時もこの仕様を守ること）。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIVE="$ROOT/data/office/live"

cmd="${1:-}"; id="${2:-}"
case "$id" in (""|*[!a-z0-9-]*)
  echo "usage: office-beacon.sh start <id> [task] [from] [key] | stop <id> [key]  (id: a-z0-9- のみ)" >&2; exit 2;;
esac

case "$cmd" in
  start)
    key="${5:-manual}"
    case "$key" in (""|*[!A-Za-z0-9._-]*) echo "key: A-Za-z0-9._- のみ" >&2; exit 2;; esac
    mkdir -p "$LIVE/$id"
    # 期限切れの残骸を掃除（TTL上限=3600秒なので60分超は必ず失効済み。有効なリースは消えない）
    find "$LIVE" -name '*.json' -type f -mmin +60 -delete 2>/dev/null || true
    # JSON生成は python3 に任せる（改行除去・エスケープ・不正UTF-8を作らない）＋アトミック書き込み
    BEACON_TASK="${3:-}" BEACON_FROM="${4:-}" python3 - "$LIVE/$id/$key.json" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
def clean(v, n):
    v = " ".join((v or "").split())     # 改行・連続空白を潰す
    return v[:n] or None
rec = {"task": clean(os.environ.get("BEACON_TASK"), 120),
       "from": clean(os.environ.get("BEACON_FROM"), 40),
       "ttl": 600}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(rec, f, ensure_ascii=False)
os.replace(tmp, path)
PY
    ;;
  stop)
    key="${3:-manual}"
    case "$key" in (""|*[!A-Za-z0-9._-]*) echo "key: A-Za-z0-9._- のみ" >&2; exit 2;; esac
    rm -f "$LIVE/$id/$key.json"
    ;;
  *)
    echo "usage: office-beacon.sh start <id> [task] [from] [key] | stop <id> [key]" >&2; exit 2
    ;;
esac
