#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""案件リスト → 「状態別割合」「月次見積額」の2グラフを site/business/projects-overview.html に出力。

スプレッドシート「案件リスト」を Google Sheets API で読み込み、
請求・支払い・失注の把握に最低限必要な可視化だけを出す（シンプル優先）。

使い方:
  python3 bin/build-projects-overview.py
"""

import json
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'bin'))
from sheets import get_service  # noqa: E402

SHEET_ID = '1u-oRLHZUE9HZHRZqFiJQLs0AVA1eZC1qJGmrOS-lxpc'
SHEET_NAME = '案件リスト'
DATA_RANGE = f"{SHEET_NAME}!A1:AE2912"
OUTPUT = ROOT / 'site' / 'business' / 'projects-overview.html'

# 状態カテゴリ（受注/失注/その他に分類）
SALES_STATES = {'完了', '支払待', '要対応', '請求待', '制作中'}
LOST_STATES = {'受注できず', '未受注'}

STATE_COLORS = {
    '完了':     '#10b981',
    '支払待':   '#3b82f6',
    '要対応':   '#f59e0b',
    '請求待':   '#a855f7',
    '制作中':   '#06b6d4',
    '受注できず': '#ef4444',
    '未受注':   '#f87171',
    '(空)':    '#9ca3af',
}
STATE_ORDER = ['完了', '支払待', '要対応', '請求待', '制作中', '受注できず', '未受注', '(空)']


def fetch_rows():
    svc = get_service()
    result = svc.spreadsheets().values().get(
        spreadsheetId=SHEET_ID,
        range=DATA_RANGE,
        valueRenderOption='UNFORMATTED_VALUE',
        dateTimeRenderOption='FORMATTED_STRING',
    ).execute()
    values = result.get('values', [])
    return values[0], values[1:]


def col(header, name):
    try:
        return header.index(name)
    except ValueError:
        return -1


def cell(row, i):
    return row[i] if 0 <= i < len(row) else ''


def to_money(v):
    if v == '' or v is None:
        return 0
    if isinstance(v, (int, float)):
        return int(round(float(v)))
    s = str(v).replace(',', '').strip()
    try:
        return int(round(float(s)))
    except ValueError:
        return 0


def parse_ym(s):
    s = str(s or '').strip()
    if not s or len(s) < 6:
        return None
    for fmt in ('%Y/%m/%d', '%Y-%m-%d', '%Y/%m', '%Y-%m'):
        try:
            dt = datetime.strptime(s[:len(fmt) + 4], fmt)
            return (dt.year, dt.month)
        except ValueError:
            continue
    return None


def build_html(total_count, state_data, months, series):
    now_str = datetime.now().strftime('%Y-%m-%d %H:%M')
    return f'''<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>案件 状態別割合＆月次見積額 — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-5xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">← 株式会社はなさか</a>
    /
    <a href="index.html" class="text-blue-600 hover:underline">ビジネスダッシュボード</a>
  </nav>

  <h1 class="text-3xl font-bold mb-2">案件 状態別割合 & 月次見積額</h1>
  <p class="text-gray-600 mb-2">スプレッドシート「案件リスト」の見える化。請求漏れ・支払い漏れ・失注の把握が目的。</p>
  <p class="text-xs text-gray-500 mb-8">最終更新: {now_str} ／ 全 {total_count:,} 件 ／ 自動生成: <code>bin/build-projects-overview.py</code></p>

  <!-- ① 状態別割合 -->
  <section class="bg-white rounded-lg shadow p-6 mb-8">
    <h2 class="text-xl font-bold mb-1">① 案件の状態別割合</h2>
    <p class="text-sm text-gray-600 mb-4">全 {total_count:,} 件の状態別件数と見積額。「受注できず」は失注分。</p>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-6 items-center">
      <div class="relative" style="height: 320px;">
        <canvas id="stateChart"></canvas>
      </div>
      <div>
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b text-gray-600">
              <th class="text-left py-2">状態</th>
              <th class="text-right py-2">件数</th>
              <th class="text-right py-2">割合</th>
              <th class="text-right py-2">見積額合計</th>
            </tr>
          </thead>
          <tbody>
{_state_rows(state_data, total_count)}
          </tbody>
        </table>
      </div>
    </div>
  </section>

  <!-- ② 月次見積額 -->
  <section class="bg-white rounded-lg shadow p-6 mb-8">
    <h2 class="text-xl font-bold mb-1">② 月次見積額の推移</h2>
    <p class="text-sm text-gray-600 mb-4">
      見積発生月（<code>date_estimate</code>）ベース。受注（売上対象）／失注／その他の積み上げ。
      <span class="text-gray-500">※ 帳簿には出てこない営業活動の量と質が見える。</span>
    </p>
    <div style="height: 420px;">
      <canvas id="monthlyChart"></canvas>
    </div>
  </section>

  <p class="text-xs text-gray-500 mt-8">
    更新方法: <code>python3 bin/build-projects-overview.py</code> → このページが再生成されます。<br>
    関連: <a href="recurring-revenue.html" class="text-blue-600 hover:underline">月次ストック収益</a>
  </p>

</div>

<script>
const stateData = {json.dumps(state_data, ensure_ascii=False)};
const months = {json.dumps(months)};
const seriesSales = {json.dumps(series['受注'])};
const seriesLost  = {json.dumps(series['失注'])};
const seriesOther = {json.dumps(series['その他'])};

new Chart(document.getElementById('stateChart'), {{
  type: 'doughnut',
  data: {{
    labels: stateData.map(s => s.label),
    datasets: [{{
      data: stateData.map(s => s.count),
      backgroundColor: stateData.map(s => s.color),
      borderWidth: 1
    }}]
  }},
  options: {{
    responsive: true,
    maintainAspectRatio: false,
    plugins: {{
      legend: {{ position: 'bottom' }},
      tooltip: {{
        callbacks: {{
          label: (ctx) => `${{ctx.label}}: ${{ctx.parsed.toLocaleString()}}件`
        }}
      }}
    }}
  }}
}});

new Chart(document.getElementById('monthlyChart'), {{
  type: 'bar',
  data: {{
    labels: months,
    datasets: [
      {{ label: '受注', data: seriesSales, backgroundColor: '#10b981' }},
      {{ label: '失注', data: seriesLost,  backgroundColor: '#ef4444' }},
      {{ label: 'その他', data: seriesOther, backgroundColor: '#9ca3af' }}
    ]
  }},
  options: {{
    responsive: true,
    maintainAspectRatio: false,
    scales: {{
      x: {{ stacked: true }},
      y: {{
        stacked: true,
        ticks: {{ callback: (v) => '¥' + v.toLocaleString() }}
      }}
    }},
    plugins: {{
      tooltip: {{
        callbacks: {{
          label: (ctx) => `${{ctx.dataset.label}}: ¥${{ctx.parsed.y.toLocaleString()}}`
        }}
      }}
    }}
  }}
}});
</script>

</body>
</html>
'''


def _state_rows(state_data, total):
    out = []
    for s in state_data:
        pct = s['count'] / total * 100 if total else 0
        out.append(
            f'            <tr class="border-b">\n'
            f'              <td class="py-2"><span class="inline-block w-3 h-3 rounded-full mr-2 align-middle" style="background:{s["color"]}"></span>{s["label"]}</td>\n'
            f'              <td class="text-right py-2 font-mono">{s["count"]:,}</td>\n'
            f'              <td class="text-right py-2 text-gray-500">{pct:.1f}%</td>\n'
            f'              <td class="text-right py-2 font-mono">¥{s["money"]:,}</td>\n'
            f'            </tr>'
        )
    return '\n'.join(out)


def main():
    header, rows = fetch_rows()
    i_state = col(header, 'state')
    i_sum = col(header, 'sum_estimate')
    i_de = col(header, 'date_estimate')

    state_count = Counter()
    state_money = defaultdict(int)
    by_month = defaultdict(lambda: {'受注': 0, '失注': 0, 'その他': 0})

    for r in rows:
        st_raw = cell(r, i_state)
        if st_raw == '状態':  # 残骸のヘッダー行を除外
            continue
        st = st_raw or '(空)'
        money = to_money(cell(r, i_sum))
        state_count[st] += 1
        state_money[st] += money

        ym = parse_ym(cell(r, i_de))
        if ym:
            if st in SALES_STATES:
                by_month[ym]['受注'] += money
            elif st in LOST_STATES:
                by_month[ym]['失注'] += money
            else:
                by_month[ym]['その他'] += money

    total = sum(state_count.values())
    state_data = [
        {
            'label': s,
            'count': state_count[s],
            'money': state_money[s],
            'color': STATE_COLORS.get(s, '#9ca3af'),
        }
        for s in STATE_ORDER if state_count.get(s, 0) > 0
    ]

    months_sorted = sorted(by_month.keys())
    labels = [f'{y}/{m:02d}' for (y, m) in months_sorted]
    series = {
        '受注':  [by_month[ym]['受注']  for ym in months_sorted],
        '失注':  [by_month[ym]['失注']  for ym in months_sorted],
        'その他': [by_month[ym]['その他'] for ym in months_sorted],
    }

    html = build_html(total, state_data, labels, series)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(html, encoding='utf-8')
    print(f'✅ 生成完了: {OUTPUT}')
    print(f'  全 {total:,} 件 ／ 状態 {len(state_data)} 種類 ／ {len(labels)} ヶ月分')


if __name__ == '__main__':
    main()
