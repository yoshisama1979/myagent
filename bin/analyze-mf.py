#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""マネーフォワード CSV 分析スクリプト

マネーフォワード クラウド会計から出力した CSV を読み込み、
経営判断に必要なサマリを Markdown 形式で出力する。

対応 CSV:
  - 損益計算書（PL）
  - 貸借対照表（BS）
  - 月次推移表（PL推移）  ※将来対応
  - 補助元帳            ※将来対応

使い方:
  python bin/analyze-mf.py data/financial/2025/      # 年度データ
  python bin/analyze-mf.py data/financial/2026-05/   # 月次データ

データディレクトリ内の損益計算書・貸借対照表 CSV を自動検出し、
標準出力に Markdown レポートを書き出す。

エンコーディング:
  マネーフォワード CSV は Shift_JIS。本スクリプトで自動的に処理する。
"""

import csv
import sys
import io
from pathlib import Path
from typing import List, Dict

# Windows コンソールで日本語を出力するための設定
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')


def read_mf_csv(path: Path) -> List[List[str]]:
    """マネーフォワード CSV を Shift_JIS で読み込む"""
    with open(path, 'r', encoding='shift_jis') as f:
        reader = csv.reader(f)
        return list(reader)


def yen(amount: int) -> str:
    """金額を ¥1,234,567 形式に整形"""
    return f"¥{amount:,}"


def parse_pl(rows: List[List[str]]) -> Dict:
    """損益計算書のCSVから主要項目を抽出"""
    result = {
        'period': '',
        'sales': 0,
        'cogs': 0,
        'gross_profit': 0,
        'sga': 0,
        'operating_profit': 0,
        'non_op_income': 0,
        'non_op_expense': 0,
        'ordinary_profit': 0,
        'special_income': 0,
        'special_loss': 0,
        'pretax_profit': 0,
        'corp_tax': 0,
        'net_profit': 0,
        'sga_items': [],  # (科目, 年間額, 構成比)
    }
    # ヘッダから期間を取得
    if len(rows) > 0:
        header = rows[0]
        for cell in header:
            if '開始月' in cell:
                result['period'] = cell.replace('開始月:', '')
            elif '終了月' in cell:
                result['period'] += ' 〜 ' + cell.replace('終了月:', '')

    in_sga = False
    for row in rows[1:]:
        if not row:
            continue
        label_main = row[0] if len(row) > 0 else ''
        label_sub = row[1] if len(row) > 1 else ''

        # セクション認識（金額のない見出し行もあり得るので、先にヘッダ判定）
        if label_main == '販売費及び一般管理費':
            in_sga = True
            continue

        # ここから金額が必要な行
        if len(row) < 7:
            continue
        amount_str = row[6] if len(row) > 6 else '0'
        try:
            amount = int(amount_str) if amount_str else 0
        except ValueError:
            amount = 0
        ratio = row[7] if len(row) > 7 else ''

        if label_main == '販売費及び一般管理費合計':
            result['sga'] = amount
            in_sga = False
            continue

        # 主要項目
        if label_main == '売上高合計':
            result['sales'] = amount
        elif label_main == '売上原価合計':
            result['cogs'] = amount
        elif label_main == '売上総利益':
            result['gross_profit'] = amount
        elif label_main == '営業利益':
            result['operating_profit'] = amount
        elif label_main == '営業外収益合計':
            result['non_op_income'] = amount
        elif label_main == '営業外費用合計':
            result['non_op_expense'] = amount
        elif label_main == '経常利益':
            result['ordinary_profit'] = amount
        elif label_main == '特別利益合計':
            result['special_income'] = amount
        elif label_main == '特別損失合計':
            result['special_loss'] = amount
        elif label_main == '税引前当期純利益':
            result['pretax_profit'] = amount
        elif label_main == '当期純利益':
            result['net_profit'] = amount
        elif in_sga and label_sub and not label_sub.startswith('合計'):
            # 販管費の中の科目
            if amount > 0:
                result['sga_items'].append((label_sub, amount, ratio))

    return result


def parse_bs(rows: List[List[str]]) -> Dict:
    """貸借対照表のCSVから主要項目を抽出"""
    result = {
        'cash': 0,
        'receivables': 0,
        'current_assets': 0,
        'fixed_assets': 0,
        'total_assets': 0,
        'current_liabilities': 0,
        'fixed_liabilities': 0,
        'total_liabilities': 0,
        'capital': 0,
        'retained_earnings': 0,
        'total_equity': 0,
        'top_clients': [],  # (クライアント名, 年間借方額, 年間貸方額, 期末残高)
    }
    in_receivables = False
    for row in rows[1:]:
        if len(row) < 7:
            continue
        label_main = row[0]
        label_sub = row[1] if len(row) > 1 else ''
        label_subsub = row[2] if len(row) > 2 else ''
        debit_str = row[4] if len(row) > 4 else '0'
        credit_str = row[5] if len(row) > 5 else '0'
        end_str = row[6] if len(row) > 6 else '0'
        try:
            debit = int(debit_str) if debit_str else 0
            credit = int(credit_str) if credit_str else 0
            end = int(end_str) if end_str else 0
        except ValueError:
            debit, credit, end = 0, 0, 0

        # 売掛金の補助科目（クライアント別）を抽出
        if label_sub == '売掛金' and label_subsub == '':
            in_receivables = True
            continue
        if in_receivables:
            if label_subsub and label_subsub != '補助科目なし':
                result['top_clients'].append((label_subsub, debit, credit, end))
            elif label_main and not label_main.startswith(''):
                in_receivables = False

        if label_main == '現金及び預金合計':
            result['cash'] = end
            in_receivables = False
        elif label_main == '売上債権合計':
            result['receivables'] = end
            in_receivables = False
        elif label_main == '流動資産合計':
            result['current_assets'] = end
        elif label_main == '固定資産合計':
            result['fixed_assets'] = end
        elif label_main == '資産の部合計':
            result['total_assets'] = end
        elif label_main == '流動負債合計':
            result['current_liabilities'] = end
        elif label_main == '固定負債合計':
            result['fixed_liabilities'] = end
        elif label_main == '負債の部合計':
            result['total_liabilities'] = end
        elif label_main == '資本金合計':
            result['capital'] = end
        elif '利益剰余金合計' in label_main:
            result['retained_earnings'] = end
        elif label_main == '純資産の部合計':
            result['total_equity'] = end

    return result


def report_pl(pl: Dict) -> None:
    """損益計算書のサマリを出力"""
    print(f'## 損益計算書サマリ')
    print(f'\n対象期間: {pl["period"]}\n')

    print('### 主要指標\n')
    print('| 指標 | 金額 | 売上比 |')
    print('|------|------|------|')
    print(f'| 売上高 | {yen(pl["sales"])} | 100.0% |')
    if pl["cogs"]:
        print(f'| 売上原価 | {yen(pl["cogs"])} | {pl["cogs"]/pl["sales"]*100:.1f}% |')
    print(f'| 売上総利益 | {yen(pl["gross_profit"])} | {pl["gross_profit"]/pl["sales"]*100:.1f}% |')
    print(f'| 販管費 | {yen(pl["sga"])} | {pl["sga"]/pl["sales"]*100:.1f}% |')
    print(f'| **営業利益** | **{yen(pl["operating_profit"])}** | **{pl["operating_profit"]/pl["sales"]*100:.1f}%** |')
    print(f'| 経常利益 | {yen(pl["ordinary_profit"])} | {pl["ordinary_profit"]/pl["sales"]*100:.1f}% |')
    print(f'| 当期純利益 | {yen(pl["net_profit"])} | {pl["net_profit"]/pl["sales"]*100:.1f}% |')

    months = 12
    print(f'\n月平均売上: {yen(pl["sales"] // months)}')

    print('\n### 販管費 上位（売上比1%以上）\n')
    print('| 科目 | 年間額 | 売上比 |')
    print('|------|------|------|')
    top_sga = sorted(pl['sga_items'], key=lambda x: -x[1])
    for label, amount, ratio in top_sga[:10]:
        ratio_num = amount / pl["sales"] * 100
        if ratio_num >= 1.0:
            print(f'| {label} | {yen(amount)} | {ratio_num:.1f}% |')


def report_bs(bs: Dict) -> None:
    """貸借対照表のサマリを出力"""
    print(f'\n## 貸借対照表サマリ\n')

    print('### 主要指標\n')
    print('| 指標 | 金額 | 備考 |')
    print('|------|------|------|')
    print(f'| 現金及び預金 | {yen(bs["cash"])} | 期末キャッシュ残高 |')
    print(f'| 売掛金 | {yen(bs["receivables"])} | 期末未回収 |')
    print(f'| 流動資産合計 | {yen(bs["current_assets"])} | |')
    print(f'| 固定資産合計 | {yen(bs["fixed_assets"])} | |')
    print(f'| **資産合計** | **{yen(bs["total_assets"])}** | |')
    print(f'| 流動負債合計 | {yen(bs["current_liabilities"])} | |')
    print(f'| 固定負債合計 | {yen(bs["fixed_liabilities"])} | |')
    print(f'| 負債合計 | {yen(bs["total_liabilities"])} | |')
    print(f'| 純資産合計 | {yen(bs["total_equity"])} | |')

    if bs['total_assets'] > 0:
        equity_ratio = bs['total_equity'] / bs['total_assets'] * 100
        print(f'\n**自己資本比率: {equity_ratio:.1f}%**（中小企業平均 約40%）')

    if bs['top_clients']:
        print('\n### 売掛金 取引先別（年間回収額 上位）\n')
        print('| クライアント | 年間回収額 | 期末売掛残 |')
        print('|------|------|------|')
        # 期間貸方金額（年間回収額）でソート
        sorted_clients = sorted(bs['top_clients'], key=lambda x: -x[2])
        for name, debit, credit, end in sorted_clients[:10]:
            if credit > 0:
                print(f'| {name} | {yen(credit)} | {yen(end)} |')


def main():
    if len(sys.argv) < 2:
        print('使い方: python bin/analyze-mf.py <data_dir>')
        print('例: python bin/analyze-mf.py data/financial/2025/      （年度データ）')
        print('例: python bin/analyze-mf.py data/financial/2026-05/   （月次データ）')
        sys.exit(1)

    data_dir = Path(sys.argv[1])
    if not data_dir.is_dir():
        print(f'エラー: ディレクトリが存在しません: {data_dir}')
        sys.exit(1)

    pl_files = list(data_dir.glob('損益計算書*.csv'))
    bs_files = list(data_dir.glob('貸借対照表*.csv'))

    print(f'# マネーフォワード 財務分析レポート\n')
    print(f'データソース: {data_dir}\n')

    if pl_files:
        pl = parse_pl(read_mf_csv(pl_files[0]))
        report_pl(pl)
    else:
        print('損益計算書 CSV が見つかりません')

    if bs_files:
        bs = parse_bs(read_mf_csv(bs_files[0]))
        report_bs(bs)
    else:
        print('\n貸借対照表 CSV が見つかりません')


if __name__ == '__main__':
    main()
