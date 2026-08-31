#!/usr/bin/env python3
"""Cycle 039: index.html の Cycle 038 節を archive.html 先頭へ移し、Cycle 039 節を差し込む。"""
import io, re, sys

IDX = 'site/hp-analysis/rally/index.html'
ARC = 'site/hp-analysis/rally/archive.html'
NEW = 'data/hp-loop/rally/_c039_section.html'

idx = io.open(IDX, encoding='utf-8').read()
arc = io.open(ARC, encoding='utf-8').read()
new = io.open(NEW, encoding='utf-8').read()

# --- 1) index から Cycle 038 節を切り出す ---
start = idx.index('  <!-- ===== Cycle 038 ===== -->')
end = idx.index('</section>', start) + len('</section>\n')
c038 = idx[start:end]

# --- 2) archive の先頭（Cycle 037 の直前）へ差し込む ---
anchor = '  <!-- ===== Cycle 037 スナップショット ===== -->'
if 'Cycle 038 スナップショット' in arc:
    sys.exit('archive に Cycle 038 が既にあります（二重挿入の防止）')
c038_arc = c038.replace('<!-- ===== Cycle 038 ===== -->',
                        '<!-- ===== Cycle 038 スナップショット ===== -->')
pos = arc.index(anchor)
arc = arc[:pos] + c038_arc + '\n' + arc[pos:]

# --- 3) index の Cycle 038 節を Cycle 039 節に置き換える ---
idx = idx[:start] + new + idx[end:]

io.open(ARC, 'w', encoding='utf-8').write(arc)
io.open(IDX, 'w', encoding='utf-8').write(idx)
print('OK: Cycle 038 -> archive / Cycle 039 -> index')
