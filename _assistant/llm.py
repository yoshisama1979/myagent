"""Claude tool_use 対応の薄いラッパ。

harness-factory-main/engine/llm/client.py から `ClaudeToolClient` 相当だけを抜粋。
評価エンジン用の `ClaudeClient` / `extract_json` は持ち込まない（不要なため）。
"""

from __future__ import annotations

import os
from typing import Any, Protocol


class ToolLLM(Protocol):
    """tool_use ループから呼ばれる最小 IF（テストではフェイクに差し替える）。"""

    def create(self, *, system: str, messages: list, tools: list) -> Any: ...


class ClaudeToolClient:
    """anthropic SDK の tool_use 対応ラッパ。API キーは ANTHROPIC_API_KEY から読む。"""

    def __init__(self, model: str, max_tokens: int = 4096, api_key: str | None = None) -> None:
        import truststore  # 社内 TLS の証明書ストアを使うため
        truststore.inject_into_ssl()
        from anthropic import Anthropic

        self._client = Anthropic(api_key=api_key or os.environ.get("ANTHROPIC_API_KEY"))
        self._model = model
        self._max_tokens = max_tokens

    def create(self, *, system: str, messages: list, tools: list) -> Any:
        return self._client.messages.create(
            model=self._model,
            max_tokens=self._max_tokens,
            system=system,
            tools=tools,
            messages=messages,
        )
