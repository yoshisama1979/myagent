#!/usr/bin/env python3
"""build-status-page — 社長がブラウザで「いまの現在地」を見るページを生成する。

契機＝2026-09-12 社長ご指示「できれば私もすぐに確認できるようにダッシュボードに
わかりやすく表示させてほしい」。セッションを立ち上げなくても現在地が分かるようにする。

設計：
- **数字の羅列にしない**。先頭は「いま開くべき窓口」＝行動につながる形にする
  （`/triage` の §7-2 誘導と同じ考え方。根拠のない誘導はしない）。
- **手書き禁止の生成物**。正は `bin/ledger-watch.py --json`（＝`/triage` が読むのと同じ数字）。
  ページと窓口で違う数字を言わないため、集計をここで作り直さない。
- **外部 API を叩かない**（`board-brief` は `--no-api`）。毎日 cron で回すので安く保つ。
- 取引先名・本文は出さない（件数と日付だけ）。
"""
import datetime
import html
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "site/business/status.html")
JST = datetime.timezone(datetime.timedelta(hours=9))
DESK_URL = {"board": None, "triage": None, "finance": None, "intake": None,
            "overseer": "../overseer/index.html", "do": None}


def run(cmd, timeout=600):
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout, cwd=ROOT)
        return r.returncode, r.stdout.decode("utf-8", "replace")
    except Exception as e:                       # 落ちてもページは出す（空白より「取れなかった」）
        return None, f"{e.__class__.__name__}"


def e(s):
    return html.escape(str(s))


def guidance(d, board_rc):
    """いま開くべき窓口。**根拠つきでしか出さない**（/triage §7-2 と同じ規律）。"""
    g = []
    # ★ledger-watch は対応表やセッションログが読めないとき、推定値を出さずに空の一覧と
    #   `desks_error` を返す（fail-closed）。ここで読まないと「窓口0件＝合図なし（健全）」と
    #   描かれて、作った安全装置が沈黙に化ける（2026-10-12・Codex🔴 2回目）。
    # ★**この節をいちばん先に積む**＝後ろに append すると、board の期日や器の 🔴 があるだけで
    #   先頭から押し出される（Codex🔴 3回目＝コメントが「最優先」と言うだけになっていた）。
    #   道具が判定できていないことは、その道具が出す合図より先に読まれないと意味がない。
    if d.get("desks_error"):
        g.append(("開発セッション", f"窓口の最終利用日を判定できません＝{d['desks_error']}", "red"))
    if board_rc == 1:
        g.append(("/board", "見直し期日が来た決定があります", "amber"))
    elif board_rc not in (0, 1):
        g.append(("開発セッション", f"board-brief が異常終了しました（exit={board_rc}）", "red"))
    red = [a for a in d["accumulators"] if a["flag"] == "🔴"]
    if red:
        w = max(red, key=lambda a: a["per_week"] or 0)
        g.append(("開発セッション",
                  f"{os.path.basename(w['path'])} が上限の{w['ratio']:.1f}倍・週あたり+{(w['per_week'] or 0)/1024:.0f}KB"
                  f"（増え続けている器 {len(red)}本）", "red"))
    stale = [m for m in d["mailbox"] if (m["oldest"] or 0) >= 7]
    if stale:
        w = max(stale, key=lambda m: m["oldest"] or 0)
        g.append(("/triage", f"{w['to']} 宛の便が {w['oldest']}日 滞留（7日以上 {len(stale)}件）", "amber"))
    for dk in d.get("desks", []):
        if dk.get("status") == "unknown":
            # ★日付を落とした窓口＝「一度も開いていない」ではない（Codex🔴 3回目）。
            #   未来の日時や stat 失敗で last=None になった分をここで「未使用」と呼ぶと、
            #   社長がいま使っている窓口へ「一度も開いていません」と誘導する。
            g.append((f"/{dk['desk']}", f"最終利用日を判定できません（{dk['what']}）", "red"))
        elif dk["days"] is None:
            g.append((f"/{dk['desk']}", f"一度も開いていません（{dk['what']}）", "sky"))
        elif dk["days"] >= 14:
            g.append((f"/{dk['desk']}", f"{dk['days']}日 開いていません（{dk['what']}）", "sky"))
    if not g:
        g.append(("—", "いま開くべき窓口はありません（合図なし）", "emerald"))
    return g


def build():
    rc, out = run(["python3", os.path.join(ROOT, "bin/ledger-watch.py"), "report", "--json"])
    if rc is None or not out.strip().startswith("{"):
        sys.exit(f"ledger-watch.py --json を取得できません: {out[:200]}")
    d = json.loads(out)
    board_rc, _ = run(["python3", os.path.join(ROOT, "bin/board-brief.py"), "--no-api"], timeout=300)
    now = datetime.datetime.now(JST)
    g = guidance(d, board_rc)

    p = [f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>いまの現在地｜株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-4xl mx-auto p-6 md:p-10">
  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">ダッシュボード</a>
    <span class="mx-1">/</span><span>いまの現在地</span>
  </nav>
  <h1 class="text-3xl font-bold mb-1">いまの現在地</h1>
  <p class="text-sm text-gray-600 mb-6">{e(now.strftime('%Y-%m-%d %H:%M'))} 時点（毎日 自動更新・
    <code class="bg-gray-100 px-1 rounded">python3 bin/build-status-page.py</code> の生成物＝手書きしない）。
    数字の正は <code class="bg-gray-100 px-1 rounded">bin/ledger-watch.py</code>＝<code class="bg-gray-100 px-1 rounded">/triage</code> が読むのと同じもの。</p>

  <h2 class="text-xl font-bold mb-3">🚦 いま開くべき窓口</h2>
  <div class="space-y-2 mb-8">"""]
    for desk, why, color in g:
        p.append(f"""    <div class="border-l-4 border-{color}-500 bg-{color}-50 rounded p-3">
      <span class="font-bold">{e(desk)}</span>
      <span class="text-sm text-gray-700 ml-2">{e(why)}</span>
    </div>""")
    p.append("""  </div>
  <p class="text-xs text-gray-500 mb-8">※ 判断はすべて <code class="bg-gray-100 px-1 rounded">/triage</code> で。
     個別の作業はそこから各窓口へ降ろします（<a class="text-blue-600 hover:underline" href="../docs/command-map.html">コマンド早見表</a>）。</p>

  <h2 class="text-xl font-bold mb-3">📈 増え続けている器</h2>
  <p class="text-xs text-gray-600 mb-2">🔴＝上限超過かつ増加中／🟡＝超過だが横ばい〜減少／🆕＝計測開始直後で傾き不明。<strong>上限内のものは出しません</strong>（鳴りっぱなしにしないため）。</p>
  <table class="w-full text-sm mb-8 border"><thead class="bg-gray-100">
    <tr><th class="p-2 text-left">器</th><th class="p-2 text-right">現在</th><th class="p-2 text-right">上限</th><th class="p-2 text-right">超過</th><th class="p-2 text-right">週あたり</th></tr>
  </thead><tbody>""")
    shown = [a for a in d["accumulators"] if a["flag"] != "✅"]
    for a in shown:
        pw = "傾き不明" if a["per_week"] is None else f"{a['per_week']/1024:+.1f}K"
        p.append(f"""    <tr class="border-t"><td class="p-2">{e(a['flag'])} <code>{e(a['path'])}</code></td>
      <td class="p-2 text-right">{a['bytes']//1024:,}K</td><td class="p-2 text-right text-gray-500">{a['limit']//1024:,}K</td>
      <td class="p-2 text-right font-bold">{a['ratio']:.1f}倍</td><td class="p-2 text-right">{e(pw)}</td></tr>""")
    p.append(f"""  </tbody></table>
  <p class="text-xs text-gray-500 -mt-6 mb-8">上限内 {len(d['accumulators']) - len(shown)} 本は省略（全 {len(d['accumulators'])} 本・履歴 {e(d['since'])}〜 {d['snapshots']}回）</p>

  <h2 class="text-xl font-bold mb-3">📥 消化されていないもの</h2>
  <table class="w-full text-sm mb-8 border"><thead class="bg-gray-100">
    <tr><th class="p-2 text-left">置き場</th><th class="p-2 text-right">件数</th><th class="p-2 text-right">最古</th></tr>
  </thead><tbody>""")
    for m in d["mailbox"]:
        if not m["count"]:
            continue
        old = "—" if m["oldest"] is None else f"{m['oldest']}日"
        cls = "font-bold text-red-700" if (m["oldest"] or 0) >= 14 else ""
        p.append(f"""    <tr class="border-t"><td class="p-2">mailbox {e(m['box'])}/ → <code>{e(m['to'])}</code></td>
      <td class="p-2 text-right">{m['count']}</td><td class="p-2 text-right {cls}">{e(old)}</td></tr>""")
    for q in d["decisions"]:
        c = "—" if q["count"] is None else q["count"]
        p.append(f"""    <tr class="border-t bg-amber-50"><td class="p-2">{e(q['name'])}<br><span class="text-xs text-gray-600">{e(q['note'])}</span></td>
      <td class="p-2 text-right font-bold">{e(c)}</td><td class="p-2 text-right">—</td></tr>""")
    p.append("""  </tbody></table>

  <h2 class="text-xl font-bold mb-3">🚪 窓口を最後に開いた日</h2>
  <table class="w-full text-sm mb-8 border"><thead class="bg-gray-100">
    <tr><th class="p-2 text-left">窓口</th><th class="p-2">扱うもの</th><th class="p-2 text-right">最終</th><th class="p-2 text-right">経過</th></tr>
  </thead><tbody>""")
    for dk in d.get("desks", []):
        last = dk["last"] or ("判定不能" if dk.get("status") == "unknown" else "一度もなし")
        days = "—" if dk["days"] is None else f"{dk['days']}日"
        # 判定不能（道具の故障）は放置の合図と色でも分ける（2026-10-12・Codex🟢）
        cls = ("bg-red-50" if dk.get("status") == "unknown"
               else "bg-sky-50" if (dk["days"] is None or dk["days"] >= 14) else "")
        url = DESK_URL.get(dk["desk"])
        name = f'<a class="text-blue-600 hover:underline" href="{url}">/{e(dk["desk"])}</a>' if url else f'/{e(dk["desk"])}'
        p.append(f"""    <tr class="border-t {cls}"><td class="p-2 font-mono">{name}</td><td class="p-2 text-gray-700">{e(dk['what'])}</td>
      <td class="p-2 text-right">{e(last)}</td><td class="p-2 text-right">{e(days)}</td></tr>""")
    if d.get("desks_error"):
        # 空の表を「全部開いている」とも「全部放置」とも読ませない（2026-10-12）
        p.append(f"""    <tr class="border-t bg-red-50"><td class="p-2" colspan="4">⚠️ 判定できません＝{e(d['desks_error'])}</td></tr>""")
    p.append("""  </tbody></table>
  <p class="text-xs text-gray-500">このページは判断をしません（良し悪しを書かない）。決めるのは社長と <code class="bg-gray-100 px-1 rounded">/triage</code> です。</p>
</div>
</body>
</html>""")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(p))
    print(f"生成: {OUT}（{os.path.getsize(OUT):,} bytes・誘導 {len(g)}件・器 {len(shown)}本）")
    return 0


if __name__ == "__main__":
    sys.exit(build())
