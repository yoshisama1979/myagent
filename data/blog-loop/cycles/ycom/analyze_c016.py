import json
d = json.load(open('data/blog-loop/cycles/ycom/gsc_q_c016.json'))
qs = d['queries']
print("window", d['start'], "→", d['end'], "| total queries:", len(qs))

def show(label, keys):
    print(f"\n== {label} ==")
    hit = [q for q in qs if any(k in q['query'] for k in keys)]
    hit.sort(key=lambda x: -x['impressions'])
    for q in hit[:14]:
        print(f"  {q['impressions']:4d}imp  pos{q['avg_position']:5.1f}  ctr{q['ctr']*100:4.1f}%  clk{q['clicks']:3d}  {q['query']}")
    print(f"  -- subtotal imp: {sum(q['impressions'] for q in hit)} / clicks: {sum(q['clicks'] for q in hit)}")

show("料金/費用/相場/見積 (T-001 buyer)", ["料金", "費用", "相場", "見積", "価格", "いくら"])
show("作成ソフト/ツール (T-005)", ["作成ソフト", "ホームページ作成", "作成 ソフト", "ツール"])
show("LINE (T-009)", ["line", "LINE", "ライン"])
show("運用/保守 (T-006)", ["運用", "保守", "運営", "メンテ"])
show("レスポンシブ/スマホ (T-007)", ["レスポンシブ", "スマホ", "モバイル"])
show("選び方/制作会社 (T-002)", ["選び方", "制作会社", "会社 おすすめ", "依頼"])
show("wordpress困りごと (B-007)", ["ワードプレス", "wordpress", "固定ページ", "プラグイン"])
