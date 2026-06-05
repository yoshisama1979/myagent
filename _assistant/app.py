"""業務パートナー Web UI（FastAPI + cookie session）。

- パスワード認証（`ASSISTANT_USER` / `ASSISTANT_PASSWORD`）+ cookie session
- CSRF トークンで状態変更 POST を保護
- 1 セッションごとの会話履歴はサーバープロセス内メモリのみ（永続化なし、TTL/件数上限あり）
- アップロード機能なし
- Tailscale IP に bind して使う想定。**uvicorn は単一ワーカ必須**（_chat_state はプロセス内 dict）

起動例:
  cd /home/vpsuser/projects/myagent
  _assistant/.venv/bin/uvicorn _assistant.app:app \\
    --host 100.123.104.87 --port 8010 --log-level warning --workers 1
"""

from __future__ import annotations

import os
import secrets
import time
from pathlib import Path

from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware
from starlette.staticfiles import StaticFiles

from _assistant.agent import PartnerAgent
from _assistant.config import load_dotenv, require_env
from _assistant.runtime import build_agent

load_dotenv()

# 起動時 fail-fast（環境変数欠落で立ち上がらない）
_SESSION_SECRET = require_env("ASSISTANT_SESSION_SECRET")
_USER = require_env("ASSISTANT_USER")
_PASSWORD = require_env("ASSISTANT_PASSWORD")

# 運用上限（過大履歴/長時間滞留によるメモリ食い潰し対策）
_CHAT_STATE_TTL_SECONDS = 24 * 60 * 60  # 24 時間アクセスが無いセッションを GC
_DISPLAY_HISTORY_MAX_TURNS = 200  # 1 セッションあたり最大保持メッセージ数（user+assistant 合計）

# ブルートフォース簡易対策（プロセス内・1 ユーザー想定）
_LOGIN_FAIL_THRESHOLD = 5
_LOGIN_LOCKOUT_SECONDS = 60

_HERE = Path(__file__).resolve().parent
_TEMPLATES = Jinja2Templates(directory=str(_HERE / "templates"))

app = FastAPI(title="経営サポート業務パートナー")
app.add_middleware(
    SessionMiddleware,
    secret_key=_SESSION_SECRET,
    max_age=8 * 60 * 60,  # 8時間
    https_only=False,  # Tailscale 経由内部利用のため
    same_site="lax",
)
app.mount("/static", StaticFiles(directory=str(_HERE / "static")), name="static")

# プロセス内チャット状態。sid -> {"agent_history": list, "display_history": list, "last_seen": float}
# プロセス再起動で消える（永続化しない方針）。マルチワーカで分散すると履歴がワーカ間で割れるので
# 必ず --workers 1 で起動すること。
_chat_state: dict[str, dict] = {}

# ログイン失敗の簡易 rate limit（プロセス内、IP は Tailscale 経由想定）
_login_failures: dict[str, list[float]] = {}

# 遅延初期化（テスト時は build_agent を別途差し替え可能）
_agent: PartnerAgent | None = None


def _get_agent() -> PartnerAgent:
    global _agent
    if _agent is None:
        _agent = build_agent()
    return _agent


def _logged_in(request: Request) -> bool:
    return bool(request.session.get("user"))


def _get_or_create_sid(request: Request) -> str:
    sid = request.session.get("sid")
    if not sid:
        sid = secrets.token_urlsafe(16)
        request.session["sid"] = sid
    return sid


def _ensure_csrf_token(request: Request) -> str:
    """セッションごとに CSRF token を発行・取り出し。POST handler で検証する。"""
    token = request.session.get("csrf_token")
    if not token:
        token = secrets.token_urlsafe(32)
        request.session["csrf_token"] = token
    return token


def _verify_csrf(request: Request, submitted_token: str | None) -> None:
    expected = request.session.get("csrf_token")
    if not expected or not submitted_token or not secrets.compare_digest(expected, submitted_token):
        raise HTTPException(status_code=403, detail="CSRF token mismatch")


def _gc_chat_state() -> None:
    """TTL 切れの sid を破棄。/chat や /clear のたびに軽量に走らせる。"""
    now = time.monotonic()
    dead = [
        sid
        for sid, st in _chat_state.items()
        if now - st.get("last_seen", now) > _CHAT_STATE_TTL_SECONDS
    ]
    for sid in dead:
        _chat_state.pop(sid, None)


def _touch(state: dict) -> None:
    state["last_seen"] = time.monotonic()


def _trim_display_history(state: dict) -> None:
    """display_history が上限を超えたら古い順から落とす。"""
    history = state.get("display_history", [])
    if len(history) > _DISPLAY_HISTORY_MAX_TURNS:
        state["display_history"] = history[-_DISPLAY_HISTORY_MAX_TURNS:]


def _login_locked_out(client_id: str) -> bool:
    now = time.monotonic()
    recent = [t for t in _login_failures.get(client_id, []) if now - t < _LOGIN_LOCKOUT_SECONDS]
    _login_failures[client_id] = recent
    return len(recent) >= _LOGIN_FAIL_THRESHOLD


def _record_login_failure(client_id: str) -> None:
    _login_failures.setdefault(client_id, []).append(time.monotonic())


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    if not _logged_in(request):
        return RedirectResponse("/login", status_code=303)
    sid = _get_or_create_sid(request)
    state = _chat_state.get(sid, {})
    csrf_token = _ensure_csrf_token(request)
    return _TEMPLATES.TemplateResponse(
        request,
        "chat.html",
        {
            "history": state.get("display_history", []),
            "user": request.session.get("user"),
            "csrf_token": csrf_token,
        },
    )


@app.get("/login", response_class=HTMLResponse)
def login_form(request: Request):
    if _logged_in(request):
        return RedirectResponse("/", status_code=303)
    csrf_token = _ensure_csrf_token(request)
    return _TEMPLATES.TemplateResponse(
        request, "login.html", {"error": None, "csrf_token": csrf_token}
    )


@app.post("/login")
def login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    csrf_token: str = Form(...),
):
    _verify_csrf(request, csrf_token)

    client_id = request.client.host if request.client else "unknown"
    if _login_locked_out(client_id):
        return _TEMPLATES.TemplateResponse(
            request,
            "login.html",
            {
                "error": f"ログイン失敗が続いています。{_LOGIN_LOCKOUT_SECONDS}秒ほど待ってから再試行してください",
                "csrf_token": _ensure_csrf_token(request),
            },
            status_code=429,
        )

    ok_user = secrets.compare_digest(username, _USER)
    ok_pass = secrets.compare_digest(password, _PASSWORD)
    if not (ok_user and ok_pass):
        _record_login_failure(client_id)
        return _TEMPLATES.TemplateResponse(
            request,
            "login.html",
            {
                "error": "ユーザー名またはパスワードが違います",
                "csrf_token": _ensure_csrf_token(request),
            },
            status_code=401,
        )

    # session fixation 対策：ログイン成功時に既存セッションを破棄して新規発行
    request.session.clear()
    request.session["user"] = username
    _ensure_csrf_token(request)  # 新セッションに新 CSRF token
    _login_failures.pop(client_id, None)
    return RedirectResponse("/", status_code=303)


@app.post("/logout")
def logout(request: Request, csrf_token: str = Form(...)):
    _verify_csrf(request, csrf_token)
    sid = request.session.get("sid")
    if sid:
        _chat_state.pop(sid, None)
    request.session.clear()
    return RedirectResponse("/login", status_code=303)


@app.post("/chat", response_class=HTMLResponse)
def chat(request: Request, message: str = Form(...), csrf_token: str = Form(...)):
    _verify_csrf(request, csrf_token)
    if not _logged_in(request):
        return RedirectResponse("/login", status_code=303)
    _gc_chat_state()

    sid = _get_or_create_sid(request)
    state = _chat_state.setdefault(
        sid,
        {"agent_history": [], "display_history": [], "last_seen": time.monotonic()},
    )

    user_msg = message.strip()
    if not user_msg:
        return RedirectResponse("/", status_code=303)

    agent = _get_agent()
    try:
        text, new_history = agent.reply(user_msg, history=state["agent_history"])
    except Exception as exc:  # noqa: BLE001 - UI 側で表示するため握りつぶす
        text = f"エラー: {exc}"
        new_history = state["agent_history"]

    state["agent_history"] = new_history
    state["display_history"].append({"role": "user", "text": user_msg})
    state["display_history"].append({"role": "assistant", "text": text})
    _trim_display_history(state)
    _touch(state)

    return _TEMPLATES.TemplateResponse(
        request,
        "chat.html",
        {
            "history": state["display_history"],
            "user": request.session.get("user"),
            "csrf_token": _ensure_csrf_token(request),
        },
    )


@app.post("/clear")
def clear_history(request: Request, csrf_token: str = Form(...)):
    """会話履歴を消す（ボタンから呼ばれる）。"""
    _verify_csrf(request, csrf_token)
    if not _logged_in(request):
        return RedirectResponse("/login", status_code=303)
    sid = request.session.get("sid")
    if sid:
        _chat_state.pop(sid, None)
    return RedirectResponse("/", status_code=303)
