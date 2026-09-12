#!/usr/bin/env python3
"""SYSTEM.md から site/docs/system-map.html（システム全体の設計マップ）を生成する。

設計地図の正は SYSTEM.md（統括者が保守）。社長がブラウザで見る図解ページを
手で書くと二重管理になり必ずズレるので **正から生成する**（command-map と同方式）。
SYSTEM.md を直したら必ずこれを実行すること。

役割分担：
- モードの事実（名前・目的・起動・読む/書く・承認ゲート・対話相手）＝ SYSTEM.md から抽出
- 図の骨格（層の並び・矢印）と色分け＝ このスクリプトが保持（変わりにくい構造）
- SYSTEM.md に新モードが増えたのに GROUPS 未分類なら「未分類」枠で赤く見せる
  ＝黙って図から消えない（地図ドリフト検出）

使い方: python3 bin/build-system-map.py
"""
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "SYSTEM.md"
OUT = ROOT / "site" / "docs" / "system-map.html"

# ---- 図の骨格（構造はここが保持・モード名は SYSTEM.md から流し込む）----------
# (グループ名, 色キー, 属するモードの短名[表の1列目から（…）を除いた部分])
GROUPS = [
    ("入口・会話", "sky", ["Main", "chat", "talk", "Memo", "memo-triage", "memo-intake", "Intake", "hp-reply"]),
    ("分析・提案ループ", "emerald",
     ["hp-improve", "hp-prospect", "hp-loop", "blog-loop", "blog-write", "blog-improve", "Reviewer"]),
    ("経営・記録", "amber", ["board", "partner", "Finance", "Comms", "task-partner"]),
    ("統括", "violet", ["Overseer", "triage"]),
]
COLORS = {
    "sky":     {"fill": "#e0f2fe", "line": "#0284c7", "text": "#075985"},
    "emerald": {"fill": "#d1fae5", "line": "#059669", "text": "#065f46"},
    "amber":   {"fill": "#fef3c7", "line": "#d97706", "text": "#92400e"},
    "violet":  {"fill": "#ede9fe", "line": "#7c3aed", "text": "#5b21b6"},
    "rose":    {"fill": "#ffe4e6", "line": "#e11d48", "text": "#9f1239"},
}


class SourceError(Exception):
    """SYSTEM.md の書き方が想定外＝黙って壊れた図を出さず、生成を失敗させる。"""


def inline(text):
    """**強調**・`コード`・[リンク]・[[記憶リンク]] だけ変換（他はエスケープのまま）。

    コードを先に退避するのは command-map と同じ理由（コード内の ** が化ける）。
    [text](path) の path はリポジトリ内ファイルでブラウザから開けないため、
    href にせず title 属性で在処だけ示す。
    """
    out = html.escape(text)
    stash = []

    def _keep(m):
        stash.append(m.group(1))
        return f"\x00CODE{len(stash) - 1}\x00"

    out = re.sub(r"`([^`]+)`", _keep, out)
    out = re.sub(r"\[\[([^\]]+)\]\]", r'<span class="text-gray-400 text-[0.85em]">[\1]</span>', out)
    out = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        r'<span class="underline decoration-dotted" title="\2">\1</span>',
        out,
    )
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    for i, code in enumerate(stash):
        out = out.replace(
            f"\x00CODE{i}\x00",
            f'<code class="bg-gray-100 px-1 rounded text-[0.9em] break-all">{code}</code>',
        )
    return out


def split_row(line):
    r"""表の1行をセルへ割る（\| はセル内の文字としての |）。command-map と同じ。"""
    cells = re.split(r"(?<!\\)\|", line.strip())
    if cells and cells[0].strip() == "":
        cells = cells[1:]
    if cells and cells[-1].strip() == "":
        cells = cells[:-1]
    return [c.strip().replace("\\|", "|") for c in cells]


def short_name(cell):
    """モード表の1列目 → 図で使う短名。'**hp-loop**（マルチサイト）' → 'hp-loop'。"""
    t = cell.replace("**", "").strip()
    return re.split(r"[（(]", t)[0].strip()


# ---- SYSTEM.md のパース --------------------------------------------------------

def parse(md):
    """行単位でトークン化。モード地図の表だけ特別扱い（カード＋SVGの材料）。"""
    lines = md.split("\n")
    tokens = []   # ('h1'|'h2'|'h3'|'p'|'quote'|'ul'|'table'|'modes'|'pre'|'hr', payload)
    modes = None
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        if line.lstrip().startswith("```"):
            block = []
            i += 1
            while i < len(lines) and not lines[i].lstrip().startswith("```"):
                block.append(lines[i])
                i += 1
            if i >= len(lines):
                raise SourceError("閉じられていないコードブロックがあります。")
            tokens.append(("pre", "\n".join(block)))
            i += 1
            continue
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|$", lines[i + 1].strip()):
            head = split_row(line)
            start = i + 1
            sep = split_row(lines[i + 1])
            if len(sep) != len(head):
                raise SourceError(
                    f"{start + 1}行目：表の区切り行の列数が見出しと違います"
                    f"（見出し {len(head)} 列・区切り {len(sep)} 列）＝表が壊れています。"
                )
            i += 2
            body = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                row = split_row(lines[i])
                if len(row) != len(head):
                    raise SourceError(
                        f"{i + 1}行目：列数が見出しと違います（見出し {len(head)} 列・この行 {len(row)} 列）。"
                        "セル内の | は \\| と書いてください。"
                    )
                body.append(row)
                i += 1
            if not body:
                raise SourceError(f"{start}行目：中身が1行も無い表です。")
            if head[0].strip() == "モード":
                if modes is not None:
                    raise SourceError("「モード」で始まる表が2つあります（想定は1つ）。")
                # ★カードとSVGが依存する前提をここで検証する★＝満たさない正からは
                #   IndexError や重複カードでなく、説明つきで生成を止める（2026-08-21 Codexレビュー🔴）
                if "目的" not in head:
                    raise SourceError(f"{start}行目：モード地図の表に「目的」列がありません。")
                seen = set()
                for r in body:
                    s = short_name(r[0])
                    if not s:
                        raise SourceError(f"{start}行目からのモード地図に、短名が空になる行があります: {r[0]!r}")
                    if s in seen:
                        raise SourceError(
                            f"モード地図の短名「{s}」が重複しています"
                            "（同じ短名の行が2つあるとカードが黙って上書きされるため止める）。"
                        )
                    seen.add(s)
                modes = {"head": head, "rows": body}
                tokens.append(("modes", modes))
            else:
                tokens.append(("table", (head, body)))
            continue
        if line.startswith("# "):
            tokens.append(("h1", line[2:]))
        elif line.startswith("## "):
            tokens.append(("h2", line[3:]))
        elif line.startswith("### "):
            tokens.append(("h3", line[4:]))
        elif line.startswith(">"):
            block = []
            while i < len(lines) and lines[i].startswith(">"):
                block.append(lines[i].lstrip(">").strip())
                i += 1
            tokens.append(("quote", block))
            continue
        elif line.startswith("- "):
            items = []
            while i < len(lines) and lines[i].startswith("- "):
                items.append(lines[i][2:])
                i += 1
            tokens.append(("ul", items))
            continue
        elif re.match(r"^-{3,}$", line.strip()):
            tokens.append(("hr", None))
        elif line.strip():
            tokens.append(("p", line))
        i += 1
    if modes is None:
        raise SourceError("「モード」で始まる表（モード地図）が見つかりません。")
    return tokens, modes


def check_groups(shorts, groups=None):
    """GROUPS 自身の腐敗を検出する（2026-08-21 Codexレビュー🟡）。

    SYSTEM.md 側の未分類は赤枠＋テストで見えるが、逆方向＝**廃止・改名済みの
    モード名が GROUPS に残る／同じ短名が2グループに居る**のは黙って通ってしまう。
    どちらも分類表の版ズレなので、説明つきで生成を止める。
    """
    where = {}
    for title, _, names in groups or GROUPS:
        for n in names:
            if n in where:
                raise SourceError(f"GROUPS で「{n}」が「{where[n]}」と「{title}」の両方に居ます（所属は1つ）。")
            where[n] = title
    ghost = [n for n in where if n not in shorts]
    if ghost:
        raise SourceError(
            "GROUPS に SYSTEM.md へ存在しないモード名が残っています: "
            + ", ".join(ghost) + "（廃止・改名なら GROUPS から外す）。"
        )


# ---- SVG（全体図） -------------------------------------------------------------

def build_svg(modes):
    shorts = [short_name(r[0]) for r in modes["rows"]]
    groups = []
    named = set()
    for title, color, names in GROUPS:
        members = [s for s in shorts if s in names]
        named.update(names)
        groups.append((title, color, members))
    leftovers = [s for s in shorts if s not in named]
    if leftovers:
        groups.append(("未分類（GROUPS更新漏れ）", "rose", leftovers))

    # グループが増えたら1枠210pxを下限に**全体の幅を広げる**＝枠外へはみ出させない
    # （固定1160pxのままだと6グループで見切れ・多数で幅が負になる。2026-08-21 Codexレビュー🟡。
    #   ページ側は overflow-x:auto なので広い図は横スクロールで見られる）
    n = len(groups)
    gap = 16
    gx0 = 20
    W = max(1160, int(2 * gx0 + n * 210 + (n - 1) * gap))
    gw = (W - 2 * gx0 - (n - 1) * gap) / n
    chip_h, chip_gap = 30, 8
    max_chips = max(len(m) for _, _, m in groups)
    grp_y = 236
    grp_h = 44 + max_chips * (chip_h + chip_gap) + 6
    bot_y = grp_y + grp_h + 52
    H = bot_y + 64 + 16

    def rect(x, y, w, h, fill, line, rx=10, dash=""):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        return (f'<rect x="{x:.0f}" y="{y:.0f}" width="{w:.0f}" height="{h:.0f}" rx="{rx}" '
                f'fill="{fill}" stroke="{line}" stroke-width="1.6"{d}/>')

    def text(x, y, s, size=15, fill="#1f2937", weight=600, anchor="middle"):
        return (f'<text x="{x:.0f}" y="{y:.0f}" font-size="{size}" fill="{fill}" '
                f'font-weight="{weight}" text-anchor="{anchor}" '
                f'font-family="\'Noto Sans JP\',sans-serif">{html.escape(s)}</text>')

    def varrow(x, y1, y2, both=True, color="#64748b"):
        m1 = ' marker-start="url(#ah)"' if both else ""
        return (f'<line x1="{x:.0f}" y1="{y1:.0f}" x2="{x:.0f}" y2="{y2:.0f}" '
                f'stroke="{color}" stroke-width="2"{m1} marker-end="url(#ah)"/>')

    p = ['<svg viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg" role="img" '
         'aria-label="システム全体図" class="w-full h-auto">' % (W, H)]
    p.append('<defs><marker id="ah" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" '
             'markerHeight="7" orient="auto-start-reverse">'
             '<path d="M0,0 L10,5 L0,10 z" fill="#64748b"/></marker></defs>')

    # 層1: 社長（すべてのハブ）
    p.append(rect(W / 2 - 170, 14, 340, 52, "#fef9c3", "#ca8a04", rx=12))
    p.append(text(W / 2, 40, "👑 社長", 19, "#854d0e", 800))
    p.append(text(W / 2, 58, "すべてのハブ＝外部送信・本番反映の承認ゲート", 12, "#a16207", 500))

    # 層1→2 矢印
    p.append(varrow(W / 2, 70, 104))
    p.append(text(W / 2 + 12, 92, "会話・閲覧・承認", 12, "#64748b", 500, "start"))

    # 層2: チャネル
    channels = [
        ("💬 Slack", "会話・#memo・日報"),
        ("📮 mailbox", "拠点横断・hold/=承認待ち"),
        ("📋 掲示板（site/）", "提案・所見をWebで閲覧"),
        ("🗂 hana-tools", "進行管理の一次台帳"),
    ]
    cw = (W - 2 * gx0 - 3 * gap) / 4
    for k, (name, sub) in enumerate(channels):
        x = gx0 + k * (cw + gap)
        p.append(rect(x, 108, cw, 60, "#f1f5f9", "#94a3b8"))
        p.append(text(x + cw / 2, 134, name, 15, "#334155", 700))
        p.append(text(x + cw / 2, 154, sub, 11.5, "#64748b", 500))

    # 層2→3 矢印
    p.append(varrow(W / 2, 172, grp_y - 6))
    p.append(text(W / 2 + 12, 200, "読む・書く・非同期に会話", 12, "#64748b", 500, "start"))

    # 層3: モード群（SYSTEM.md モード地図から自動反映）
    for k, (title, color, members) in enumerate(groups):
        c = COLORS[color]
        x = gx0 + k * (gw + gap)
        p.append(rect(x, grp_y, gw, grp_h, c["fill"], c["line"], rx=12))
        p.append(text(x + gw / 2, grp_y + 26, title, 14.5, c["text"], 800))
        for j, s in enumerate(members):
            cy = grp_y + 40 + j * (chip_h + chip_gap)
            p.append(rect(x + 10, cy, gw - 20, chip_h, "#ffffff", c["line"], rx=8))
            # 長い短名はチップ幅（gw-20）に収まるよう文字を縮める（半角0.55em/全角1.1em の概算）
            est = sum(1.1 if ord(ch) > 0xFF else 0.55 for ch in s)
            size = min(13.5, max(9.5, (gw - 28) / max(est, 1)))
            p.append(text(x + gw / 2, cy + 20, s, round(size, 1), c["text"], 700))

    # 層4: 無人運用とデータ源（下から支える）
    half = (W - 2 * gx0 - gap) / 2
    p.append(rect(gx0, bot_y, half, 60, "#f8fafc", "#94a3b8", dash="6 4"))
    p.append(text(gx0 + half / 2, bot_y + 26, "⏰ cron 無人ディスパッチャ（bin/agent-tick.sh）", 14, "#334155", 700))
    p.append(text(gx0 + half / 2, bot_y + 46, "新着 or 定時で各モードを起動（黙って止まらない）", 11.5, "#64748b", 500))
    x2 = gx0 + half + gap
    p.append(rect(x2, bot_y, half, 60, "#f8fafc", "#94a3b8", dash="6 4"))
    p.append(text(x2 + half / 2, bot_y + 26, "📊 実データ（読み取り専用）", 14, "#334155", 700))
    p.append(text(x2 + half / 2, bot_y + 46, "BigQuery（GSC・GA4・広告）・Chatwork・WordPress・財務", 11.5, "#64748b", 500))
    p.append(varrow(gx0 + half / 2, bot_y - 4, grp_y + grp_h + 6, both=False))
    p.append(varrow(x2 + half / 2, bot_y - 4, grp_y + grp_h + 6, both=False))

    p.append("</svg>")
    return "".join(p), groups


# ---- モードカード --------------------------------------------------------------

def build_cards(modes, groups):
    head = modes["head"]
    pi = head.index("目的")   # 列名で引く＝SYSTEM.md 側で列の並びが変わっても誤表示しない（存在は parse で検証済み）
    by_short = {short_name(r[0]): r for r in modes["rows"]}
    out = []
    for title, color, members in groups:
        if not members:
            continue
        c = COLORS[color]
        out.append(f'<h3 class="text-lg font-bold mt-6 mb-3" style="color:{c["text"]}">{html.escape(title)}</h3>')
        out.append('<div class="grid md:grid-cols-2 gap-4">')
        for s in members:
            r = by_short[s]
            rows = ""
            for k in range(1, len(head)):
                if k == pi:
                    continue
                rows += (f'<div class="flex gap-2 text-xs mt-1.5">'
                         f'<div class="w-24 shrink-0 text-gray-500 font-semibold">{inline(head[k])}</div>'
                         f'<div class="text-gray-700 min-w-0">{inline(r[k])}</div></div>')
            out.append(
                f'<div class="bg-white rounded-lg p-4 shadow-sm border-l-4" style="border-left-color:{c["line"]}">'
                f'<div class="font-bold text-gray-900">{inline(r[0])}</div>'
                f'<div class="text-sm text-gray-700 mt-1">{inline(r[pi])}</div>'
                f'<div class="mt-2 border-t pt-1">{rows}</div></div>'
            )
        out.append("</div>")
    return "\n".join(out)


# ---- 本文（SYSTEM.md 全体を順番どおり描画） -----------------------------------

def render_tokens(tokens, groups):
    out = []
    for kind, payload in tokens:
        if kind == "h1":
            continue   # ページ側で固定タイトルを持つ
        if kind == "h2":
            out.append(f'<h2 class="text-xl font-bold mt-10 mb-3 border-b-2 border-gray-300 pb-1">{inline(payload)}</h2>')
        elif kind == "h3":
            out.append(f'<h3 class="text-base font-bold mt-6 mb-2">{inline(payload)}</h3>')
        elif kind == "p":
            out.append(f'<p class="text-sm mb-3">{inline(payload)}</p>')
        elif kind == "quote":
            body = "<br>".join(inline(x) for x in payload if x)
            out.append(f'<div class="text-xs text-gray-600 border-l-4 border-gray-300 pl-3 mb-3 leading-relaxed">{body}</div>')
        elif kind == "ul":
            items = "".join(f'<li class="mb-1">{inline(x)}</li>' for x in payload)
            out.append(f'<ul class="text-sm list-disc ml-6 mb-4">{items}</ul>')
        elif kind == "hr":
            pass   # 節の区切りは h2 の罫線で十分
        elif kind == "pre":
            out.append('<div class="overflow-x-auto mb-4"><pre class="bg-slate-900 text-slate-200 '
                       'text-xs rounded-lg p-4 leading-relaxed">'
                       f"{html.escape(payload)}</pre></div>")
        elif kind == "table":
            head, body = payload
            th = "".join(f'<th class="border border-gray-300 p-2 text-left bg-gray-100">{inline(c)}</th>' for c in head)
            rows = ""
            for r in body:
                tds = "".join(f'<td class="border border-gray-300 p-2 align-top">{inline(c)}</td>' for c in r)
                rows += f"<tr>{tds}</tr>"
            out.append('<div class="overflow-x-auto mb-6"><table class="w-full text-sm border-collapse">'
                       f"<thead><tr>{th}</tr></thead><tbody>{rows}</tbody></table></div>")
        elif kind == "modes":
            out.append(build_cards(payload, groups))
    return "\n".join(out)


def generate(md):
    """SYSTEM.md の中身 → 完成HTML を**純粋関数**として返す。

    ファイルへ書くのは main() だけ。テストはこれをメモリ上で呼んで比較する
    ＝「生成忘れ検出」テストが本番の生成物を書き換えない（2026-08-21 Codexレビュー🔴・rules/testing.md 準拠）。
    """
    tokens, modes = parse(md)
    check_groups([short_name(r[0]) for r in modes["rows"]])
    svg, groups = build_svg(modes)
    body = render_tokens(tokens, groups)
    n_modes = len(modes["rows"])
    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>システム全体マップ｜株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-5xl mx-auto p-6 md:p-10">
  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">ダッシュボード</a>
    <span class="mx-1">/</span><span>システム全体マップ</span>
  </nav>

  <h1 class="text-3xl font-bold mb-2">🗺 システム全体マップ</h1>
  <p class="text-sm text-gray-600 mb-6">
    はなさかの AI 作業環境で動いている <strong>{n_modes} のモード</strong>が、
    どのチャネルで読み書きし、どこに承認ゲートがあるかの地図。
    正は <code class="bg-gray-100 px-1 rounded">SYSTEM.md</code>（統括者が保守）。
  </p>

  <div class="border-2 border-amber-400 bg-amber-50 rounded-lg p-4 mb-6 text-sm text-amber-900">
    <strong>読み方（3行）</strong>：
    ①社長がすべてのハブ＝外部送信・本番反映は必ず社長の承認を通る。
    ②各モードは半自律＝一次情報源を読み、掲示板・台帳に書き、チャネル越しに非同期で会話する。
    ③夜も止まらない＝cron が新着・定時で各モードを起こす（実データは読み取り専用）。
  </div>

  <div class="bg-white rounded-xl shadow-sm p-4 md:p-6 mb-2 overflow-x-auto">
    <div style="min-width:900px">{svg}</div>
  </div>
  <p class="text-xs text-gray-500 mb-8">図の枠・矢印は生成スクリプトが保持し、モード名は SYSTEM.md のモード地図から自動反映。
  未分類の赤い枠が出たら SYSTEM.md に新モードが増えた合図（bin/build-system-map.py の GROUPS へ追加する）。</p>

{body}

  <p class="text-xs text-gray-500 border-t pt-4 mt-8">
    このページは <code>SYSTEM.md</code> から <code>python3 bin/build-system-map.py</code> で生成しています。
    <strong>直接編集しないでください</strong>（次の生成で消えます）。
  </p>
</div>
</body>
</html>
"""


def main():
    if not SRC.exists():
        print(f"ERROR: 正のファイルがありません: {SRC}", file=sys.stderr)
        return 1
    try:
        doc = generate(SRC.read_text(encoding="utf-8"))
    except SourceError as e:
        print(f"ERROR: {SRC.name} の書き方が想定外です → {e}", file=sys.stderr)
        print("（HTML は更新していません＝古い版がそのまま残っています）", file=sys.stderr)
        return 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(OUT.suffix + ".tmp")
    tmp.write_text(doc, encoding="utf-8")
    tmp.replace(OUT)
    print(f"生成: {OUT}（{len(doc.encode())} bytes）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
