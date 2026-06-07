"""業務パートナーが使うツール群の Claude tool_use 用スキーマと dispatcher。

- hana-tools 4 種（GET のみ）: get_todos / list_clients / search_clients / list_outsources
- site/ 参照 3 種: list_site_files / read_site_file / grep_site

書き込み・実行系ツールは登録しない（PLAN.md §9 セキュリティ要件）。
"""

from __future__ import annotations

from typing import Any, Callable

from _assistant import site_reader
from _assistant.hana_client import HanaToolsClient


TOOL_SCHEMAS: list[dict[str, Any]] = [
    {
        "name": "get_todos",
        "description": (
            "hana-tools の ToDo 一覧を取得する。引数なしで全件取得。"
            "自分宛の未完了タスクを見たい場合は assignee_user_id=<あなたの user_id> と "
            "status='incomplete' を指定する。"
            "各 ToDo の completed_at が null なら未完了。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "user_id": {
                    "type": "integer",
                    "description": "登録者の user_id で絞り込む（任意）",
                },
                "assignee_user_id": {
                    "type": "integer",
                    "description": "担当者の user_id で絞り込む（任意。自分のタスクならシステムプロンプトで通知された user_id を渡す）",
                },
                "work_id": {
                    "type": "integer",
                    "description": "案件 work_id で絞り込む（任意）",
                },
                "status": {
                    "type": "string",
                    "enum": ["incomplete", "complete"],
                    "description": "状態で絞り込む（任意）",
                },
            },
            "required": [],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_clients",
        "description": "hana-tools の顧客一覧を全件取得する。引数なし。",
        "input_schema": {
            "type": "object",
            "properties": {},
            "required": [],
            "additionalProperties": False,
        },
    },
    {
        "name": "search_clients",
        "description": (
            "hana-tools の顧客を部分一致で検索する。q はカンマ区切りで OR 検索可能。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "q": {
                    "type": "string",
                    "description": "検索クエリ（カンマ区切りで OR 検索）",
                },
            },
            "required": ["q"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_outsources",
        "description": "hana-tools の外注先一覧を全件取得する。引数なし。",
        "input_schema": {
            "type": "object",
            "properties": {},
            "required": [],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_site_files",
        "description": (
            "site/ 配下の参照可能ファイル一覧を返す。pattern は fnmatch 形式"
            "（例: 'clients/*/projects/*/memo.html'）。"
            "件数が上限を超えた場合はエラーになるので pattern で絞り込むこと。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "fnmatch パターン（任意、省略時は全件）",
                },
            },
            "required": [],
            "additionalProperties": False,
        },
    },
    {
        "name": "read_site_file",
        "description": (
            "site/ 配下の 1 ファイルを UTF-8 テキストとして取得する。"
            "サイズ上限 100KB。許可拡張子は .md .txt .html .json .csv .yaml .yml のみ。"
            "site/ 外への参照や symlink、隠しファイルは拒否される。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "site/ ルートからの相対パス（例: 'business/skill-map.html'）",
                },
            },
            "required": ["path"],
            "additionalProperties": False,
        },
    },
    {
        "name": "grep_site",
        "description": (
            "site/ 配下を部分文字列検索する。前後 2 行の文脈つき。"
            "path_glob で対象ファイルを絞り込み可能（fnmatch 形式）。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "検索する文字列",
                },
                "path_glob": {
                    "type": "string",
                    "description": "対象ファイルの fnmatch パターン（任意）",
                },
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
]

# スキーマと実装の取りこぼし検出用（後方互換ではなくドキュメンテーション目的）。
TOOL_NAMES: frozenset[str] = frozenset(t["name"] for t in TOOL_SCHEMAS)


def make_dispatcher(client: HanaToolsClient) -> Callable[[str, dict[str, Any]], Any]:
    """tool 名 → 実装関数の dispatcher を返す（client は closure で保持）。

    薄い呼び出し層に徹する：JSON Schema による型・余剰キー検証は Anthropic 側
    （tool_use レイヤ）に委ねる。dispatcher は (1) 未知ツール名、(2) 必須キー欠落、
    (3) 必須 string 引数の最低限の型ガードのみ自前で確認する。
    呼び出し先（hana_client / site_reader）の例外は素通しさせ、agent.py 側で
    tool_result.is_error=True に詰める想定。
    """

    def dispatch(name: str, args: dict[str, Any]) -> Any:
        if not isinstance(args, dict):
            raise ValueError(f"tool args は dict である必要があります: {type(args).__name__}")

        if name == "get_todos":
            return client.get_todos(
                user_id=args.get("user_id"),
                assignee_user_id=args.get("assignee_user_id"),
                work_id=args.get("work_id"),
                status=args.get("status"),
            )
        if name == "list_clients":
            return client.get_clients()
        if name == "search_clients":
            q = args.get("q")
            if not isinstance(q, str) or not q:
                raise ValueError("search_clients の q は非空の文字列が必要です")
            return client.search_clients(q)
        if name == "list_outsources":
            return client.get_outsources()
        if name == "list_site_files":
            return site_reader.list_site_files(args.get("pattern"))
        if name == "read_site_file":
            path = args.get("path")
            if not isinstance(path, str) or not path:
                raise ValueError("read_site_file の path は非空の文字列が必要です")
            return site_reader.read_site_file(path)
        if name == "grep_site":
            query = args.get("query")
            if not isinstance(query, str) or not query:
                raise ValueError("grep_site の query は非空の文字列が必要です")
            return site_reader.grep_site(query, args.get("path_glob"))

        raise ValueError(f"未知のツール: {name}")

    return dispatch
