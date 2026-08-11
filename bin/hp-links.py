#!/usr/bin/env python3
"""hp-links.py — ページのリンク棚卸し（読み取り専用・T-021）

使い方:
  bin/.venv/bin/python3 bin/hp-links.py <URL>              # リンク一覧（アンカー文言＋リンク先）
  bin/.venv/bin/python3 bin/hp-links.py <URL> --check      # 内部リンクの HTTP ステータスも見る（HEAD/GET）
  bin/.venv/bin/python3 bin/hp-links.py <URL> --filter foo # リンク先に foo を含むものだけ

何のためか:
  hp-audit.sh はリンクを「本数」でしか出さないため、「どのアンカー文言で・どこへ」が分からない。
  内部リンク設計（文脈内リンクの有無）・発リンク元としての価値・死にリンクの検出に必要。

注意: HTTP GET / HEAD のみ。外部送信・ファイル書き込み・破壊的操作はしない（rules/automation.md 準拠）。
      --check は内部リンク（同一ホスト）だけを対象にする（他所のサーバを叩かない）。
"""
import argparse
import re
import sys
import urllib.parse
import urllib.request

UA = "Mozilla/5.0 (hanasaka-hp-links; +internal-analysis)"
A_TAG = re.compile(r"<a\b([^>]*)>(.*?)</a>", re.I | re.S)
HREF = re.compile(r"""\bhref\s*=\s*["']([^"']+)["']""", re.I)
TAG = re.compile(r"<[^>]+>")
WS = re.compile(r"\s+")


def fetch(url, method="GET"):
    req = urllib.request.Request(url, headers={"User-Agent": UA}, method=method)
    with urllib.request.urlopen(req, timeout=25) as res:
        body = res.read(5_000_000) if method == "GET" else b""
        return res.status, res.geturl(), body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--check", action="store_true", help="内部リンクのHTTPステータスを確認")
    ap.add_argument("--filter", default="", help="リンク先に含まれる文字列で絞り込む")
    args = ap.parse_args()

    if not args.url.startswith(("http://", "https://")):
        sys.exit("ERROR: http:// または https:// のURLのみ対応します")

    try:
        status, final_url, body = fetch(args.url)
    except Exception as e:  # 取得失敗は成功を装わない
        sys.exit(f"ERROR: 取得失敗 {args.url}: {e}")

    html = body.decode("utf-8", errors="replace")
    # コメント内のリンクはブラウザ/クローラが辿らないので除去してから解析する
    html = re.sub(r"<!--.*?-->", "", html, flags=re.S)
    host = urllib.parse.urlparse(final_url).netloc

    print(f"■ hp-links: {final_url}  (HTTP {status})")

    seen = []
    for attrs, inner in A_TAG.findall(html):
        m = HREF.search(attrs)
        if not m:
            continue
        href = m.group(1).strip()
        if href.startswith(("#", "javascript:")):
            continue
        text = WS.sub(" ", TAG.sub(" ", inner)).strip()
        # 画像リンク等でテキストが無い場合は alt を拾う
        if not text:
            alt = re.search(r"""\balt\s*=\s*["']([^"']*)["']""", inner, re.I)
            text = f"[img alt: {alt.group(1)}]" if alt and alt.group(1) else "(テキスト無)"
        absu = urllib.parse.urljoin(final_url, href)
        if args.filter and args.filter not in absu:
            continue
        internal = urllib.parse.urlparse(absu).netloc == host
        seen.append((text, href, absu, internal))

    if not seen:
        print("  （該当リンクなし）")
        return

    # 同じ (文言, リンク先) の重複は件数にまとめる（グローバルナビ等で膨らむため）
    counts = {}
    order = []
    for text, href, absu, internal in seen:
        key = (text, absu, internal)
        if key not in counts:
            counts[key] = 0
            order.append(key)
        counts[key] += 1

    checked = {}
    print(f"--- リンク一覧（{len(seen)}本 / ユニーク {len(order)}本） ---")
    for text, absu, internal in order:
        n = counts[(text, absu, internal)]
        mark = "内" if internal else "外"
        dup = f" ×{n}" if n > 1 else ""
        line = f"  [{mark}] {text[:48]:<48} -> {absu}{dup}"
        if args.check and internal:
            if absu not in checked:
                try:
                    st, _, _ = fetch(absu, method="HEAD")
                    checked[absu] = str(st)
                except Exception as e:
                    code = getattr(e, "code", None)
                    checked[absu] = str(code) if code else f"ERR({type(e).__name__})"
            st = checked[absu]
            flag = "" if st == "200" else "  ⚠️"
            line += f"  [HTTP {st}]{flag}"
        print(line)

    if args.check:
        bad = sorted({u: s for u, s in checked.items() if s != "200"}.items())
        print(f"--- 内部リンクの状態: 確認 {len(checked)}本 / 非200 {len(bad)}本 ---")
        for u, s in bad:
            print(f"  ⚠️ HTTP {s}  {u}")


if __name__ == "__main__":
    main()
