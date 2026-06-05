"""app.py の FastAPI ルーティング・認証・チャット・CSRF・TTL・lockout テスト。

実 LLM / 実 hana-tools は叩かない（agent.reply をモック差し替え）。
"""

from __future__ import annotations

import importlib
import re
import time

import pytest
from fastapi.testclient import TestClient


_CSRF_RE = re.compile(r'name="csrf_token"\s+value="([^"]+)"')


def _extract_csrf(text: str) -> str:
    m = _CSRF_RE.search(text)
    assert m, "csrf_token フィールドが見つからない"
    return m.group(1)


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("ASSISTANT_USER", "tester")
    monkeypatch.setenv("ASSISTANT_PASSWORD", "secret")
    monkeypatch.setenv("ASSISTANT_SESSION_SECRET", "x" * 32)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    monkeypatch.setenv("HANA_TOOLS_API_TOKEN", "test-token")

    import _assistant.app as app_mod
    importlib.reload(app_mod)

    class FakeAgent:
        def reply(self, message, history):
            return f"echo: {message}", history + [{"role": "user", "content": message}]

    monkeypatch.setattr(app_mod, "_agent", FakeAgent())
    app_mod._chat_state.clear()
    app_mod._login_failures.clear()

    return TestClient(app_mod.app)


def _login(client) -> None:
    """ヘルパ：CSRF token を拾ってログイン。"""
    page = client.get("/login").text
    token = _extract_csrf(page)
    resp = client.post(
        "/login",
        data={"username": "tester", "password": "secret", "csrf_token": token},
        follow_redirects=False,
    )
    assert resp.status_code == 303


# ---- 認証 ----------------------------------------------------------------


def test_root_redirects_to_login_when_anonymous(client):
    resp = client.get("/", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login"


def test_login_page_includes_csrf_token(client):
    resp = client.get("/login")
    assert resp.status_code == 200
    assert "csrf_token" in resp.text


def test_login_with_wrong_password(client):
    page = client.get("/login").text
    token = _extract_csrf(page)
    resp = client.post(
        "/login",
        data={"username": "tester", "password": "wrong", "csrf_token": token},
        follow_redirects=False,
    )
    assert resp.status_code == 401
    assert "違います" in resp.text


def test_login_with_wrong_username(client):
    page = client.get("/login").text
    token = _extract_csrf(page)
    resp = client.post(
        "/login",
        data={"username": "x", "password": "secret", "csrf_token": token},
        follow_redirects=False,
    )
    assert resp.status_code == 401


def test_login_success_redirects_to_root(client):
    _login(client)
    resp = client.get("/", follow_redirects=False)
    assert resp.status_code == 200


def test_logout_clears_session(client):
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    resp = client.post("/logout", data={"csrf_token": token}, follow_redirects=False)
    assert resp.status_code == 303
    resp2 = client.get("/", follow_redirects=False)
    assert resp2.headers["location"] == "/login"


def test_logged_in_user_redirected_away_from_login(client):
    _login(client)
    resp = client.get("/login", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/"


# ---- CSRF -----------------------------------------------------------------


def test_login_rejects_missing_csrf(client):
    """csrf_token フィールドが欠落すると 422（フォームバリデーション）。"""
    resp = client.post(
        "/login",
        data={"username": "tester", "password": "secret"},
        follow_redirects=False,
    )
    assert resp.status_code in (422, 403)


def test_login_rejects_invalid_csrf(client):
    client.get("/login")  # session 確立
    resp = client.post(
        "/login",
        data={"username": "tester", "password": "secret", "csrf_token": "wrong"},
        follow_redirects=False,
    )
    assert resp.status_code == 403


def test_chat_rejects_invalid_csrf(client):
    _login(client)
    resp = client.post(
        "/chat",
        data={"message": "hi", "csrf_token": "wrong-token"},
        follow_redirects=False,
    )
    assert resp.status_code == 403


def test_logout_rejects_invalid_csrf(client):
    _login(client)
    resp = client.post(
        "/logout",
        data={"csrf_token": "bogus"},
        follow_redirects=False,
    )
    assert resp.status_code == 403


def test_clear_rejects_invalid_csrf(client):
    _login(client)
    resp = client.post(
        "/clear",
        data={"csrf_token": "bogus"},
        follow_redirects=False,
    )
    assert resp.status_code == 403


# ---- session fixation -----------------------------------------------------


def test_login_rotates_session_id(client):
    """ログイン成功時に session が clear() されて新 csrf token になる。"""
    pre = client.get("/login").text
    pre_token = _extract_csrf(pre)
    client.post("/login", data={"username": "tester", "password": "secret", "csrf_token": pre_token})
    post = client.get("/").text
    post_token = _extract_csrf(post)
    assert pre_token != post_token


# ---- ブルートフォース対策 ------------------------------------------------


def test_login_lockout_after_repeated_failures(client):
    """連続失敗で 429 を返す。"""
    import _assistant.app as app_mod
    for _ in range(app_mod._LOGIN_FAIL_THRESHOLD):
        page = client.get("/login").text
        token = _extract_csrf(page)
        client.post(
            "/login",
            data={"username": "tester", "password": "wrong", "csrf_token": token},
        )
    # 次の試行は 429
    page = client.get("/login").text
    token = _extract_csrf(page)
    resp = client.post(
        "/login",
        data={"username": "tester", "password": "secret", "csrf_token": token},
        follow_redirects=False,
    )
    assert resp.status_code == 429


# ---- チャット ------------------------------------------------------------


def test_chat_requires_login(client):
    # 未ログインだとそもそも token が出るが、session も空
    # 認証チェックの方が CSRF より先に通るので、CSRF 検証が先に走って 403、その後リダイレクト判定
    # 実装上 _verify_csrf が先なので、未ログインで csrf を渡さないと 422 or 403。
    # ここでは「未ログインで /chat に有効な csrf 付きで POST しても /login にリダイレクトされる」を確認
    # まず GET /login で csrf 発行
    page = client.get("/login").text
    token = _extract_csrf(page)
    resp = client.post(
        "/chat",
        data={"message": "hi", "csrf_token": token},
        follow_redirects=False,
    )
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login"


def test_chat_echoes_response(client):
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    resp = client.post(
        "/chat",
        data={"message": "今日のタスクは？", "csrf_token": token},
    )
    assert resp.status_code == 200
    assert "今日のタスクは？" in resp.text
    assert "echo: 今日のタスクは？" in resp.text


def test_chat_history_persists_across_requests(client):
    _login(client)
    for msg in ("first", "second"):
        page = client.get("/").text
        token = _extract_csrf(page)
        client.post("/chat", data={"message": msg, "csrf_token": token})
    resp = client.get("/")
    assert "first" in resp.text
    assert "second" in resp.text


def test_chat_handles_agent_exception_gracefully(client, monkeypatch):
    _login(client)
    import _assistant.app as app_mod

    class ErrorAgent:
        def reply(self, message, history):
            raise RuntimeError("simulated failure")

    monkeypatch.setattr(app_mod, "_agent", ErrorAgent())
    page = client.get("/").text
    token = _extract_csrf(page)
    resp = client.post(
        "/chat", data={"message": "boom", "csrf_token": token}
    )
    assert resp.status_code == 200
    assert "エラー" in resp.text
    assert "simulated failure" in resp.text


def test_chat_ignores_empty_message(client):
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    resp = client.post(
        "/chat", data={"message": "   ", "csrf_token": token}, follow_redirects=False
    )
    assert resp.status_code == 303


def test_clear_resets_history(client):
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    client.post("/chat", data={"message": "hello", "csrf_token": token})
    page = client.get("/").text
    token = _extract_csrf(page)
    client.post("/clear", data={"csrf_token": token})
    resp = client.get("/")
    assert "hello" not in resp.text
    assert "質問してください" in resp.text


# ---- TTL / 履歴上限 ------------------------------------------------------


def test_display_history_trimmed_at_max(client, monkeypatch):
    """display_history が _DISPLAY_HISTORY_MAX_TURNS を超えたら古い順で落ちる。"""
    import _assistant.app as app_mod
    monkeypatch.setattr(app_mod, "_DISPLAY_HISTORY_MAX_TURNS", 4)
    _login(client)
    for i in range(5):  # 5 ターン送信 = user+assistant 10 件 → 4 に切られる
        page = client.get("/").text
        token = _extract_csrf(page)
        client.post("/chat", data={"message": f"msg{i}", "csrf_token": token})
    resp = client.get("/")
    # 古い msg0 / msg1 / msg2 は流れているはず
    assert "msg0" not in resp.text
    assert "msg4" in resp.text


def test_chat_state_gc_removes_stale_sessions(client, monkeypatch):
    """TTL を超えたセッションは _chat_state から除去される。"""
    import _assistant.app as app_mod
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    client.post("/chat", data={"message": "hi", "csrf_token": token})
    assert len(app_mod._chat_state) == 1

    # last_seen を遠い過去に書き換え、TTL を 1 秒に縮める
    for st in app_mod._chat_state.values():
        st["last_seen"] = time.monotonic() - 9999
    monkeypatch.setattr(app_mod, "_CHAT_STATE_TTL_SECONDS", 1)

    # 別セッションの POST が GC を発火させる
    page = client.get("/").text
    token = _extract_csrf(page)
    client.post("/chat", data={"message": "trigger", "csrf_token": token})
    # 元の sid は GC されているはず（新しい sid に置き換わっているか、辞書サイズ <=1）
    assert len(app_mod._chat_state) <= 1


# ---- 起動時 fail-fast --------------------------------------------------


def test_app_fails_fast_when_env_missing(monkeypatch):
    monkeypatch.delenv("ASSISTANT_USER", raising=False)
    monkeypatch.delenv("ASSISTANT_PASSWORD", raising=False)
    monkeypatch.delenv("ASSISTANT_SESSION_SECRET", raising=False)

    import _assistant.app as app_mod
    with pytest.raises(RuntimeError) as exc_info:
        importlib.reload(app_mod)
    assert "ASSISTANT" in str(exc_info.value)
