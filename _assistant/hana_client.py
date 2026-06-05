"""hana-tools 外部API の読み取り専用クライアント。

v1 は GET のみ（書き込み=ToDo登録・Chatwork通知は対象外）。
`{success, data}` 封筒を剥がして data を返す。社内 TLS が必要な環境でも truststore で通す。

環境変数（myagent の `bin/hana-api.sh` と統一）:
- `HANA_TOOLS_BASE_URL`（任意、既定: ステージング）
- `HANA_TOOLS_API_TOKEN`（必須、未設定なら起動時 fail-fast）
"""

from __future__ import annotations

import os
from typing import Any

import httpx

from _assistant.config import HANA_HTTP_TIMEOUT_SECONDS, require_env


class HanaToolsError(RuntimeError):
    """API 呼び出しの失敗（非 200 / success=false / 不正 JSON / その他通信エラー）。"""


_DEFAULT_BASE = "https://stg.hana-tools.com"


class HanaToolsClient:
    """hana-tools API への薄いラッパ。

    実通信時は `http_client=None` で起動し、内部で `httpx.Client` を作る。
    テストでは `httpx.MockTransport` を載せた `httpx.Client` を `http_client` 引数で注入する。
    """

    def __init__(
        self,
        base_url: str | None = None,
        token: str | None = None,
        http_client: httpx.Client | None = None,
    ) -> None:
        self._base = (
            base_url or os.environ.get("HANA_TOOLS_BASE_URL", _DEFAULT_BASE)
        ).rstrip("/")

        # トークンは http_client の有無に関わらず fail-fast。
        # 空文字や None を許容すると、誤って認証ヘッダなしのリクエストが飛ぶ。
        if token is None:
            self._token = require_env("HANA_TOOLS_API_TOKEN")
        elif token == "":
            raise RuntimeError("HANA_TOOLS_API_TOKEN が空文字です。明示的な空トークンは許可しません。")
        else:
            self._token = token

        if http_client is None:
            import truststore  # 実通信時のみ社内 TLS 対応（テストでは注入クライアントを使う）

            truststore.inject_into_ssl()
            http_client = httpx.Client(timeout=HANA_HTTP_TIMEOUT_SECONDS)
        self._http = http_client

    def _get(self, path: str, params: dict | None = None) -> Any:
        try:
            resp = self._http.get(
                f"{self._base}{path}",
                headers={"X-API-TOKEN": self._token},
                params=params,
            )
        except httpx.HTTPError as exc:
            raise HanaToolsError(f"{path} -> HTTP error: {exc}") from exc

        if resp.status_code != 200:
            raise HanaToolsError(f"{path} -> HTTP {resp.status_code}")

        try:
            body = resp.json()
        except ValueError as exc:
            raise HanaToolsError(f"{path} -> invalid JSON: {exc}") from exc

        if not isinstance(body, dict):
            raise HanaToolsError(f"{path} -> unexpected response shape: {type(body).__name__}")

        if not body.get("success"):
            raise HanaToolsError(f"{path} -> success=false: {body.get('message')}")
        return body.get("data")

    def get_todos(
        self,
        *,
        user_id: int | None = None,
        assignee_user_id: int | None = None,
        work_id: int | None = None,
        status: str | None = None,
    ) -> list[dict]:
        """ToDo 一覧。完了判定は各レコードの `completed_at` が null かで見る。"""
        params: dict = {}
        if user_id is not None:
            params["user_id"] = user_id
        if assignee_user_id is not None:
            params["assignee_user_id"] = assignee_user_id
        if work_id is not None:
            params["work_id"] = work_id
        if status is not None:
            params["status"] = status
        return self._get("/api/external/todos", params)

    def get_clients(self) -> list[dict]:
        return self._get("/api/external/clients")

    def search_clients(self, q: str) -> list[dict]:
        return self._get("/api/external/clients/search", {"q": q})

    def get_outsources(self) -> list[dict]:
        return self._get("/api/external/outsources")
