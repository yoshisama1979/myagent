#!/usr/bin/env python3
"""売掛金の消し込み候補を機械で出す（読み取り専用・仕訳帳は一切書き換えない）。

契機＝2026-08-07 社長ご質問「売掛金の消し込みなどチェックを行っていますか？」。
調べたところ **していなかった**。原因も特定できた：

    ・売上計上（借方=売掛金）36件 … 補助科目に取引先が入っている（35/36）
    ・入金消込（貸方=売掛金）33件 … **取引先も補助科目も空（0/33）**。摘要に振込名義だけが入る

そのため「合計は合うが、取引先別にいくら残っているか分からない」状態だった
（finance-snapshot が出していた「上位1社38%集中」は、入金を差し引く前のグロス計上額）。

摘要（振込名義）と補助科目（取引先名）は表記が違う（カナ vs 漢字・法人格の有無）ので、
機械だけでは決められない。そこで **社長ご指示（2026-08-07）「摘要のルールを決める」** に沿って：

    ① 金額と日付で機械的に絞れるものは絞る（1対1で金額が一致すれば強い候補）
    ② 確定したものから **振込名義→取引先** の対応を学習し、対応表の案を出す
    ③ 対応表 `data/financial/payer-aliases.md` は **社長が編集し、AI は読むだけ**
       （senders.md・rooms.md と同じ規律＝振り分けは人の判断）

## 絶対にしないこと
・仕訳帳・カード明細・PL/BS を書き換えない（読むだけ）
・会計システム（マネーフォワード）へ書きに行かない
・取引先名を git 追跡ファイルへ出さない（出力先は data/financial/generated/ と
  site/finance/ の2つ＝どちらも .gitignore 済み）

使い方：
    python3 bin/ar-match.py                # 照合してレポートを出す
    python3 bin/ar-match.py --stats        # 件数だけ（固有名詞を出さない＝ログに残してよい）
    python3 bin/ar-match.py --write        # CSV と作業ページも書き出す
"""
from __future__ import annotations

import argparse
import csv
import html
import io
import os
import re
import sys
import tempfile
import unicodedata
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIN = ROOT / "data" / "financial"
# 仕訳帳は MCP 自動取得（generated/journal-mcp/）が現行の正。旧アップロード先は受け皿として残す
# ＝F-017 で journal-check.php と同じ切り替えにする。ここを揃えないと、画面は最新なのに
# 入金突合だけ 7/24 で止まった古い仕訳帳を見る、という**片肺の食い違い**が起きる。
JOURNAL_MCP_DIR = FIN / "generated" / "journal-mcp"
JOURNAL_DIR = JOURNAL_MCP_DIR if list(JOURNAL_MCP_DIR.glob("FY*.csv")) else FIN / "journal"
ALIASES = FIN / "payer-aliases.md"          # 社長が編集・AIは読むだけ
GENERATED = FIN / "generated"
PAGE = ROOT / "site" / "finance" / "ar-match.html"   # .gitignore 済み

AR = "売掛金"
# 振込手数料を差し引かれた入金を「金額違い」にしないための許容幅（円）。
# 一般的な他行あて手数料の上限まで。これを超える差は「一部入金」として別扱いにする。
FEE_TOLERANCE = 1100
# 入金が計上より前に来ることはある（前受・着手金）が、常識的な範囲を超えたら候補から外す
MAX_DAYS_BEFORE = 60

LEGAL = re.compile(r"(株式会社|有限会社|合同会社|合資会社|一般社団法人|医療法人|"
                   r"\(株\)|\(有\)|㈱|㈲|カ\)|ｶ\)|ユ\)|ﾕ\)|\(ｶ\)|\(カ\))")
NOISE = re.compile(r"[\s　・．.,，、\-ー－―_/／\\（）()【】\[\]]+")


def norm(s: str) -> str:
    """表記ゆれを吸収した比較用の文字列。ひらがな→カタカナ、半角カナ→全角、法人格・記号を除去。"""
    s = unicodedata.normalize("NFKC", (s or "").strip())
    s = LEGAL.sub("", s)
    s = NOISE.sub("", s)
    out = []
    for ch in s:
        o = ord(ch)
        if 0x3041 <= o <= 0x3096:        # ひらがな → カタカナ
            out.append(chr(o + 0x60))
        else:
            out.append(ch)
    return "".join(out).upper()


def money(v) -> int:
    try:
        return int(str(v).replace(",", "").strip() or 0)
    except ValueError:
        return 0


def parse_day(s: str) -> date | None:
    s = (s or "").strip().replace("-", "/")
    for f in ("%Y/%m/%d", "%Y/%m/%d %H:%M:%S"):
        try:
            return datetime.strptime(s, f).date()
        except ValueError:
            continue
    return None


def read_journal() -> tuple[list[dict], list[str]]:
    """仕訳帳を読む（Shift-JIS）。壊れて読めないファイルは黙って飛ばさず申告する。"""
    rows, problems = [], []
    files = sorted(JOURNAL_DIR.glob("*.csv")) if JOURNAL_DIR.is_dir() else []
    if not files:
        problems.append(f"仕訳帳がありません: {JOURNAL_DIR}")
    for f in files:
        raw = f.read_bytes()
        text = None
        for enc in ("cp932", "utf-8-sig", "utf-8"):
            try:
                text = raw.decode(enc); break
            except UnicodeDecodeError:
                continue
        if text is None:
            problems.append(f"{f.name}: 文字コードを判定できません")
            continue
        for r in csv.DictReader(io.StringIO(text)):
            r["_file"] = f.name
            rows.append(r)
    return rows, problems


def load_aliases() -> tuple[dict[str, str], list[str]]:
    """payer-aliases.md → {正規化した振込名義: 取引先名}。無ければ空（＝全部が候補どまり）。"""
    if not ALIASES.exists():
        return {}, []
    out, problems = {}, []
    for n, line in enumerate(ALIASES.read_text(encoding="utf-8-sig").splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        body = s.split("#")[0]
        parts = [p for p in re.split(r"\t|  +", body) if p.strip()]
        if len(parts) < 2:
            problems.append(f"{n}行目: 『振込名義  取引先名』の2つに分かれていません「{s[:40]}」")
            continue
        key = norm(parts[0])
        if key in out:
            problems.append(f"{n}行目: 振込名義が重複しています（後の行で上書き）")
        out[key] = parts[1].strip()
    return out, problems


def split_ar(rows: list[dict]) -> tuple[list[dict], list[dict]]:
    """売掛金の計上（請求）と入金に分ける。"""
    bills, pays = [], []
    for r in rows:
        if r.get("借方勘定科目") == AR:
            bills.append({
                "no": r.get("取引No", ""), "day": parse_day(r.get("取引日", "")),
                "client": (r.get("借方補助科目") or r.get("借方取引先") or "").strip(),
                "amount": money(r.get("借方金額(円)")),
                "note": (r.get("摘要") or "").strip(), "file": r["_file"],
            })
        if r.get("貸方勘定科目") == AR:
            pays.append({
                "no": r.get("取引No", ""), "day": parse_day(r.get("取引日", "")),
                "payer": (r.get("摘要") or "").strip(),
                "tagged": (r.get("貸方補助科目") or r.get("貸方取引先") or "").strip(),
                "amount": money(r.get("貸方金額(円)")),
                "against": (r.get("借方勘定科目") or "").strip(), "file": r["_file"],
            })
    return bills, pays


def name_score(payer: str, client: str) -> float:
    """振込名義と取引先名の近さ（0〜1）。カナと漢字は比べようがないので、あくまで補助。"""
    a, b = norm(payer), norm(client)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    if a in b or b in a:
        return 0.85
    # 先頭が一致する長さで見る（振込名義は途中で切られることが多い）
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return min(0.8, n / max(len(a), len(b))) if n >= 2 else 0.0


def match(bills: list[dict], pays: list[dict], aliases: dict[str, str]) -> dict:
    """入金1件ごとに、当てはまりそうな請求を探す。**確定はしない**（候補と根拠を出す）。"""
    open_bills = [dict(b, remaining=b["amount"]) for b in bills]
    results = []

    for p in pays:
        cands = []
        alias_client = aliases.get(norm(p["payer"]))
        for b in open_bills:
            if b["remaining"] <= 0:
                continue
            if p["day"] and b["day"] and (b["day"] - p["day"]).days > MAX_DAYS_BEFORE:
                continue                       # 入金がその請求より極端に前＝別物
            diff = b["remaining"] - p["amount"]
            reasons, score = [], 0.0
            if alias_client and b["client"] == alias_client:
                score += 0.6; reasons.append("対応表で一致")
            ns = name_score(p["payer"], b["client"])
            if ns >= 0.8:
                score += 0.3; reasons.append(f"名義が近い({ns:.0%})")
            elif ns > 0:
                score += 0.1; reasons.append(f"名義が一部一致({ns:.0%})")
            if diff == 0:
                score += 0.5; reasons.append("金額が完全一致")
            elif 0 < diff <= FEE_TOLERANCE:
                score += 0.4; reasons.append(f"金額が手数料分だけ少ない(差{diff:,}円)")
            elif diff < 0:
                score += 0.1; reasons.append(f"入金が請求より多い(差{-diff:,}円)")
            else:
                score += 0.05; reasons.append(f"一部入金の可能性(残{diff:,}円)")
            if score > 0:
                cands.append({"bill": b, "score": round(score, 2), "reasons": reasons, "diff": diff})
        cands.sort(key=lambda c: -c["score"])

        top = cands[0] if cands else None
        second = cands[1] if len(cands) > 1 else None
        # 「決めてよい」＝対応表で取引先が確定していて、金額も合っていて、対抗馬と差がある
        decided = bool(
            top and alias_client and top["bill"]["client"] == alias_client
            and top["diff"] <= FEE_TOLERANCE and top["diff"] >= -FEE_TOLERANCE
            and (not second or top["score"] - second["score"] >= 0.3))
        if decided:
            top["bill"]["remaining"] -= min(p["amount"], top["bill"]["remaining"])
        results.append({"pay": p, "cands": cands[:3], "decided": decided,
                        "alias_client": alias_client})

    return {"results": results, "open_bills": open_bills}


def learn_aliases(m: dict) -> list[tuple[str, str, str]]:
    """まだ対応表に無い振込名義について、証拠のある対応の案を出す（採否は社長）。

    根拠＝「金額がぴったり一致する請求が1件しかなく、対抗馬と差がある」。
    ここで自動的に表へ書き込まない（書けば、間違いも自動で固定化されるため）。
    """
    hits: dict[str, dict] = {}
    for r in m["results"]:
        if r["alias_client"] or not r["cands"]:
            continue
        top = r["cands"][0]
        second = r["cands"][1] if len(r["cands"]) > 1 else None
        if top["diff"] != 0 or (second and second["diff"] == 0):
            continue
        # 同じ振込名義が複数回出るのは普通（毎月払い）＝1行にまとめる。
        # ただし**別々の取引先に当たった**ときは、機械で決めてよい話ではないので提案しない。
        key = norm(r["pay"]["payer"])
        h = hits.setdefault(key, {"payer": r["pay"]["payer"], "clients": set(), "days": []})
        h["clients"].add(top["bill"]["client"])
        h["days"].append((r["pay"]["day"], r["pay"]["amount"]))

    props = []
    for h in hits.values():
        if len(h["clients"]) != 1:
            props.append((h["payer"], "【要確認】",
                          f"同じ名義が複数の取引先に当たりました＝人が決めてください"
                          f"（候補: {len(h['clients'])}社・{len(h['days'])}回）"))
            continue
        n = len(h["days"])
        d0, a0 = h["days"][0]
        why = (f"金額 {a0:,}円 が完全一致（{d0}）" if n == 1
               else f"{n}回とも金額が完全一致（{h['days'][0][0]}〜{h['days'][-1][0]}）")
        props.append((h["payer"], next(iter(h["clients"])), why))
    return props


def outstanding(m: dict) -> list[dict]:
    """取引先別の未回収残高（確定した消し込みを引いた後）。"""
    agg = defaultdict(lambda: {"amount": 0, "count": 0, "oldest": None})
    for b in m["open_bills"]:
        if b["remaining"] <= 0:
            continue
        k = b["client"] or "（補助科目なし）"
        a = agg[k]
        a["amount"] += b["remaining"]; a["count"] += 1
        if b["day"] and (a["oldest"] is None or b["day"] < a["oldest"]):
            a["oldest"] = b["day"]
    today = date.today()
    out = []
    for k, a in agg.items():
        out.append({"client": k, **a,
                    "days": (today - a["oldest"]).days if a["oldest"] else None})
    return sorted(out, key=lambda x: -x["amount"])


def atomic_write(path: Path, text: str, secret: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-")
    try:
        os.fchmod(fd, 0o600 if secret else 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def render_page(m: dict, props, out, bills, pays, problems) -> str:
    today = datetime.now().strftime("%Y-%m-%d %H:%M")
    total_bill = sum(b["amount"] for b in bills)
    total_pay = sum(p["amount"] for p in pays)
    undecided = [r for r in m["results"] if not r["decided"]]
    e = html.escape

    h = [f"""<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>売掛金の消し込み作業ページ｜株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-gray-50 text-gray-900"><div class="max-w-6xl mx-auto p-6 md:p-10">
<h1 class="text-2xl font-bold mb-1">💰 売掛金の消し込み — 作業ページ</h1>
<p class="text-sm text-gray-500 mb-6">生成 {today}／出典＝<span class="font-mono">data/financial/journal/</span>（読み取り専用・仕訳帳は書き換えていません）<br>
<strong class="text-red-700">このページは取引先名を含むため git 管理外です。</strong>社内・Tailscale 経由でのみ閲覧できます。</p>

<div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-8">
  <div class="bg-white border rounded p-4"><div class="text-xs text-gray-500">請求（借方=売掛金）</div>
    <div class="text-xl font-bold">{len(bills)}件</div><div class="text-sm">{total_bill:,}円</div></div>
  <div class="bg-white border rounded p-4"><div class="text-xs text-gray-500">入金（貸方=売掛金）</div>
    <div class="text-xl font-bold">{len(pays)}件</div><div class="text-sm">{total_pay:,}円</div></div>
  <div class="bg-green-50 border border-green-300 rounded p-4"><div class="text-xs text-green-700">対応表で確定した消し込み</div>
    <div class="text-xl font-bold text-green-800">{len(pays) - len(undecided)}件</div></div>
  <div class="bg-red-50 border border-red-300 rounded p-4"><div class="text-xs text-red-700">要確認（社長の判断待ち）</div>
    <div class="text-xl font-bold text-red-800">{len(undecided)}件</div></div>
</div>"""]

    if problems:
        h.append('<div class="bg-yellow-50 border-l-4 border-yellow-500 p-4 mb-6 text-sm"><strong>⚠️ 入力の不備</strong><ul class="list-disc ml-5">')
        h += [f"<li>{e(p)}</li>" for p in problems]
        h.append("</ul></div>")

    if props:
        h.append(f"""<h2 class="text-xl font-bold mt-8 mb-2 border-b pb-1">① 対応表に足す案 {len(props)}件</h2>
<p class="text-sm text-gray-600 mb-3">金額がぴったり一致する請求が1件しかなかったものです。
<strong>合っていれば下の行をそのまま <span class="font-mono">data/financial/payer-aliases.md</span> に貼ってください。</strong>
（AIは自動で書き込みません＝間違いをそのまま固定化しないため）</p>
<pre class="bg-gray-900 text-gray-100 text-xs p-4 rounded overflow-x-auto">""")
        h += [e(f"{p}\t{c}\t# {why}") + "\n" for p, c, why in props]
        h.append("</pre>")

    h.append(f"""<h2 class="text-xl font-bold mt-8 mb-2 border-b pb-1">② 要確認の入金 {len(undecided)}件</h2>
<p class="text-sm text-gray-600 mb-3">機械では決められなかったものです。候補を上位3件まで、根拠つきで並べています。</p>
<div class="overflow-x-auto"><table class="w-full text-sm border-collapse"><thead class="bg-gray-100"><tr>
<th class="border p-2 text-left">入金日</th><th class="border p-2 text-left">振込名義（摘要）</th>
<th class="border p-2 text-right">金額</th><th class="border p-2 text-left">候補（根拠）</th></tr></thead><tbody>""")
    for r in undecided:
        p = r["pay"]
        cand = "<br>".join(
            f'<span class="font-semibold">{e(c["bill"]["client"] or "（補助科目なし）")}</span>'
            f' <span class="text-gray-500">{c["bill"]["day"]}・{c["bill"]["amount"]:,}円</span>'
            f' <span class="text-xs text-blue-700">{e("／".join(c["reasons"]))}</span>'
            for c in r["cands"]) or '<span class="text-red-700">候補なし＝合算入金・前受・別勘定の可能性</span>'
        h.append(f'<tr class="align-top"><td class="border p-2">{p["day"]}</td>'
                 f'<td class="border p-2">{e(p["payer"])}</td>'
                 f'<td class="border p-2 text-right">{p["amount"]:,}</td>'
                 f'<td class="border p-2">{cand}</td></tr>')
    h.append("</tbody></table></div>")

    h.append(f"""<h2 class="text-xl font-bold mt-10 mb-2 border-b pb-1">③ 取引先別の未回収残高 {len(out)}社</h2>
<p class="text-sm text-gray-600 mb-3">確定した消し込みを引いた後の残高です。
<strong>対応表が育つほど、この数字が実態に近づきます。</strong></p>
<div class="overflow-x-auto"><table class="w-full text-sm border-collapse"><thead class="bg-gray-100"><tr>
<th class="border p-2 text-left">取引先</th><th class="border p-2 text-right">未回収</th>
<th class="border p-2 text-right">件数</th><th class="border p-2 text-left">最古の請求</th>
<th class="border p-2 text-right">経過</th></tr></thead><tbody>""")
    for o in out:
        aged = ' class="text-red-700 font-bold"' if (o["days"] or 0) >= 90 else ""
        h.append(f'<tr><td class="border p-2">{e(o["client"])}</td>'
                 f'<td class="border p-2 text-right">{o["amount"]:,}</td>'
                 f'<td class="border p-2 text-right">{o["count"]}</td>'
                 f'<td class="border p-2">{o["oldest"] or "—"}</td>'
                 f'<td class="border p-2 text-right"><span{aged}>{o["days"] if o["days"] is not None else "—"}日</span></td></tr>')
    h.append(f"""</tbody></table></div>
<p class="text-xs text-gray-500 border-t pt-4 mt-10">
再生成＝<span class="font-mono">python3 bin/ar-match.py --write</span>（読み取り専用・仕訳帳は変更しません）。<br>
⚠️ ここに出る「確定」は<strong>AIの照合結果であって会計処理ではありません</strong>。
実際の消し込みはマネーフォワード側で行う必要があります（このページは、その下ごしらえです）。</p>
</div></body></html>""")
    return "".join(h)


def main() -> int:
    ap = argparse.ArgumentParser(description="売掛金の消し込み候補を出す（読み取り専用）")
    ap.add_argument("--stats", action="store_true", help="件数だけ（固有名詞を出さない）")
    ap.add_argument("--write", action="store_true", help="CSV と作業ページも書き出す")
    a = ap.parse_args()

    rows, problems = read_journal()
    if not rows:
        for p in problems:
            print(p, file=sys.stderr)
        return 1
    aliases, alias_problems = load_aliases()
    problems += alias_problems

    bills, pays = split_ar(rows)
    m = match(bills, pays, aliases)
    props = learn_aliases(m)
    out = outstanding(m)
    undecided = [r for r in m["results"] if not r["decided"]]

    for p in problems:
        print(f"⚠️ {p}")
        print(f"⚠️ {p}", file=sys.stderr)

    print(f"■ 売掛金の消し込み（仕訳帳ベース・{date.today()}）")
    print(f"  請求（借方=売掛金）: {len(bills)}件 / {sum(b['amount'] for b in bills):,}円")
    print(f"  入金（貸方=売掛金）: {len(pays)}件 / {sum(p['amount'] for p in pays):,}円")
    print(f"  取引先が付いている入金: {sum(1 for p in pays if p['tagged'])}/{len(pays)} 件")
    print(f"  対応表 payer-aliases.md: {len(aliases)}件")
    print(f"  ✅ 確定した消し込み: {len(pays) - len(undecided)}件")
    print(f"  ❓ 要確認: {len(undecided)}件")
    print(f"  📝 対応表に足す案: {len(props)}件")
    print(f"  未回収の取引先: {len(out)}社 / {sum(o['amount'] for o in out):,}円")
    if out:
        old = [o for o in out if (o['days'] or 0) >= 90]
        print(f"  うち90日以上の滞留: {len(old)}社 / {sum(o['amount'] for o in old):,}円")

    if a.stats:
        return 0

    if props:
        print(f"\n【対応表に足す案】data/financial/payer-aliases.md に貼ってください")
        for p, c, why in props:
            print(f"  {p}\t{c}\t# {why}")

    if a.write:
        GENERATED.mkdir(parents=True, exist_ok=True)
        stamp = date.today().isoformat()
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["入金日", "振込名義", "入金額", "確定", "候補1", "候補1金額", "根拠", "候補2"])
        for r in m["results"]:
            c = r["cands"]
            w.writerow([r["pay"]["day"], r["pay"]["payer"], r["pay"]["amount"],
                        "確定" if r["decided"] else "要確認",
                        c[0]["bill"]["client"] if c else "", c[0]["bill"]["amount"] if c else "",
                        "／".join(c[0]["reasons"]) if c else "候補なし",
                        c[1]["bill"]["client"] if len(c) > 1 else ""])
        csv_path = GENERATED / f"ar-match-{stamp}.csv"
        atomic_write(csv_path, buf.getvalue())
        atomic_write(PAGE, render_page(m, props, out, bills, pays, problems), secret=False)
        print(f"\n→ {csv_path.relative_to(ROOT)}")
        print(f"→ {PAGE.relative_to(ROOT)}  （http://100.123.104.87/finance/ar-match.html）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
