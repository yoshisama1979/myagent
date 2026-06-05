"""PartnerAgent の tool_use ループの単体テスト。

実 LLM を呼ばず、FakeLLM で固定 response を返す。dispatcher も差し替えて、
agent.py の制約（max_tool_calls / 同一ツール連続 / total timeout / size 切り詰め）
だけを検証する。
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from _assistant import agent as agent_mod
from _assistant.agent import AgentLoopDetectedError, PartnerAgent
from _assistant.config import (
    CONSECUTIVE_SAME_TOOL_LIMIT,
    MAX_TOOL_CALLS_PER_MESSAGE,
    TOOL_RESULT_MAX_BYTES,
)


# ---- フェイク helper -------------------------------------------------------


def _text_block(text: str):
    return SimpleNamespace(type="text", text=text)


def _tool_use_block(name: str, input_: dict, id_: str = "tu_1"):
    return SimpleNamespace(type="tool_use", name=name, input=input_, id=id_)


def _response(stop_reason: str, content: list):
    return SimpleNamespace(stop_reason=stop_reason, content=content)


class _FakeLLM:
    def __init__(self, responses):
        self._responses = list(responses)
        self.calls: list[dict] = []

    def create(self, *, system, messages, tools):
        self.calls.append({"system": system, "messages": messages, "tools": tools})
        if not self._responses:
            raise AssertionError("FakeLLM: 想定外の追加呼び出し")
        return self._responses.pop(0)


def _build(llm, dispatcher=None, my_user_id=42, prompt="TEST PROMPT"):
    if dispatcher is None:
        dispatcher = lambda name, args: {"echo": [name, args]}
    return PartnerAgent(llm=llm, dispatcher=dispatcher, prompt=prompt, my_user_id=my_user_id)


# ---- 正常系 ----------------------------------------------------------------


def test_ask_returns_text_when_no_tool_use():
    llm = _FakeLLM([
        _response("end_turn", [_text_block("こんにちは")]),
    ])
    agent = _build(llm)
    assert agent.ask("hi") == "こんにちは"
    assert len(llm.calls) == 1


def test_reply_runs_one_tool_then_finishes():
    calls = []
    def dispatcher(name, args):
        calls.append((name, args))
        return [{"id": 1, "content": "todo"}]

    llm = _FakeLLM([
        _response("tool_use", [_tool_use_block("get_todos", {"status": "incomplete"}, id_="tu_a")]),
        _response("end_turn", [_text_block("未完了タスクは1件です")]),
    ])
    agent = _build(llm, dispatcher=dispatcher)

    text, history = agent.reply("今日のタスクは？", history=[])
    assert text == "未完了タスクは1件です"
    assert calls == [("get_todos", {"status": "incomplete"})]
    # 履歴に user / assistant(tool_use) / user(tool_result) / assistant(text) が入る
    assert len(history) == 4
    assert history[0]["role"] == "user"
    assert history[1]["role"] == "assistant"
    assert history[2]["role"] == "user"
    tool_result = history[2]["content"][0]
    assert tool_result["type"] == "tool_result"
    assert tool_result["tool_use_id"] == "tu_a"
    assert "todo" in tool_result["content"]
    assert history[3]["role"] == "assistant"


def test_system_prompt_includes_jst_date_and_user_id():
    llm = _FakeLLM([
        _response("end_turn", [_text_block("ok")]),
    ])
    agent = _build(llm, my_user_id=99, prompt="MY_PROMPT")
    agent.ask("hi")
    sys_text = llm.calls[0]["system"]
    assert "MY_PROMPT" in sys_text
    assert "user_id: 99" in sys_text
    assert "今日(JST):" in sys_text


def test_system_prompt_omits_user_id_line_when_none():
    """my_user_id 未設定なら user_id 行を出さない（None と表示されない）。"""
    llm = _FakeLLM([
        _response("end_turn", [_text_block("ok")]),
    ])
    agent = _build(llm, my_user_id=None)
    agent.ask("hi")
    sys_text = llm.calls[0]["system"]
    assert "user_id" not in sys_text
    assert "None" not in sys_text


# ---- 異常系（ツール失敗）-----------------------------------------------------


def test_tool_error_is_returned_as_is_error_block():
    def dispatcher(name, args):
        raise ValueError("nope")

    llm = _FakeLLM([
        _response("tool_use", [_tool_use_block("get_todos", {}, id_="tu_x")]),
        _response("end_turn", [_text_block("失敗を踏まえて回答")]),
    ])
    agent = _build(llm, dispatcher=dispatcher)

    text, history = agent.reply("?", history=[])
    assert text == "失敗を踏まえて回答"
    tool_result = history[2]["content"][0]
    assert tool_result["is_error"] is True
    assert "ツール実行エラー" in tool_result["content"]
    assert "nope" in tool_result["content"]


# ---- 制約: 同一ツール連続検出 ----------------------------------------------


def test_consecutive_same_tool_calls_raise_loop_detected():
    """同じ name+args が CONSECUTIVE_SAME_TOOL_LIMIT 回連続したら例外。"""
    same_block = lambda i: _tool_use_block("get_todos", {"status": "incomplete"}, id_=f"tu_{i}")

    # 3 ターン連続で同じツールを要求 → 3 回目で AgentLoopDetectedError
    responses = []
    for i in range(CONSECUTIVE_SAME_TOOL_LIMIT):
        responses.append(_response("tool_use", [same_block(i)]))

    llm = _FakeLLM(responses)
    agent = _build(llm)
    with pytest.raises(AgentLoopDetectedError):
        agent.reply("?", history=[])


def test_consecutive_different_args_does_not_trigger():
    """同じ name でも引数が違えば連続検出には引っかからない。"""
    responses = []
    for i in range(CONSECUTIVE_SAME_TOOL_LIMIT + 1):
        responses.append(_response("tool_use", [_tool_use_block("get_todos", {"work_id": i}, id_=f"tu_{i}")]))
    responses.append(_response("end_turn", [_text_block("done")]))

    llm = _FakeLLM(responses)
    agent = _build(llm)
    text, _ = agent.reply("?", history=[])
    assert text == "done"


# ---- 制約: max tool calls / message ----------------------------------------


def test_max_tool_calls_per_message_terminates_with_notice(monkeypatch):
    """tool 呼び出し総数が上限を超えたら中断メッセージで return する。"""
    monkeypatch.setattr(agent_mod, "MAX_TOOL_CALLS_PER_MESSAGE", 2)

    # 各ターン異なる引数で名前は同じ（連続検出には引っかからない）
    responses = []
    for i in range(5):  # 5 回連続 tool_use → 2 を超えた時点で中断
        responses.append(_response("tool_use", [_tool_use_block("get_todos", {"work_id": i}, id_=f"tu_{i}")]))

    llm = _FakeLLM(responses)
    agent = _build(llm)
    text, history = agent.reply("?", history=[])
    assert "中断" in text and "tool 呼び出し回数" in text
    # 中断時：未解決 tool_use を is_error tool_result で閉じてから assistant の通知を入れる
    assert history[-2]["role"] == "user"
    tr = history[-2]["content"][0]
    assert tr["type"] == "tool_result"
    assert tr["is_error"] is True
    assert history[-1]["role"] == "assistant"
    assert "中断" in history[-1]["content"]


# ---- 制約: total timeout ---------------------------------------------------


def test_total_timeout_terminates_with_notice(monkeypatch):
    """time.monotonic を進めて timeout 経過を再現。

    1 周目の check 時点では deadline 内（続行）、2 周目の check 時点で deadline 超過
    を作るため、tool_use を 2 ターン連続させる。
    """
    monkeypatch.setattr(agent_mod, "TOTAL_TIMEOUT_SECONDS", 1)

    # 0.0: deadline 計算 → deadline=1.0
    # 0.5: 1 周目 check → < 1.0 → 続行
    # 5.0: 2 周目 check → > 1.0 → 中断
    times = iter([0.0, 0.5, 5.0])
    monkeypatch.setattr(agent_mod.time, "monotonic", lambda: next(times))

    llm = _FakeLLM([
        _response("tool_use", [_tool_use_block("get_todos", {"work_id": 1}, id_="tu_1")]),
        _response("tool_use", [_tool_use_block("get_todos", {"work_id": 2}, id_="tu_2")]),
    ])
    agent = _build(llm)
    text, history = agent.reply("?", history=[])
    assert "中断" in text and "総実行時間" in text
    # 中断時：tu_2 の tool_use に対する is_error tool_result が挿入されてから assistant 通知
    assert history[-2]["role"] == "user"
    assert history[-2]["content"][0]["type"] == "tool_result"
    assert history[-2]["content"][0]["tool_use_id"] == "tu_2"
    assert history[-2]["content"][0]["is_error"] is True
    assert history[-1]["role"] == "assistant"


# ---- tool_result サイズ切り詰め -------------------------------------------


def test_tool_result_truncated_when_oversized(monkeypatch):
    """注記込みで TOOL_RESULT_MAX_BYTES を厳密に超えないこと（Codex 指摘反映）。"""
    monkeypatch.setattr(agent_mod, "TOOL_RESULT_MAX_BYTES", 200)

    def dispatcher(name, args):
        return "x" * 5000  # 大きく超過

    llm = _FakeLLM([
        _response("tool_use", [_tool_use_block("read_site_file", {"path": "a.md"}, id_="tu_big")]),
        _response("end_turn", [_text_block("ok")]),
    ])
    agent = _build(llm, dispatcher=dispatcher)

    _, history = agent.reply("?", history=[])
    tool_result = history[2]["content"][0]
    assert "省略" in tool_result["content"]
    # 注記込みで 200 バイト以内に厳密収まる
    assert len(tool_result["content"].encode("utf-8")) <= 200


def test_tool_result_passthrough_when_within_limit():
    def dispatcher(name, args):
        return {"key": "value"}

    llm = _FakeLLM([
        _response("tool_use", [_tool_use_block("get_todos", {}, id_="tu_s")]),
        _response("end_turn", [_text_block("ok")]),
    ])
    agent = _build(llm, dispatcher=dispatcher)

    _, history = agent.reply("?", history=[])
    tool_result = history[2]["content"][0]
    assert "省略" not in tool_result["content"]
    payload = json.loads(tool_result["content"])
    assert payload == {"key": "value"}
