#!/usr/bin/env python3
"""経営パートナー台帳の「索引ビュー」を生成する（読み取り専用・都度生成）。

契機＝2026-08-05 社長ご質問「そのリスト（溜まっている案件）はどこかで見れますか？」。
台帳 data/partner/ledger.md は AI が読む形（1行に経緯・決め事・結線を詰めた Markdown 表）で、
人間がブラウザで見渡す形になっていない。そこで**台帳を正のまま**、読み取り専用のビューを起こす。

設計の約束（[[project_progress-ledger-hana-tools]] の規律に合わせる）：
  ・台帳（data/partner/ledger.md）が source of truth。**このビューは状態を持たない**。
  ・進行表を site/ に二重に持たない＝**毎回作り直す**（差分でなく再生成）。
  ・「推定ボール」は状態欄の文言からの機械の当て推量＝**原文を必ず併記して隠さない**。

使い方：
    python3 bin/partner-index.py              # site/business/partner/backlog.html を生成
    python3 bin/partner-index.py --stdout     # 集計だけ標準出力（生成しない）
"""
from __future__ import annotations

import html
import re
import sys
from datetime import date, datetime
from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent
LEDGER = PROJ / "data" / "partner" / "ledger.md"
OUT = PROJ / "site" / "business" / "partner" / "backlog.html"

# 状態欄の文言 → ボール。**上から順に当てる**（先に書いたものが勝つ）。
# 「待ち」は社長・先方・開発のどれにも出るので、先に外部/開発/保留を確定させてから社長を当てる。
BALLS = [
    ("✅", "done",  "✅ 完了", "gray",
     ("✅",)),
    ("⏸", "hold",  "⏸ 保留・休止", "gray",
     ("⏸", "🔵", "据え置き", "督促停止", "寝かせる", "保留")),
    ("⏳", "out",   "⏳ 先方ボール（こちらから押さない）", "blue",
     ("先方ボール", "先方の", "押さない", "⏳", "日取り共有待ち", "候補日")),
    ("🔧", "dev",   "🔧 開発・ツール側の実装待ち", "purple",
     ("実装待ち", "開発の領域", "api実装", "実装は開発", "動きが見えたら")),
    ("🙋", "pres",  "🙋 社長のご判断・ご返信待ち", "red",
     ("◎○×", "◎×", "◎待ち", "一言待ち", "回答", "返信待ち", "ご判断", "ご回答", "未回収",
      "ご自身", "結果待ち", "3問", "2問", "確認4点", "outcome check", "の2行")),
    ("🤖", "mine",  "🤖 私（AI・有人セッション）が動く", "green",
     ("設置済み", "実装済み", "作成済み", "私が", "有人", "受領")),
]
FALLBACK = ("🔄", "run", "🔄 進行中・待機列（いま誰も待っていない）", "yellow")

# §3＝社長が「やる」と言ったこと／社長からのご依頼。§4＝AI が勝手に並べた優先度キュー。
# この2つを混ぜて数えると「社長が抱えている件数」が実際より多く見える＝分けて数える。
SECTIONS = [
    ("§3", "§3 約束・アクション追跡", "社長が「やる」と宣言されたこと／社長からのご依頼。<strong>ここが社長の持ち物です。</strong>"),
    ("§4", "§4 優先度キュー", "<strong>私（AI）が全体最適で勝手に並べた提案の列です。</strong>社長の宿題ではありません。"),
]

BADGE = {"red": "bg-red-100 text-red-800", "blue": "bg-blue-100 text-blue-800",
         "purple": "bg-purple-100 text-purple-800", "green": "bg-green-100 text-green-800",
         "yellow": "bg-yellow-100 text-yellow-800", "gray": "bg-gray-200 text-gray-700"}


def strip_md(t: str) -> str:
    """Markdown の飾りを落として素の文にする（リンクは本文だけ残す）。"""
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t)
    t = re.sub(r"</?u>|</?span[^>]*>|\*\*|`", "", t)
    return re.sub(r"\s+", " ", t).strip()


def md_links(t: str) -> str:
    """台帳の相対リンク（data/partner/ 起点）をビュー（site/business/partner/）起点へ張り替える。"""
    def one(m):
        label, href = m.group(1), m.group(2)
        if href.startswith("../../site/"):        # data/partner → site/... を site/business/partner 起点へ
            href = "../../" + href[len("../../site/"):]
        elif href.endswith(".md") or href.startswith("data/"):
            return html.escape(label)             # AI用のファイルはブラウザから開けない＝リンクにしない
        return f'<a href="{html.escape(href)}" class="text-blue-600 hover:underline">{html.escape(label)}</a>'
    parts, last = [], 0
    for m in re.finditer(r"\[([^\]]*)\]\(([^)]*)\)", t):
        parts.append(html.escape(t[last:m.start()])); parts.append(one(m)); last = m.end()
    parts.append(html.escape(t[last:]))
    out = "".join(parts)
    return re.sub(r"</?u>|\*\*|`", "", out)


def classify(state: str) -> tuple[str, str, str, str]:
    s = state.lower()
    for icon, key, label, color, words in BALLS:
        if any(w.lower() in s for w in words):
            return icon, key, label, color
    return FALLBACK


def parse_rows(lines: list[str], start: int, end: int, prefix: str) -> list[dict]:
    """§3／§4 の表から ID 行を拾う。列数が違う表（§4）にも耐えるよう位置でなく先頭IDで判定。"""
    out = []
    for ln in lines[start:end]:
        m = re.match(r"^\|\s*\*{0,2}(" + prefix + r"-\d{3})\*{0,2}\s*\|", ln)
        if not m:
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        out.append({"id": m.group(1), "cells": cells, "bytes": len(ln.encode("utf-8"))})
    return out


def section_bounds(lines: list[str], head: str) -> tuple[int, int]:
    start = next((i for i, l in enumerate(lines) if l.startswith(head)), -1)
    if start < 0:
        return 0, 0
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return start, end


def days_since(s: str) -> int | None:
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", s)
    if not m:
        return None
    return (date.today() - date(*map(int, m.groups()))).days


def build() -> tuple[list[dict], list[dict]]:
    lines = LEDGER.read_text(encoding="utf-8").split("\n")

    a0, a1 = section_bounds(lines, "## §3")
    p0, p1 = section_bounds(lines, "## §4")

    items = []
    for r in parse_rows(lines, a0, a1, "A"):
        c = r["cells"]
        state = c[3] if len(c) > 3 else ""
        icon, key, label, color = classify(state)
        items.append({**r, "sec": "§3", "date": strip_md(c[1]) if len(c) > 1 else "",
                      "title": strip_md(c[2]) if len(c) > 2 else "",
                      "state": state, "next": c[4] if len(c) > 4 else "",
                      "icon": icon, "key": key, "label": label, "color": color})
    for r in parse_rows(lines, p0, p1, "P"):
        c = r["cells"]
        # §4 ＝ | 番号 | 観点 | 内容 | なぜ今 | 効果 | 工数 | 優先度 | 状態 |
        state = c[7] if len(c) > 7 else ""
        icon, key, label, color = classify(state)
        items.append({**r, "sec": "§4", "date": "", "title": strip_md(c[2]) if len(c) > 2 else "",
                      "state": state, "next": c[3] if len(c) > 3 else "",
                      "prio": strip_md(c[6]) if len(c) > 6 else "",
                      "icon": icon, "key": key, "label": label, "color": color})

    for it in items:
        it["days"] = days_since(it["date"]) if it["date"] else None
    return items, [b for b in BALLS]


def render(items: list[dict]) -> str:
    order = ["pres", "run", "mine", "dev", "out", "hold", "done"]
    labels = {b[1]: (b[2], b[3]) for b in BALLS}
    labels["run"] = (FALLBACK[2], FALLBACK[3])

    total = len(items)
    a_items = [i for i in items if i["sec"] == "§3"]
    a_pres = sum(1 for i in a_items if i["key"] == "pres")
    now = datetime.now()
    gen = now.strftime("%Y-%m-%d %H:%M")
    gen_iso = now.strftime("%Y-%m-%dT%H:%M:%S")

    h = [f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>いま抱えている案件の一覧（台帳の索引）｜経営パートナー</title>
<script src="https://cdn.tailwindcss.com"></script>
</head><body class="bg-gray-50 text-gray-900">
<div class="max-w-5xl mx-auto p-6 md:p-10">
  <nav class="text-sm text-gray-500 mb-4">
    <a href="../../index.html" class="text-blue-600 hover:underline">トップ</a><span class="mx-1">/</span>
    <a href="index.html" class="text-blue-600 hover:underline">経営パートナー 朝礼</a><span class="mx-1">/</span>
    <span>案件の一覧（索引）</span></nav>
  <!-- 古いまま置かれるのが最悪＝リンクした以上、鮮度は画面が自分で申告する（黙って古びない） -->
  <div id="stale" class="hidden bg-red-100 border-l-4 border-red-500 text-red-900 p-4 mb-6 rounded"></div>
  <script>
  (function(){{
    var gen = new Date("{gen_iso}");
    var h = (Date.now() - gen.getTime()) / 3600000;
    if (h > 24) {{
      var el = document.getElementById("stale");
      el.className = el.className.replace("hidden","");
      el.innerHTML = "<strong>⚠️ この一覧は " + Math.floor(h/24) + " 日前に作られたものです。</strong>"
        + "台帳はその後も動いているので、内容が古い可能性があります。"
        + "<span class='block text-sm mt-1'>再生成＝<span class='font-mono'>python3 bin/partner-index.py</span></span>";
    }}
  }})();
  </script>
  <h1 class="text-2xl font-bold mb-1">📇 いま抱えている案件の一覧</h1>
  <p class="text-sm text-gray-500 mb-6">生成 {gen}／出典＝<span class="font-mono">data/partner/ledger.md</span>（台帳が正・このページは<strong>読み取り専用のビュー</strong>で毎回作り直します）<br>
  <strong>全 {total} 件</strong>（§3 {len(a_items)} 件 ＋ §4 {total - len(a_items)} 件）</p>

  <div class="bg-white border-l-4 border-red-500 p-4 mb-6 rounded shadow-sm">
    <p class="font-bold mb-1">🙋 このうち「いま社長のご判断を待っている」のは <span class="text-2xl text-red-700">{a_pres}</span> 件です（§3 のみ）。</p>
    <p class="text-sm text-gray-700">残りは<strong>先方ボール・開発待ち・保留、そして私（AI）の提案キュー</strong>です。
    <strong>§4 の {total - len(a_items)} 件は私が勝手に並べた列で、社長の宿題ではありません。</strong></p>
  </div>

  <div class="bg-gray-100 border-l-4 border-gray-400 p-4 mb-8 rounded text-sm">
    <strong>「ボール」は状態欄の文言からの機械の当て推量です（初版）。</strong>誤りうるので、各行に<strong>台帳の状態欄の原文をそのまま</strong>載せています。
    ずれていたら教えてください＝分類の語を直します。
  </div>"""]

    for sec, sec_title, sec_note in SECTIONS:
        sec_items = [i for i in items if i["sec"] == sec]
        if not sec_items:
            continue
        counts = {k: sum(1 for i in sec_items if i["key"] == k) for k in order}
        h.append(f'<h2 class="text-xl font-bold mt-10 mb-1">{html.escape(sec_title)}'
                 f' <span class="text-base font-normal text-gray-500">{len(sec_items)}件</span></h2>')
        h.append(f'<p class="text-sm text-gray-600 mb-3">{sec_note}</p>')
        h.append('<div class="grid grid-cols-2 md:grid-cols-7 gap-2 mb-6">')
        for k in order:
            lab, col = labels[k]
            h.append(f'<div class="{BADGE[col]} rounded p-2 text-center"><div class="text-xl font-bold">{counts[k]}</div>'
                     f'<div class="text-xs mt-1 leading-tight">{html.escape(lab.split("（")[0])}</div></div>')
        h.append("</div>")

        for k in order:
            rows = [i for i in sec_items if i["key"] == k]
            if not rows:
                continue
            rows.sort(key=lambda r: (-(r["days"] or 0), r["id"]))
            lab, col = labels[k]
            h.append(f'<h3 class="font-bold mt-6 mb-2 border-b pb-1">{html.escape(lab)}'
                     f' <span class="text-sm font-normal text-gray-500">{len(rows)}件</span></h3>')
            h.append('<div class="overflow-x-auto"><table class="w-full text-sm border-collapse mb-2">'
                     '<thead class="bg-gray-100"><tr>'
                     '<th class="border p-2 text-left w-20">ID</th>'
                     '<th class="border p-2 text-left w-16">経過</th>'
                     '<th class="border p-2 text-left">件名</th>'
                     '<th class="border p-2 text-left">台帳の状態欄（原文）</th></tr></thead><tbody>')
            for r in rows:
                d = f'{r["days"]}日' if r["days"] is not None else "—"
                aged = ' class="text-red-700 font-bold"' if (r["days"] or 0) >= 30 else ""
                title = html.escape(r["title"][:110]) + ("…" if len(r["title"]) > 110 else "")
                h.append(f'<tr class="align-top"><td class="border p-2 font-mono text-xs">{r["id"]}</td>'
                         f'<td class="border p-2 text-xs"><span{aged}>{d}</span></td>'
                         f'<td class="border p-2">{title}</td>'
                         f'<td class="border p-2 text-xs text-gray-700">{md_links(r["state"])[:600]}</td></tr>')
            h.append("</tbody></table></div>")

    h.append(f"""
  <p class="text-xs text-gray-500 border-t pt-4 mt-10">
  再生成＝<span class="font-mono">python3 bin/partner-index.py</span>（読み取り専用・台帳は変更しません）。<br>
  台帳が正＝このページは状態を持ちません。行の詳細・経緯は <span class="font-mono">data/partner/ledger.md</span> と
  <span class="font-mono">ledger-archive.md</span> にあります。</p>
</div></body></html>""")
    return "\n".join(h)


def main() -> int:
    if not LEDGER.exists():
        print(f"台帳が見つかりません: {LEDGER}", file=sys.stderr)
        return 1
    items, _ = build()
    counts: dict[str, int] = {}
    for i in items:
        counts[i["label"]] = counts.get(i["label"], 0) + 1
    for lab, n in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"{n:3d}  {lab}")
    print(f"{len(items):3d}  合計")
    if "--stdout" in sys.argv:
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(render(items), encoding="utf-8")
    print(f"→ {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
