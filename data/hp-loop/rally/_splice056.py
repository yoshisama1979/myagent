#!/usr/bin/env python3
"""C056: index の旧ブロック（C055追補・C053判定・C053本体）を archive 先頭へ移す。"""
from pathlib import Path

base = Path(__file__).resolve().parents[3] / "site/hp-analysis/rally"
idx = (base / "index.html").read_text(encoding="utf-8").split("\n")
arc = (base / "archive.html").read_text(encoding="utf-8").split("\n")

# 1始まりの行番号で 30-60（C055追補＋C053判定）と 251-284（C053本体）
assert idx[29].startswith("  <!-- 🔑 Cycle 055"), idx[29]
assert idx[250].startswith("  <!-- ===== Cycle 053"), idx[250]
assert idx[283].strip() == "</section>", idx[283]
block = idx[29:60] + idx[250:284]

marker = "  <!-- ===== Cycle 055（反応・追補）／Cycle 053 の判定ブロック・本体の記録（Cycle 056 のローテで移動・2026-09-23） ===== -->"
assert arc[32].startswith("  <!-- ===== Cycle 054"), arc[32]
if marker in arc:
    raise SystemExit("already spliced")
arc = arc[:32] + [marker] + block + [""] + arc[32:]

# index から除去（後ろから）＋プレースホルダ
idx = idx[:250] + ["  <!-- C056_SECTION -->"] + idx[284:]
idx = idx[:29] + ["  <!-- C056_TOP -->"] + idx[60:]

(base / "archive.html").write_text("\n".join(arc), encoding="utf-8")
(base / "index.html").write_text("\n".join(idx), encoding="utf-8")
print("ok", len(block), "lines moved")
