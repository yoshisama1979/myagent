#!/usr/bin/env python3
"""build-spec-html.py — 仕様書(Markdown)から人が読めるHTMLビューを自動生成する。

原本＝リポジトリの Markdown（OVERVIEW.md / SYSTEM.md / CLAUDE.md / rules/*.md /
rules/modes/*.md）。本スクリプトはそれを site/docs/spec/ に HTML として書き出す
「都度生成の読み取りビュー」を作るだけで、原本は一切変更しない（台帳を二重に持たない原則）。

使い方:
    python3 bin/build-spec-html.py

- 依存ライブラリなし（標準ライブラリのみ・無人VPSで動く）
- 仕様書を更新したら再実行する（rules/development.md「仕様書の更新」参照）
- .md 間の相対リンクは、生成対象同士なら生成後の .html へ書き換える
"""

import html
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "site" / "docs" / "spec"

# 生成対象（repoパス → 出力相対パス）。.claude は nginx でドットファイル扱いに
# なり得るため mode-rules/ に写す。
SOURCES = [
    ("OVERVIEW.md", "OVERVIEW.html", "リポジトリ全体像・ディレクトリ早見表"),
    ("SYSTEM.md", "SYSTEM.html", "動くモード同士の地図（役割・一次情報源・承認ゲート・ハンドオフ）"),
    ("CLAUDE.md", "CLAUDE.html", "AIの役割・会社概要・行動指針・出力先ルール（基本仕様）"),
]
for p in sorted((ROOT / "rules").glob("*.md")):
    SOURCES.append((f"rules/{p.name}", f"rules/{p.stem}.html", ""))
for p in sorted((ROOT / "rules" / "modes").glob("*.md")):
    SOURCES.append((f"rules/modes/{p.name}", f"mode-rules/{p.stem}.html", ""))

SRC_TO_OUT = {src: out for src, out, _ in SOURCES}

H_CLASS = {
    1: "text-3xl font-bold mb-4 mt-8",
    2: "text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10",
    3: "text-lg font-semibold mb-3 mt-6",
    4: "text-base font-semibold mb-2 mt-4",
}


def rel_href(from_out: str, to_out: str) -> str:
    """出力ファイル同士の相対パス"""
    from_dir = Path(from_out).parent
    to = Path(to_out)
    # os.path.relpath 相当（Path.relative_to は上位方向に使えない）
    import os
    return os.path.relpath(str(to), str(from_dir)).replace("\\", "/")


def rewrite_link(url: str, src_path: str, out_path: str) -> str:
    """.md への相対リンクを、生成対象なら生成後 .html へ書き換える"""
    if re.match(r"^[a-z]+://", url) or url.startswith("#") or url.startswith("mailto:"):
        return url
    base = url.split("#", 1)
    frag = ("#" + base[1]) if len(base) > 1 else ""
    target = base[0]
    if not target.endswith(".md"):
        return url
    # src からの相対を repo 相対に解決
    src_dir = (ROOT / src_path).parent
    try:
        resolved = (src_dir / target).resolve().relative_to(ROOT)
    except ValueError:
        return url
    key = str(resolved).replace("\\", "/")
    if key in SRC_TO_OUT:
        return rel_href(out_path, SRC_TO_OUT[key]) + frag
    return url


def inline(text: str, src_path: str, out_path: str) -> str:
    """インライン記法をHTML化（エスケープ→code退避→装飾→リンク）"""
    text = html.escape(text, quote=False)

    # code span を退避（中は装飾しない）
    codes: list[str] = []

    def stash(m: re.Match) -> str:
        codes.append(m.group(1))
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"`([^`]+)`", stash, text)

    # [[wiki-link]]（メモリ参照）は淡色表示
    text = re.sub(r"\[\[([^\]]+)\]\]",
                  r'<span class="text-gray-400 text-xs">[[\1]]</span>', text)

    # リンク [text](url)
    def link(m: re.Match) -> str:
        label, url = m.group(1), m.group(2)
        url = rewrite_link(url, src_path, out_path)
        return f'<a href="{url}" class="text-blue-600 hover:underline">{label}</a>'

    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)

    # 強調
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)

    # code span を戻す
    def unstash(m: re.Match) -> str:
        c = codes[int(m.group(1))]
        return f'<code class="bg-gray-100 px-1 rounded text-sm font-mono">{c}</code>'

    return re.sub(r"\x00(\d+)\x00", unstash, text)


def convert(md: str, src_path: str, out_path: str) -> str:
    lines = md.split("\n")
    out: list[str] = []
    i = 0
    n = len(lines)

    def is_table_sep(s: str) -> bool:
        s = s.strip()
        return bool(re.match(r"^\|?[\s:|-]+\|[\s:|-]*$", s)) and "-" in s

    while i < n:
        line = lines[i]
        stripped = line.strip()

        # フェンスコード
        if stripped.startswith("```"):
            buf = []
            i += 1
            while i < n and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1  # 終端 ```
            code = html.escape("\n".join(buf), quote=False)
            out.append(f'<pre class="bg-gray-800 text-gray-100 rounded p-4 text-xs '
                       f'overflow-x-auto mb-6"><code>{code}</code></pre>')
            continue

        # 空行
        if not stripped:
            i += 1
            continue

        # 水平線
        if re.match(r"^-{3,}$", stripped) or re.match(r"^\*{3,}$", stripped):
            out.append('<hr class="my-8 border-gray-300">')
            i += 1
            continue

        # 見出し
        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            level = min(len(m.group(1)), 4)
            out.append(f'<h{level} class="{H_CLASS[level]}">'
                       f'{inline(m.group(2), src_path, out_path)}</h{level}>')
            i += 1
            continue

        # 引用ブロック
        if stripped.startswith(">"):
            buf = []
            while i < n and lines[i].strip().startswith(">"):
                buf.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            inner = "<br>\n".join(inline(b, src_path, out_path) for b in buf if b.strip())
            out.append(f'<div class="bg-blue-50 border-l-4 border-blue-400 p-4 my-4 '
                       f'text-sm text-gray-700">{inner}</div>')
            continue

        # テーブル
        if stripped.startswith("|") and i + 1 < n and is_table_sep(lines[i + 1]):
            header = [c.strip() for c in stripped.strip("|").split("|")]
            i += 2
            rows = []
            while i < n and lines[i].strip().startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            th = "".join(f'<th class="text-left px-3 py-2 border border-gray-200 '
                         f'font-semibold">{inline(c, src_path, out_path)}</th>' for c in header)
            trs = []
            for r in rows:
                tds = "".join(f'<td class="px-3 py-2 border border-gray-200 align-top">'
                              f'{inline(c, src_path, out_path)}</td>' for c in r)
                trs.append(f"<tr>{tds}</tr>")
            out.append('<div class="overflow-x-auto mb-6"><table class="w-full '
                       'border-collapse text-sm">'
                       f'<thead><tr class="bg-gray-100">{th}</tr></thead>'
                       f'<tbody>{"".join(trs)}</tbody></table></div>')
            continue

        # リスト（ネスト対応・スタック方式）
        if re.match(r"^\s*([-*+]|\d+[.)])\s+", line):
            stack: list[str] = []  # "ul" / "ol"
            prev_indent = -1
            buf: list[str] = []

            def close_to(depth: int):
                while len(stack) > depth:
                    buf.append(f"</{stack.pop()}>")

            while i < n:
                lm = re.match(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$", lines[i])
                if not lm:
                    break
                indent = len(lm.group(1)) // 2
                kind = "ol" if lm.group(2)[0].isdigit() else "ul"
                if indent > prev_indent:
                    for _ in range(indent - prev_indent):
                        cls = ("list-decimal" if kind == "ol" else "list-disc")
                        buf.append(f'<{kind} class="{cls} list-inside space-y-1 '
                                   f'text-sm mb-2 {"ml-5" if stack else "mb-4"}">')
                        stack.append(kind)
                elif indent < prev_indent:
                    close_to(len(stack) - (prev_indent - indent))
                buf.append(f"<li>{inline(lm.group(3), src_path, out_path)}</li>")
                prev_indent = indent
                i += 1
            close_to(0)
            out.append("\n".join(buf))
            continue

        # 段落（連続行をまとめる）
        buf = [stripped]
        i += 1
        while i < n:
            nxt = lines[i].strip()
            if (not nxt or nxt.startswith(("#", ">", "|", "```"))
                    or re.match(r"^\s*([-*+]|\d+[.)])\s+", lines[i])
                    or re.match(r"^-{3,}$", nxt)):
                break
            buf.append(nxt)
            i += 1
        out.append('<p class="text-sm mb-4 leading-relaxed">'
                   + "<br>\n".join(inline(b, src_path, out_path) for b in buf) + "</p>")

    return "\n".join(out)


PAGE = """<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{title} — 仕様書ビュー</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-4xl mx-auto p-6 md:p-10">
  <p class="text-sm text-gray-500 mb-2"><a href="{home}" class="text-blue-600 hover:underline">← 仕様書一覧</a></p>
  <div class="bg-yellow-50 border-l-4 border-yellow-400 p-3 mb-6 text-xs text-gray-700">
    これは自動生成ビューです（生成: {ts}）。原本は
    <code class="bg-gray-100 px-1 rounded font-mono">{src}</code>。
    編集は原本の Markdown に行い、<code class="bg-gray-100 px-1 rounded font-mono">python3 bin/build-spec-html.py</code> で再生成してください。
  </div>
{body}
</div>
</body>
</html>
"""


def first_summary(md: str) -> str:
    """索引用の1行説明を抽出（最初の見出し以外のテキスト行）"""
    for line in md.split("\n"):
        s = line.strip()
        if not s or s.startswith(("#", "```", "|", "---")):
            continue
        s = re.sub(r"^>\s*", "", s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"\1", s)
        s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)
        s = re.sub(r"[`>]", "", s)
        return s[:80]
    return ""


def main() -> int:
    ts = time.strftime("%Y-%m-%d %H:%M")
    entries = []
    for src, out_rel, desc in SOURCES:
        src_file = ROOT / src
        if not src_file.exists():
            print(f"[skip] {src}（無し）", file=sys.stderr)
            continue
        md = src_file.read_text(encoding="utf-8")
        title = src
        m = re.search(r"^#\s+(.+)$", md, re.M)
        if m:
            title = re.sub(r"[*`]", "", m.group(1)).strip()
        body = convert(md, src, out_rel)
        home = rel_href(out_rel, "index.html")
        page = PAGE.format(title=html.escape(title), home=home, ts=ts,
                           src=src, body=body)
        out_file = OUT / out_rel
        out_file.parent.mkdir(parents=True, exist_ok=True)
        out_file.write_text(page, encoding="utf-8")
        entries.append((src, out_rel, title, desc or first_summary(md)))
        print(f"[ok] {src} -> site/docs/spec/{out_rel}")

    # 索引ページ
    groups = [
        ("全体仕様（入口）", lambda s: "/" not in s),
        ("横断ルール（rules/）", lambda s: s.startswith("rules/") and not s.startswith("rules/modes/")),
        ("モード別ルール（rules/modes/）", lambda s: s.startswith("rules/modes/")),
    ]
    sections = []
    for gtitle, pred in groups:
        items = [e for e in entries if pred(e[0])]
        if not items:
            continue
        lis = "\n".join(
            f'<li class="mb-2"><a href="{out_rel}" class="text-blue-600 hover:underline '
            f'font-semibold">{html.escape(title)}</a>'
            f'<span class="text-gray-400 text-xs ml-2">{src}</span><br>'
            f'<span class="text-sm text-gray-600">{html.escape(desc)}</span></li>'
            for src, out_rel, title, desc in items)
        sections.append(f'<h2 class="text-xl font-semibold border-b border-gray-300 '
                        f'pb-2 mb-4 mt-10">{gtitle}</h2>\n<ul class="list-none">{lis}</ul>')

    index_html = f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>仕様書ビュー — 一覧</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-4xl mx-auto p-6 md:p-10">
  <p class="text-sm text-gray-500 mb-2"><a href="../../index.html" class="text-blue-600 hover:underline">← サイトトップ</a></p>
  <h1 class="text-3xl font-bold mb-2">仕様書ビュー（自動生成）</h1>
  <p class="text-gray-600 mb-2 text-sm">このシステムの仕様書（Markdown 原本）をブラウザで読めるように変換したもの。生成: {ts}</p>
  <div class="bg-yellow-50 border-l-4 border-yellow-400 p-3 mb-6 text-xs text-gray-700">
    原本は各 .md ファイル。編集は原本へ行い、<code class="bg-gray-100 px-1 rounded font-mono">python3 bin/build-spec-html.py</code> で再生成する
    （<code class="bg-gray-100 px-1 rounded font-mono">rules/development.md</code>「仕様書の更新」参照）。
    ※ AI-INDEX.md（在処マップ）と .claude/commands/（スキル定義）は対象外。
  </div>
{"".join(sections)}
</div>
</body>
</html>
"""
    (OUT / "index.html").write_text(index_html, encoding="utf-8")
    print(f"[ok] index -> site/docs/spec/index.html（{len(entries)}ファイル）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
