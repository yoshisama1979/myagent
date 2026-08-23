#!/usr/bin/env python3
"""Cycle 028: index.html の Cycle 027 セクションを archive.html 先頭へ移し、Cycle 028 を差し込む。"""
import re, sys, pathlib

BASE = pathlib.Path(__file__).resolve().parents[3]
idx = BASE / "site/hp-analysis/rally/index.html"
arc = BASE / "site/hp-analysis/rally/archive.html"
new_sec = (BASE / "data/hp-loop/rally/_cycle028_section.html").read_text(encoding="utf-8")

html = idx.read_text(encoding="utf-8")

START = "  <!-- ===== Cycle 027 ===== -->"
END = "  </section>\n"
s = html.index(START)
e = html.index(END, s) + len(END)
old_sec = html[s:e]

# 1) index: Cycle 027 -> Cycle 028 に置き換え
html = html[:s] + new_sec + html[e:]

# 2) 過去サイクル行に 027 を追加
html = html.replace(
    "・026 競合実測でR-R25の目標値を確定）は",
    "・026 競合実測でR-R25の目標値を確定・027 配信HTMLにリンクと本文が無いことの実測）は",
)
idx.write_text(html, encoding="utf-8")

# 3) archive: 先頭のサイクル記録の直前に Cycle 027 のスナップショットを差し込む
a = arc.read_text(encoding="utf-8")
anchor = "  <!-- ===== Cycle 026 スナップショット ===== -->"
if anchor not in a:
    sys.exit(f"archive.html に挿入位置 {anchor!r} が見つかりません")
NOTE = (
    "  <!-- ===== Cycle 027 スナップショット ===== -->\n"
    "  <p class=\"text-xs text-amber-700 mb-1\">※ このスナップショットは 2026-08-23 時点の記録です。"
    "<strong>翌 2026-08-24（Cycle 028）の実測で、下記のうち「スポット14,477件は検索エンジンから見ると存在しない」は誤りと判明し訂正されています</strong>"
    "（個別ページは検索エンジンに登録済み＝問題は「名札が無いこと」）。最新の見解は"
    "<a href=\"index.html\" class=\"text-blue-600 hover:underline\">最新レポート</a>を参照。</p>"
)
snap = old_sec.replace("  <!-- ===== Cycle 027 ===== -->", NOTE, 1)
a = a.replace(anchor, snap + "\n" + anchor, 1)
arc.write_text(a, encoding="utf-8")

print(f"index={idx.stat().st_size}B archive={arc.stat().st_size}B moved={len(old_sec)}B")
