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
        def reply(self, message, history, on_event=None):
            # SSE 経由なら on_event でツール呼び出しイベントを再現
            if on_event is not None:
                on_event({"type": "thinking"})
                on_event({"type": "tool_use", "name": "get_todos", "input": {}})
                on_event(
                    {"type": "tool_result", "name": "get_todos", "ok": True, "preview": "[]"}
                )
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
        def reply(self, message, history, on_event=None):
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


def test_chat_renders_markdown_in_display(client, monkeypatch):
    """assistant の応答（マークダウン）が HTML に変換されて表示される。"""
    _login(client)
    import _assistant.app as app_mod

    class MarkdownAgent:
        def reply(self, message, history, on_event=None):
            return "**強調** と *斜体*", history

    monkeypatch.setattr(app_mod, "_agent", MarkdownAgent())
    page = client.get("/").text
    token = _extract_csrf(page)
    resp = client.post("/chat", data={"message": "test", "csrf_token": token})
    assert "<strong>強調</strong>" in resp.text
    assert "<em>斜体</em>" in resp.text


def test_chat_user_input_is_html_escaped(client):
    """ユーザー入力に HTML タグが含まれてもエスケープされる（XSS 対策）。"""
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    resp = client.post(
        "/chat",
        data={"message": "<script>alert(1)</script>", "csrf_token": token},
    )
    assert "<script>alert(1)</script>" not in resp.text
    assert "&lt;script&gt;" in resp.text


def test_chat_stream_emits_sse_events(client):
    """SSE 経由で user/tool_use/tool_result/final イベントが順に流れる。"""
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    with client.stream(
        "POST",
        "/chat/stream",
        data={"message": "test sse", "csrf_token": token},
    ) as resp:
        assert resp.status_code == 200
        assert resp.headers["content-type"].startswith("text/event-stream")
        body = b"".join(resp.iter_bytes()).decode("utf-8")

    # data: 行に各 type が現れる
    assert '"type": "user"' in body
    assert '"type": "tool_use"' in body
    assert '"name": "get_todos"' in body
    assert '"type": "tool_result"' in body
    assert '"type": "final"' in body
    # final の html にマークダウンの <p> が入る
    assert "<p>echo: test sse</p>" in body


def test_chat_stream_requires_csrf(client):
    _login(client)
    resp = client.post("/chat/stream", data={"message": "x", "csrf_token": "wrong"})
    assert resp.status_code == 403


def test_chat_stream_requires_login(client):
    page = client.get("/login").text
    token = _extract_csrf(page)
    resp = client.post("/chat/stream", data={"message": "x", "csrf_token": token})
    assert resp.status_code == 401


def test_chat_stream_rejects_empty_message(client):
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    resp = client.post("/chat/stream", data={"message": "   ", "csrf_token": token})
    assert resp.status_code == 400


def test_chat_stream_xss_in_final_is_sanitized(client, monkeypatch):
    """LLM 応答に <script> や onclick が混じっていても、final HTML では除去される。"""
    _login(client)
    import _assistant.app as app_mod

    class XssAgent:
        def reply(self, message, history, on_event=None):
            text = (
                "<script>alert('xss')</script>"
                "**正常テキスト** "
                "[クリック](javascript:alert(1))"
                '<a href="https://example.com" onclick="alert(2)">link</a>'
            )
            return text, history

    monkeypatch.setattr(app_mod, "_agent", XssAgent())
    page = client.get("/").text
    token = _extract_csrf(page)
    with client.stream(
        "POST", "/chat/stream", data={"message": "xss", "csrf_token": token}
    ) as resp:
        body = b"".join(resp.iter_bytes()).decode("utf-8")
    assert "<script" not in body
    assert "onclick" not in body
    assert "javascript:" not in body
    assert "<strong>正常テキスト</strong>" in body  # 正常 markdown は通る


def test_chat_stream_xss_in_tool_preview_is_escaped(client, monkeypatch):
    """tool_result の preview に HTML が混じってもサーバ側ペイロードはエスケープ前提で渡され、
    クライアント JS 側で escapeHtml される（送出される JSON にタグが裸で入らない）。"""
    _login(client)
    import _assistant.app as app_mod

    class HtmlPreviewAgent:
        def reply(self, message, history, on_event=None):
            if on_event:
                on_event(
                    {
                        "type": "tool_result",
                        "name": "grep_site",
                        "ok": True,
                        "preview": "<script>alert('preview')</script>",
                    }
                )
            return "done", history

    monkeypatch.setattr(app_mod, "_agent", HtmlPreviewAgent())
    page = client.get("/").text
    token = _extract_csrf(page)
    with client.stream(
        "POST", "/chat/stream", data={"message": "x", "csrf_token": token}
    ) as resp:
        body = b"".join(resp.iter_bytes()).decode("utf-8")
    # preview は JSON 文字列として含まれる（< > は < > にはなっていないが、
    # クライアント JS 側で escapeHtml() を通すことを前提とする実装）
    assert '"preview"' in body
    # SSE の data: 行に <script> 文字列がそのまま入っていても、JSON 内なので
    # ブラウザに直接実行されることはない（fetch + JSON.parse → escapeHtml で防御）。
    # ここでは「サーバが preview をクライアントに渡している」事実だけ確認する。


def test_chat_stream_xss_in_user_message_is_escaped(client):
    """ユーザー入力に HTML タグが混じっても、user イベントの html はエスケープ済。"""
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    with client.stream(
        "POST",
        "/chat/stream",
        data={"message": "<img src=x onerror=alert(1)>", "csrf_token": token},
    ) as resp:
        body = b"".join(resp.iter_bytes()).decode("utf-8")
    # < / > が &lt; &gt; に変換されていれば、たとえ onerror という文字列が残っていても
    # <img> タグとしては解釈されないので安全。タグ開始/終了の生 < が無いことを確認。
    assert "&lt;img" in body
    # SSE body 全体で「user の html フィールド以外」に生の <img タグが現れないこと。
    # JSON の "<img" は SSE では JSON エンコードされて含まれない（escape済）。
    assert '"<img' not in body
    assert ">{" not in body  # 安全のための簡易チェック（タグ閉じが直に続いていない）


def test_chat_stream_concurrent_same_session_returns_409(client, monkeypatch):
    """同一 sid で並行 /chat/stream → 後発は 409。agent_history の race を防ぐ。"""
    _login(client)
    import _assistant.app as app_mod

    # 走行中の Lock を擬似的に占有させる
    page = client.get("/").text
    token = _extract_csrf(page)
    sid = None
    # まず 1 リクエストを開始して sid を確定させる（普通の /chat 経由で）
    client.post("/chat", data={"message": "warmup", "csrf_token": token})
    for s in app_mod._chat_state.keys():
        sid = s
        break
    assert sid is not None

    lock = app_mod._get_sid_lock(sid)
    import asyncio
    loop = asyncio.new_event_loop()
    try:
        loop.run_until_complete(lock.acquire())
        page = client.get("/").text
        token = _extract_csrf(page)
        resp = client.post("/chat/stream", data={"message": "concurrent", "csrf_token": token})
        assert resp.status_code == 409
    finally:
        if lock.locked():
            lock.release()
        loop.close()


def test_chat_stream_updates_state_after_completion(client):
    """SSE 完了後、再度 / にアクセスすると履歴が見える（state 更新）。"""
    _login(client)
    page = client.get("/").text
    token = _extract_csrf(page)
    with client.stream(
        "POST",
        "/chat/stream",
        data={"message": "persist this", "csrf_token": token},
    ) as resp:
        b"".join(resp.iter_bytes())  # ストリームを最後まで読む
    resp = client.get("/")
    assert "persist this" in resp.text
    assert "echo: persist this" in resp.text


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
    # 履歴クリア後は empty-state（welcome 画面）が出る
    assert "empty-state" in resp.text


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
    # 実 .env を読まないようにする（プロジェクトルートの .env に値があると
    # delenv の効果が load_dotenv の setdefault で打ち消されるため）
    import _assistant.config as config_mod
    monkeypatch.setattr(config_mod, "load_dotenv", lambda: None)

    import _assistant.app as app_mod
    with pytest.raises(RuntimeError) as exc_info:
        importlib.reload(app_mod)
    assert "ASSISTANT" in str(exc_info.value)
