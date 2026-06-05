"""業務パートナーの実体組み立て（実 LLM ＋ 実 API クライアント）。

CLI（scripts/ask.py）と Chainlit UI（app.py）から共通で使う。
"""

from __future__ import annotations

import os
from pathlib import Path

from _assistant.agent import PartnerAgent
from _assistant.config import MAX_TOKENS_PARTNER, MODEL_PARTNER, load_dotenv
from _assistant.hana_client import HanaToolsClient
from _assistant.llm import ClaudeToolClient
from _assistant.tools import make_dispatcher

_PROMPT_PATH = Path(__file__).resolve().parent / "prompt.md"


def build_agent() -> PartnerAgent:
    """実 LLM ＋ 実 hana-tools クライアント ＋ dispatcher ＋ prompt を組み立てる。

    `.env` を `load_dotenv()` で読んでから、必須キーは各クライアントの fail-fast に
    任せる（`HANA_TOOLS_API_TOKEN` 必須、`ANTHROPIC_API_KEY` は ClaudeToolClient 内で
    `ANTHROPIC_API_KEY` 環境変数を読む）。
    """
    load_dotenv()

    my_user_id_raw = os.environ.get("HANA_MY_USER_ID")
    if my_user_id_raw:
        try:
            my_user_id: int | None = int(my_user_id_raw)
        except ValueError as exc:
            raise RuntimeError(
                f"HANA_MY_USER_ID は整数で指定してください（実値: {my_user_id_raw!r}）"
            ) from exc
    else:
        my_user_id = None

    client = HanaToolsClient()  # token fail-fast
    prompt = _PROMPT_PATH.read_text(encoding="utf-8")

    return PartnerAgent(
        llm=ClaudeToolClient(model=MODEL_PARTNER, max_tokens=MAX_TOKENS_PARTNER),
        dispatcher=make_dispatcher(client),
        prompt=prompt,
        my_user_id=my_user_id,
    )
