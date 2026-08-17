#!/usr/bin/env python3
# Cycle 014 ローカル再分析（読み取り専用・c010保存データの新しい切り口）
# 1) 買い手・制作隣接クエリの未カバー洗い出し 2) 高表示×低CTRページ（title/スニペット改善候補）
import json, os
base = os.path.dirname(os.path.abspath(__file__))
q = json.load(open(os.path.join(base, 'gsc_q_c010.json')))
p = json.load(open(os.path.join(base, 'gsc_pages_c010.json')))
print("=== queries total:", len(q['queries']), "/ pages total:", len(p['pages']))
buyer_kw = ['制作','費用','料金','依頼','会社','見積','相場','ホームページ','web制作','リニューアル',
            '保守','運用','wordpress','ワードプレス','ロゴ','ソフト','作成','スマホ','レスポンシブ',
            'パートナー','外注','大阪','神戸','京都','seo','集客']
hits = [x for x in q['queries'] if any(k in x['query'].lower() for k in buyer_kw)]
print("\n=== 買い手・制作隣接クエリ（impressions降順・上位60）===", len(hits), "件")
for x in sorted(hits, key=lambda v: -v['impressions'])[:60]:
    print(f"{x['impressions']:6d}imp {x['clicks']:4d}c pos{x['avg_position']:5.1f} ctr{x['ctr']*100:5.1f}% | {x['query']}")
print("\n=== 高表示(300imp+)×低CTR(<3%)×1ページ目(pos<=10) ページ＝スニペット改善候補 ===")
for x in sorted(p['pages'], key=lambda v: -v['impressions']):
    if x['impressions'] >= 300 and x['ctr'] < 0.03 and x['avg_position'] <= 10:
        print(f"{x['impressions']:6d}imp {x['clicks']:4d}c pos{x['avg_position']:5.1f} ctr{x['ctr']*100:5.1f}% | {x['url']}")
