#!/usr/bin/env python3
"""C037 スプライス（読み取り＋自リポジトリ内書き込みのみ・外部送信なし）

やること:
  1) index.html から「Cycle 036 スナップショット」ブロックを切り出す
  2) archive.html の「Cycle 035 スナップショット」の直前へ挿入する
  3) index.html からは当該ブロックを削除し、後で Cycle 037 を差し込む目印を残す
"""
import io, sys, pathlib

base = pathlib.Path(__file__).resolve().parents[3]
idx = base / "site/hp-analysis/rally/index.html"
arc = base / "site/hp-analysis/rally/archive.html"

idx_s = idx.read_text(encoding="utf-8")
arc_s = arc.read_text(encoding="utf-8")

START = "  <!-- ===== Cycle 036 ===== -->\n"
END = '  <p class="text-xs text-gray-400 mb-2">過去サイクル'

i = idx_s.index(START)
j = idx_s.index(END)
block = idx_s[i:j]

# 1) index から除去し、Cycle 037 の差し込み目印を置く
idx_new = idx_s[:i] + "  <!-- ===== CYCLE037_HERE ===== -->\n\n" + idx_s[j:]
idx.write_text(idx_new, encoding="utf-8")

# 2) archive の Cycle 035 スナップショットの直前へ挿入（見出しをスナップショット表記に）
block = block.replace("  <!-- ===== Cycle 036 ===== -->\n",
                      "  <!-- ===== Cycle 036 スナップショット ===== -->\n", 1)
A = "  <!-- ===== Cycle 035 スナップショット ===== -->"
k = arc_s.index(A)
arc_new = arc_s[:k] + block + arc_s[k:]
arc.write_text(arc_new, encoding="utf-8")

print("moved bytes:", len(block))
print("index:", len(idx_new), "archive:", len(arc_new))
