#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""案件リスト（YCOMデータ）の構成分析ツール

スプレッドシート「案件リスト」を全件取得し、複数の軸で集計サマリーを標準出力に出す。
HTML化は別ツールに分離する。

使い方:
  python bin/analyze-projects.py summary      # 全体俯瞰
  python bin/analyze-projects.py monthly      # 月次推移（date_estimate基準）
  python bin/analyze-projects.py clients      # クライアント別ランキング
  python bin/analyze-projects.py categories   # カテゴリ別集計
  python bin/analyze-projects.py dump TSV     # 全データTSV出力（パイプ用途）

データ仕様（2026-05-27現在）:
  - シートID: 1u-oRLHZUE9HZHRZqFiJQLs0AVA1eZC1qJGmrOS-lxpc / 案件リスト
  - 30列（A〜AE主要）、データ行 2〜2912（実データ約2432行）
  - state: 受注できず/完了/支払待/要対応/請求待/制作中/未受注
  - 売上計上対象: 「受注できず」と「未受注」以外
"""

import sys
import json
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sheets import get_service  # noqa: E402

SHEET_ID = '1u-oRLHZUE9HZHRZqFiJQLs0AVA1eZC1qJGmrOS-lxpc'
SHEET_NAME = '案件リスト'
DATA_RANGE = f"{SHEET_NAME}!A1:AE2912"

# 売上計上対象（失注・未受注は除く）
SALES_STATES = {'完了', '支払待', '要対応', '請求待', '制作中'}


def fetch_all_rows():
    """シート全体を1リクエストで取得し、ヘッダー＋データ行のタプルを返す"""
    service = get_service()
    result = service.spreadsheets().values().get(
        spreadsheetId=SHEET_ID,
        range=DATA_RANGE,
        valueRenderOption='UNFORMATTED_VALUE',
        dateTimeRenderOption='FORMATTED_STRING',
    ).execute()
    values = result.get('values', [])
    if not values:
        print('データが取得できませんでした', file=sys.stderr)
        sys.exit(1)
    header = values[0]
    rows = values[1:]
    return header, rows


def col_idx(header, name):
    """列名 → インデックス。見つからなければ -1"""
    try:
        return header.index(name)
    except ValueError:
        return -1


def get_cell(row, idx):
    """範囲外を空文字に正規化"""
    if idx < 0 or idx >= len(row):
        return ''
    return row[idx]


def to_money(v):
    """セル値を整数（円）に変換。空 / 文字列は 0。"""
    if v == '' or v is None:
        return 0
    if isinstance(v, (int, float)):
        return int(round(float(v)))
    s = str(v).replace(',', '').strip()
    if not s:
        return 0
    try:
        return int(round(float(s)))
    except ValueError:
        return 0


def parse_year(date_str):
    """YYYY/MM/DD or YYYY-MM-DD → 年(int)。失敗時 None"""
    if not date_str:
        return None
    s = str(date_str).strip()
    if not s:
        return None
    # よくある形式: 2025/12/31, 2025-12-31, 2025/12
    for fmt in ('%Y/%m/%d', '%Y-%m-%d', '%Y/%m', '%Y-%m', '%Y'):
        try:
            return datetime.strptime(s[:len(fmt) + 4], fmt).year
        except ValueError:
            continue
    # 先頭4文字が年
    if len(s) >= 4 and s[:4].isdigit():
        try:
            y = int(s[:4])
            if 2000 <= y <= 2100:
                return y
        except ValueError:
            pass
    return None


def parse_ym(date_str):
    """YYYY/MM/DD → (year, month) tuple。失敗時 None"""
    if not date_str:
        return None
    s = str(date_str).strip()
    if not s or len(s) < 6:
        return None
    for fmt in ('%Y/%m/%d', '%Y-%m-%d', '%Y/%m', '%Y-%m'):
        try:
            dt = datetime.strptime(s[:len(fmt) + 4], fmt)
            return (dt.year, dt.month)
        except ValueError:
            continue
    return None


def fiscal_year(year, month):
    """株式会社はなさかの会計年度（10月始まり）。
    2025/10〜2026/9 → FY2026"""
    if month >= 10:
        return year + 1
    return year


def cmd_summary(header, rows):
    """全体俯瞰：state × カテゴリのクロス、合計金額、データ年範囲"""
    i_state = col_idx(header, 'state')
    i_cat = col_idx(header, 'category')
    i_sum = col_idx(header, 'sum_estimate')
    i_de = col_idx(header, 'date_estimate')
    i_dr = col_idx(header, 'date_received')

    state_count = Counter()
    state_money = defaultdict(int)
    cat_count = Counter()
    cat_money = defaultdict(int)
    cross = defaultdict(int)  # (state, cat) → 件数
    de_years = Counter()
    dr_years = Counter()

    for r in rows:
        state = get_cell(r, i_state) or '(空)'
        cat = get_cell(r, i_cat) or '(空)'
        money = to_money(get_cell(r, i_sum))
        state_count[state] += 1
        state_money[state] += money
        cat_count[cat] += 1
        cat_money[cat] += money
        cross[(state, cat)] += 1
        y_de = parse_year(get_cell(r, i_de))
        if y_de:
            de_years[y_de] += 1
        y_dr = parse_year(get_cell(r, i_dr))
        if y_dr:
            dr_years[y_dr] += 1

    print(f'=== 案件リスト 全体俯瞰（{len(rows)}行） ===\n')

    print('▼ state別 件数 / 見積額合計')
    print(f'  {"state":<10} {"件数":>6}  {"見積額合計":>14}')
    for s, n in state_count.most_common():
        print(f'  {s:<10} {n:>6}  {state_money[s]:>14,} 円')
    print()

    print('▼ category別 件数 / 見積額合計')
    print(f'  {"category":<12} {"件数":>6}  {"見積額合計":>14}')
    for c, n in cat_count.most_common():
        print(f'  {c:<12} {n:>6}  {cat_money[c]:>14,} 円')
    print()

    print('▼ date_estimate（見積日）の年分布')
    for y in sorted(de_years.keys()):
        print(f'  {y}: {de_years[y]:>4}件')
    print()

    print('▼ date_received（受注日）の年分布')
    for y in sorted(dr_years.keys()):
        print(f'  {y}: {dr_years[y]:>4}件')
    print()

    print('▼ 売上計上対象（完了+支払待+要対応+請求待+制作中）の集計')
    sales_total = sum(state_money[s] for s in SALES_STATES if s in state_money)
    sales_count = sum(state_count[s] for s in SALES_STATES if s in state_count)
    print(f'  対象件数: {sales_count} 件')
    print(f'  合計金額: {sales_total:,} 円（全期間累計、未来分含む）')


def cmd_monthly(header, rows):
    """月次推移：date_estimate（見積日）または date_received（受注日）ベース"""
    i_state = col_idx(header, 'state')
    i_sum = col_idx(header, 'sum_estimate')
    i_de = col_idx(header, 'date_estimate')
    i_dr = col_idx(header, 'date_received')
    i_expire = col_idx(header, 'expire')

    # キー: (year, month, 区分) → 金額
    by_month_estimate = defaultdict(int)   # 見積発生月（受注見込み）
    by_month_received = defaultdict(int)   # 受注月
    by_month_expire = defaultdict(int)     # 期限月（運用管理費の発生月の代理）

    for r in rows:
        state = get_cell(r, i_state)
        if state not in SALES_STATES:
            continue
        money = to_money(get_cell(r, i_sum))
        ym_e = parse_ym(get_cell(r, i_de))
        if ym_e:
            by_month_estimate[ym_e] += money
        ym_r = parse_ym(get_cell(r, i_dr))
        if ym_r:
            by_month_received[ym_r] += money
        ym_x = parse_ym(get_cell(r, i_expire))
        if ym_x:
            by_month_expire[ym_x] += money

    print(f'=== 月次推移（売上計上対象のみ）===\n')

    def print_monthly(label, d):
        if not d:
            return
        print(f'▼ {label}')
        print(f'  {"年月":<8} {"金額":>14}  {"FY":>6}')
        for ym in sorted(d.keys()):
            y, m = ym
            fy = fiscal_year(y, m)
            print(f'  {y:04d}/{m:02d} {d[ym]:>14,} 円  FY{fy}')
        print()
        # 年度合計
        fy_total = defaultdict(int)
        for (y, m), v in d.items():
            fy_total[fiscal_year(y, m)] += v
        print(f'  ▽ 年度合計（FY、10月始まり）')
        for fy in sorted(fy_total.keys()):
            print(f'    FY{fy}: {fy_total[fy]:>14,} 円')
        print()

    print_monthly('date_estimate（見積発生月）基準', by_month_estimate)
    print_monthly('date_received（受注月）基準', by_month_received)
    print_monthly('expire（期限月＝運用管理費の発生月の代理）基準', by_month_expire)


def cmd_clients(header, rows):
    """クライアント別ランキング（売上計上対象のみ）"""
    i_state = col_idx(header, 'state')
    i_sum = col_idx(header, 'sum_estimate')
    i_cn = col_idx(header, 'client_name')

    client_count = Counter()
    client_money = defaultdict(int)

    for r in rows:
        state = get_cell(r, i_state)
        if state not in SALES_STATES:
            continue
        cn = get_cell(r, i_cn) or '(空)'
        client_count[cn] += 1
        client_money[cn] += to_money(get_cell(r, i_sum))

    print(f'=== クライアント別 売上Top30（全期間累計）===\n')
    print(f'  {"順位":>4} {"件数":>5} {"見積額合計":>14}  クライアント名')
    ranking = sorted(client_money.items(), key=lambda x: -x[1])[:30]
    for i, (cn, money) in enumerate(ranking, 1):
        print(f'  {i:>4} {client_count[cn]:>5} {money:>14,} 円  {cn}')
    print()
    print(f'  該当クライアント総数: {len(client_money)} 社')
    print(f'  Top30合計: {sum(m for _,m in ranking):,} 円')


def cmd_categories(header, rows):
    """カテゴリ × state クロス集計"""
    i_state = col_idx(header, 'state')
    i_cat = col_idx(header, 'category')
    i_sum = col_idx(header, 'sum_estimate')

    cross_count = defaultdict(int)
    cross_money = defaultdict(int)
    states_in_data = set()
    cats_in_data = set()

    for r in rows:
        state = get_cell(r, i_state) or '(空)'
        cat = get_cell(r, i_cat) or '(空)'
        money = to_money(get_cell(r, i_sum))
        cross_count[(cat, state)] += 1
        cross_money[(cat, state)] += money
        states_in_data.add(state)
        cats_in_data.add(cat)

    state_order = ['完了', '支払待', '要対応', '請求待', '制作中', '受注できず', '未受注', '(空)']
    states = [s for s in state_order if s in states_in_data]
    # カテゴリは出現件数順
    cat_total = Counter()
    for (cat, _), v in cross_count.items():
        cat_total[cat] += v
    cats = [c for c, _ in cat_total.most_common()]

    print(f'=== カテゴリ × state クロス集計 ===\n')
    print(f'▼ 件数（行: カテゴリ、列: state）')
    header_str = f'  {"category":<12}' + ''.join(f' {s:>9}' for s in states) + f' {"計":>7}'
    print(header_str)
    for c in cats:
        row_total = sum(cross_count[(c, s)] for s in states)
        cells = ''.join(f' {cross_count[(c, s)]:>9}' for s in states)
        print(f'  {c:<12}{cells} {row_total:>7}')
    print()

    print(f'▼ 見積額合計（万円単位、行: カテゴリ、列: state）')
    print(header_str)
    for c in cats:
        row_total = sum(cross_money[(c, s)] for s in states)
        cells = ''.join(f' {cross_money[(c, s)]//10000:>9}' for s in states)
        print(f'  {c:<12}{cells} {row_total//10000:>7}')
    print()


def cmd_dump(header, rows):
    """TSV ダンプ（パイプ用途）"""
    print('\t'.join(header))
    for r in rows:
        padded = r + [''] * (len(header) - len(r))
        print('\t'.join(str(v) for v in padded[:len(header)]))


def main():
    if len(sys.argv) < 2:
        print('使い方:')
        print('  python bin/analyze-projects.py summary')
        print('  python bin/analyze-projects.py monthly')
        print('  python bin/analyze-projects.py clients')
        print('  python bin/analyze-projects.py categories')
        print('  python bin/analyze-projects.py dump')
        sys.exit(1)

    cmd = sys.argv[1]
    header, rows = fetch_all_rows()

    if cmd == 'summary':
        cmd_summary(header, rows)
    elif cmd == 'monthly':
        cmd_monthly(header, rows)
    elif cmd == 'clients':
        cmd_clients(header, rows)
    elif cmd == 'categories':
        cmd_categories(header, rows)
    elif cmd == 'dump':
        cmd_dump(header, rows)
    else:
        print(f'未知のコマンド: {cmd}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
