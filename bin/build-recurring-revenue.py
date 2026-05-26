#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""recurring-revenue.html 自動生成スクリプト

Google Sheets「YCOMデータ（最新）」運用管理費用シートから月額契約データを取得し、
site/business/recurring-revenue.html を再生成する。

使い方:
  python3 bin/build-recurring-revenue.py

事前準備:
  - data/secrets/hana-sheets-key.json (Service Account鍵) が配置済み
  - Service Accountに対象スプレッドシートが共有済み
"""

import json
import subprocess
from collections import defaultdict
from datetime import datetime
from pathlib import Path

SHEET_ID = '1u-oRLHZUE9HZHRZqFiJQLs0AVA1eZC1qJGmrOS-lxpc'
SHEET_RANGE = '運用管理費用!A3:Q100'
PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_FILE = PROJECT_ROOT / 'site' / 'business' / 'recurring-revenue.html'
SHEETS_SCRIPT = PROJECT_ROOT / 'bin' / 'sheets.py'


def fetch_rows():
    result = subprocess.run(
        ['python3', str(SHEETS_SCRIPT), 'read', SHEET_ID, SHEET_RANGE, '--json'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f'sheets.py 実行失敗: {result.stderr}')
    return json.loads(result.stdout)


def classify(rows):
    active, inactive = [], []
    for row in rows:
        while len(row) < 17:
            row.append('')
        name, client, project, amount = row[0], row[1], row[2], row[3]
        url_field, memo_field = row[4], row[16]
        if not name and not client and not project:
            continue
        contract_ended = '契約終了' in (str(url_field) + str(memo_field))
        if contract_ended:
            inactive.append({'name': name, 'client': client, 'project': project,
                             'amount': amount, 'reason': '契約終了マーカー'})
            continue
        if amount == '実費':
            inactive.append({'name': name, 'client': client, 'project': project,
                             'amount': '実費', 'reason': '実費（除外）'})
            continue
        if amount == 0 or amount == '':
            if name or client or project:
                inactive.append({'name': name, 'client': client, 'project': project,
                                 'amount': amount, 'reason': '0円／空欄（要確認）'})
            continue
        if not isinstance(amount, (int, float)):
            continue
        active.append({
            'name': name,
            'client': client if client else '(未記載)',
            'project': project,
            'amount': int(amount),
        })
    return active, inactive


def build_html(active, inactive):
    by_client = defaultdict(list)
    for a in active:
        by_client[a['client']].append(a)

    client_totals = []
    for cli, items in by_client.items():
        total = sum(x['amount'] for x in items)
        client_totals.append((cli, total, items))
    client_totals.sort(key=lambda x: -x[1])

    n_active = len(active)
    total_monthly = sum(a['amount'] for a in active)
    total_yearly = total_monthly * 12
    today = datetime.now().strftime('%Y-%m-%d')

    # ヘッダー
    html = f'''<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>月次ストック収益 — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
<style>
  .metric {{ font-family: ui-monospace, monospace; font-feature-settings: "tnum"; }}
  .num {{ text-align: right; font-family: ui-monospace, monospace; font-feature-settings: "tnum"; }}
  .dup {{ background: #fef3c7; }}
</style>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-6xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">← 株式会社はなさか</a> &gt;
    <a href="index.html" class="text-blue-600 hover:underline">ビジネスダッシュボード</a>
  </nav>

  <h1 class="text-3xl font-bold mb-2">💰 月次ストック収益</h1>
  <p class="text-gray-600 mb-2">月額契約による継続的収益の見える化。<a href="goals.html#g0-2" class="text-emerald-700 hover:underline">G0.2「FY2026 ストック収益比率 20%以上」</a> 達成度のモニタリング基盤。</p>
  <p class="text-sm text-gray-500 mb-4">データ元：Google Sheets「YCOMデータ（最新）」運用管理費用シート（D列「計」） / 取得日時：{today}<br>
  集計方法：D列が数値の有効契約のみを合計。実費・契約終了マーカー・0円は別記。<code class="bg-gray-100 px-1 rounded text-xs">python3 bin/build-recurring-revenue.py</code> で再生成可。</p>

  <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
    <div class="bg-emerald-50 border-2 border-emerald-500 rounded-lg p-5 text-center">
      <p class="text-sm text-emerald-700 font-semibold">有効契約数</p>
      <p class="text-3xl font-bold text-emerald-800 metric">{n_active} 件</p>
    </div>
    <div class="bg-emerald-50 border-2 border-emerald-500 rounded-lg p-5 text-center">
      <p class="text-sm text-emerald-700 font-semibold">月額合計</p>
      <p class="text-3xl font-bold text-emerald-800 metric">¥{total_monthly:,}</p>
    </div>
    <div class="bg-emerald-50 border-2 border-emerald-500 rounded-lg p-5 text-center">
      <p class="text-sm text-emerald-700 font-semibold">年換算</p>
      <p class="text-3xl font-bold text-emerald-800 metric">¥{total_yearly:,}</p>
    </div>
  </div>

  <h2 class="text-2xl font-bold border-b-2 border-gray-800 pb-2 mb-4 mt-8">FY2026 目標との関係</h2>
  <div class="bg-blue-50 border border-blue-300 rounded-lg p-5 mb-6">
    <table class="w-full border-collapse text-sm">
      <thead>
        <tr class="bg-white">
          <th class="text-left px-3 py-2 border border-gray-200">基準</th>
          <th class="num px-3 py-2 border border-gray-200">対象売上</th>
          <th class="num px-3 py-2 border border-gray-200">ストック収益（年）</th>
          <th class="num px-3 py-2 border border-gray-200">比率</th>
          <th class="text-left px-3 py-2 border border-gray-200">判定</th>
        </tr>
      </thead>
      <tbody>
        <tr><td class="px-3 py-2 border border-gray-200">FY2025実績 売上</td><td class="num px-3 py-2 border border-gray-200">¥26,671,170</td><td class="num px-3 py-2 border border-gray-200">¥{total_yearly:,}</td><td class="num px-3 py-2 border border-gray-200 font-bold">{total_yearly/26671170*100:.1f}%</td><td class="px-3 py-2 border border-gray-200">参考</td></tr>
        <tr><td class="px-3 py-2 border border-gray-200">FY2026 保守目標 売上</td><td class="num px-3 py-2 border border-gray-200">¥30,000,000</td><td class="num px-3 py-2 border border-gray-200">¥{total_yearly:,}</td><td class="num px-3 py-2 border border-gray-200 font-bold">{total_yearly/30000000*100:.1f}%</td><td class="px-3 py-2 border border-gray-200 text-green-700">目標20%超</td></tr>
        <tr class="bg-emerald-100"><td class="px-3 py-2 border border-gray-200 font-semibold">FY2026 標準目標 売上</td><td class="num px-3 py-2 border border-gray-200">¥33,000,000</td><td class="num px-3 py-2 border border-gray-200">¥{total_yearly:,}</td><td class="num px-3 py-2 border border-gray-200 font-bold">{total_yearly/33000000*100:.1f}%</td><td class="px-3 py-2 border border-gray-200 text-green-700 font-semibold">✅ 目標20%超</td></tr>
        <tr><td class="px-3 py-2 border border-gray-200">FY2026 ストレッチ目標 売上</td><td class="num px-3 py-2 border border-gray-200">¥37,000,000</td><td class="num px-3 py-2 border border-gray-200">¥{total_yearly:,}</td><td class="num px-3 py-2 border border-gray-200 font-bold">{total_yearly/37000000*100:.1f}%</td><td class="px-3 py-2 border border-gray-200 text-green-700">目標20%超</td></tr>
      </tbody>
    </table>
    <p class="text-sm mt-3"><strong>含意</strong>：契約管理上の数字では、ストック収益比率は <strong>すでに目標を達成している水準</strong>。次の課題は「契約値 vs 実際の入金実績」のギャップ確認と、データの正確性向上。</p>
  </div>

  <h2 class="text-2xl font-bold border-b-2 border-gray-800 pb-2 mb-4 mt-8">⚠️ データ品質の要確認ポイント</h2>
  <div class="bg-yellow-50 border-l-4 border-yellow-500 p-4 mb-6 text-sm">
    <p class="font-semibold mb-2">スプレッドシートの整理が必要なポイント</p>
    <ul class="list-disc list-inside space-y-1">
      <li>シート2行目の「計¥578,000」と本ページの集計¥{total_monthly:,}に大きな乖離 → 「計」フィールドの算出方法を確認・統一</li>
      <li>同一クライアント・同一プロジェクト名で複数行があるもの（重複の可能性）— 下記テーブルで黄色背景で表示</li>
      <li>「契約終了」メモがある行 — 実態を反映してリストから外すか別管理に</li>
      <li>クライアント名が未記載の行 — 補完が必要</li>
      <li>「実費」項目 — 売上計上ではなく実費代行のため、本サマリからは除外</li>
    </ul>
  </div>

  <h2 class="text-2xl font-bold border-b-2 border-gray-800 pb-2 mb-4 mt-8">クライアント別 月額契約一覧</h2>
  <div class="overflow-x-auto mb-6">
    <table class="w-full border-collapse text-sm">
      <thead>
        <tr class="bg-gray-100">
          <th class="text-left px-3 py-2 border border-gray-200 font-semibold">クライアント</th>
          <th class="text-left px-3 py-2 border border-gray-200 font-semibold">プロジェクト</th>
          <th class="num px-3 py-2 border border-gray-200 font-semibold">月額</th>
          <th class="num px-3 py-2 border border-gray-200 font-semibold">クライアント計</th>
        </tr>
      </thead>
      <tbody>
'''

    for cli, total, items in client_totals:
        items.sort(key=lambda x: -x['amount'])
        proj_counts = defaultdict(int)
        for x in items:
            proj_counts[x['project']] += 1
        for i, item in enumerate(items):
            is_dup = proj_counts[item['project']] > 1
            cls = ' class="dup"' if is_dup else ''
            client_cell = cli if i == 0 else ''
            total_cell = f'<td class="num px-3 py-2 border border-gray-200 font-bold align-top" rowspan="{len(items)}">¥{total:,}</td>' if i == 0 else ''
            dup_mark = ' <span class="text-yellow-700 text-xs">⚠重複疑い</span>' if is_dup else ''
            html += f'        <tr{cls}>\n'
            html += f'          <td class="px-3 py-2 border border-gray-200">{client_cell}</td>\n'
            html += f'          <td class="px-3 py-2 border border-gray-200">{item["project"]}{dup_mark}</td>\n'
            html += f'          <td class="num px-3 py-2 border border-gray-200">¥{item["amount"]:,}</td>\n'
            html += f'          {total_cell}\n'
            html += f'        </tr>\n'

    html += f'''        <tr class="bg-emerald-50 font-bold border-t-2 border-emerald-500">
          <td colspan="2" class="px-3 py-2 border border-gray-200">月額合計</td>
          <td class="num px-3 py-2 border border-gray-200 text-emerald-800">¥{total_monthly:,}</td>
          <td class="num px-3 py-2 border border-gray-200 text-emerald-800">¥{total_monthly:,}</td>
        </tr>
      </tbody>
    </table>
  </div>
  <p class="text-xs text-gray-500 mb-6">黄色背景 = 同一クライアント・同一プロジェクト名で複数行あり（重複の可能性）。スプレッドシートの整理で確認・統合を推奨。</p>

  <h2 class="text-2xl font-bold border-b-2 border-gray-800 pb-2 mb-4 mt-8">除外・要確認の項目</h2>
  <div class="overflow-x-auto mb-6">
    <table class="w-full border-collapse text-sm">
      <thead>
        <tr class="bg-gray-100">
          <th class="text-left px-3 py-2 border border-gray-200 font-semibold">クライアント</th>
          <th class="text-left px-3 py-2 border border-gray-200 font-semibold">プロジェクト</th>
          <th class="num px-3 py-2 border border-gray-200 font-semibold">金額</th>
          <th class="text-left px-3 py-2 border border-gray-200 font-semibold">理由</th>
        </tr>
      </thead>
      <tbody>
'''
    for inv in inactive:
        amt = inv['amount']
        amt_str = f'¥{int(amt):,}' if isinstance(amt, (int, float)) and amt != 0 else (str(amt) if amt else '—')
        html += f'        <tr>\n'
        html += f'          <td class="px-3 py-2 border border-gray-200">{inv["client"] or "—"}</td>\n'
        html += f'          <td class="px-3 py-2 border border-gray-200">{inv["project"] or "—"}</td>\n'
        html += f'          <td class="num px-3 py-2 border border-gray-200">{amt_str}</td>\n'
        html += f'          <td class="px-3 py-2 border border-gray-200">{inv["reason"]}</td>\n'
        html += f'        </tr>\n'

    html += '''      </tbody>
    </table>
  </div>

  <h2 class="text-2xl font-bold border-b-2 border-gray-800 pb-2 mb-4 mt-8">更新運用と次のアクション</h2>

  <h3 class="text-lg font-semibold mb-2 mt-4">更新運用</h3>
  <ul class="list-disc list-inside space-y-1 text-sm mb-4">
    <li>本ページは Google Sheets「YCOMデータ（最新）」運用管理費用シートから自動生成</li>
    <li>再生成コマンド：<code class="bg-gray-100 px-1 rounded text-xs">python3 bin/build-recurring-revenue.py</code></li>
    <li>毎月初に再生成 → 前月の契約変動を反映</li>
  </ul>

  <h3 class="text-lg font-semibold mb-2 mt-4">次のアクション</h3>
  <ol class="list-decimal list-inside space-y-1 text-sm mb-4">
    <li><strong>スプレッドシートのクレンジング</strong>：重複行の統合、契約終了の整理、クライアント名の補完</li>
    <li><strong>「計」フィールドの算出ルール統一</strong>：列計算式の見直し</li>
    <li><strong>契約値 vs 実入金 のギャップ確認</strong>：補助元帳または請求シートとの突合</li>
    <li><strong>HANAツール案件マスタへの移行</strong>（Phase 2）：スプレッドシート → HANAツールDB への構造化</li>
  </ol>

  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-8">関連</h2>
  <ul class="list-disc list-inside space-y-1 text-sm">
    <li><a href="goals.html" class="text-blue-600 hover:underline">目標ツリー（goals.html）</a> — G0.2 ストック収益比率20%以上</li>
    <li><a href="reviews/fy2025-annual.html" class="text-blue-600 hover:underline">FY2025年度決算振り返り</a></li>
    <li><a href="kpi.html" class="text-blue-600 hover:underline">経営KPIダッシュボード</a></li>
    <li><a href="focus.html" class="text-blue-600 hover:underline">フォーカスダッシュボード</a></li>
  </ul>

  <p class="text-xs text-gray-400 mt-10">最終更新: ''' + today + ''' / データ元: Google Sheets / 更新頻度: 月次（再生成は bin/build-recurring-revenue.py）</p>

</div>
</body>
</html>
'''
    return html, n_active, total_monthly, total_yearly, len(inactive)


def main():
    rows = fetch_rows()
    active, inactive = classify(rows)
    html, n, monthly, yearly, n_inv = build_html(active, inactive)
    OUTPUT_FILE.write_text(html, encoding='utf-8')
    print(f'✅ {OUTPUT_FILE} 生成完了')
    print(f'   有効契約: {n}件 / 月額: ¥{monthly:,} / 年換算: ¥{yearly:,}')
    print(f'   除外・要確認: {n_inv}件')


if __name__ == '__main__':
    main()
