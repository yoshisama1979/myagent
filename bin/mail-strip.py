#!/usr/bin/env python3
"""保存済みメールに対して抽出（引用・署名の除去）を試し、結果を集計・レポートする検証ツール。

抽出ロジック本体は bin/_mail_strip.py（取り込み側 gmail-fetch.py と共有）。
このファイルは「効いているか」を人が確かめるための道具で、本番の取り込みには関与しない。

  python3 bin/mail-strip.py            集計だけ（本文は出力しない）
  python3 bin/mail-strip.py --report   社長が目視確認するページも生成
"""

import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _mail_strip import (  # noqa: E402
    OWN_SIGNATURE_MARK, QUOTE_LINE, find_quote_start, learn_signatures, strip_quotes,
)

PROJ = Path(__file__).resolve().parent.parent

# 判定名の表はここ1箇所。集計とレポートで別々に持つと、判定を増やしたとき
# 片方だけ書き忘れて「判定名が生のまま表示される」状態が静かに生まれる（実際に一度やった）。
METHODS = {
    "header-cut":     ("引用ヘッダで切れた",                  "bg-green-100 text-green-800"),
    "bottom-post":    ("ボトムポスト＝引用の後ろの地の文を残した", "bg-sky-100 text-sky-800"),
    "inline-sig-cut": ("インライン返信＋自社署名で切断",         "bg-amber-50 text-amber-800"),
    "inline-kept":    ("インライン返信＝切らずに残した",        "bg-amber-100 text-amber-800"),
    "thread-diff":    ("スレッド差分で引いた",                "bg-blue-100 text-blue-800"),
    "suspect-empty":  ("⚠️空になったので切らず全部残した（安全弁）", "bg-red-100 text-red-800"),
    "none":           ("引用が見つからず素通し",               "bg-gray-100 text-gray-700"),
}

# --- 評価（既存の保存分に対して試す。集計だけを出力し本文は出さない）--------------
def load_raw():
    msgs = []
    for p in sorted((PROJ / "data/comms/gmail/raw").glob("*.jsonl")):
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                msgs.append(json.loads(line))
    msgs.sort(key=lambda m: m.get("ts", ""))
    return msgs


def _pass(msgs, sigs):
    by_thread = defaultdict(list)
    out = []
    for m in msgs:
        tid = m.get("thread_id", "")
        parents = by_thread[tid][:]          # 同スレッドで自分より前に届いた分
        r = strip_quotes(m.get("body") or "", parents, sigs.get(m.get("from", "")))
        body = m.get("body") or ""
        r["orig"] = len(body)
        r["kept"] = len(r["text"])
        r["thread_pos"] = len(parents) + 1
        # QUOTE_LINE は行頭アンカー＝本文全体に search すると先頭行しか見ない。必ず行ごとに当てる
        r["has_quote_mark"] = any(QUOTE_LINE.match(l) for l in body.splitlines()) \
            or find_quote_start(body.splitlines()) is not None
        out.append(r)
        by_thread[tid].append(m.get("body") or "")   # 差分の材料は引用を含む原文
    return out


def evaluate(msgs):
    """2回まわす：署名は【引用を落としたあとの文面】の末尾に現れるため。

    原文の末尾は引用の最後尾であって署名ではない（署名は引用より前に来る）。
    1回目の結果から署名を学習し、2回目でそれを落とす。
    """
    first = _pass(msgs, {})
    stripped = [dict(m, body=r["text"]) for m, r in zip(msgs, first)]
    sigs = learn_signatures(stripped)
    return _pass(msgs, sigs), sigs


def write_report(msgs, results, path):
    """社長が目視確認するためのページ。site/comms/ は git 外・Tailscale 経由のみ。

    集計だけでは「正しく切れたか」は判断できない（切りすぎても数字は良く見える）。
    抽出結果と捨てた部分を並べて、人が見て気づける形にしておく。
    """
    import html as h

    total_o = sum(r["orig"] for r in results) or 1
    total_k = sum(r["kept"] for r in results) or 1
    # 全部を見るのは大変なので、残した文字数が多い順に並べる（社長ご指示 2026-07-31）。
    # 長いものほど「必要な情報が消えていないか」の確認価値が高く、短いものは見なくても被害が小さい。
    order = sorted(zip(msgs, results), key=lambda x: -x[1]["kept"])
    rows = []
    cum = 0
    divided = False
    for i, (m, r) in enumerate(order, 1):
        cum += r["kept"]
        share = 100 * cum / total_k
        # 累積が9割を超えたら区切りを入れる＝ここから下は見なくても全体の1割
        if not divided and share > 90 and i > 1:
            rows.append(f"""
  <div class="my-6 border-t-2 border-dashed border-gray-400 pt-3 text-sm text-gray-600">
    <strong>ここまでで残り全体の {share:.0f}% を確認したことになります。</strong>
    以下は1件あたりが短く、見送っても被害は小さい範囲です（残り {len(order) - i + 1} 件）。
  </div>""")
            divided = True
        body = m.get("body") or ""
        dropped = body[len(r["text"]):] if body.startswith(r["text"]) else "（差分方式のため単純な後半ではありません）"
        name, cls = METHODS.get(r["method"], (r["method"], "bg-gray-100"))
        rows.append(f"""
  <details class="border border-gray-300 rounded mb-3">
    <summary class="cursor-pointer p-3 hover:bg-gray-50 text-sm">
      <span class="inline-block w-8 text-gray-400 font-mono">{i}</span>
      <span class="inline-block px-2 py-0.5 rounded text-xs {cls} mr-2">{h.escape(name)}</span>
      <strong class="text-base">残り {r['kept']:,}字</strong>
      <span class="ml-2">{h.escape(m.get('subject') or '(件名なし)')}</span>
      <span class="text-gray-500 ml-2">{h.escape(m.get('from_name') or m.get('from') or '')}</span>
      <span class="text-gray-400 ml-2">（元{r['orig']:,}字・{100 - 100 * r['kept'] / (r['orig'] or 1):.0f}%削減・スレッド{r['thread_pos']}通目・ここまで累積{share:.0f}%）</span>
    </summary>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3 p-3 border-t border-gray-200">
      <div><h4 class="font-semibold text-sm mb-1 text-green-700">✅ 残した部分（これを蒸留に渡す）</h4>
        <pre class="text-xs bg-green-50 p-3 rounded whitespace-pre-wrap break-words max-h-96 overflow-y-auto">{h.escape(r['text']) or '（空）'}</pre></div>
      <div><h4 class="font-semibold text-sm mb-1 text-gray-500">🗑 捨てた部分</h4>
        <pre class="text-xs bg-gray-50 p-3 rounded whitespace-pre-wrap break-words max-h-96 overflow-y-auto text-gray-600">{h.escape(dropped) or '（なし）'}</pre></div>
    </div>
  </details>""")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>メール本文の抽出テスト — 目視確認</title>
<script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-gray-50 text-gray-900"><div class="max-w-6xl mx-auto p-6 md:p-10">
<h1 class="text-3xl font-bold mb-2">メール本文の抽出テスト</h1>
<p class="text-gray-600 mb-6">返信で積み重なった引用と署名を落とし、<strong>今回書かれた部分だけ</strong>を取り出せるかの検証。
まだ本番のパイプラインには入れていません。</p>
<div class="bg-blue-50 border-l-4 border-blue-400 rounded p-4 mb-6 text-sm">
  <p class="mb-1"><strong>{len(results)}通 / {total_o:,}字 → {total_k:,}字（{100 - 100 * total_k / total_o:.1f}% 削減）</strong></p>
  <p class="text-gray-700 mb-2">見ていただきたいのは <strong>「✅残した部分」から必要な情報が消えていないか</strong> の1点です。
  行をクリックすると中身が開きます。おかしいものがあれば件名でお知らせください。</p>
  <p class="text-gray-700"><strong>残した文字数が多い順に並べてあります。</strong>上から見ていって、点線の区切りまで確認すれば全体の9割をカバーできます。
  下にいくほど1件が短く、見送っても被害は小さくなります。</p>
</div>
{''.join(rows)}
<p class="text-xs text-gray-500 mt-8">このページは git 管理外（Tailscale 経由のみ）。生成＝<code>python3 bin/mail-strip.py --report</code></p>
</div></body></html>""", encoding="utf-8")
    return path


def main():
    msgs = load_raw()
    results, sigs = evaluate(msgs)
    total_o = sum(r["orig"] for r in results)
    total_k = sum(r["kept"] for r in results)
    methods = defaultdict(int)
    for r in results:
        methods[r["method"]] += 1

    print(f"対象 {len(results)} 通 / 署名を学習できた送信者 {len(sigs)} 人")
    print(f"合計 {total_o:,} 文字 → {total_k:,} 文字（{100 * total_k / total_o:.1f}% ・削減 {100 - 100 * total_k / total_o:.1f}%）")
    print("\n判定の内訳:")
    for k, v in sorted(methods.items(), key=lambda x: -x[1]):
        print(f"  {METHODS.get(k, (k,))[0]:32s} {v:3d}通")

    # 要注意（本文は出さない。長さと判定だけ）
    # 「素通し＝失敗」ではない。引用の無い初回メールは素通しが正解なので、
    # 失敗の疑いは「引用の痕跡があるのに切れていない」ものに限る。
    empty = [r for r in results if r["kept"] == 0 and r["orig"] > 0]
    missed = [r for r in results if r["method"] == "none" and (r["has_quote_mark"] or r["thread_pos"] > 1)]
    print("\n要確認:")
    print(f"  抽出結果が0文字（切りすぎの疑い）          {len(empty):3d}通")
    print(f"  引用の痕跡があるのに切れていない（失敗）    {len(missed):3d}通")
    print(f"  インライン返信として温存（意図的に残す）    {methods['inline-kept']:3d}通")
    print(f"  インライン返信＋署名で切断（回答は保持）    {methods['inline-sig-cut']:3d}通")
    print(f"  引用が無い初回メール＝素通しが正解          {methods['none'] - len(missed):3d}通")
    print(f"  ⚠️安全弁が働いた（切ると空になるため未切断） {methods['suspect-empty']:3d}通")

    print("\n返信の深さ別（何通目か → 平均削減率）:")
    depth = defaultdict(list)
    for r in results:
        depth[min(r["thread_pos"], 5)].append(r)
    for d in sorted(depth):
        rs = depth[d]
        o = sum(x["orig"] for x in rs) or 1
        k = sum(x["kept"] for x in rs)
        tag = f"{d}通目" if d < 5 else "5通目以降"
        print(f"  {tag:10s} {len(rs):3d}通  {100 - 100 * k / o:5.1f}% 削減")

    if "--report" in sys.argv:
        p = write_report(msgs, results, PROJ / "site/comms/gmail-strip-review.html")
        print(f"\n目視確認ページ: http://100.123.104.87/comms/{p.name}（git 管理外）")


if __name__ == "__main__":
    sys.exit(main())
