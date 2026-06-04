"""経営サポート用業務パートナーの設定モジュール。

`.env` の読み込み、モデル定数、必須環境変数の fail-fast 検証を提供する。
harness-factory-main/engine/config.py から partner 関連だけを抜粋した最小版。
"""

from __future__ import annotations

import os
from pathlib import Path

# このファイルは _assistant/config.py。プロジェクトルートは親ディレクトリ
ROOT = Path(__file__).resolve().parent.parent

# Claude モデル割当（応答性とコストのバランスで sonnet を既定に）
MODEL_PARTNER = "claude-sonnet-4-6"

# 出力トークン上限
MAX_TOKENS_PARTNER = 4096

# エージェント実行制約（PLAN.md §4.3）
MAX_TOOL_CALLS_PER_MESSAGE = 8
TOTAL_TIMEOUT_SECONDS = 120
HANA_HTTP_TIMEOUT_SECONDS = 30
SITE_READER_TIMEOUT_SECONDS = 10
TOOL_RESULT_MAX_BYTES = 50 * 1024
CONSECUTIVE_SAME_TOOL_LIMIT = 3

# site_reader 制限（PLAN.md §4.1）
READ_SITE_FILE_MAX_BYTES = 100 * 1024
GREP_SITE_MAX_HITS = 50
GREP_SITE_CONTEXT_LINES = 2
GREP_SITE_MAX_OUTPUT_BYTES = 100 * 1024
LIST_SITE_FILES_MAX_ENTRIES = 200
ALLOWED_SITE_EXTENSIONS = frozenset({".md", ".txt", ".html", ".json", ".csv", ".yaml", ".yml"})

# site/ ルート（プロジェクトルート直下）
SITE_ROOT = ROOT / "site"


def load_dotenv(path: Path | None = None) -> None:
    """`.env` があれば KEY=VALUE を環境変数へ読み込む（既存の環境変数は上書きしない）。

    依存を増やさないための最小実装。`_assistant/.env` を優先し、
    無ければプロジェクトルートの `.env` を読む（myagent 既存の .env 流用）。
    """
    if path is None:
        local = Path(__file__).resolve().parent / ".env"
        path = local if local.exists() else ROOT / ".env"
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def require_env(name: str) -> str:
    """必須環境変数を読み、未設定なら起動時に fail-fast。"""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"必須環境変数 {name} が未設定です。_assistant/.env または "
            f"プロジェクトルートの .env に設定してください"
        )
    return value
