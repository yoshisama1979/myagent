#!/usr/bin/env python3
"""Cycle 018 GSC light re-check (read-only).
Window 2026-06-22〜07-05. Verify the two zero-input actionable clusters are alive:
  - software cluster (T-005 target)
  - WordPress-troubles cluster (B-007 target)
Also: price cluster (monitoring wrap-up), LINE cluster (T-009 park), draft post-id publish detection.
"""
import json, re

d = json.load(open('data/blog-loop/cycles/ycom/gsc_q_c018.json'))
rows = d if isinstance(d, list) else d.get('rows', d.get('data', []))
# normalize
def g(r, *ks):
    for k in ks:
        if k in r: return r[k]
    return None
recs = []
for r in rows:
    q = g(r, 'query', 'keys', 'q')
    if isinstance(q, list): q = q[0]
    recs.append({
        'q': q,
        'imp': g(r, 'impressions', 'imp') or 0,
        'clk': g(r, 'clicks', 'clk') or 0,
        'ctr': g(r, 'ctr') or 0,
        'pos': g(r, 'position', 'pos') or 0,
    })
print(f"total rows: {len(recs)}")

def show(label, pats):
    print(f"\n=== {label} ===")
    rx = re.compile('|'.join(pats))
    hits = [r for r in recs if r['q'] and rx.search(r['q'])]
    hits.sort(key=lambda r: -r['imp'])
    for r in hits[:15]:
        print(f"  {r['imp']:>4} imp  {r['clk']:>3} clk  pos {r['pos']:>5.1f}  ctr {r['ctr']*100:>4.1f}%  {r['q']}")
    if not hits:
        print("  (none)")
    return hits

show("料金クラスター (price)", ['料金', '費用', '価格', '相場', '見積'])
show("作成ソフト系 (T-005 target)", ['ソフト', 'ツール', '作成 アプリ', 'wix', 'studio', 'ペライチ', 'jimdo'])
show("WordPress困りごと (B-007 target)", ['ワードプレス', 'wordpress', 'wp '])
show("LINE系 (T-009 park)", ['line', 'ライン'])
show("運用保守 (T-006 target)", ['運用', '保守', '運営', '代行'])
show("スマホ/レスポンシブ (T-007 target)", ['スマホ', 'レスポンシブ', 'モバイル'])

# publish detection: are any of our draft post-ids surfacing? (we only have query dim here; check top pages via separate call if needed)
print("\n=== top 15 by impressions (overall snapshot) ===")
for r in sorted(recs, key=lambda r: -r['imp'])[:15]:
    print(f"  {r['imp']:>4} imp  {r['clk']:>3} clk  pos {r['pos']:>5.1f}  ctr {r['ctr']*100:>4.1f}%  {r['q']}")
