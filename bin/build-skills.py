#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""スキルシート HTML 自動生成スクリプト

data/skill-sheets/<id>.json を正（ソース・オブ・トゥルース）として、
site/business/skill-sheet/<id>.html を再生成する。

- 各グループ内のスキルは重要度 A→B→C の順に自動ソート（同ランク内は記載順を保持）
- 項目数・A/B/C集計・小計・オプション数・総数はすべて自動算出
- レビュー観点・総数メモ中の {A} {B} {C} {SUBTOTAL} {OPTION} {TOTAL} は算出値に置換

使い方:
  python3 bin/build-skills.py            # data/skill-sheets/ の全JSONを生成
  python3 bin/build-skills.py pc-skills  # 指定IDのみ生成

スキル本文（text）は信頼済み内部データとして HTML をそのまま出力する
（<strong> 等のマークアップを許可。エスケープしない）。
"""

import json
import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / 'data' / 'skill-sheets'
OUTPUT_DIR = PROJECT_ROOT / 'site' / 'business' / 'skill-sheet'

RANK_ORDER = {'A': 0, 'B': 1, 'C': 2}
RANK_BG = {'A': 'bg-red-50', 'B': 'bg-yellow-50', 'C': 'bg-green-50', 'O': 'bg-gray-200'}
BOX_COLOR = {
    'blue': ('bg-blue-50', 'border-blue-400'),
    'amber': ('bg-amber-50', 'border-amber-400'),
}
LEGEND_DEFS = [
    ('bg-red-100', 'A', '基礎（必須）'),
    ('bg-yellow-100', 'B', '業務効率（推奨）'),
    ('bg-green-100', 'C', '専門（応用）'),
]
DEFAULT_RANK_REMARKS = {'A': '初回評価対象', 'B': 'Aクリア後', 'C': 'Bクリア後'}


def sorted_skills(skills):
    """A→B→C の安定ソート（同ランク内は元の順序を保つ）。"""
    return sorted(skills, key=lambda s: RANK_ORDER[s['rank']])


def rank_row(rank, text):
    bg = RANK_BG[rank]
    return (f'      <tr><td class="px-3 py-2 border border-gray-200 {bg} text-center font-semibold">{rank}</td>'
            f'<td class="px-3 py-2 border border-gray-200">{text}</td></tr>')


def skill_table(rows_html):
    return f'''  <table class="w-full border-collapse text-sm mb-6">
    <thead>
      <tr class="bg-gray-100">
        <th class="text-left px-3 py-2 border border-gray-200 font-semibold w-16">重要度</th>
        <th class="text-left px-3 py-2 border border-gray-200 font-semibold">項目</th>
      </tr>
    </thead>
    <tbody>
{rows_html}
    </tbody>
  </table>'''


def render_box(box):
    bg, border = BOX_COLOR[box.get('color', 'blue')]
    lines = [f'  <div class="{bg} border-l-4 {border} p-4 my-4 text-sm">',
             f'    <p class="font-semibold mb-1">{box["heading"]}</p>']
    for p in box['paragraphs']:
        lines.append(f'    <p class="{p["cls"]}">{p["html"]}</p>')
    lines.append('  </div>')
    return '\n'.join(lines)


def render_legend(has_options):
    defs = list(LEGEND_DEFS)
    if has_options:
        defs.append(('bg-gray-200', 'O', 'オプション（任意）'))
    spans = []
    for i, (bg, rank, label) in enumerate(defs):
        cls = f'{bg} px-2 py-1 rounded text-xs'
        if i != len(defs) - 1:
            cls += ' mr-2'
        spans.append(f'    <span class="{cls}"><strong>{rank}</strong> {label}</span>')
    return '  <p class="text-sm mb-2"><strong>重要度の凡例:</strong>\n' + '\n'.join(spans) + '\n  </p>'


def render_summary(d, counts, subtotal, option_total, total, opt_summary, sub):
    s = d.get('summary', {})
    has_options = bool(d.get('optionGroups'))
    first_col = s.get('firstColHeader', '区分' if has_options else '重要度')
    show_remarks = True if has_options else s.get('showRemarks', False)
    remarks = s.get('rankRemarks', DEFAULT_RANK_REMARKS)

    head_cells = [f'        <th class="text-left px-3 py-2 border border-gray-200 font-semibold">{first_col}</th>',
                  '        <th class="text-right px-3 py-2 border border-gray-200 font-semibold">項目数</th>']
    if show_remarks:
        head_cells.append('        <th class="text-left px-3 py-2 border border-gray-200 font-semibold">備考</th>')

    def row(label_html, count, bg='', remark='', count_bold=False):
        bg_cls = f' {bg}' if bg else ''
        cnt = f'<strong>{count}</strong>' if count_bold else f'{count}'
        cells = [f'<td class="px-3 py-2 border border-gray-200{bg_cls}">{label_html}</td>',
                 f'<td class="px-3 py-2 border border-gray-200 text-right">{cnt}</td>']
        if show_remarks:
            cells.append(f'<td class="px-3 py-2 border border-gray-200">{remark}</td>')
        return '      <tr>' + ''.join(cells) + '</tr>'

    body = [
        row('<strong>A 基礎（必須）</strong>', counts['A'], 'bg-red-50', remarks.get('A', '')),
        row('<strong>B 業務効率（推奨）</strong>', counts['B'], 'bg-yellow-50', remarks.get('B', '')),
        row('<strong>C 専門（応用）</strong>', counts['C'], 'bg-green-50', remarks.get('C', '')),
    ]
    if has_options:
        body.append(row('<strong>評価対象 小計</strong>', subtotal, '', '段階的評価ルールの対象', count_bold=True))
        body.append(row('<strong>O オプション</strong>', option_total, 'bg-gray-200',
                        f'{opt_summary}、利用者のみ任意で評価'))
        body.append(row('<strong>シート総項目数</strong>', total, '', sub(d.get('totalsNote', '')), count_bold=True))
    else:
        body.append(row(f'<strong>{s.get("totalLabel", "合計")}</strong>', subtotal, '', '', count_bold=True))

    return f'''  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">項目数 集計</h2>
  <table class="w-full border-collapse text-sm mb-6">
    <thead>
      <tr class="bg-gray-100">
{chr(10).join(head_cells)}
      </tr>
    </thead>
    <tbody>
{chr(10).join(body)}
    </tbody>
  </table>'''


def build_html(d):
    eval_groups = [{'title': g['title'], 'note': g.get('note'),
                    'skills': sorted_skills(g['skills'])} for g in d['groups']]
    counts = {'A': 0, 'B': 0, 'C': 0}
    for g in eval_groups:
        for s in g['skills']:
            counts[s['rank']] += 1
    subtotal = counts['A'] + counts['B'] + counts['C']
    option_groups = d.get('optionGroups', [])
    option_total = sum(len(og['skills']) for og in option_groups)
    total = subtotal + option_total
    has_options = bool(option_groups)

    tokens = {'{A}': counts['A'], '{B}': counts['B'], '{C}': counts['C'],
              '{SUBTOTAL}': subtotal, '{OPTION}': option_total, '{TOTAL}': total}

    def sub(text):
        for k, v in tokens.items():
            text = text.replace(k, str(v))
        return text

    parts = []

    # nav
    nav = ' &gt;\n    '.join(
        f'<a href="{n["href"]}" class="text-blue-600 hover:underline">{n["label"]}</a>'
        for n in d['nav'])
    parts.append(f'  <nav class="text-sm text-gray-500 mb-4">\n    {nav}\n  </nav>')

    # 見出し（h1・サブタイトル・更新履歴は密着＝空行なし）
    parts.append(
        f'  <h1 class="text-3xl font-bold mb-2">{d["title"]}</h1>\n'
        f'  <p class="text-gray-600 mb-2">{d["subtitle"]}</p>\n'
        f'  <p class="text-sm text-gray-500 mb-8">{"<br>".join(d["updates"])}</p>')

    # ボックス
    for box in d.get('boxes', []):
        parts.append(render_box(box))

    # 凡例
    parts.append(render_legend(has_options))

    # 評価対象グループ
    for i, g in enumerate(eval_groups, start=1):
        rows = '\n'.join(rank_row(s['rank'], s['text']) for s in g['skills'])
        block = (f'  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">'
                 f'{i}. {g["title"]}（{len(g["skills"])}項目）</h2>\n')
        if g['note']:
            block += f'  <p class="text-sm text-gray-500 mb-3">{g["note"]}</p>\n'
        block += skill_table(rows)
        parts.append(block)

    # オプション
    opt_summary = ''
    if has_options:
        parts.append('  <hr class="my-10 border-gray-300">')
        oi = d['optionIntro']
        parts.append(f'  <h2 class="text-2xl font-bold mt-10 mb-4">{oi["heading"]}</h2>\n'
                     f'  <p class="text-sm text-gray-600 mb-6">{oi["body"]}</p>')
        summary_parts = []
        for og in option_groups:
            n = len(og['skills'])
            summary_parts.append(f'{og["title"]} {n}')
            rows = '\n'.join(rank_row('O', t) for t in og['skills'])
            parts.append(
                f'  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">'
                f'{og["id"]}. {og["title"]}（{n}項目、オプション）</h2>\n' + skill_table(rows))
        opt_summary = ' / '.join(summary_parts)

        rm = d.get('removed')
        if rm:
            items = '\n'.join(f'      <li>{it}</li>' for it in rm['items'])
            parts.append(f'''  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">削除した項目（2026-05-24 社長判断）</h2>
  <div class="bg-gray-100 border border-gray-300 p-4 my-4 text-sm">
    <p class="font-semibold mb-2">{rm["intro"]}</p>
    <ul class="list-disc list-inside space-y-1">
{items}
    </ul>
    <p class="mt-2 text-gray-600">{rm["note"]}</p>
  </div>''')

    # 集計
    parts.append(render_summary(d, counts, subtotal, option_total, total, opt_summary, sub))

    # レビュー観点
    if d.get('reviewPoints'):
        review = '\n'.join(f'    <li>{sub(p)}</li>' for p in d['reviewPoints'])
        parts.append('  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">'
                     'レビュー観点（社長判断用）</h2>\n'
                     f'  <ul class="list-disc list-inside space-y-1 text-sm">\n{review}\n  </ul>')

    # 追加セクション（今後追加予定 等）
    for sec in d.get('extraSections', []):
        list_cls = sec.get('listClass', '')
        ul_cls = 'list-disc list-inside space-y-1 text-sm' + (f' {list_cls}' if list_cls else '')
        items = '\n'.join(f'    <li>{it}</li>' for it in sec['items'])
        parts.append(f'  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">'
                     f'{sec["heading"]}</h2>\n  <ul class="{ul_cls}">\n{items}\n  </ul>')

    # 関連
    related = '\n'.join(
        f'    <li>{r["prefix"]}<a href="{r["href"]}" class="text-blue-600 hover:underline">{r["label"]}</a></li>'
        for r in d.get('related', []))
    parts.append('  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">関連</h2>\n'
                 f'  <ul class="list-disc list-inside space-y-1 text-sm">\n{related}\n  </ul>')

    head = f'''<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{d["title"]} — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-5xl mx-auto p-6 md:p-10">'''

    html = head + '\n\n' + '\n\n'.join(parts) + '\n\n</div>\n</body>\n</html>\n'
    return html, counts, subtotal, option_total, total


def sheet_counts(d):
    counts = {'A': 0, 'B': 0, 'C': 0}
    for g in d['groups']:
        for s in g['skills']:
            counts[s['rank']] += 1
    subtotal = counts['A'] + counts['B'] + counts['C']
    option_total = sum(len(og['skills']) for og in d.get('optionGroups', []))
    return subtotal, option_total, subtotal + option_total


def update_index():
    """index.html の各カード末尾の件数（…項目）を全JSONから自動同期する。
    カード説明文（プロセは index.html 固有の編集物）はそのまま、末尾の括弧件数だけ差し替える。"""
    index = OUTPUT_DIR / 'index.html'
    if not index.exists():
        return
    html = index.read_text(encoding='utf-8')
    changed = []
    for jp in sorted(DATA_DIR.glob('*.json')):
        d = json.loads(jp.read_text(encoding='utf-8'))
        subtotal, option_total, total = sheet_counts(d)
        if option_total:
            count_str = f'（評価対象{subtotal}項目＋オプション{option_total}項目）'
        else:
            count_str = f'（{total}項目）'
        card = re.compile(
            rf'(<a href="{re.escape(d["id"])}\.html"[^>]*>.*?'
            rf'<p class="text-sm text-gray-600">)(.*?)(</p>)', re.S)

        def repl(m):
            # 末尾の「（…項目）」だけを差し替える（別用途の括弧は壊さない）
            new_inner = re.sub(r'（[^（）]*項目）\s*$', count_str, m.group(2))
            return m.group(1) + new_inner + m.group(3)

        new_html, n = card.subn(repl, html)
        if n == 0:
            print(f'⚠ index.html に {d["id"]} のカードが見つからず件数を更新できませんでした', file=sys.stderr)
        elif new_html != html:
            changed.append(d['id'])
        html = new_html
    index.write_text(html, encoding='utf-8')
    if changed:
        print(f'✅ index.html 件数同期: {", ".join(changed)}')
    else:
        print('・index.html 件数 変更なし')


def build_one(json_path):
    d = json.loads(json_path.read_text(encoding='utf-8'))
    html, counts, subtotal, option_total, total = build_html(d)
    out = OUTPUT_DIR / f'{d["id"]}.html'
    out.write_text(html, encoding='utf-8')
    opt = f' + オプション{option_total} = 総数{total}' if option_total else ''
    print(f'✅ {out.relative_to(PROJECT_ROOT)} 生成完了')
    print(f'   A{counts["A"]} / B{counts["B"]} / C{counts["C"]} / 小計{subtotal}{opt}')


def main():
    targets = sys.argv[1:]
    if targets:
        paths = [DATA_DIR / f'{t.removesuffix(".json")}.json' for t in targets]
    else:
        paths = sorted(DATA_DIR.glob('*.json'))
    if not paths:
        print(f'対象JSONが見つかりません: {DATA_DIR}', file=sys.stderr)
        sys.exit(1)
    for p in paths:
        if not p.exists():
            print(f'⚠ JSONなし: {p}', file=sys.stderr)
            continue
        build_one(p)
    update_index()


if __name__ == '__main__':
    main()
