#!/usr/bin/env python3
# Cycle 015 (2026-07-04) 読み取り専用ローカル分析
# 入力: gsc_q_c015.json / gsc_pages_c015.json（窓 2026-06-15〜07-01）
# 過去窓 gsc_q_c010.json（6/01〜6/29）と対比して「動き」を見る。
import json, os
D=os.path.dirname(__file__)
def load(f):
    return json.load(open(os.path.join(D,f)))
def rows(o):
    return o.get('queries',o.get('rows',o.get('pages',[])))
q15=rows(load('gsc_q_c015.json'))
q10=rows(load('gsc_q_c010.json'))
p15=rows(load('gsc_pages_c015.json'))

def qkey(r): return r.get('query','')
def imp(r): return r.get('impressions',0)
def pos(r): return r.get('avg_position',0)
def ctr(r): return round(r.get('ctr',0)*100,2)
def clk(r): return r.get('clicks',0)

print("=== window c015:",len(q15),"queries / c010:",len(q10),"queries ===")

buyer=['料金','費用','価格','相場','見積','依頼','制作会社','作成ソフト','おすすめ','比較','選び方','リニューアル','保守','運用','スマホ','レスポンシブ','line','ライン','外注','パートナー','ホームページ制作','ホームページ作成']
print("\n--- buyer-intent queries impr>=8 (query, impr, ctr%, pos, clicks) ---")
sb=sorted([r for r in q15 if any(b in qkey(r) for b in buyer) and imp(r)>=8], key=lambda r:-imp(r))
for r in sb:
    print(f"{qkey(r)[:48]:48} impr={imp(r):5} ctr={ctr(r):5} pos={pos(r):5.1f} clk={clk(r)}")

# movement: compare position for queries present in both windows
m10={qkey(r):r for r in q10}
print("\n--- position movement (both windows, buyer-intent, |Δpos|>=3) ---")
for r in q15:
    k=qkey(r)
    if k in m10 and any(b in k for b in buyer):
        d=pos(m10[k])-pos(r)  # positive=improved (rank number went down)
        if abs(d)>=3:
            print(f"{k[:44]:44} pos {pos(m10[k]):5.1f}->{pos(r):5.1f} (d={d:+.1f}) impr {imp(m10[k])}->{imp(r)}")

# new buyer queries appearing in c015 not in c010
print("\n--- NEW buyer-intent queries in c015 not in c010 (impr>=5) ---")
for r in sorted([r for r in q15 if any(b in qkey(r) for b in buyer) and imp(r)>=5 and qkey(r) not in m10], key=lambda r:-imp(r)):
    print(f"{qkey(r)[:48]:48} impr={imp(r):5} ctr={ctr(r):5} pos={pos(r):5.1f} clk={clk(r)}")

# almost-there (pos 8-20, impr>=15, ctr low)
print("\n--- almost-there buyer queries pos 8-20 impr>=15 ctr<3% ---")
for r in sorted([r for r in q15 if any(b in qkey(r) for b in buyer) and 8<=pos(r)<=20 and imp(r)>=15 and ctr(r)<3], key=lambda r:-imp(r)):
    print(f"{qkey(r)[:48]:48} impr={imp(r):5} ctr={ctr(r):5} pos={pos(r):5.1f} clk={clk(r)}")
