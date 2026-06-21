#!/usr/bin/env python3
# hp-compete.py — 競合サイトとのオンページSEO横並び比較（読み取り専用）
#
# 使い方:
#   python3 bin/hp-compete.py <自社URL> <競合URL> [<競合URL> ...]
#   python3 bin/hp-compete.py <自社URL> <競合URL> ... --json
#   python3 bin/hp-compete.py --self <自社URL> --rivals <競合URL,競合URL,...>
#
# 何をするか:
#   既存の hp-audit.sh(T-001) を各URLに --json で回し、SEOに効く構造シグナルを横並び表にする。
#   さらに「競合にあって自社に無い／競合が勝っている」点を【ギャップ】として抽出する。
#   ＝社長のSEOワークフロー③「競合を超えるために何をするか」を決定論で支える（レイヤーA）。
#
# 注意（automation.md 準拠）:
#   実行時は読み取り専用。ネットワーク取得は hp-audit.sh(HTTP GET) に委譲し、本スクリプト自身は
#   外部送信・ファイル書き込み・破壊的操作をしない（標準出力に出すだけ）。順位/SERP は扱わない
#   （「誰が上か」は別データ源＝社長のSERP確認 or 有料API。本ツールは中身の対比に専念）。
import os, sys, json, subprocess, argparse

BIN_DIR = os.path.dirname(os.path.abspath(__file__))
HP_AUDIT = os.path.join(BIN_DIR, 'hp-audit.sh')

# meta description / title の推奨レンジ（hp-audit と揃える）
TITLE_MIN, TITLE_MAX = 10, 35
DESC_MIN, DESC_MAX = 50, 140


def audit(url):
    """hp-audit.sh <url> --json を呼んで dict を返す。失敗時は fetch_ok=False の dict。"""
    if not os.path.exists(HP_AUDIT):
        return {'url': url, 'fetch_ok': False, 'error': f'hp-audit.sh が見つからない: {HP_AUDIT}'}
    try:
        # hp-audit は監査不能時 exit 3 でも JSON を吐く。例外は捕捉して握りつぶさず記録する。
        p = subprocess.run([HP_AUDIT, url, '--json'], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return {'url': url, 'fetch_ok': False, 'error': '監査タイムアウト(60s)'}
    except Exception as e:  # noqa: BLE001
        return {'url': url, 'fetch_ok': False, 'error': f'監査実行エラー: {e}'}
    out = (p.stdout or '').strip()
    if not out:
        return {'url': url, 'fetch_ok': False, 'error': f'hp-audit 出力なし(exit={p.returncode}): {(p.stderr or "").strip()[:200]}'}
    try:
        d = json.loads(out)
    except json.JSONDecodeError:
        return {'url': url, 'fetch_ok': False, 'error': f'hp-audit JSON 解析失敗(exit={p.returncode})'}
    return d


def in_range(n, lo, hi):
    return isinstance(n, int) and lo <= n <= hi


def jsonld_types(d):
    types = []
    for l in d.get('jsonld', []) or []:
        for t in l.get('types', []) or []:
            types.append(t if isinstance(t, str) else str(t))
    return types


def metrics(d):
    """比較に使う指標を1サイト分まとめる（fetch_ok 前提）。"""
    h = d.get('headings', {}) or {}
    cv = d.get('cv', {}) or {}
    links = d.get('links', {}) or {}
    lds = jsonld_types(d)
    valid_ld = [l for l in (d.get('jsonld') or []) if l.get('parse_ok') and not l.get('looks_disabled')]
    return {
        'http': d.get('http_code', ''),
        'cms': d.get('cms', ''),
        'size_kb': round(int(d.get('size_bytes') or 0) / 1024) if str(d.get('size_bytes') or '').isdigit() else 0,
        'title_len': d.get('title_len', 0),
        'desc_len': d.get('description_len', 0),
        'canonical': bool(d.get('canonical')),
        'ogp': len(d.get('ogp', {}) or {}),
        'twitter': len(d.get('twitter', {}) or {}),
        'jsonld': len(valid_ld),
        'jsonld_types': sorted(set(lds)),
        'h1': h.get('h1', 0), 'h2': h.get('h2', 0), 'h3': h.get('h3', 0),
        'sections': (h.get('h2', 0) or 0) + (h.get('h3', 0) or 0),  # コンテンツの厚みの近似
        'links': links.get('total', 0),
        'img_no_alt': (d.get('images', {}) or {}).get('no_alt', 0),
        'tel': len(cv.get('tel_numbers', []) or []),
        'line': bool(cv.get('line_present')),
        'forms': cv.get('form_count', 0),
        'cv_anchors': len(cv.get('cv_anchors', []) or []),
        'issues': len(d.get('issues', []) or []),
    }


def gaps(self_m, rival_m):
    """競合が自社より勝っている点を抽出（＝自社の伸びしろ）。"""
    g = []
    # 構造化データ（リッチリザルト＝SEO/CTRに効く）
    if rival_m['jsonld'] > 0 and self_m['jsonld'] == 0:
        g.append(f"構造化データ(JSON-LD)あり {rival_m['jsonld_types'] or ''}／自社は無し")
    elif rival_m['jsonld_types'] and set(rival_m['jsonld_types']) - set(self_m['jsonld_types']):
        diff = sorted(set(rival_m['jsonld_types']) - set(self_m['jsonld_types']))
        g.append(f"自社に無い構造化データ型: {diff}")
    # title/description が推奨レンジ内（検索結果での見え方）
    if in_range(rival_m['title_len'], TITLE_MIN, TITLE_MAX) and not in_range(self_m['title_len'], TITLE_MIN, TITLE_MAX):
        g.append(f"title が適正長({rival_m['title_len']}字)／自社は範囲外({self_m['title_len']}字)")
    if in_range(rival_m['desc_len'], DESC_MIN, DESC_MAX) and not in_range(self_m['desc_len'], DESC_MIN, DESC_MAX):
        g.append(f"meta description が適正長({rival_m['desc_len']}字)／自社は範囲外({self_m['desc_len']}字)")
    # OGP / Twitter（SNSでの拡散・見え方）
    if rival_m['ogp'] > 0 and self_m['ogp'] == 0:
        g.append("OGP あり／自社は無し")
    if rival_m['canonical'] and not self_m['canonical']:
        g.append("canonical あり／自社は無し")
    # コンテンツの厚み（見出しセクション数）— 1.5倍以上を有意差とする
    if rival_m['sections'] >= max(8, int(self_m['sections'] * 1.5) + 1):
        g.append(f"コンテンツが厚い(h2+h3={rival_m['sections']}／自社{self_m['sections']})")
    # CV導線の多さ（LINE・フォーム・申込導線）
    if rival_m['line'] and not self_m['line']:
        g.append("LINE導線あり／自社は無し")
    if rival_m['forms'] > self_m['forms']:
        g.append(f"フォーム数 {rival_m['forms']}／自社 {self_m['forms']}")
    if rival_m['cv_anchors'] >= max(3, self_m['cv_anchors'] + 3):
        g.append(f"CV導線アンカーが多い({rival_m['cv_anchors']}／自社{self_m['cv_anchors']})")
    return g


def label(url, i):
    return '自社' if i == 0 else f'競合{i}'


def main():
    ap = argparse.ArgumentParser(description='競合サイトとのオンページSEO横並び比較（読み取り専用）')
    ap.add_argument('urls', nargs='*', help='<自社URL> <競合URL> [<競合URL> ...]')
    ap.add_argument('--self', dest='self_url', help='自社URL（位置引数の代わり）')
    ap.add_argument('--rivals', help='競合URLをカンマ区切りで（--self と併用）')
    ap.add_argument('--json', action='store_true', help='機械可読JSONで出力')
    a = ap.parse_args()

    urls = []
    if a.self_url:
        urls.append(a.self_url)
        if a.rivals:
            urls += [u.strip() for u in a.rivals.split(',') if u.strip()]
        urls += a.urls
    else:
        urls = a.urls
    if len(urls) < 2:
        ap.error('自社URLと競合URLを最低1つずつ指定してください（例: hp-compete.py https://自社/ https://競合/）')

    audited = [audit(u) for u in urls]
    rows = []
    for i, (u, d) in enumerate(zip(urls, audited)):
        ok = d.get('fetch_ok')
        rows.append({'i': i, 'label': label(u, i), 'url': u, 'fetch_ok': ok,
                     'error': d.get('error') if not ok else None,
                     'm': metrics(d) if ok else None})

    self_row = rows[0]
    gap_report = []
    if self_row['fetch_ok']:
        for r in rows[1:]:
            if r['fetch_ok']:
                gap_report.append({'rival': r['label'], 'url': r['url'],
                                   'gaps': gaps(self_row['m'], r['m'])})

    # 取得不能の総合判定（捏造しない＝失敗を成功と偽らない）：
    # 自社の取得失敗、または比較可能サイトが2つ未満なら exit 3。
    live = [r for r in rows if r['fetch_ok']]
    failed = (not self_row['fetch_ok']) or len(live) < 2

    if a.json:
        print(json.dumps({'ok': not failed, 'rows': rows, 'gaps': gap_report},
                         ensure_ascii=False, indent=1))
        sys.exit(3 if failed else 0)

    # ---- 人が読む横並び表 ----
    print("■ hp-compete: オンページSEO 競合比較（読み取り専用・順位/SERPは含まない）")
    for r in rows:
        tag = '★' if r['i'] == 0 else ' '
        if r['fetch_ok']:
            print(f"  {tag}{r['label']}: {r['url']}")
        else:
            print(f"  {tag}{r['label']}: {r['url']}  ⛔ {r['error']}")
    print("")

    if not self_row['fetch_ok']:
        print("  ⛔ 自社サイトの取得に失敗（比較の基準が無い）。URL・到達性を確認してください。")
        sys.exit(3)
    if len(live) < 2:
        print("  ⛔ 比較可能なサイトが2つ未満（取得失敗）。URL・到達性を確認してください。")
        sys.exit(3)

    # 指標行（自社=★列、以降が競合）
    fields = [
        ('title長', 'title_len'), ('desc長', 'desc_len'), ('canonical', 'canonical'),
        ('OGP数', 'ogp'), ('構造化LD', 'jsonld'), ('h1', 'h1'), ('h2+h3', 'sections'),
        ('リンク数', 'links'), ('alt欠落', 'img_no_alt'),
        ('電話', 'tel'), ('LINE', 'line'), ('フォーム', 'forms'), ('CV導線', 'cv_anchors'),
        ('課題数', 'issues'), ('容量KB', 'size_kb'),
    ]
    hdr = f"  {'指標':<10}" + ''.join(f"{r['label']:>10}" for r in live)
    print(hdr)
    print("  " + "-" * (10 + 10 * len(live)))
    for name, key in fields:
        cells = []
        for r in live:
            v = r['m'][key]
            v = ('あり' if v else 'なし') if isinstance(v, bool) else str(v)
            cells.append(f"{v:>10}")
        print(f"  {name:<10}" + ''.join(cells))
    # 構造化データ型は別途列挙（横幅の都合）
    print("")
    for r in live:
        if r['m']['jsonld_types']:
            print(f"  {r['label']} 構造化型: {r['m']['jsonld_types']}")

    # ---- ギャップ（競合が勝っている点＝自社の伸びしろ） ----
    print("\n  === ギャップ（競合にあって自社に無い／競合が勝る点＝施策候補） ===")
    if not self_row['fetch_ok']:
        print("  ⛔ 自社サイトの取得に失敗したためギャップ抽出不可")
    else:
        any_gap = False
        for gr in gap_report:
            if gr['gaps']:
                any_gap = True
                print(f"  ▼ {gr['rival']}（{gr['url']}）に対して:")
                for g in gr['gaps']:
                    print(f"      - {g}")
        if not any_gap:
            print("  ✅ 構造シグナル上、競合が明確に勝っている点は検出されず（中身/コピー/被リンクは別途・hp-shot/手動で）")
    print("\n  ※ これは構造シグナルの対比。実コンテンツの質・E-E-A-T・被リンク・"
          "検索順位は本ツール対象外（hp-shotの目視＋社長のSERP確認で補う）。")


if __name__ == '__main__':
    main()
