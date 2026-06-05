"""業務パートナーの tool_use ループ。

会話 → Claude がツール要求 → dispatcher で実行 → 結果を返す → 回答、を回す。

partner/agent.py を移植元として、PLAN.md §4.3 のエージェント実行制約を追加:
- 1 メッセージあたり最大 tool call 回数 (MAX_TOOL_CALLS_PER_MESSAGE)
- 総実行時間 timeout (TOTAL_TIMEOUT_SECONDS)
- tool result サイズ上限切り詰め (TOOL_RESULT_MAX_BYTES)
- 同一ツール連続呼び出し検出 (CONSECUTIVE_SAME_TOOL_LIMIT)

LLM は `create(system, messages, tools)` を持つオブジェクトとして注入する
（実体は `_assistant.llm.ClaudeToolClient`、テストではフェイク）。
dispatcher は `_assistant.tools.make_dispatcher(client)` の戻り値。
"""

from __future__ import annotations

import json
import time
from collections import deque
from datetime import UTC, datetime, timedelta
from typing import Any, Callable

from _assistant.config import (
    CONSECUTIVE_SAME_TOOL_LIMIT,
    MAX_TOOL_CALLS_PER_MESSAGE,
    TOOL_RESULT_MAX_BYTES,
    TOTAL_TIMEOUT_SECONDS,
)
from _assistant.llm import ToolLLM
from _assistant.tools import TOOL_SCHEMAS

_JST = timedelta(hours=9)
_TRUNCATION_NOTICE = "\n…(以下省略：tool_result はサイズ上限で切り詰めました)"


class AgentLoopDetectedError(RuntimeError):
    """同一ツール+同一引数が連続呼ばれた時に投げる（暴走検出）。"""


class PartnerAgent:
    """LLM の tool_use ループを回す業務パートナー。

    `ask` は履歴なし、`reply` は履歴を返すので Chainlit セッションから使う。
    """

    def __init__(
        self,
        llm: ToolLLM,
        dispatcher: Callable[[str, dict[str, Any]], Any],
        prompt: str,
        my_user_id: int | None = None,
    ) -> None:
        self._llm = llm
        self._dispatch = dispatcher
        self._prompt = prompt
        self._my_user_id = my_user_id

    def ask(self, user_message: str) -> str:
        """1問1答（履歴なし、CLI 動作確認用）。"""
        text, _ = self.reply(user_message, history=[])
        return text

    def reply(self, user_message: str, history: list) -> tuple[str, list]:
        """会話履歴つきの応答。返り値は (回答テキスト, 更新後の履歴)。

        履歴には user/assistant に加え tool_use / tool_result も積み、
        次ターンで Claude が「何を取得したか」を覚えていられるようにする。
        """
        system = self._render_system()
        messages: list = list(history)
        messages.append({"role": "user", "content": user_message})

        deadline = time.monotonic() + TOTAL_TIMEOUT_SECONDS
        recent_calls: deque = deque(maxlen=CONSECUTIVE_SAME_TOOL_LIMIT)
        total_tool_calls = 0

        response = self._llm.create(system=system, messages=messages, tools=TOOL_SCHEMAS)
        while True:
            messages.append({"role": "assistant", "content": response.content})
            if getattr(response, "stop_reason", None) != "tool_use":
                return _text_of(response), messages

            tool_blocks = [b for b in response.content if getattr(b, "type", None) == "tool_use"]

            # 中断する場合でも、未解決 tool_use は必ず is_error の tool_result で閉じてから return。
            # でないと履歴を次回 reply() に渡したとき Anthropic API が tool_use/result の対応欠落で拒否する。
            if time.monotonic() > deadline:
                notice = f"中断: 総実行時間 {TOTAL_TIMEOUT_SECONDS}s を超えたため打ち切りました"
                return _abort_with_tool_results(messages, tool_blocks, notice)

            # 同一ツール+同一引数が連続上限回 → 強制終了（無限ループ防止）
            for block in tool_blocks:
                sig = (block.name, json.dumps(block.input, sort_keys=True, default=str))
                recent_calls.append(sig)
                if (
                    len(recent_calls) == CONSECUTIVE_SAME_TOOL_LIMIT
                    and len(set(recent_calls)) == 1
                ):
                    # ここで raise する前にも tool_use を未解決のまま残さない（履歴は最後の
                    # assistant tool_use まで含まれている）。raise を受けた呼び出し側が履歴を
                    # 再利用する設計なら _abort_with_tool_results を使う想定だが、現状は呼び側で
                    # 履歴を捨てる前提なので raise 単独で OK。
                    raise AgentLoopDetectedError(
                        f"同一ツール+引数が {CONSECUTIVE_SAME_TOOL_LIMIT} 回連続呼ばれました: {block.name}"
                    )

            total_tool_calls += len(tool_blocks)
            if total_tool_calls > MAX_TOOL_CALLS_PER_MESSAGE:
                notice = (
                    f"中断: 1 会話あたりの tool 呼び出し回数 {MAX_TOOL_CALLS_PER_MESSAGE} を超えました"
                )
                return _abort_with_tool_results(messages, tool_blocks, notice)

            messages.append({"role": "user", "content": self._run_tools(tool_blocks)})
            response = self._llm.create(system=system, messages=messages, tools=TOOL_SCHEMAS)

    def _run_tools(self, blocks: list) -> list[dict]:
        results: list[dict] = []
        for block in blocks:
            try:
                data = self._dispatch(block.name, block.input)
                content = _stringify(data)
                content = _truncate(content, TOOL_RESULT_MAX_BYTES)
                results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": content,
                    }
                )
            except Exception as exc:  # noqa: BLE001 - ツール失敗は Claude に返して継続させる
                results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": f"ツール実行エラー: {exc}",
                        "is_error": True,
                    }
                )
        return results

    def _render_system(self) -> str:
        today = (datetime.now(UTC) + _JST).date().isoformat()
        lines = [self._prompt, "", "# 実行コンテキスト"]
        if self._my_user_id is not None:
            lines.append(f"- あなた(self)の user_id: {self._my_user_id}")
        lines.append(f"- 今日(JST): {today}")
        return "\n".join(lines)


def _stringify(data: Any) -> str:
    if isinstance(data, str):
        return data
    return json.dumps(data, ensure_ascii=False, default=str)


def _truncate(s: str, max_bytes: int) -> str:
    """UTF-8 でエンコードした際に注記込みで max_bytes を超えないよう切り詰める。"""
    encoded = s.encode("utf-8")
    if len(encoded) <= max_bytes:
        return s
    notice_bytes = len(_TRUNCATION_NOTICE.encode("utf-8"))
    body_budget = max(0, max_bytes - notice_bytes)
    truncated = encoded[:body_budget].decode("utf-8", errors="ignore")
    return truncated + _TRUNCATION_NOTICE


def _abort_with_tool_results(messages: list, tool_blocks: list, notice: str) -> tuple[str, list]:
    """中断時：未解決 tool_use を全て is_error の tool_result で閉じてから notice を返す。

    Anthropic API は tool_use と tool_result の対応欠落を拒否するので、履歴を次回も
    使えるように必ず閉じる。
    """
    if tool_blocks:
        results = [
            {
                "type": "tool_result",
                "tool_use_id": b.id,
                "content": notice,
                "is_error": True,
            }
            for b in tool_blocks
        ]
        messages.append({"role": "user", "content": results})
    messages.append({"role": "assistant", "content": f"({notice})"})
    return f"({notice})", messages


def _text_of(response: Any) -> str:
    parts = [
        block.text
        for block in getattr(response, "content", [])
        if getattr(block, "type", None) == "text"
    ]
    return "".join(parts).strip()
