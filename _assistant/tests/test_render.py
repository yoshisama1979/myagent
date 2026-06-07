"""render.markdown_to_safe_html / escape_text の動作検証。

XSS 対策のホワイトリストが効いていること、マークダウン要素が正しく HTML 化される
ことを確認する。
"""

from __future__ import annotations

from _assistant.render import escape_text, markdown_to_safe_html


def test_markdown_basic_paragraph_renders():
    out = markdown_to_safe_html("hello world")
    assert "<p>" in out
    assert "hello world" in out


def test_markdown_bold_and_emphasis():
    out = markdown_to_safe_html("**bold** *em*")
    assert "<strong>bold</strong>" in out
    assert "<em>em</em>" in out


def test_markdown_unordered_list():
    md = "- a\n- b\n- c"
    out = markdown_to_safe_html(md)
    assert "<ul>" in out
    assert "<li>a</li>" in out
    assert "<li>c</li>" in out


def test_markdown_ordered_list():
    md = "1. one\n2. two"
    out = markdown_to_safe_html(md)
    assert "<ol>" in out
    assert "<li>one</li>" in out


def test_markdown_fenced_code():
    md = "```\nprint('hi')\n```"
    out = markdown_to_safe_html(md)
    assert "<pre>" in out
    assert "<code>" in out
    assert "print(&#39;hi&#39;)" in out or "print('hi')" in out


def test_markdown_inline_code():
    out = markdown_to_safe_html("see `foo` here")
    assert "<code>foo</code>" in out


def test_markdown_table():
    md = "| a | b |\n|---|---|\n| 1 | 2 |"
    out = markdown_to_safe_html(md)
    assert "<table>" in out
    assert "<th>a</th>" in out
    assert "<td>1</td>" in out


def test_markdown_link_gets_rel_and_target():
    out = markdown_to_safe_html("[click](https://example.com)")
    assert 'href="https://example.com"' in out
    assert 'rel="noopener noreferrer"' in out
    assert 'target="_blank"' in out


def test_markdown_strips_script_tags():
    out = markdown_to_safe_html("<script>alert(1)</script>hello")
    # script タグ自体が消えていれば良い（中身がプレーンテキストとして残るのは無害）
    assert "<script" not in out
    assert "hello" in out


def test_markdown_strips_onload_attribute():
    out = markdown_to_safe_html('<a href="https://example.com" onclick="alert(1)">x</a>')
    assert "onclick" not in out
    assert "alert" not in out


def test_markdown_strips_javascript_protocol():
    out = markdown_to_safe_html("[x](javascript:alert(1))")
    # bleach は javascript: プロトコルを許可リストに無いので href を削るか空にする
    assert "javascript:" not in out


def test_markdown_strips_iframe():
    out = markdown_to_safe_html('<iframe src="https://evil.com"></iframe>safe')
    assert "<iframe" not in out
    assert "safe" in out


def test_markdown_blockquote():
    out = markdown_to_safe_html("> quoted text")
    assert "<blockquote>" in out
    assert "quoted text" in out


def test_markdown_empty_string_returns_empty():
    assert markdown_to_safe_html("") == ""
    assert markdown_to_safe_html(None) == ""  # type: ignore[arg-type]


def test_escape_text_basic():
    assert escape_text("<b>x</b>") == "&lt;b&gt;x&lt;/b&gt;"


def test_escape_text_quote():
    assert escape_text('"a"') == "&quot;a&quot;"


def test_escape_text_ampersand():
    assert escape_text("a & b") == "a &amp; b"
