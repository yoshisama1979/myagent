#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI-INDEX.md 自動生成スクリプト

site/ 配下の全 HTML/PHP を機械的に辿り、各ページの
  - <title>
  - 見出し（h1〜h3）
  - リード文（最初の意味のある <p>）
を抽出して、リポジトリ直下の AI-INDEX.md を再生成する。

目的：AI（ビジネスパートナー）が「どこに何があるか」を1枚で把握し、
必要なページ/データだけを深掘りできるようにする“在処の地図”。
ビジュアル用 HTML はそのまま、別の場所にデータを移さずに findability だけ上げる。

使い方:
  python3 bin/build-ai-index.py

注意:
  - 動的に算出される数値（保守合計など）は出力されない。これは在処の地図であり、
    数値本体は各ページ/スクリプト/CSV を読みにいく前提。
  - data/secrets は機密のため中身を出さない。
"""

import re
from datetime import date
from html import unescape
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SITE_DIR = PROJECT_ROOT / 'site'
DATA_DIR = PROJECT_ROOT / 'data'
OUTPUT_FILE = PROJECT_ROOT / 'AI-INDEX.md'

MAX_HEADINGS = 10          # 1ページあたり列挙する見出しの上限
LEAD_MAX_CHARS = 110       # リード文の最大長
DATA_SECRET_DIRS = {'secrets'}   # 中身を掲載しないディレクトリ
DATA_SKIP_DIRS = {'cache'}       # 一覧から省くディレクトリ

TAG_RE = re.compile(r'<[^>]+>')
WS_RE = re.compile(r'\s+')
# 英数字・ひらがな・カタカナ・漢字のいずれかを含むか（PHP断片由来のゴミ見出し除け）
CONTENT_RE = re.compile(r'[0-9A-Za-z぀-ヿ㐀-鿿]')
# 本文ではない塊（中の <p>/<h2> 等を誤って拾わないよう抽出前に除去）
COMMENT_RE = re.compile(r'<!--.*?-->', re.DOTALL)
NONCONTENT_RE = re.compile(
    r'<(script|style|noscript|template)\b[^>]*>.*?</\1>', re.IGNORECASE | re.DOTALL)


def strip_noncontent(html: str) -> str:
    """script/style/noscript/template とコメントを除去（中身ごと落とす）。"""
    html = COMMENT_RE.sub(' ', html)
    return NONCONTENT_RE.sub(' ', html)


def strip_tags(html: str) -> str:
    """タグを除去し、HTMLエンティティを戻して空白を畳む。"""
    return WS_RE.sub(' ', unescape(TAG_RE.sub('', html))).strip()


def extract_title(html: str) -> str:
    m = re.search(r'<title[^>]*>(.*?)</title>', html, re.IGNORECASE | re.DOTALL)
    if not m:
        return ''
    title = strip_tags(m.group(1))
    # 「○○ — 株式会社はなさか」の会社名サフィックスは冗長なので落とす
    return re.sub(r'\s*[—\-–|]\s*株式会社はなさか\s*$', '', title)


def extract_headings(html: str):
    """h1〜h3 をドキュメント順に (level, text) で返す。"""
    out = []
    for m in re.finditer(r'<h([1-3])[^>]*>(.*?)</h\1>', html, re.IGNORECASE | re.DOTALL):
        text = strip_tags(m.group(2))
        if text and CONTENT_RE.search(text):
            out.append((int(m.group(1)), text))
    return out


def extract_lead(html: str) -> str:
    """最初の意味のある <p>（短すぎ・ナビらしきものは飛ばす）。"""
    for m in re.finditer(r'<p[^>]*>(.*?)</p>', html, re.IGNORECASE | re.DOTALL):
        text = strip_tags(m.group(1))
        if len(text) < 15:
            continue
        if text.startswith('←'):  # パンくず（unescape 済みなので &larr; もここで弾ける）
            continue
        if len(text) > LEAD_MAX_CHARS:
            text = text[:LEAD_MAX_CHARS].rstrip() + '…'
        return text
    return ''


def page_entry(path: Path) -> str:
    html = strip_noncontent(path.read_text(encoding='utf-8', errors='replace'))
    rel = path.relative_to(PROJECT_ROOT).as_posix()
    title = extract_title(html) or '(タイトルなし)'
    lead = extract_lead(html)
    headings = extract_headings(html)

    # h1 はタイトルと重複しがちなので、見出し一覧は h2/h3 を中心に
    sub = [t for lvl, t in headings if lvl >= 2]
    lines = [f'- **`{rel}`** — {title}']
    if lead:
        lines.append(f'  - {lead}')
    if sub:
        shown = sub[:MAX_HEADINGS]
        suffix = f' …他{len(sub) - MAX_HEADINGS}件' if len(sub) > MAX_HEADINGS else ''
        lines.append('  - 見出し: ' + ' / '.join(shown) + suffix)
    return '\n'.join(lines)


def build_site_section() -> str:
    if not SITE_DIR.exists():
        raise SystemExit(f'site/ が見つかりません: {SITE_DIR}')
    # ディレクトリ単位で連続するよう (親ディレクトリ, ファイル名) でソート
    files = sorted(
        list(SITE_DIR.rglob('*.html')) + list(SITE_DIR.rglob('*.php')),
        key=lambda p: (p.parent.relative_to(PROJECT_ROOT).as_posix(), p.name),
    )
    blocks = []
    current_dir = None
    for path in files:
        rel_dir = path.parent.relative_to(PROJECT_ROOT).as_posix()
        if rel_dir != current_dir:
            current_dir = rel_dir
            blocks.append(f'\n### `{rel_dir}/`\n')
        blocks.append(page_entry(path))
    return f'件数: HTML/PHP 合計 {len(files)} ページ\n' + '\n'.join(blocks)


def build_data_section() -> str:
    """data/ の主要ファイルを2階層まで一覧化（機密は中身を出さない）。"""
    if not DATA_DIR.exists():
        return '(data/ なし)'
    lines = []
    for top in sorted(DATA_DIR.iterdir(), key=lambda p: p.name):
        if not top.is_dir():
            if top.suffix:
                lines.append(f'- `{top.relative_to(PROJECT_ROOT).as_posix()}`')
            continue
        if top.name in DATA_SKIP_DIRS:
            continue
        rel = top.relative_to(PROJECT_ROOT).as_posix()
        if top.name in DATA_SECRET_DIRS:
            lines.append(f'- `{rel}/` — 🔒 機密（中身は非掲載）')
            continue
        readme = top / 'README.md'
        note = ''
        if readme.exists():
            first = next((l.strip().lstrip('# ').strip()
                          for l in readme.read_text(encoding='utf-8', errors='replace').splitlines()
                          if l.strip()), '')
            if first:
                note = f' — {first}'
        lines.append(f'- `{rel}/`{note}')
        # 直下のファイル / サブディレクトリを軽く列挙
        children = sorted(top.iterdir(), key=lambda p: p.name)
        names = [c.name + ('/' if c.is_dir() else '') for c in children
                 if not c.name.startswith('.') and c.name != 'README.md']
        if names:
            shown = names[:12]
            suffix = f' …他{len(names) - 12}件' if len(names) > 12 else ''
            lines.append('  - ' + ', '.join(f'`{n}`' for n in shown) + suffix)
    return '\n'.join(lines)


def main():
    generated = date.today().isoformat()
    parts = [
        '# AI-INDEX — はなさか作業環境の在処マップ',
        '',
        '> **自動生成ファイル。手で編集しない。** `python3 bin/build-ai-index.py` で再生成。',
        f'> 生成日: {generated}',
        '>',
        '> 用途：AI（ビジネスパートナー）が「どこに何があるか」を即把握するための地図。',
        '> ビジュアル確認用の HTML はそのまま、必要なページ/CSV をここから辿って深掘りする。',
        '> 全体方針・各フォルダの役割は [OVERVIEW.md](OVERVIEW.md) を参照。',
        '',
        '## 恒久ファクト（毎回確認不要）',
        '',
        '- **会計年度**: 4月1日〜翌3月31日（例: FY2025 = 2025-04〜2026-03）。',
        '- **会社**: 株式会社はなさか。HP制作 / システム開発 / AI活用。社長＋社員体制。',
        '- **財務実績の在処**: `data/financial/<西暦>/pl.csv`・`bs.csv`（Shift-JIS）。'
        '保守ストック収益は `site/business/recurring-revenue.html`。',
        '',
        '## site/ ページ索引',
        '',
        build_site_section(),
        '',
        '## data/ 主要ファイル',
        '',
        build_data_section(),
        '',
    ]
    OUTPUT_FILE.write_text('\n'.join(parts) + '\n', encoding='utf-8')
    print(f'✅ {OUTPUT_FILE.relative_to(PROJECT_ROOT)} を生成しました')


if __name__ == '__main__':
    main()
