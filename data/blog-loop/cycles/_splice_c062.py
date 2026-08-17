#!/usr/bin/env python3
"""Cycle 062 の記録を index.html から archive.html へ移す（1回限りの補助・読み書きはこの2ファイルのみ）。

- index.html の「最新サイクル」ブロック（<!-- 最新サイクル --> の見出しから </div>閉じまで）を切り出し
- archive.html の「過去サイクルのスナップショット」見出し直後へ <details id="c062"> として挿入
- index.html 側は placeholder（<!--CYCLE-SLOT-->）に置換して、後段で Cycle 063 を書き込む
"""
import io
import sys

IDX = "site/hp-analysis/ycom/blog/index.html"
ARC = "site/hp-analysis/ycom/blog/archive.html"

idx = io.open(IDX, encoding="utf-8").read().split("\n")

# 1-indexed 行番号（Read で確認済み）: 172 = 区切りコメント / 288 = フッタ p 直前の行
start = 171          # 0-indexed: line 172
end = 287            # 0-indexed: line 288 (exclusive の直前まで＝286 まで本文)
# 実際の切り出し範囲は「<!-- ====== -->（172）」〜「対応記録 div の閉じ（286）」
block = idx[start:end - 1]
rest_head = idx[:start]
rest_tail = idx[end - 1:]

body = "\n".join(block)
if "Cycle 062" not in body:
    sys.exit("ERR: Cycle 062 が切り出し範囲に見つからない（行番号ずれ）")
if "Cycle 062" in "\n".join(rest_head) or "Cycle 062" in "\n".join(rest_tail):
    sys.exit("ERR: 切り出し外に Cycle 062 が残っている（行番号ずれ）")

summary = (
    '📸 Cycle 062 — 2026-08-11（<span class="text-emerald-700">リライトした記事が本番では「2017年の記事」に見えていた</span>'
    '＝<span class="font-mono">p=2117</span> は 2026-07-15 に全面反映済みなのに署名は「2017年9月13日 代表」・更新日表示なし・'
    '記事の構造化データ（BlogPosting）ゼロ＝テンプレ由来（<span class="font-mono">B-034</span> 起票）／'
    '指名検索28日＝「株式会社はなさか」22表示・「ワイコム」2表示＝①→②の橋がゼロを実測／'
    '新規 <span class="font-mono">T-024</span>（問い合わせが来ない…の切り分け＝1ページ目10枠中9枠が制作会社のコラム）｜記録スナップショット'
)

entry = (
    '  <details class="bg-white border-2 border-gray-300 rounded-lg p-5 mb-4 text-sm text-gray-700" id="c062">\n'
    '    <summary class="font-bold text-gray-800 cursor-pointer">' + summary + "</summary>\n\n"
    '    <div class="mt-3 space-y-3">\n'
    + body + "\n"
    "    </div>\n"
    "  </details>\n"
)

arc = io.open(ARC, encoding="utf-8").read()
anchor = '<h2 class="text-2xl font-bold border-b-2 border-gray-300 pb-2 mb-4">過去サイクルのスナップショット</h2>\n'
if anchor not in arc:
    sys.exit("ERR: archive のアンカー見出しが見つからない")
arc = arc.replace(anchor, anchor + "\n" + entry, 1)
io.open(ARC, "w", encoding="utf-8").write(arc)

new_idx = rest_head + ["<!--CYCLE-SLOT-->"] + rest_tail
io.open(IDX, "w", encoding="utf-8").write("\n".join(new_idx))
print("OK: C062 を archive へ移設、index に <!--CYCLE-SLOT--> を残した")
