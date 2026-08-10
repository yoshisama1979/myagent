#!/usr/bin/env python3
"""社長が確認・対応すべきことを1ページに集める（読み取り専用・都度生成）。

契機＝2026-08-10 社長ご質問「私が確認して対応すべき上記の事項はどこかにまとまってますか？」。
答え＝**まとまっていなかった**。実測で7か所に散っていた：

    ①経営パートナー台帳（A-NNN）②会話台帳の🔴（C-NNN）③売掛の対応表の候補
    ④Chatworkルームの役割の初期値 ⑤Gmailの承認待ち ⑥統括の起票（O-NNN）⑦未pushのコミット

散っていること自体が取りこぼしの原因になる（SSL が5日間誰の仕事にもならなかったのと同じ形）。
そこで**置き場を増やさず**、各所の一次情報を読んで**その場で組み立てるビュー**を1枚作る。

## 設計の約束
・**状態を持たない**。各台帳が正で、このページは毎回作り直す（[[project_progress-ledger-hana-tools]]）
・**件数を数えるだけでなく「社長が何をすればよいか」と「所要時間」を書く**（見ても動けない一覧にしない）
・読めない一次情報があれば **⚠️ を出す**（黙って0件にしない＝それが取りこぼしになる）
・出力は git 外（`site/todo/`）。取引先名・実名を含むため

使い方：
    python3 bin/president-todo.py            # 集計してページを書き出す
    python3 bin/president-todo.py --stdout   # 画面に出すだけ（書き出さない）
"""
from __future__ import annotations

import argparse
import html
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "site" / "todo" / "index.html"

PARTNER_LEDGER = ROOT / "data" / "partner" / "ledger.md"
COMMS_LEDGER = ROOT / "data" / "comms" / "chatwork" / "ledger.md"
ROOMS = ROOT / "data" / "comms" / "chatwork" / "rooms.md"
ALIASES = ROOT / "data" / "financial" / "payer-aliases.md"
GMAIL_PENDING = ROOT / "data" / "comms" / "gmail" / "pending.json"
OVERSEER = ROOT / "site" / "overseer" / "index.html"

# 「すぐ終わる」の目安。ここを決めておかないと、全部が同じ重さに見えて手が止まる。
QUICK = "1〜2分"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def item(cat, title, action, minutes, link="", note="", days=None, source=""):
    return {"cat": cat, "title": title, "action": action, "minutes": minutes,
            "link": link, "note": note, "days": days, "source": source}


def from_partner(problems: list[str]) -> list[dict]:
    """経営パートナー台帳の §3 から「社長のご判断・ご返信待ち」を拾う。"""
    if not PARTNER_LEDGER.exists():
        problems.append("経営パートナー台帳が読めません")
        return []
    try:
        pi = load_module("pi", ROOT / "bin" / "partner-index.py")
        items, _ = pi.build()
    except Exception as e:
        problems.append(f"経営パートナー台帳の解析に失敗（{type(e).__name__}）")
        return []
    out = []
    for i in items:
        if i["key"] != "pres":
            continue
        st = pi.strip_md(i["state"])
        action = ("◎○×をつける" if "◎○×" in st or "◎待ち" in st
                  else "「やって」の一言" if "一言待ち" in st
                  else "結果を一言" if "結果待ち" in st
                  else "ご返信")
        # §3＝社長が「やる」と言われたこと（社長の持ち物）／§4＝AIが並べた提案。
        # §4 を落とすと「まとめたのに漏れている」になるので、区別して**両方載せる**。
        proposal = i["sec"] == "§4"
        out.append(item("partner", f'{i["id"]} {i["title"][:60]}',
                        action + ("（提案）" if proposal else ""), 3,
                        "../business/partner/backlog.html",
                        ("【AIからの提案＝急ぎません】" if proposal else "") + st[:80],
                        i["days"], "経営パートナー台帳"))
    return out


def from_comms(problems: list[str]) -> list[dict]:
    """会話台帳の 🔴（社長ボール）。v0.7 以降は宛先で絞り込まれている。"""
    if not COMMS_LEDGER.exists():
        problems.append("会話台帳が読めません")
        return []
    out = []
    for line in COMMS_LEDGER.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\s*(C-\d{3})\s*\|", line)
        if not m or "🔴" not in line[:30]:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        who = cells[2] if len(cells) > 2 else ""
        what = cells[3] if len(cells) > 3 else ""
        what = re.sub(r"\*\*|<[^>]+>", "", what)
        out.append(item("comms", f'{m.group(1)} {who[:34]}', "返信する", 10,
                        "../comms/index.html", what[:90], None, "会話台帳（Chatwork・メール）"))
    return out


def from_finance(problems: list[str]) -> list[dict]:
    """売掛の対応表に残っている候補（#候補# のまま＝まだ有効になっていない）。"""
    if not ALIASES.exists():
        return []
    lines = [l for l in ALIASES.read_text(encoding="utf-8-sig").splitlines()
             if l.startswith("#候補#")]
    if not lines:
        return []
    need = sum(1 for l in lines if "【要確認】" in l)
    note = f"金額がぴったり一致した{len(lines) - need}件＋人が決める{need}件"
    return [item("finance", f"売掛金の消し込み：振込名義の対応表 {len(lines)}件",
                 "合っている行の行頭 `#候補# ` を消す", 5,
                 "../finance/ar-match.html", note, None, "payer-aliases.md")]


def from_rooms(problems: list[str]) -> list[dict]:
    """Chatwork ルームの役割ラベル（AIが推定した初期値の確認は1回だけ）。"""
    if not ROOMS.exists():
        return []
    n = sum(1 for l in ROOMS.read_text(encoding="utf-8-sig").splitlines()
            if re.match(r"^\s*\d{6,}", l))
    if not n:
        return []
    return [item("comms", f"Chatworkルームの役割 {n}件（AIの推定した初期値）",
                 "違うものだけ直す（合っていれば何もしない）", 5,
                 "../comms/index.html", "役割が分かると同じ文面でも意味の取り方が変わる",
                 None, "rooms.md")]


def from_gmail(problems: list[str]) -> list[dict]:
    if not GMAIL_PENDING.exists():
        return []
    try:
        n = len(json.loads(GMAIL_PENDING.read_text(encoding="utf-8")))
    except Exception:
        problems.append("Gmail の承認待ちリストが読めません")
        return []
    if not n:
        return []
    return [item("comms", f"メールの承認待ち送信者 {n}件",
                 "ドメイン単位で「適用」か「無視」に振り分ける", 10,
                 "../tools/gmail-pending.php",
                 "許可した送信者だけ本文を取得＝未許可は中身を見ていない", None, "pending.json")]


def from_overseer(problems: list[str]) -> list[dict]:
    """統括の起票のうち 🔴（社長の判断が要るもの）。"""
    if not OVERSEER.exists():
        problems.append("統括の掲示板が読めません")
        return []
    t = OVERSEER.read_text(encoding="utf-8")
    out = []
    for m in re.finditer(r"🔴\s*(O-\d{3})", t):
        oid = m.group(1)
        if any(o["title"].startswith(oid) for o in out):
            continue
        ctx = re.sub(r"<[^>]+>", "", t[m.end():m.end() + 260])
        ctx = re.sub(r"\s+", " ", ctx).strip()
        out.append(item("overseer", f"{oid} {ctx[:60]}", "方針を決める", 5,
                        "../overseer/index.html", ctx[:110], None, "統括レポート"))
    return out


def from_git(problems: list[str]) -> list[dict]:
    try:
        r = subprocess.run(["git", "log", "--oneline", "origin/main..HEAD"],
                           cwd=str(ROOT), capture_output=True, text=True, timeout=20)
        n = len([l for l in r.stdout.splitlines() if l.strip()])
    except Exception:
        problems.append("未pushコミット数を確認できません")
        return []
    if not n:
        return []
    return [item("dev", f"未pushのコミット {n}件", "`git push origin main`", 1,
                 "", "他エージェントの分も含まれる可能性あり", None, "git")]


CATS = {
    "partner": ("☀️ 経営パートナー", "amber"),
    "comms":   ("💬 会話・メール", "blue"),
    "finance": ("💰 経理", "green"),
    "overseer": ("🧭 システム統括", "indigo"),
    "dev":     ("🛠 開発", "gray"),
}
BADGE = {"amber": "bg-amber-100 text-amber-800", "blue": "bg-blue-100 text-blue-800",
         "green": "bg-green-100 text-green-800", "indigo": "bg-indigo-100 text-indigo-800",
         "gray": "bg-gray-200 text-gray-700"}


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-")
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def render(items: list[dict], problems: list[str]) -> str:
    e = html.escape
    now = datetime.now()
    gen = now.strftime("%Y-%m-%d %H:%M")
    quick = [i for i in items if i["minutes"] <= 5]
    total_min = sum(i["minutes"] for i in items)

    h = [f"""<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>社長の対応事項｜株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-gray-50 text-gray-900"><div class="max-w-5xl mx-auto p-6 md:p-10">
<div id="stale" class="hidden bg-red-100 border-l-4 border-red-500 text-red-900 p-4 mb-6 rounded"></div>
<script>(function(){{var g=new Date("{now.strftime('%Y-%m-%dT%H:%M:%S')}"),h=(Date.now()-g)/3600000;
if(h>24){{var el=document.getElementById("stale");el.className=el.className.replace("hidden","");
el.innerHTML="<strong>⚠️ この一覧は "+Math.floor(h/24)+" 日前のものです。</strong>再生成＝<span class='font-mono'>python3 bin/president-todo.py</span>";}}}})();</script>

<h1 class="text-2xl font-bold mb-1">✅ 社長の対応事項</h1>
<p class="text-sm text-gray-500 mb-6">生成 {gen}／各台帳から<strong>毎回組み立てる読み取り専用のビュー</strong>（このページは状態を持ちません）</p>

<div class="grid grid-cols-2 md:grid-cols-3 gap-3 mb-8">
  <div class="bg-white border-2 border-red-400 rounded p-4"><div class="text-xs text-gray-500">対応事項</div>
    <div class="text-3xl font-bold text-red-700">{len(items)}<span class="text-base font-normal">件</span></div></div>
  <div class="bg-white border rounded p-4"><div class="text-xs text-gray-500">うち5分以内で終わる</div>
    <div class="text-3xl font-bold">{len(quick)}<span class="text-base font-normal">件</span></div></div>
  <div class="bg-white border rounded p-4"><div class="text-xs text-gray-500">全部やると</div>
    <div class="text-3xl font-bold">約{total_min}<span class="text-base font-normal">分</span></div></div>
</div>"""]

    if problems:
        h.append('<div class="bg-yellow-50 border-l-4 border-yellow-500 p-4 mb-6 text-sm">'
                 '<strong>⚠️ 読めなかった一次情報があります＝この一覧は完全ではありません</strong><ul class="list-disc ml-5">')
        h += [f"<li>{e(p)}</li>" for p in problems]
        h.append("</ul></div>")

    if quick:
        h.append('<div class="bg-green-50 border-l-4 border-green-500 p-5 mb-8 rounded">'
                 f'<h2 class="font-bold mb-2">⚡ まずここから — 5分以内で終わるもの {len(quick)}件</h2>'
                 '<ul class="text-sm space-y-1 ml-1">')
        for i in sorted(quick, key=lambda x: x["minutes"]):
            lk = f'<a href="{e(i["link"])}" class="text-blue-600 hover:underline">開く</a>' if i["link"] else ""
            h.append(f'<li>□ <strong>{e(i["action"])}</strong> — {e(i["title"][:56])} '
                     f'<span class="text-gray-500">({i["minutes"]}分)</span> {lk}</li>')
        h.append("</ul></div>")

    for key, (label, color) in CATS.items():
        rows = [i for i in items if i["cat"] == key]
        if not rows:
            continue
        rows.sort(key=lambda r: -(r["days"] or 0))
        h.append(f'<h2 class="text-lg font-bold mt-8 mb-2 border-b pb-1">{e(label)} '
                 f'<span class="{BADGE[color]} text-xs px-2 py-1 rounded-full">{len(rows)}件</span></h2>')
        h.append('<div class="overflow-x-auto"><table class="w-full text-sm border-collapse">'
                 '<thead class="bg-gray-100"><tr>'
                 '<th class="border p-2 text-left w-40">やること</th>'
                 '<th class="border p-2 text-left">件名</th>'
                 '<th class="border p-2 text-left">状況</th>'
                 '<th class="border p-2 text-right w-16">経過</th></tr></thead><tbody>')
        for i in rows:
            d = f'{i["days"]}日' if i["days"] is not None else "—"
            aged = ' class="text-red-700 font-bold"' if (i["days"] or 0) >= 30 else ""
            lk = (f'<div class="text-xs mt-1"><a href="{e(i["link"])}" '
                  f'class="text-blue-600 hover:underline">→ 開く</a></div>') if i["link"] else ""
            h.append(f'<tr class="align-top">'
                     f'<td class="border p-2"><strong>{e(i["action"])}</strong>'
                     f'<div class="text-xs text-gray-500">{i["minutes"]}分</div>{lk}</td>'
                     f'<td class="border p-2">{e(i["title"])}</td>'
                     f'<td class="border p-2 text-xs text-gray-700">{e(i["note"])}</td>'
                     f'<td class="border p-2 text-right text-xs"><span{aged}>{d}</span></td></tr>')
        h.append("</tbody></table></div>")

    srcs = sorted({i["source"] for i in items})
    h.append(f"""<p class="text-xs text-gray-500 border-t pt-4 mt-10">
一次情報＝{e('／'.join(srcs))}。<strong>このページは状態を持ちません</strong>＝各台帳を直せばここも変わります。<br>
再生成＝<span class="font-mono">python3 bin/president-todo.py</span>（読み取り専用）。
取引先名を含むため git 管理外です。</p>
</div></body></html>""")
    return "".join(h)


def main() -> int:
    ap = argparse.ArgumentParser(description="社長の対応事項を1ページに集める（読み取り専用）")
    ap.add_argument("--stdout", action="store_true", help="画面に出すだけ（ページを書き出さない）")
    a = ap.parse_args()

    problems: list[str] = []
    items: list[dict] = []
    for fn in (from_partner, from_comms, from_finance, from_rooms,
               from_gmail, from_overseer, from_git):
        try:
            items += fn(problems)
        except Exception as ex:            # 1つ落ちても残りは出す（全滅させない）
            problems.append(f"{fn.__name__} で例外（{type(ex).__name__}）")

    by = {}
    for i in items:
        by[i["source"]] = by.get(i["source"], 0) + 1
    print(f"対応事項 {len(items)}件（うち5分以内 {sum(1 for i in items if i['minutes'] <= 5)}件）")
    for k, v in sorted(by.items(), key=lambda x: -x[1]):
        print(f"  {v:3d}  {k}")
    for p in problems:
        print(f"  ⚠️ {p}")

    if not a.stdout:
        atomic_write(OUT, render(items, problems))
        print(f"→ {OUT.relative_to(ROOT)}  （http://100.123.104.87/todo/）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
