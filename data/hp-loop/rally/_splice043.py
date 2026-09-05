#!/usr/bin/env python3
# Cycle 043 splice: index.html の Cycle 042 節を archive.html 先頭へ移し、Cycle 043 節を差し込む。
# 履歴は消さない（置き場を変えるだけ）。
import io, re, sys

IDX = 'site/hp-analysis/rally/index.html'
ARC = 'site/hp-analysis/rally/archive.html'
NEW = 'data/hp-loop/rally/_c043_section.html'
SNAP = 'data/hp-loop/rally/_c042_snapshot.html'

idx = io.open(IDX, encoding='utf-8').read()
new_section = io.open(NEW, encoding='utf-8').read()

start = idx.index('  <!-- ===== Cycle 042 ===== -->')
end = idx.index('  <hr class="my-8 border-gray-300">')
c042 = idx[start:end]

# 1) 退避スナップショット（生データ）
io.open(SNAP, 'w', encoding='utf-8').write(c042)

# 2) archive.html の先頭（本文開始直後）へ Cycle 042 を差し込む
arc = io.open(ARC, encoding='utf-8').read()
anchor = None
for cand in ('<!-- ARCHIVE-BODY-START -->', '<h1 ', '<body'):
    if cand in arc:
        anchor = cand
        break
# 挿入位置＝最初のセクション見出しの直前を探す
m = re.search(r'\n  <section', arc)
if not m:
    sys.exit('archive.html に <section> が見つかりません（手動確認が要ります）')
ins = m.start()
c042_arc = c042.replace('<!-- ===== Cycle 042 ===== -->',
                        '<!-- ===== Cycle 042（Cycle 043 のローテで index から移動・2026-09-05） ===== -->')
arc2 = arc[:ins] + '\n' + c042_arc.rstrip() + '\n' + arc[ins:]
io.open(ARC, 'w', encoding='utf-8').write(arc2)

# 3) index.html の Cycle 042 を Cycle 043 に置き換え
idx2 = idx[:start] + new_section + idx[end:]

# 4) ヘッダの最終更新
idx2 = idx2.replace('最終更新＝Cycle 042（2026-09-05）', '最終更新＝Cycle 043（2026-09-05）')

io.open(IDX, 'w', encoding='utf-8').write(idx2)

print('c042 moved: %d bytes' % len(c042.encode('utf-8')))
print('index: %d -> %d bytes' % (len(idx.encode('utf-8')), len(idx2.encode('utf-8'))))
print('archive: %d -> %d bytes' % (len(arc.encode('utf-8')), len(arc2.encode('utf-8'))))
