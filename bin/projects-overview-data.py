#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""案件リストから「状態別割合」「月次見積額」用のデータを JSON で stdout に吐く。

site/business/projects-overview.php から呼び出される。
HTML 生成は PHP 側で行うので、ここはデータ集計のみ。

使い方:
  python3 bin/projects-overview-data.py
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


def main():
    header, rows = fetch_rows()
    i_state = col(header, 'state')
    i_sum = col(header, 'sum_estimate')
    i_de = col(header, 'date_estimate')
    i_client = col(header, 'client_name')
    i_project = col(header, 'project_name')
    i_cat = col(header, 'category')

    state_count = Counter()
    state_money = defaultdict(int)
    by_month = defaultdict(lambda: {'受注': 0, '失注': 0, 'その他': 0})
    by_month_details = defaultdict(list)

    for r in rows:
        st_raw = cell(r, i_state)
        if st_raw == '状態':
            continue
        st = st_raw or '(空)'
        money = to_money(cell(r, i_sum))
        state_count[st] += 1
        state_money[st] += money

        ym = parse_ym(cell(r, i_de))
        if ym:
            if st in SALES_STATES:
                bucket = '受注'
            elif st in LOST_STATES:
                bucket = '失注'
            else:
                bucket = 'その他'
            by_month[ym][bucket] += money
            by_month_details[ym].append({
                'state': st,
                'client': str(cell(r, i_client) or ''),
                'project': str(cell(r, i_project) or ''),
                'category': str(cell(r, i_cat) or ''),
                'date': str(cell(r, i_de) or ''),
                'money': money,
                'bucket': bucket,
                'color': STATE_COLORS.get(st, '#9ca3af'),
            })

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

    details = {
        f'{y}/{m:02d}': sorted(by_month_details[(y, m)], key=lambda d: -d['money'])
        for (y, m) in months_sorted
    }

    payload = {
        'fetched_at': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'total_count': total,
        'state_data': state_data,
        'months': labels,
        'series': series,
        'details': details,
    }
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == '__main__':
    main()
