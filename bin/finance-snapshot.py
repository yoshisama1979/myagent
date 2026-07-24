#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""finance-snapshot.py — 経理入力状況＋財務スナップショット（読み取り専用・T-019）

目的:
  「会話だけでなく数字の根拠を見てアドバイスする」ために、経営パートナーが
  週次朝礼・月初レビューで参照する数値ダイジェストを1コマンドで出す。

  ① 経理入力の状況 … 会計が何ヶ月分入っているか／費目の欠落／未分類残高
  ② 財務状況       … 入力済み期間ベースの売上・費用・利益／前年同ペース比／目標比
  ③ 案件の動き     … 受注・請求待ち・支払待ち（Google Sheets・日次更新）
  ④ ストック収益   … recurring-revenue.html の生成値

設計原則:
  - **入っている数字だけで語る**。未入力を利益に化けさせない（本ツールの主目的）。
    期中PLの単純12倍予測は、費用の入力が遅れているときに利益を過大表示するため出さない。
  - 会計（MF）と案件シートは**基準が違う**（売上計上 vs 案件金額）。合算・換算しない。
  - 目標値は goals.html を正とし、ここでは読むだけ（二重台帳にしない）。

使い方:
  python3 bin/finance-snapshot.py             # 人が読む要約
  python3 bin/finance-snapshot.py --json      # JSON
  python3 bin/finance-snapshot.py --no-fetch  # Sheets を取りに行かない（キャッシュのみ）

読み取り専用: ファイル書き込み・外部送信・API書き込みは一切しない。
"""

import argparse
import csv
import io
import json
import re
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FINANCIAL = ROOT / 'data' / 'financial'
GOALS_HTML = ROOT / 'site' / 'business' / 'goals.html'
RECURRING_HTML = ROOT / 'site' / 'business' / 'recurring-revenue.html'
PROJECTS_CACHE = ROOT / 'data' / 'cache' / 'projects-overview.json'
PROJECTS_SCRIPT = ROOT / 'bin' / 'projects-overview-data.py'

CACHE_MAX_AGE_SEC = 6 * 3600
# 前年の販管費のうち「売上比 この割合以上」の勘定科目が今期に無ければ入力漏れを疑う
MISSING_ACCOUNT_MIN_RATIO = 0.01
# 未分類とみなす勘定科目名（マネーフォワードの自動仕訳が判定を保留した残高）
UNCLASSIFIED_RE = re.compile(r'要確認|不明|仮受|仮払|未確定')

KEY_ITEMS = ['売上高合計', '売上総利益', '販売費及び一般管理費合計',
             '営業利益', '経常利益', '当期純利益']


# ---------------------------------------------------------------- 共通ユーティリティ

def yen(v):
    if v is None:
        return '—'
    return f'¥{v:,}'


def man(v):
    """万円表記（読みやすさ用）。"""
    if v is None:
        return '—'
    return f'{v/10000:,.0f}万'


def fiscal_year(d: date) -> int:
    """はなさかの決算期は4月始まり。FY2026 = 2026-04〜2027-03。"""
    return d.year if d.month >= 4 else d.year - 1


def closed_month_count(d: date, fy: int) -> int:
    """当該FYで「すでに月末を迎えた（＝締めるべき）」月数。当月は締め前なので数えない。"""
    months = (d.year - fy) * 12 + (d.month - 4)
    return max(0, months)


def lag_months(end: str, d: date) -> int:
    """入力済みの終了月と「締めるべき月（＝前月）」の差。

    月末どうしの日数差（2/28 と 6/30 等）で端数が出ないよう、月インデックスの差で数える。
    PL が FY 開始月から始まっていない場合でも正しく測れる（月数の引き算に依存しない）。
    """
    due_y, due_m = (d.year, d.month - 1) if d.month > 1 else (d.year - 1, 12)
    end_y, end_m = int(end[:4]), int(end[5:7])
    return max(0, (due_y * 12 + due_m) - (end_y * 12 + end_m))


# ---------------------------------------------------------------- 会計（MFクラウドPL/BS）

def read_sjis(path: Path) -> str:
    raw = path.read_bytes()
    for enc in ('cp932', 'utf-8-sig', 'utf-8'):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode('cp932', errors='replace')


def parse_pl(fy: int):
    """data/financial/<FY>/pl.csv を読む。無ければ None。"""
    path = FINANCIAL / str(fy) / 'pl.csv'
    if not path.is_file():
        return None
    rows = list(csv.reader(io.StringIO(read_sjis(path))))
    if len(rows) < 2:
        return None

    dates = [m.group(0) for h in rows[0]
             if (m := re.search(r'\d{4}-\d{2}-\d{2}', str(h)))]
    if len(dates) < 2:
        return None
    start, end = dates[0], dates[1]

    items, sga = {}, {}
    in_sga = False
    for row in rows[1:]:
        top = (row[0] if len(row) > 0 else '').strip()
        name = (row[1] if len(row) > 1 else '').strip()
        sub = (row[2] if len(row) > 2 else '').strip()

        if len(row) < 4:
            if top == '販売費及び一般管理費':
                in_sga = True
            continue
        if len(row) < 7:
            continue
        if sub:  # 補助科目の行は親科目と二重計上になるので飛ばす
            continue

        try:
            balance = int(str(row[6]).replace(',', '').replace('"', '') or 0)
        except ValueError:
            continue

        if top and not name:
            items[top] = balance
            if top in ('販売費及び一般管理費合計', '営業利益'):
                in_sga = False
        elif not top and name:
            items[name] = balance
            if in_sga:
                sga[name] = balance

    sy, sm = int(start[:4]), int(start[5:7])
    ey, em = int(end[:4]), int(end[5:7])
    months = (ey - sy) * 12 + (em - sm) + 1

    return {
        'fy': fy, 'start': start, 'end': end, 'months': months,
        'is_full_year': months >= 12,
        'items': items, 'sga': sga,
        'mtime': datetime.fromtimestamp(path.stat().st_mtime).strftime('%Y-%m-%d'),
    }


BS_KEYS = {
    'cash': '現金及び預金合計',
    'receivable': '売上債権合計',
    'assets': '資産の部合計',
    'liabilities': '負債の部合計',
    'equity': '純資産の部合計',
}


def parse_bs(fy: int):
    """data/financial/<FY>/bs.csv を読む。期首（列3）と期末（列6）の残高を取る。

    ※ 売掛金の補助科目には取引先名が入っているが、**名前は一切保持しない**
      （data/financial/README.md「個別取引明細・取引先名の詳細は集計結果から除外」）。
      依存度は名前を伏せた比率だけを出す。
    """
    path = FINANCIAL / str(fy) / 'bs.csv'
    if not path.is_file():
        return None
    rows = list(csv.reader(io.StringIO(read_sjis(path))))
    if len(rows) < 2:
        return None

    def num(cell):
        try:
            return int(str(cell).replace(',', '').replace('"', '') or 0)
        except ValueError:
            return None

    out = {'opening': {}, 'closing': {}, 'unclassified': []}
    receivable_subs = []  # 金額のみ（取引先名は保持しない）
    parent = ''           # 補助科目の行は勘定科目名が空なので、直前の親を覚えておく
    for row in rows[1:]:
        if len(row) < 7:
            continue
        top = (row[0] or '').strip()
        name = (row[1] or '').strip()
        sub = (row[2] or '').strip()
        if name:
            parent = name
        op, cl = num(row[3]), num(row[6])
        if cl is None:
            continue
        for key, label in BS_KEYS.items():
            if top == label:
                out['opening'][key] = op
                out['closing'][key] = cl
        if parent == '売掛金' and sub and sub != '補助科目なし' and cl > 0:
            receivable_subs.append(cl)
        # BS の未分類（仮受金・仮払金・不明勘定）。名前は勘定科目名のみで取引先名は含まない
        if name and not sub and UNCLASSIFIED_RE.search(name) and cl:
            out['unclassified'].append({'name': name, 'amount': cl, 'source': 'BS'})

    receivable_subs.sort(reverse=True)
    total = sum(receivable_subs)
    if total > 0:
        out['receivable_concentration'] = {
            'top1_pct': receivable_subs[0] / total * 100,
            'top3_pct': sum(receivable_subs[:3]) / total * 100,
            'clients': len(receivable_subs),
            # 分母＝取引先別（補助科目）の**プラス残高の合計**。BS の売上債権合計とは
            # 一致しない（マイナス残高・補助科目なし・貸倒引当金を含まないため）
            'basis': total,
            'bs_total': out['closing'].get('receivable'),
        }
    cl, opn = out['closing'], out['opening']
    if cl.get('assets'):
        out['equity_ratio'] = (cl.get('equity') or 0) / cl['assets'] * 100
    out['delta'] = {k: (cl[k] - opn[k]) for k in cl if k in opn and opn[k] is not None}
    return out


def balance_alerts(bs):
    """資金の危険信号と BS 側の未分類。数字が言っていること以上は言わない（原因は社長に確認する）。"""
    if not bs:
        return []
    alerts = []
    if bs.get('unclassified'):
        total = sum(u['amount'] for u in bs['unclassified'])
        alerts.append('BS に未分類の勘定が ' + yen(total) + ' 残っている'
                      f"（{'・'.join(u['name'] for u in bs['unclassified'])}）")
    cash_d = bs['delta'].get('cash')
    recv_d = bs['delta'].get('receivable')
    if cash_d is not None and recv_d is not None and cash_d < 0 < recv_d:
        alerts.append(
            f'現預金が {man(abs(cash_d))} 減る一方で売掛金が {man(recv_d)} 増えている'
            '＝売上は立っているが現金になっていない（回収の状況を確認）')
    conc = bs.get('receivable_concentration')
    if conc and conc['top1_pct'] >= 30:
        alerts.append(f"売掛金の {conc['top1_pct']:.0f}% が1社に集中"
                      f"（上位3社で {conc['top3_pct']:.0f}%）＝回収が遅れると資金繰りに直撃")
    return alerts


def monthly_dirs(fy: int):
    """data/financial/YYYY-MM/（月次推移表・補助元帳）の投入状況。"""
    found = []
    for m in range(4, 16):
        y, mm = (fy, m) if m <= 12 else (fy + 1, m - 12)
        d = FINANCIAL / f'{y}-{mm:02d}'
        if d.is_dir() and any(d.iterdir()):
            found.append(d.name)
    return found


def accounting_status(today: date):
    fy = fiscal_year(today)
    cur = parse_pl(fy)
    prev = parse_pl(fy - 1)
    closed = closed_month_count(today, fy)
    entered = cur['months'] if cur else 0
    alerts = []

    st = {
        'fy': fy, 'prev_fy': fy - 1,
        'closed_months': closed, 'entered_months': entered,
        'lag_months': lag_months(cur['end'], today) if cur else closed,
        'period': f"{cur['start']}〜{cur['end']}" if cur else None,
        'mtime': cur['mtime'] if cur else None,
        'monthly_dirs': monthly_dirs(fy),
        'unclassified': [], 'missing_accounts': [],
    }

    if cur is None:
        alerts.append(f'FY{fy} の pl.csv が未投入（data/financial/{fy}/pl.csv）')
        st['alerts'] = alerts
        return st, cur, prev

    if st['lag_months'] > 0:
        alerts.append(
            f"会計入力が {st['lag_months']}ヶ月 遅れ（締めるべき {closed}ヶ月分 に対し "
            f"入力済み {entered}ヶ月分＝{cur['end']} まで）")

    # 未分類（★要確認・仮受金・仮払金 等）の残高。**販管費内だけでなく PL 全科目**を見る
    # （BS 側は parse_bs → unclassified_bs で別途拾う）
    revenue = cur['items'].get('売上高合計') or 0
    for name, val in cur['items'].items():
        if UNCLASSIFIED_RE.search(name) and val:
            st['unclassified'].append({
                'name': name, 'amount': val, 'source': 'PL',
                'ratio': (val / revenue) if revenue else None})
    if st['unclassified']:
        total = sum(u['amount'] for u in st['unclassified'])
        alerts.append(f'未分類の勘定が {yen(total)} 残っている'
                      f"（{'・'.join(u['name'] for u in st['unclassified'])}）")

    # 前年にあった主要費目が今期に無い＝入力漏れの疑い
    if prev:
        prev_rev = prev['items'].get('売上高合計') or 0
        for name, val in prev['sga'].items():
            if UNCLASSIFIED_RE.search(name) or val <= 0:
                continue
            if prev_rev and (val / prev_rev) < MISSING_ACCOUNT_MIN_RATIO:
                continue
            if cur['sga'].get(name, 0) == 0:
                st['missing_accounts'].append({
                    'name': name,
                    'prev_annual': val,
                    'expected': int(round(val / prev['months'] * entered)),
                })
        st['missing_accounts'].sort(key=lambda x: -x['expected'])
        if st['missing_accounts']:
            total = sum(a['expected'] for a in st['missing_accounts'])
            alerts.append(
                f"前年にあった主要費目 {len(st['missing_accounts'])}件 が今期ゼロ"
                f'＝入力漏れか年次計上か要確認（前年ペースなら約 {yen(total)} 相当）'
                '➡ 入力漏れならこのぶん利益が過大に見えている'
                '（※保険料・減価償却費・租税公課などは決算期にまとめて計上する会社もある）')

        # 偽陰性の穴埋め：科目が「ゼロ」でなく「一部だけ入力」の場合は上の検知に出ない。
        # 販管費の合計が前年同ペースを大きく下回っていれば、その取りこぼしを拾う。
        cur_sga = cur['items'].get('販売費及び一般管理費合計')
        prev_sga = prev['items'].get('販売費及び一般管理費合計')
        if cur_sga is not None and prev_sga and entered:
            pace = prev_sga / prev['months'] * entered
            st['sga_pace_pct'] = cur_sga / pace * 100 if pace else None
            if pace and cur_sga < pace * 0.7:
                alerts.append(
                    f'販管費の合計が前年同ペースの {st["sga_pace_pct"]:.0f}% しかない'
                    f'（{yen(cur_sga)} / 想定 {yen(int(round(pace)))}）'
                    '＝科目が一部だけ入力されている可能性（ゼロでない科目は上の欠落検知に出ない）')

    if not st['monthly_dirs']:
        alerts.append('月次推移表・補助元帳（data/financial/YYYY-MM/）が未投入'
                      '＝月別の伸びとクライアント別の依存度が見られない')

    st['alerts'] = alerts
    return st, cur, prev


def financials(cur, prev, target, missing_accounts=None):
    """入力済み期間ベースの実績。単純12倍の年間予測は出さない（未入力を利益に化けさせないため）。"""
    if cur is None:
        return None
    m = cur['months'] or 1
    out = {'months': m, 'items': {}, 'target': target}
    for key in KEY_ITEMS:
        v = cur['items'].get(key)
        if v is None:
            continue
        row = {'value': v, 'per_month': int(round(v / m))}
        if prev and prev['months']:
            base = int(round((prev['items'].get(key) or 0) / prev['months'] * m))
            row['prev_pace'] = base
            row['diff_pct'] = ((v - base) / abs(base) * 100) if base else None
        out['items'][key] = row

    rev = out['items'].get('売上高合計')
    if rev and target:
        out['target_monthly'] = int(round(target / 12))
        out['target_pace_pct'] = rev['per_month'] / (target / 12) * 100

    # 今期ゼロの費目の「前年同期間との差額」。**補正後の利益を確定値のように出さない**
    # （partner.md「入っていない数字を推測で埋めない」。あくまで要確認額のレンジ提示）
    op = out['items'].get('営業利益')
    if op and missing_accounts:
        out['unverified_cost'] = sum(a['expected'] for a in missing_accounts)
    return out


# ---------------------------------------------------------------- 目標（goals.html を読むだけ）

def read_target_revenue():
    """G0.1 の「標準」ラインの年間売上目標を goals.html から読む。取れなければ None。"""
    if not GOALS_HTML.is_file():
        return None
    html = GOALS_HTML.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'標準.{0,400}?¥([\d,]{7,})', html, re.S)
    if not m:
        return None
    return int(m.group(1).replace(',', ''))


# ---------------------------------------------------------------- ストック収益

def read_recurring():
    if not RECURRING_HTML.is_file():
        return None
    html = RECURRING_HTML.read_text(encoding='utf-8', errors='replace')
    out = {}
    m = re.search(r'月額合計.*?¥([\d,]+)', html, re.S)
    if m:
        out['monthly'] = int(m.group(1).replace(',', ''))
    m = re.search(r'有効契約数.*?>([\d]+)\s*件', html, re.S)
    if m:
        out['contracts'] = int(m.group(1))
    m = re.search(r'最終更新:\s*([\d-]+)', html)
    if m:
        out['updated'] = m.group(1)
    return out or None


# ---------------------------------------------------------------- 案件シート（Google Sheets）

def load_projects(no_fetch: bool):
    """案件シートを取得。**鮮度を必ず呼び出し元へ返す**（stale を fresh と誤認させない）。

    戻り値 = (data, source, fresh)。fresh=False のとき render は ⚠️ を出し、
    partner.md 側は「今週取得済み」として扱ってはいけない（Codex 指摘 🔴6）。
    """
    age = None
    if PROJECTS_CACHE.is_file():
        age = (datetime.now().timestamp() - PROJECTS_CACHE.stat().st_mtime)
    fetch_error = None
    if (age is None or age > CACHE_MAX_AGE_SEC) and not no_fetch:
        try:
            r = subprocess.run([sys.executable, str(PROJECTS_SCRIPT)],
                               cwd=str(ROOT), capture_output=True, text=True, timeout=120)
            return json.loads(r.stdout), 'fresh', True
        except Exception as e:
            fetch_error = type(e).__name__  # 例外の中身は出さない（認証情報が混ざりうる）
    if PROJECTS_CACHE.is_file():
        try:
            data = json.loads(PROJECTS_CACHE.read_text())
        except Exception:
            return None, 'キャッシュ破損', False
        hours = int(age / 3600)
        stale = age > CACHE_MAX_AGE_SEC
        label = f'キャッシュ{hours}h前'
        if fetch_error:
            label += f'／取得失敗({fetch_error})'
        elif no_fetch:
            label += '／--no-fetch'
        return data, label, not stale and not fetch_error
    return None, ('取得失敗' if fetch_error else 'データなし'), False


def projects_summary(data, fy: int, today: date):
    """案件シートの動き。会計の売上とは基準が違うので、合算・換算はしない。"""
    if not data:
        return None
    details = data.get('details', {})
    months = []
    for i in range(12):
        y, mm = divmod(4 - 1 + i, 12)
        y, mm = fy + y, mm + 1
        key = f'{y}/{mm:02d}'
        if (y, mm) > (today.year, today.month):
            break
        rows = details.get(key, [])
        months.append({
            'month': key,
            'total': sum(r.get('money') or 0 for r in rows if r.get('bucket') == '受注'),
            'count': sum(1 for r in rows if r.get('bucket') == '受注'),
        })
    states = {s['label']: {'count': s['count'], 'money': s['money']}
              for s in data.get('state_data', [])}
    return {
        'fetched_at': data.get('fetched_at'),
        'months': months,
        'fy_total': sum(m['total'] for m in months),
        'states': states,
        'quality': data.get('quality', {}),
        'thresholds': data.get('quality_thresholds', {}),
    }


# ---------------------------------------------------------------- 出力

def render(snap) -> str:
    L = []
    acc, fin, proj, rec = snap['accounting'], snap['financials'], snap['projects'], snap['recurring']
    fy = acc['fy']

    L.append(f"■ 財務スナップショット（{snap['date']} 時点・FY{fy}＝{fy}-04〜{fy+1}-03）")

    if acc['alerts']:
        L.append('')
        L.append('【⚠️ 要対応】')
        for a in acc['alerts']:
            L.append(f'  ⚠️ {a}')

    L.append('')
    L.append('【① 経理の入力状況（マネーフォワード）】')
    lag = ('✅ 追いついている' if acc['lag_months'] == 0
           else f"⚠️ {acc['lag_months']}ヶ月 遅れ")
    L.append(f"  入力済み: {acc['entered_months']}ヶ月分（{acc['period'] or '未投入'}）"
             f" / 締めるべき: {acc['closed_months']}ヶ月分 → {lag}")
    L.append(f"  CSV最終更新: {acc['mtime'] or '—'}"
             f" / 月次データ: {'・'.join(acc['monthly_dirs']) if acc['monthly_dirs'] else '未投入'}")
    for u in acc['unclassified']:
        r = f"（売上比 {u['ratio']*100:.1f}%）" if u['ratio'] is not None else ''
        L.append(f"  ⚠️ 未分類 {u['name']}: {yen(u['amount'])}{r}")
    if acc['missing_accounts']:
        L.append(f"  ⚠️ 今期ゼロの主要費目（前年ペース換算）:")
        for a in acc['missing_accounts'][:8]:
            L.append(f"       {a['name']}: 想定 {yen(a['expected'])}（前年通年 {yen(a['prev_annual'])}）")

    if fin:
        L.append('')
        L.append(f"【② 財務状況（入力済み {fin['months']}ヶ月ベース／年間予測は出さない）】")
        for key in KEY_ITEMS:
            row = fin['items'].get(key)
            if not row:
                continue
            s = f"  {key:<12} {yen(row['value']):>14}  (月平均 {man(row['per_month'])})"
            if row.get('prev_pace') is not None:
                d = row.get('diff_pct')
                s += f"  前年同ペース {man(row['prev_pace'])}"
                if d is not None:
                    s += f" / {d:+.0f}%"
            L.append(s)
        if fin.get('target_monthly'):
            L.append(f"  目標ペース（goals.html G0.1 標準 {man(fin['target'])}/年 → "
                     f"月 {man(fin['target_monthly'])}）に対し {fin['target_pace_pct']:.0f}%")
        if fin.get('unverified_cost'):
            L.append(f"  ↳ 要確認額 {man(fin['unverified_cost'])}"
                     '＝今期ゼロの費目を前年同期間と比べた差額。入力漏れならこのぶん利益が下がるが、'
                     '年次計上なら下がらない。どちらか確定するまで補正後の利益は出さない')
        L.append('  ※ 上の利益は費用の入力が済んだぶんだけの数字。①に⚠️があるうちは利益を信用しない。')

    bs = snap['balance']
    if bs:
        L.append('')
        L.append('【③ 資金の状態（BS・期首→期末）】')
        for key, label in (('cash', '現預金'), ('receivable', '売上債権（売掛金）')):
            o, c = bs['opening'].get(key), bs['closing'].get(key)
            if c is None:
                continue
            d = bs['delta'].get(key)
            arrow = f"{man(o)} → {man(c)}" if o is not None else man(c)
            s = f"  {label:<10} {arrow}"
            if d is not None:
                s += f"（{'+' if d >= 0 else '−'}{man(abs(d))}）"
            L.append(s)
        conc = bs.get('receivable_concentration')
        if conc:
            L.append(f"  売掛金の集中度: 上位1社 {conc['top1_pct']:.0f}% / "
                     f"上位3社 {conc['top3_pct']:.0f}%（{conc['clients']}社・"
                     f"取引先名は出さない＝README の方針）")
            gap = (conc['bs_total'] or 0) - conc['basis']
            L.append(f"       ↳ 分母＝取引先別のプラス残高 合計 {man(conc['basis'])}"
                     f"（BS売上債権 {man(conc['bs_total'])} との差 {man(gap)}"
                     '＝補助科目なし・マイナス残高・貸倒引当金）')
        if bs.get('equity_ratio') is not None:
            L.append(f"  自己資本比率 {bs['equity_ratio']:.0f}%"
                     '（※当期純利益を含む＝費用が未入力なら過大に出る）')

    if proj:
        L.append('')
        L.append(f"【④ 案件の動き（Google Sheets・{snap['projects_source']}"
                 f"{'' if snap['projects_fresh'] else '・⚠️最新でない'}）※会計とは基準が別】")
        L.append(f"  FY{fy} 受注 累計 {man(proj['fy_total'])}（"
                 + ' / '.join(f"{m['month'][5:]}月 {man(m['total'])}" for m in proj['months']) + '）')
        for label in ('請求待', '支払待', '要対応', '制作中'):
            s = proj['states'].get(label)
            if s:
                L.append(f"  {label}: {s['count']}件 {man(s['money'])}")
        q, th = proj['quality'], proj['thresholds']
        bits = []
        if q.get('billing_overdue'):
            bits.append(f"請求漏れ疑い {q['billing_overdue']}件（完了から{th.get('bill_overdue_days')}日超）")
        if q.get('payment_overdue'):
            bits.append(f"入金遅れ {q['payment_overdue']}件（請求から{th.get('pay_overdue_days')}日超）")
        if q.get('completed_no_bill'):
            bits.append(f"完了なのに請求日空 {q['completed_no_bill']}件")
        if bits:
            L.append('  ⚠️ ' + ' / '.join(bits) + '  ※全期間の累計値＝棚卸しが要る')

    if rec:
        L.append('')
        L.append('【⑤ ストック収益】')
        L.append(f"  月額合計 {yen(rec.get('monthly'))}"
                 f"（{rec.get('contracts', '—')}契約・年換算 {man((rec.get('monthly') or 0)*12)}）"
                 f" / 生成: {rec.get('updated', '—')}")
        if fin and fin.get('target'):
            ratio = (rec.get('monthly') or 0) * 12 / fin['target'] * 100
            L.append(f"  売上目標に対するストック比率 {ratio:.0f}%（G0.2 目標 20%以上・契約値ベース）")

    L.append('')
    L.append('出典: data/financial/<FY>/pl.csv（MFクラウド・社長が投入）／'
             'Google Sheets 案件管理／site/business/recurring-revenue.html／goals.html')
    return '\n'.join(L)


def main():
    ap = argparse.ArgumentParser(description='経理入力状況＋財務スナップショット（読み取り専用）')
    ap.add_argument('--json', action='store_true', help='JSON で出力')
    ap.add_argument('--no-fetch', action='store_true', help='Sheets を取りに行かない（キャッシュのみ）')
    ap.add_argument('--date', help='基準日 YYYY-MM-DD（既定＝今日）')
    args = ap.parse_args()

    today = date.fromisoformat(args.date) if args.date else date.today()
    acc, cur, prev = accounting_status(today)
    target = read_target_revenue()
    fin = financials(cur, prev, target, acc.get('missing_accounts'))
    bs = parse_bs(acc['fy'])
    acc['alerts'].extend(balance_alerts(bs))
    if bs and bs.get('unclassified'):
        acc['unclassified'].extend(bs['unclassified'])
    pdata, psource, pfresh = load_projects(args.no_fetch)
    proj = projects_summary(pdata, acc['fy'], today)
    rec = read_recurring()
    if not pfresh:
        acc['alerts'].append(
            f'案件シートの数字が最新ではない（{psource}）'
            '＝この数字を「今週取得した」として扱わないこと。次サイクルで取り直す')

    snap = {
        'date': today.isoformat(),
        'accounting': acc,
        'financials': fin,
        'balance': bs,
        'projects': proj,
        'projects_source': psource,
        'projects_fresh': pfresh,
        'recurring': rec,
    }

    if args.json:
        print(json.dumps(snap, ensure_ascii=False, indent=2))
    else:
        print(render(snap))


if __name__ == '__main__':
    main()
