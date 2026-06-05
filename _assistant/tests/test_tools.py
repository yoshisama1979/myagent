"""tools.py の TOOL_SCHEMAS と dispatcher の単体テスト。

dispatch は実 client/site_reader を呼ばずに振る舞いだけ検証する（モック注入）。
"""

from __future__ import annotations

from typing import Any

import pytest

from _assistant import site_reader, tools
from _assistant.tools import TOOL_NAMES, TOOL_SCHEMAS, make_dispatcher


class _FakeClient:
    """HanaToolsClient の最低限のスタブ。呼び出された (method, kwargs) を記録する。"""

    def __init__(self):
        self.calls: list[tuple[str, dict[str, Any]]] = []

    def get_todos(self, *, user_id=None, assignee_user_id=None, work_id=None, status=None):
        self.calls.append(
            ("get_todos", {
                "user_id": user_id,
                "assignee_user_id": assignee_user_id,
                "work_id": work_id,
                "status": status,
            })
        )
        return [{"id": 1, "content": "todo"}]

    def get_clients(self):
        self.calls.append(("get_clients", {}))
        return [{"id": 1}]

    def search_clients(self, q):
        self.calls.append(("search_clients", {"q": q}))
        return [{"id": 2, "name": q}]

    def get_outsources(self):
        self.calls.append(("get_outsources", {}))
        return [{"id": 3}]


# ---- TOOL_SCHEMAS の構造 ---------------------------------------------------


def test_tool_schemas_have_required_fields():
    for schema in TOOL_SCHEMAS:
        assert "name" in schema and isinstance(schema["name"], str)
        assert "description" in schema and schema["description"]
        assert "input_schema" in schema
        assert schema["input_schema"]["type"] == "object"
        assert schema["input_schema"].get("additionalProperties") is False
        # required は空配列でも明示する方針（解釈揺れ防止）
        assert "required" in schema["input_schema"]
        assert isinstance(schema["input_schema"]["required"], list)


def test_tool_names_unique():
    names = [s["name"] for s in TOOL_SCHEMAS]
    assert len(names) == len(set(names))


def test_expected_seven_tools_present():
    expected = {
        "get_todos",
        "list_clients",
        "search_clients",
        "list_outsources",
        "list_site_files",
        "read_site_file",
        "grep_site",
    }
    assert TOOL_NAMES == expected


# ---- dispatch: hana-tools 経路 --------------------------------------------


def test_dispatch_get_todos_passes_all_args():
    client = _FakeClient()
    dispatch = make_dispatcher(client)
    out = dispatch("get_todos", {"assignee_user_id": 34, "status": "incomplete"})
    assert out == [{"id": 1, "content": "todo"}]
    assert client.calls == [
        ("get_todos", {
            "user_id": None,
            "assignee_user_id": 34,
            "work_id": None,
            "status": "incomplete",
        }),
    ]


def test_dispatch_list_clients_no_args():
    client = _FakeClient()
    dispatch = make_dispatcher(client)
    dispatch("list_clients", {})
    assert client.calls == [("get_clients", {})]


def test_dispatch_search_clients_requires_q():
    client = _FakeClient()
    dispatch = make_dispatcher(client)

    dispatch("search_clients", {"q": "ABC"})
    assert client.calls[-1] == ("search_clients", {"q": "ABC"})

    # q 欠落 / None / 空文字 / 非文字列 すべて拒否
    for bad in [{}, {"q": None}, {"q": ""}, {"q": 123}]:
        with pytest.raises(ValueError) as exc_info:
            dispatch("search_clients", bad)
        assert "q" in str(exc_info.value)


def test_dispatch_list_outsources():
    client = _FakeClient()
    dispatch = make_dispatcher(client)
    dispatch("list_outsources", {})
    assert client.calls == [("get_outsources", {})]


# ---- dispatch: site/ 経路（site_reader をモック）---------------------------


def test_dispatch_list_site_files_calls_site_reader(monkeypatch):
    captured = {}

    def fake_list(pattern=None):
        captured["pattern"] = pattern
        return ["a.md", "b.md"]

    monkeypatch.setattr(site_reader, "list_site_files", fake_list)

    dispatch = make_dispatcher(_FakeClient())
    out = dispatch("list_site_files", {"pattern": "*.md"})
    assert out == ["a.md", "b.md"]
    assert captured["pattern"] == "*.md"


def test_dispatch_list_site_files_no_pattern(monkeypatch):
    captured = {}

    def fake_list(pattern=None):
        captured["pattern"] = pattern
        return []

    monkeypatch.setattr(site_reader, "list_site_files", fake_list)

    dispatch = make_dispatcher(_FakeClient())
    dispatch("list_site_files", {})
    assert captured["pattern"] is None


def test_dispatch_read_site_file_requires_path(monkeypatch):
    monkeypatch.setattr(site_reader, "read_site_file", lambda p: f"content of {p}")
    dispatch = make_dispatcher(_FakeClient())

    assert dispatch("read_site_file", {"path": "notes.html"}) == "content of notes.html"

    for bad in [{}, {"path": None}, {"path": ""}, {"path": 42}]:
        with pytest.raises(ValueError) as exc_info:
            dispatch("read_site_file", bad)
        assert "path" in str(exc_info.value)


def test_dispatch_grep_site_requires_query(monkeypatch):
    captured = {}

    def fake_grep(query, path_glob=None):
        captured.update({"query": query, "path_glob": path_glob})
        return "result"

    monkeypatch.setattr(site_reader, "grep_site", fake_grep)
    dispatch = make_dispatcher(_FakeClient())

    out = dispatch("grep_site", {"query": "needle", "path_glob": "*.md"})
    assert out == "result"
    assert captured == {"query": "needle", "path_glob": "*.md"}

    for bad in [{}, {"query": None}, {"query": ""}, {"query": ["a"]}]:
        with pytest.raises(ValueError) as exc_info:
            dispatch("grep_site", bad)
        assert "query" in str(exc_info.value)


# ---- dispatch: 異常系 -----------------------------------------------------


def test_dispatch_unknown_tool_raises():
    dispatch = make_dispatcher(_FakeClient())
    with pytest.raises(ValueError) as exc_info:
        dispatch("write_file", {"path": "x", "content": "y"})
    assert "未知のツール" in str(exc_info.value)


def test_dispatch_rejects_non_dict_args():
    dispatch = make_dispatcher(_FakeClient())
    with pytest.raises(ValueError):
        dispatch("list_clients", ["not", "a", "dict"])


def test_dispatch_passes_through_site_reader_errors(monkeypatch):
    """site_reader が SiteReaderError を投げたら dispatch は素通しする。"""
    def boom(p):
        raise site_reader.SiteReaderError("nope")

    monkeypatch.setattr(site_reader, "read_site_file", boom)
    dispatch = make_dispatcher(_FakeClient())
    with pytest.raises(site_reader.SiteReaderError):
        dispatch("read_site_file", {"path": "x.md"})


# ---- TOOL_NAMES と dispatch の整合性 --------------------------------------


def test_all_schema_tools_are_dispatchable(monkeypatch):
    """TOOL_SCHEMAS に載っているツールは全て dispatch が処理できる（未知ツールにならない）。"""
    monkeypatch.setattr(site_reader, "list_site_files", lambda pattern=None: [])
    monkeypatch.setattr(site_reader, "read_site_file", lambda p: "")
    monkeypatch.setattr(site_reader, "grep_site", lambda q, path_glob=None: "")

    dispatch = make_dispatcher(_FakeClient())
    minimal_args = {
        "get_todos": {},
        "list_clients": {},
        "search_clients": {"q": "x"},
        "list_outsources": {},
        "list_site_files": {},
        "read_site_file": {"path": "x.md"},
        "grep_site": {"query": "x"},
    }
    # スキーマと最小引数の取りこぼしがないか確認
    assert set(minimal_args) == TOOL_NAMES
    for name in TOOL_NAMES:
        dispatch(name, minimal_args[name])  # raise しないことだけ確認
