import json
d = json.load(open('data/blog-loop/cycles/ycom/gsc_q_c010.json'))
qs = d['queries']
print("total queries:", len(qs))
rows = []
for q in qs:
    if q['impressions'] >= 8:
        rows.append((q['query'], q['impressions'], round(q['avg_position'], 1),
                     round(q['ctr'] * 100, 1), q['clicks']))

def commercial(t):
    kws = ['制作', '作成', 'リニューアル', '依頼', '会社', '業者', '外注', '補助金', '助成金',
           '集客', '採用', 'ロゴ', '名刺', 'ec', 'ネットショップ', 'lp', 'ランディング',
           '格安', '安い', 'おすすめ', '相場', '大阪', '京都', '神戸', '兵庫', 'デザイン', 'スマホ', 'sslの']
    return any(k in t for k in kws)

com = [r for r in rows if commercial(r[0])]
com.sort(key=lambda x: -x[1])
print("\n=== commercial-ish queries (imp>=8), top 70 ===")
for r in com[:70]:
    print(f"{r[1]:>4}imp {r[2]:>5}pos CTR{r[3]:>4}% clk{r[4]:>2}  {r[0]}")
