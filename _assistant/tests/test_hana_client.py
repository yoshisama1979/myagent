"""HanaToolsClient の最小テスト（httpx.MockTransport で実通信を行わない）。

partner/client のテストを基に、myagent 環境変数（HANA_TOOLS_*）に合わせて移植。
fail-fast 検証のテストも追加。
"""

from __future__ import annotations

import httpx
import pytest

from _assistant.hana_client import HanaToolsClient, HanaToolsError


def _client(handler) -> HanaToolsClient:
    transport = httpx.MockTransport(handler)
    http = httpx.Client(transport=transport)
    return HanaToolsClient(base_url="https://x.test", token="tok", http_client=http)


def test_get_todos_unwraps_data_and_sends_token():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["X-API-TOKEN"] == "tok"
        assert request.url.path == "/api/external/todos"
        return httpx.Response(200, json={"success": True, "data": [{"id": 1, "content": "x"}]})

    todos = _client(handler).get_todos(assignee_user_id=34, status="incomplete")

    assert todos[0]["content"] == "x"


def test_get_todos_passes_filter_params():
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured.update(dict(request.url.params))
        return httpx.Response(200, json={"success": True, "data": []})

    _client(handler).get_todos(assignee_user_id=34, status="incomplete")

    assert captured["assignee_user_id"] == "34"
    assert captured["status"] == "incomplete"


def test_search_clients_sends_q():
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured.update(dict(request.url.params))
        assert request.url.path == "/api/external/clients/search"
        return httpx.Response(200, json={"success": True, "data": []})

    _client(handler).search_clients("ABC")

    assert captured["q"] == "ABC"


def test_get_clients_unwraps_data():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/external/clients"
        return httpx.Response(200, json={"success": True, "data": [{"id": 1}]})

    clients = _client(handler).get_clients()

    assert clients == [{"id": 1}]


def test_get_outsources_unwraps_data():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/external/outsources"
        return httpx.Response(200, json={"success": True, "data": [{"id": 2}]})

    outsources = _client(handler).get_outsources()

    assert outsources == [{"id": 2}]


def test_raises_on_success_false():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"success": False, "message": "ng"})

    with pytest.raises(HanaToolsError):
        _client(handler).get_clients()


def test_raises_on_http_error_status():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"success": False, "message": "auth"})

    with pytest.raises(HanaToolsError):
        _client(handler).get_outsources()


def test_raises_on_connection_error():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    with pytest.raises(HanaToolsError) as exc_info:
        _client(handler).get_clients()

    assert "HTTP error" in str(exc_info.value)


def test_fail_fast_when_token_missing(monkeypatch):
    """実通信モード（http_client=None）でトークン未設定なら起動時に fail-fast。"""
    monkeypatch.delenv("HANA_TOOLS_API_TOKEN", raising=False)

    with pytest.raises(RuntimeError) as exc_info:
        HanaToolsClient(base_url="https://x.test")  # http_client=None, token=None

    assert "HANA_TOOLS_API_TOKEN" in str(exc_info.value)


def test_fail_fast_when_token_missing_even_with_http_client(monkeypatch):
    """http_client 注入時でも token=None なら fail-fast（テストの抜け穴を塞ぐ）。"""
    monkeypatch.delenv("HANA_TOOLS_API_TOKEN", raising=False)

    transport = httpx.MockTransport(lambda req: httpx.Response(200, json={"success": True, "data": []}))
    http = httpx.Client(transport=transport)

    with pytest.raises(RuntimeError) as exc_info:
        HanaToolsClient(base_url="https://x.test", http_client=http)  # token=None

    assert "HANA_TOOLS_API_TOKEN" in str(exc_info.value)


def test_rejects_empty_token():
    """空文字トークンは明示的に拒否（認証なしリクエストの誤発射防止）。"""
    transport = httpx.MockTransport(lambda req: httpx.Response(200, json={"success": True, "data": []}))
    http = httpx.Client(transport=transport)

    with pytest.raises(RuntimeError) as exc_info:
        HanaToolsClient(base_url="https://x.test", token="", http_client=http)

    assert "HANA_TOOLS_API_TOKEN" in str(exc_info.value)


def test_raises_on_invalid_json():
    """非 JSON のレスポンスは HanaToolsError に包んで投げる。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"<html>error page</html>")

    with pytest.raises(HanaToolsError) as exc_info:
        _client(handler).get_clients()

    assert "invalid JSON" in str(exc_info.value)


def test_raises_on_non_dict_body():
    """JSON だが dict 以外（配列など）も HanaToolsError に包む。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[1, 2, 3])

    with pytest.raises(HanaToolsError) as exc_info:
        _client(handler).get_clients()

    assert "unexpected response shape" in str(exc_info.value)


def test_uses_env_base_url_when_not_given(monkeypatch):
    """base_url を渡さない時、HANA_TOOLS_BASE_URL を読む。"""
    monkeypatch.setenv("HANA_TOOLS_BASE_URL", "https://env-base.test")

    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["host"] = request.url.host
        return httpx.Response(200, json={"success": True, "data": []})

    transport = httpx.MockTransport(handler)
    http = httpx.Client(transport=transport)
    client = HanaToolsClient(token="tok", http_client=http)
    client.get_clients()

    assert captured["host"] == "env-base.test"
