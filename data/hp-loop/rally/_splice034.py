#!/usr/bin/env python3
"""index.html の Cycle 033 セクション（<!-- ===== Cycle 033 ===== --> 〜 直後の </section>）を
Cycle 034 セクションで置き換える。読み取り＋自ファイルの書き換えのみ（外部送信・本番改変なし）。"""
from pathlib import Path

idx = Path("site/hp-analysis/rally/index.html")
new = Path("data/hp-loop/rally/_c034_section.html").read_text(encoding="utf-8")
lines = idx.read_text(encoding="utf-8").splitlines(keepends=True)

start = next(i for i, l in enumerate(lines) if "===== Cycle 033 =====" in l)
end = next(i for i in range(start, len(lines)) if lines[i].rstrip() == "  </section>")

out = lines[:start] + [new] + lines[end + 1:]
idx.write_text("".join(out), encoding="utf-8")
print(f"replaced lines {start+1}-{end+1} ({end-start+1} lines) with Cycle 034 section")
