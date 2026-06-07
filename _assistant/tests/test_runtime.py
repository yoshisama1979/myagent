"""runtime.build_agent() の組み立て検証。

実 LLM / 実 hana-tools を叩かないよう、ClaudeToolClient と HanaToolsClient を
ダミーに差し替えた状態で組み立てが成功することだけ確認する。
"""

from __future__ import annotations

import pytest

from _assistant import runtime
from _assistant.agent import PartnerAgent


class _FakeLLM:
    def __init__(self, **kwargs):
        self.kwargs = kwargs

    def create(self, **kwargs):
        raise AssertionError("build_agent はインスタンス組立のみ。create を呼ぶべきでない")


class _FakeHana:
    def __init__(self, *args, **kwargs):
        self.kwargs = kwargs


@pytest.fixture(autouse=True)
def _inject_fakes(monkeypatch):
    monkeypatch.setattr(runtime, "ClaudeToolClient", _FakeLLM)
    monkeypatch.setattr(runtime, "HanaToolsClient", _FakeHana)
    # 実 .env を読まないようにする（monkeypatch.setenv/delenv の結果が
    # load_dotenv の setdefault に上書きされる事故を防ぐ）
    monkeypatch.setattr(runtime, "load_dotenv", lambda: None)


def test_build_agent_returns_partner_agent(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-anthropic")
    monkeypatch.setenv("HANA_TOOLS_API_TOKEN", "test-hana")
    monkeypatch.delenv("HANA_TOOLS_DEFAULT_USER_ID", raising=False)
    monkeypatch.delenv("HANA_MY_USER_ID", raising=False)

    agent = runtime.build_agent()
    assert isinstance(agent, PartnerAgent)


def test_build_agent_parses_default_user_id_as_int(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-anthropic")
    monkeypatch.setenv("HANA_TOOLS_API_TOKEN", "test-hana")
    monkeypatch.setenv("HANA_TOOLS_DEFAULT_USER_ID", "42")
    monkeypatch.delenv("HANA_MY_USER_ID", raising=False)

    agent = runtime.build_agent()
    # 内部 attr に依存するが、agent の外向き API では user_id を観測できないため最小限の例外
    assert agent._my_user_id == 42  # noqa: SLF001


def test_build_agent_falls_back_to_legacy_my_user_id(monkeypatch):
    """旧名 HANA_MY_USER_ID も後方互換で読める。"""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-anthropic")
    monkeypatch.setenv("HANA_TOOLS_API_TOKEN", "test-hana")
    monkeypatch.delenv("HANA_TOOLS_DEFAULT_USER_ID", raising=False)
    monkeypatch.setenv("HANA_MY_USER_ID", "7")

    agent = runtime.build_agent()
    assert agent._my_user_id == 7  # noqa: SLF001


def test_build_agent_prefers_default_user_id_over_legacy(monkeypatch):
    """両方設定されていたら新名（HANA_TOOLS_DEFAULT_USER_ID）が勝つ。"""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-anthropic")
    monkeypatch.setenv("HANA_TOOLS_API_TOKEN", "test-hana")
    monkeypatch.setenv("HANA_TOOLS_DEFAULT_USER_ID", "10")
    monkeypatch.setenv("HANA_MY_USER_ID", "99")

    agent = runtime.build_agent()
    assert agent._my_user_id == 10  # noqa: SLF001


def test_build_agent_loads_prompt_md(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-anthropic")
    monkeypatch.setenv("HANA_TOOLS_API_TOKEN", "test-hana")

    agent = runtime.build_agent()
    assert agent._prompt  # noqa: SLF001
    assert "業務パートナー" in agent._prompt or "業務" in agent._prompt  # noqa: SLF001
    assert "ツール" in agent._prompt  # noqa: SLF001


def test_build_agent_uses_dispatcher_for_tool_routing(monkeypatch):
    """組み立てた dispatcher が未知ツール拒否する（make_dispatcher 経由が確認できる）。"""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-anthropic")
    monkeypatch.setenv("HANA_TOOLS_API_TOKEN", "test-hana")

    agent = runtime.build_agent()
    with pytest.raises(ValueError):
        agent._dispatch("not_a_real_tool", {})  # noqa: SLF001


def test_build_agent_rejects_invalid_default_user_id(monkeypatch):
    """HANA_TOOLS_DEFAULT_USER_ID が整数でないなら文脈つきエラーを出して落ちる。"""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-anthropic")
    monkeypatch.setenv("HANA_TOOLS_API_TOKEN", "test-hana")
    monkeypatch.setenv("HANA_TOOLS_DEFAULT_USER_ID", "not-a-number")
    monkeypatch.delenv("HANA_MY_USER_ID", raising=False)

    with pytest.raises(RuntimeError) as exc_info:
        runtime.build_agent()
    assert "HANA_TOOLS_DEFAULT_USER_ID" in str(exc_info.value)
