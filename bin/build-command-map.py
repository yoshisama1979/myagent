#!/usr/bin/env python3
"""rules/command-map.md から site/docs/command-map.html を生成する。

早見表の正は rules/command-map.md（/do がこれを読む）。
社長がブラウザで見る早見表を手で書くと二重管理になり、必ずズレる。
そこで **正から生成する**。command-map.md を直したら必ずこれを実行すること。

使い方: python3 bin/build-command-map.py
"""
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "rules" / "command-map.md"
OUT = ROOT / "site" / "docs" / "command-map.html"


def inline(text):
    """**強調** と `コード` だけを変換する（それ以外はエスケープしたまま）。

    ★コードを先にトークンへ退避する★＝先に強調を処理すると `**not bold**` のような
    「コード内の記号」まで <strong> になり、コードとして見せたいものが化ける
    （2026-08-19 Codexレビュー🟡）。
    """
    out = html.escape(text)
    stash = []

    def _keep(m):
        stash.append(m.group(1))
        return f"\x00CODE{len(stash) - 1}\x00"

    out = re.sub(r"`([^`]+)`", _keep, out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    for i, code in enumerate(stash):
        out = out.replace(
            f"\x00CODE{i}\x00",
            f'<code class="bg-gray-100 px-1 rounded text-[0.9em]">{code}</code>',
        )
    return out


class SourceError(Exception):
    """早見表の書き方が想定外＝黙って壊れたHTMLを出さず、生成を失敗させる。

    ここは社長が見る一次資料の生成器なので、**気づけないズレを作るくらいなら止める**
    （2026-08-19 Codexレビュー🟡）。
    """


def split_row(line, lineno):
    r"""表の1行をセルへ割る。`\|` は区切りでなく文字としての | として扱う。

    ★素朴に split("|") すると、セル内に | を書いた瞬間に列がずれる★
    ＝2列の表が黙って3列になり、崩れたHTMLがそのまま公開される（2026-08-19 Codexレビュー🟡で実測）。
    """
    cells = re.split(r"(?<!\\)\|", line.strip())
    if cells and cells[0].strip() == "":
        cells = cells[1:]
    if cells and cells[-1].strip() == "":
        cells = cells[:-1]
    return [c.strip().replace("\\|", "|") for c in cells]


def render(md):
    lines = md.split("\n")
    html_parts = []
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()

        if line.lstrip().startswith("```"):
            raise SourceError(
                f"{i + 1}行目：コードブロックは未対応です。"
                "早見表では使わないでください（`バッククォート` の行内コードは使えます）。"
            )

        # 表（ヘッダ行 → 区切り行 → 本体）
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|$", lines[i + 1].strip()):
            lineno = i + 1
            head = split_row(line, lineno)
            i += 2
            body = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                row = split_row(lines[i], i + 1)
                if len(row) != len(head):
                    raise SourceError(
                        f"{lineno + 2 + len(body)}行目：列数が見出しと違います"
                        f"（見出し {len(head)} 列・この行 {len(row)} 列）。"
                        "セル内で表の区切りに使わない `|` は `\\|` と書いてください。"
                    )
                body.append(row)
                i += 1
            if not body:
                raise SourceError(f"{lineno}行目：中身が1行も無い表です。")
            th = "".join(f'<th class="border border-gray-300 p-2 text-left bg-gray-100">{inline(c)}</th>' for c in head)
            rows = ""
            for r in body:
                tds = "".join(f'<td class="border border-gray-300 p-2 align-top">{inline(c)}</td>' for c in r)
                rows += f"<tr>{tds}</tr>"
            html_parts.append(
                '<div class="overflow-x-auto mb-6"><table class="w-full text-sm border-collapse">'
                f"<thead><tr>{th}</tr></thead><tbody>{rows}</tbody></table></div>"
            )
            continue

        if line.startswith("# "):
            html_parts.append(f'<h1 class="text-3xl font-bold mb-4">{inline(line[2:])}</h1>')
        elif line.startswith("## "):
            html_parts.append(f'<h2 class="text-xl font-bold mt-8 mb-3 border-b-2 border-gray-300 pb-1">{inline(line[3:])}</h2>')
        elif line.startswith("> "):
            html_parts.append(f'<p class="text-xs text-gray-600 border-l-4 border-gray-300 pl-3 mb-2">{inline(line[2:])}</p>')
        elif line.startswith("- "):
            # 連続する箇条書きは1つの <ul> にまとめる（裸の <li> は不正なHTML）
            items = []
            while i < len(lines) and lines[i].startswith("- "):
                items.append(f'<li class="mb-1">{inline(lines[i][2:])}</li>')
                i += 1
            html_parts.append('<ul class="text-sm list-disc ml-6 mb-4">' + "".join(items) + "</ul>")
            continue
        elif line.strip():
            html_parts.append(f'<p class="text-sm mb-3">{inline(line)}</p>')
        i += 1

    return "\n".join(html_parts)


def main():
    if not SRC.exists():
        print(f"ERROR: 正のファイルがありません: {SRC}", file=sys.stderr)
        return 1
    try:
        body = render(SRC.read_text(encoding="utf-8"))
    except SourceError as e:
        print(f"ERROR: {SRC.name} の書き方が想定外です → {e}", file=sys.stderr)
        print("（HTML は更新していません＝古い版がそのまま残っています）", file=sys.stderr)
        return 1
    doc = f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>コマンド早見表｜株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-4xl mx-auto p-6 md:p-10">
  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">ダッシュボード</a>
    <span class="mx-1">/</span><span>コマンド早見表</span>
  </nav>

  <div class="border-2 border-emerald-500 bg-emerald-50 rounded-lg p-5 mb-8">
    <p class="text-lg font-bold text-emerald-900">迷ったら <code class="bg-white px-2 py-0.5 rounded border">/do</code> に用件をそのまま貼ってください。</p>
    <p class="text-sm text-emerald-900 mt-1">適切なモードへ振り分けます。判断がつかないときは選択肢でお聞きします。</p>
  </div>

{body}

  <p class="text-xs text-gray-500 border-t pt-4 mt-8">
    このページは <code>rules/command-map.md</code> から <code>python3 bin/build-command-map.py</code> で生成しています。
    <strong>直接編集しないでください</strong>（次の生成で消えます）。
  </p>
</div>
</body>
</html>
"""
    # ★一時ファイルへ書いてから置き換える★＝途中で止まっても、空や欠けたHTMLを公開しない
    #   （2026-08-19 Codexレビュー🟡）。
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(OUT.suffix + ".tmp")
    tmp.write_text(doc, encoding="utf-8")
    tmp.replace(OUT)
    print(f"生成: {OUT}（{len(doc.encode())} bytes）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
