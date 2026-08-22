#!/usr/bin/env python3
"""Cycle 027: index.html の Cycle 026 節を archive.html へ移し、Cycle 027 節を差し込む（1回限りの補助）。"""
import io, sys

IDX = 'site/hp-analysis/rally/index.html'
ARC = 'site/hp-analysis/rally/archive.html'
NEW = 'data/hp-loop/rally/_cycle027_section.html'

idx = io.open(IDX, encoding='utf-8').read()
arc = io.open(ARC, encoding='utf-8').read()
new = io.open(NEW, encoding='utf-8').read()

START = '  <!-- ===== Cycle 026 ===== -->\n'
END = '\n  <p class="text-xs text-gray-400 mb-2">過去サイクル'

i = idx.find(START)
j = idx.find(END, i)
if i < 0 or j < 0:
    sys.exit('markers not found in index.html')

block = idx[i:j]                      # Cycle 026 セクション（</section> まで）
idx_new = idx[:i] + new.rstrip('\n') + idx[j:]

# archive: Cycle 025 スナップショットの直前へ挿入（新しい順を維持）
anchor = '  <!-- ===== Cycle 025 スナップショット ===== -->'
k = arc.find(anchor)
if k < 0:
    sys.exit('anchor not found in archive.html')
snap = block.replace('<!-- ===== Cycle 026 ===== -->',
                     '<!-- ===== Cycle 026 スナップショット ===== -->', 1)
arc_new = arc[:k] + snap.rstrip('\n') + '\n\n' + arc[k:]

io.open(IDX, 'w', encoding='utf-8').write(idx_new)
io.open(ARC, 'w', encoding='utf-8').write(arc_new)
print('index.html %d -> %d bytes' % (len(idx.encode()), len(idx_new.encode())))
print('archive.html %d -> %d bytes' % (len(arc.encode()), len(arc_new.encode())))
