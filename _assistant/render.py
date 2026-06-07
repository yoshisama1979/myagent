"""アシスタント応答のマークダウン→HTML レンダリング（XSS サニタイズ込み）。

LLM が返す本文はマークダウン想定。これを HTML に変換し、bleach でホワイトリスト
方式のサニタイズを通してから UI に流す。`tool_use` イベントなどの表示文字列も
同じ関数で安全化する（プレーンテキスト用にエスケープのみのヘルパも提供）。
"""

from __future__ import annotations

import html

import bleach
import markdown

# 表示で許可するタグ（GFM 風の最小セット）
_ALLOWED_TAGS = frozenset(
    [
        "p", "br", "strong", "em", "u", "s", "del", "code", "pre",
        "ul", "ol", "li",
        "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "hr",
        "a",
        "table", "thead", "tbody", "tr", "th", "td",
        "span", "div",
    ]
)

_ALLOWED_ATTRS = {
    "a": ["href", "title", "rel"],
    "code": ["class"],
    "pre": ["class"],
    "span": ["class"],
    "div": ["class"],
    "th": ["align"],
    "td": ["align"],
}

_ALLOWED_PROTOCOLS = frozenset(["http", "https", "mailto"])

_MD_EXTENSIONS = [
    "fenced_code",  # ``` コードブロック
    "tables",       # GFM テーブル
    "nl2br",        # 改行を <br> に
    "sane_lists",   # 不正な箇条書きを保護
]


def markdown_to_safe_html(text: str) -> str:
    """マークダウン本文を安全な HTML に変換する。

    1. `markdown` で HTML に変換（fenced_code/tables/nl2br/sane_lists 有効）
    2. `bleach` でホワイトリストタグ/属性以外を除去
    3. 外部リンクは `rel="noopener noreferrer"` を強制
    """
    if not text:
        return ""
    html_body = markdown.markdown(text, extensions=_MD_EXTENSIONS)
    cleaned = bleach.clean(
        html_body,
        tags=_ALLOWED_TAGS,
        attributes=_ALLOWED_ATTRS,
        protocols=_ALLOWED_PROTOCOLS,
        strip=True,
    )
    # 外部リンクには rel と target を補正（noopener で安全）
    cleaned = bleach.linkify(
        cleaned,
        callbacks=[_link_rel_callback],
        skip_tags=["pre", "code"],
        parse_email=False,
    )
    return cleaned


def escape_text(text: str) -> str:
    """ユーザー入力やツール引数の表示用にプレーンエスケープ。"""
    return html.escape(text, quote=True)


def _link_rel_callback(attrs: dict, new: bool = False) -> dict:
    """bleach linkify 用：全リンクに rel=noopener と target=_blank を付ける。"""
    attrs[(None, "rel")] = "noopener noreferrer"
    attrs[(None, "target")] = "_blank"
    return attrs
