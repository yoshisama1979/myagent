#!/usr/bin/env python3
"""社内共有ダッシュボード（team-board）を site/business/goals.html から**生成**する。

board からの要件＝`data/board/spec-team-board-20260923.md`（2026-09-23 経営会議・社長ご指示）。
社内の大きな共有モニターに常時表示し、社員が誰でも会社の目標と現在地を見られるようにする。

設計の要点（なぜこうしたか）:
- **目標の正は goals.html。ここは読み取りビュー**＝手書きしない（board が目標を変えたら次の生成で反映）。
- **出してはいけない語は「気をつける」ではなく機械で止める**（spec §4）。当たった欄は**出さずに名指しで報告**する。
  ⇒ `bin/test-build-team-board.sh` が回帰テストで固定する。約束ではなく検査。
- **黙って減らない**＝前回より目標の数が減ったら**書かずに止まる**（goals.html の構造が変わって
  取りこぼしたのか、board が本当に減らしたのかを人が確かめる）。`--accept-drop` で意図的な減少を通す。
- 深さ2まで（G0＋中目標）を出す。31件を1画面に詰めると読めない＝board 自身が「多すぎる合図」と書いている。

使い方:
  python3 bin/build-team-board.py            # 生成（既定）
  python3 bin/build-team-board.py --dry-run  # 書かずに、何を出し何を伏せるかだけ表示
  python3 bin/build-team-board.py --accept-drop   # 目標が減ったことを承知で生成する
"""
import argparse
import datetime
import glob
import html
import json
import os
import re
import sys

ROOT = os.environ.get("TEAM_BOARD_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JST = datetime.timezone(datetime.timedelta(hours=9))
SRC = os.path.join(ROOT, "site/business/goals.html")
OUT = os.path.join(ROOT, "site/business/team-board.html")
STATE = os.path.join(ROOT, "data/board/team-board-state.json")
MAX_DEPTH = 2          # G0 と G0.x／G1〜G3 まで（深さ3の10件は出さない＝1画面に収めるため）
RELOAD_SEC = 600       # ブラウザ側の自動リロード（生成は1日1回で足りる＝spec §5）

# ── 出してはいけないもの（spec §4）。**当たった欄は出さない**。
#    ⚠️ ここを緩めるのは board の線引きを変えること＝社長の承認が要る。
FORBIDDEN = [
    ("人件費", "給与・役員報酬・人件費の実額"),
    ("役員報酬", "給与・役員報酬・人件費の実額"),
    ("給与", "給与・役員報酬・人件費の実額"),
    ("現預金", "現預金残高"),
    ("赤字", "月次の赤字額"),
    ("融資", "融資の検討そのもの"),
    ("公庫", "融資の検討そのもの"),
    ("採用", "採用・退職・個人のご事情"),
    ("退職", "採用・退職・個人のご事情"),
    ("未分類仕訳", "経理の内部状態"),
    ("未仕訳", "経理の内部状態"),
    ("要確認", "経理の内部状態"),
]
FORBIDDEN_RE = [(re.compile(r"D-0\d\d"), "board の決定台帳の生データ")]

# 題そのものが線に当たる目標＝丸ごと出さない（2026-09-27 社長ご決定＝(a) 出さない）
#   G0.3.3 未分類仕訳の解消 ／ G0.3.4 現預金・売掛金の見張り
#   ⚠️ 番号で持たない（board が採番を変えたら黙って復活する）＝題を機械で判定する。
HEAD_RE = re.compile(r"<h([1-6])[^>]*>(.*?)</h\1>", re.S)
# ★番号は**最長一致で先に確定**させる。`^(G\d+(?:\.\d+)*)\.?\s*(.+)$` のような形にすると
#   「G0.9」（題の無い壊れた見出し）が「G0」＋題「9」として通ってしまい、**壊れを取りこぼしでなく
#   目標として増やす**（実測 2026-09-27）。番号を確定してから、残りが題として成立するかを別に見る。
NUM_RE = re.compile(r"^(G\d+(?:\.\d+)*)")
SEP = ".：: \u3000\t"
BADGE_RE = re.compile(r'<span class="badge[^"]*">(.*?)</span>', re.S)
TARGET_RE = re.compile(r"(?:数値目標|目標（案）)\s*[：:]?\s*</td>\s*<td[^>]*>(.*?)</td>", re.S)
TARGET2_RE = re.compile(r"目標（案）\s*[：:]\s*(.*?)</p>", re.S)
CURRENT_RE = re.compile(r"(?:現状|現在地)\s*</td>\s*<td[^>]*>(.*?)</td>", re.S)


def text(s):
    """タグを落として1行の素の文にする。"""
    s = re.sub(r"<br\s*/?>", " ", s)
    s = re.sub(r"<[^>]+>", "", s)
    return re.sub(r"\s+", " ", html.unescape(s)).strip()


# 社員が見る画面に **社内の作業メモ**を出さない（spec §2「経緯は要らない」）。
# 実測 2026-09-27＝素で抜くと「bin/hana-api.sh todos --status=incomplete」「recurring-revenue.html」
# 「シート『計』と整合確認済み」まで出た。読み手が違う＝道具の名前と突合の経緯は社員には意味がない。
INTERNAL = re.compile(r"bin/|\.py\b|\.html\b|\.md\b|--[a-z]|⚠️|実測|突合|あえて|捏造|シート")
LEAD_MAX = 64


def short(s):
    """1行の短い言い方にする。**先頭の要点だけ**＝根拠・注記・経緯は落とす。

    ★社内向けの語が出てきたら**そこで切る**（欄ごと捨てない）。捨てると spec §4 が「出してよい」と
      名指しした数字まで消える（実測＝「月¥837,300」が `→ recurring-revenue.html …` と同じ欄にあり、
      欄ごと落とすと看板の数字が消えた）。
    """
    s = re.split(r"[。\n]", s)[0]
    m = INTERNAL.search(s)
    if m:
        s = s[:m.start()]
    s = re.sub(r"[→＝=/・\s]+$", "", s)
    # 途中で切ると「（48契約・2026-06-07」のように閉じないカッコが残る＝読み手が不安になる。
    for op, cl in (("（", "）"), ("(", ")")):
        if s.count(op) > s.count(cl):
            s = s[:s.rindex(op)].rstrip(" 　・/")
    s = re.sub(r"[（(][^（()）]{12,}[)）]", "", s)     # 長い注記の丸カッコは落とす
    s = re.sub(r"\s+", " ", s).strip(" 　・/")
    return (s[:LEAD_MAX] + "…") if len(s) > LEAD_MAX else s


MIN_LEAD = 8


def usable(s):
    """社員向けに出してよい短さ・中身か。

    短く切りすぎて言い切れていないもの（例＝「初回の実入金」）は出さない。
    中途半端に出すほうが、無いより誤解を生む（spec §4「迷ったら出さない」）。
    """
    return bool(s) and len(s) >= MIN_LEAD and not INTERNAL.search(s)


def forbidden_in(s):
    """その文が線に当たるなら理由を返す（当たらなければ None）。"""
    for word, why in FORBIDDEN:
        if word in s:
            return f"語「{word}」＝{why}"
    for pat, why in FORBIDDEN_RE:
        m = pat.search(s)
        if m:
            return f"「{m.group(0)}」＝{why}"
    for name in client_names():
        if name in s:
            return "取引先名"      # ★実名はログにも出さない
    return None


_NAMES = None


def client_names():
    """取引先の名簿は**ファイルから毎回引く**（手で書くと増えた日に古くなる）。実名は表示しない。"""
    global _NAMES
    if _NAMES is None:
        out = set()

        def walk(o):
            if isinstance(o, dict):
                for k, v in o.items():
                    if k in ("client_name", "name") and isinstance(v, str) and len(v.strip()) >= 3:
                        out.add(v.strip())
                    else:
                        walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)
        p = os.path.join(ROOT, "data/clients-cache.json")
        if os.path.exists(p):
            try:
                with open(p, encoding="utf-8") as f:
                    walk(json.load(f))
            except (OSError, ValueError):
                pass
        for f_ in glob.glob(os.path.join(ROOT, "data/hp-loop/sites/*.md")):
            out.add(os.path.basename(f_)[:-3])
        _NAMES = sorted(out, key=len, reverse=True)
    return _NAMES


def parse_goals(src_html):
    """goals.html から目標を起こす。取りこぼしは**名指しで返す**（黙って減らさない）。"""
    goals, unparsed = [], []
    heads = list(HEAD_RE.finditer(src_html))
    for i, m in enumerate(heads):
        raw = text(m.group(2))
        if not raw:
            continue
        g = NUM_RE.match(raw)
        title = raw[g.end():].lstrip(SEP).strip() if g else ""
        if not g or not title:
            if re.match(r"^G\s*\d", raw):   # G＋数字で始まるのに題が取れない＝取りこぼし
                unparsed.append(raw[:60])
            continue
        num = g.group(1)
        body = src_html[m.end(): heads[i + 1].start() if i + 1 < len(heads) else len(src_html)]
        badge = BADGE_RE.search(body)
        tm = TARGET_RE.search(body) or TARGET2_RE.search(body)
        cm = CURRENT_RE.search(body)
        goals.append({
            "num": num,
            "depth": num.count(".") + 1,
            "title": title,
            "status": text(badge.group(1)) if badge else "",
            "target": short(text(tm.group(1))) if tm else "",
            "current": short(text(cm.group(1))) if cm else "",
        })
    return goals, unparsed


def redact(goals):
    """線に当たる欄を落とす。**落としたものは必ず名指しで返す**（黙って伏せない）。"""
    kept, dropped = [], []
    for g in goals:
        why = forbidden_in(g["title"])
        if why:
            dropped.append((g["num"], "目標そのもの", why))
            continue
        for field, label in (("target", "目標値"), ("current", "現在地"), ("status", "状態")):
            w = forbidden_in(g[field])
            if w:
                dropped.append((g["num"], label, w))
                g[field] = ""
                continue
            # 状態は「進行中」「構想中」のように短いのが正常＝長さの下限は掛けない
            bad = INTERNAL.search(g[field]) if field == "status" else (g[field] and not usable(g[field]))
            if g[field] and bad:
                dropped.append((g["num"], label, "社内の作業メモ・道具の名前が入る"))
                g[field] = ""
        kept.append(g)
    return kept, dropped


def load_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(n, dropped):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"generated_at": datetime.datetime.now(JST).isoformat(timespec="seconds"),
                   "goal_count": n, "dropped": len(dropped)}, f, ensure_ascii=False, indent=1)
    os.replace(tmp, STATE)


def render(goals, now):
    """大型モニター向け＝文字を大きく・1画面・人が操作しない（spec §5）。"""
    top = [g for g in goals if g["depth"] == 1]
    mid = [g for g in goals if g["depth"] == 2]
    e = html.escape

    def card(g):
        rows = ""
        if g["target"]:
            rows += f'<div class="row"><span class="k">目標</span><span class="v">{e(g["target"])}</span></div>'
        if g["current"]:
            rows += f'<div class="row"><span class="k">現在</span><span class="v now">{e(g["current"])}</span></div>'
        badge = f'<span class="st">{e(g["status"])}</span>' if g["status"] else ""
        return (f'<article class="card"><h3><span class="num">{e(g["num"])}</span>'
                f'{e(g["title"])}{badge}</h3>{rows}</article>')

    head = "".join(f'<div class="ns"><span class="num">{e(g["num"])}</span>'
                   f'<span class="t">{e(g["title"])}</span></div>' for g in top)
    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="{RELOAD_SEC}">
<title>はなさか 目標と現在地</title>
<!-- このファイルは bin/build-team-board.py の生成物です。手で編集しないでください
     （目標の正は site/business/goals.html。ここを直しても次の生成で消えます）。 -->
<style>
  :root {{ --bg:#0f172a; --fg:#f8fafc; --dim:#94a3b8; --line:#1e293b; --ac:#38bdf8; --ok:#4ade80; }}
  * {{ box-sizing:border-box; margin:0; padding:0; }}
  body {{ background:var(--bg); color:var(--fg); font-family:"Noto Sans JP",system-ui,sans-serif;
          padding:1.6vh 2vw; min-height:100vh; }}
  header {{ display:flex; justify-content:space-between; align-items:baseline;
            border-bottom:2px solid var(--line); padding-bottom:.8vh; margin-bottom:1.1vh; }}
  h1 {{ font-size:1.9vw; letter-spacing:.04em; }}
  .as {{ color:var(--dim); font-size:1.1vw; }}
  .ns {{ display:flex; gap:.8vw; align-items:baseline; margin-bottom:.7vh; }}
  .ns .num {{ color:var(--ac); font-size:1.15vw; font-weight:700; }}
  .ns .t {{ font-size:1.35vw; font-weight:700; line-height:1.25; }}
  .grid {{ display:grid; grid-template-columns:repeat(4,1fr); gap:.9vw 1vw; }}
  .card {{ background:#152036; border:1px solid var(--line); border-radius:.5vw; padding:1vh .9vw; }}
  .card h3 {{ font-size:1.25vw; line-height:1.4; font-weight:700; margin-bottom:.7vh; }}
  .card .num {{ color:var(--ac); margin-right:.5vw; }}
  .st {{ color:var(--dim); font-size:.85vw; font-weight:400; margin-left:.6vw; white-space:nowrap; }}
  .row {{ display:flex; gap:.7vw; font-size:.95vw; line-height:1.5; margin-top:.3vh; }}
  .k {{ color:var(--dim); flex:0 0 3vw; }}
  .v {{ flex:1; }}
  .now {{ color:var(--ok); font-weight:700; }}
  footer {{ margin-top:1.2vh; color:var(--dim); font-size:.85vw; border-top:1px solid var(--line); padding-top:1vh; }}
  @media (max-width:900px) {{
    h1 {{ font-size:5vw; }} .grid {{ grid-template-columns:1fr; }}
    .ns .t {{ font-size:5vw; }} .ns .num {{ font-size:4vw; }}
    .card h3 {{ font-size:4.2vw; }} .row {{ font-size:3.6vw; }} .k {{ flex:0 0 10vw; }}
    .as, .st, footer {{ font-size:3vw; }}
  }}
</style>
</head>
<body>
<header>
  <h1>いま会社が目指していること</h1>
  <div class="as">{now.strftime('%Y-%m-%d %H:%M')} 現在</div>
</header>
{head}
<div class="grid">
{''.join(card(g) for g in mid)}
</div>
<footer>目標の正＝経営会議（board）が決めた目標ツリー。この画面は毎日つくり直しています。</footer>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="書かずに、出すもの・伏せるものを表示する")
    ap.add_argument("--accept-drop", action="store_true", help="目標の数が前回より減ったことを承知で生成する")
    a = ap.parse_args()

    if not os.path.exists(SRC):
        sys.exit(f"ERROR: 目標の正が見つかりません（{os.path.relpath(SRC, ROOT)}）")
    with open(SRC, encoding="utf-8") as f:
        src = f.read()

    goals, unparsed = parse_goals(src)
    if unparsed:
        print(f"⚠️ 読めなかった見出し {len(unparsed)}件（構造が変わった可能性）:")
        for u in unparsed:
            print(f"   ・{u}")
    shown = [g for g in goals if g["depth"] <= MAX_DEPTH]
    shown, dropped = redact(shown)

    print(f"目標 {len(goals)}件（深さ{MAX_DEPTH}まで {len(shown)}件を出す・深さ{MAX_DEPTH + 1}以上 "
          f"{len([g for g in goals if g['depth'] > MAX_DEPTH])}件は出さない）")
    for num, label, why in dropped:
        print(f"  🙈 伏せた: {num} の{label}（{why}）")

    prev = load_state().get("goal_count")
    if prev is not None and len(shown) < prev and not a.accept_drop:
        sys.exit(f"ERROR: 出せる目標が前回より減っています（{prev} → {len(shown)}）。"
                 "goals.html の構造が変わって取りこぼしたのか、board が本当に減らしたのかを"
                 "確かめてください。意図した減少なら --accept-drop を付けて再実行します（書きませんでした）")
    if not shown:
        sys.exit("ERROR: 出せる目標が0件です（書きませんでした）")

    page = render(shown, datetime.datetime.now(JST))
    bad = forbidden_in(text(page))
    if bad:
        sys.exit(f"ERROR: 生成した画面に出してはいけないものが残っています（{bad}）。書きませんでした")

    if a.dry_run:
        print(f"（--dry-run のため書いていません。{len(page)} バイト生成できました）")
        return 0
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(page)
    os.replace(tmp, OUT)
    save_state(len(shown), dropped)
    print(f"→ {os.path.relpath(OUT, ROOT)}（{len(page)} バイト）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
