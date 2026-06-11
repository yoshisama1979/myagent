#!/bin/bash
# hp-audit.sh — オンページSEO信号の監査（読み取り専用）
#
# 使い方:
#   bash bin/hp-audit.sh <URL>            # 人が読む要約（⚠️で課題を表示）
#   bash bin/hp-audit.sh <URL> --json     # JSON出力（/hp-loop の一次情報・差分比較用）
#
# 取得する信号: HTTPステータス / title / meta description・keywords / canonical / robots /
#   viewport(ズーム禁止検出) / OGP・Twitterカード(プレースホルダ検出) / JSON-LD(型・無効化検出) /
#   見出し h1-h3(h1複数検出) / img と alt欠落 / 内部リンク・問い合わせ動線(tel/mailto/contact) / CMSヒント
#
# 注意: HTTP GET のみ。外部送信・ファイル書き込み・破壊的操作はしない（rules/automation.md 準拠）。
#       これは /hp-loop の Step 2「現状把握」の一次情報を、手作業 curl/grep の代わりに決定論的に取るためのツール。
set -euo pipefail

command -v curl    >/dev/null 2>&1 || { echo "ERROR: curl が必要です"    >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 が必要です" >&2; exit 1; }

URL=""
JSON=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    -*)     echo "ERROR: 不明なオプション: $a" >&2; exit 1 ;;
    *)      if [ -n "$URL" ]; then echo "ERROR: URLは1つだけ指定してください（複数指定: '$URL' と '$a'）" >&2; exit 1; fi
            URL="$a" ;;
  esac
done
[ -z "$URL" ] && { echo "使い方: bash bin/hp-audit.sh <URL> [--json]" >&2; exit 1; }

# URLスキームは http/https のみ許可（HTTP GET 要件。file:// 等を弾く）
case "$URL" in
  http://*|https://*) : ;;
  *) echo "ERROR: http:// または https:// のURLのみ対応します: $URL" >&2; exit 1 ;;
esac

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# HTTP取得。スキームをhttp/httpsに限定（リダイレクト先も）、サイズ上限5MB。
# 失敗時の exit code を捕捉して python 側で明示的に失敗扱いにする（成功を装わない）。
curl_exit=0
http_meta="$(curl -sSL \
  --proto '=http,https' --proto-redir '=http,https' \
  --connect-timeout 8 --max-time 25 --max-filesize 5000000 \
  -A 'Mozilla/5.0 (hanasaka-hp-audit; +internal-analysis)' \
  -o "$tmp" -w '%{http_code}\t%{url_effective}\t%{size_download}\t%{time_total}' "$URL")" || curl_exit=$?

URL="$URL" HTTP_META="$http_meta" CURL_EXIT="$curl_exit" JSON_OUT="$JSON" python3 - "$tmp" <<'PY'
import os, sys, re, json

path = sys.argv[1]
html_raw = open(path, encoding='utf-8', errors='replace').read()
# HTMLコメントを除去してから解析する（ブラウザ/クローラはコメント内タグを無視するため）。
# これをしないと、コメントアウトされた meta/og タグを「配信中」と誤検出する（T-001 の既知バグ修正・2026-06-11）。
html = re.sub(r'<!--.*?-->', ' ', html_raw, flags=re.S)
commented_meta = len(re.findall(r'<!--.*?</?meta.*?-->', html_raw, re.S | re.I))
url = os.environ.get('URL', '')
hm = os.environ.get('HTTP_META', '').split('\t')
http_code = hm[0] if len(hm) > 0 else ''
final_url = hm[1] if len(hm) > 1 else ''
size      = hm[2] if len(hm) > 2 else ''
ttime     = hm[3] if len(hm) > 3 else ''
curl_exit = os.environ.get('CURL_EXIT', '0')
json_out  = os.environ.get('JSON_OUT') == '1'

# --- 取得失敗の明示扱い（成功を装って空ページを監査しない） ---
# curl 異常終了（タイムアウト/DNS/プロトコル違反/サイズ超過）・非2xx・空body は監査不能とする
fetch_err = None
if curl_exit != '0':
    fetch_err = f'取得失敗（curl exit={curl_exit}：接続失敗/タイムアウト/サイズ超過等）'
elif not http_code.startswith('2'):
    fetch_err = f'HTTPステータスが非2xx（{http_code or "不明"}）'
elif not html_raw.strip():
    fetch_err = '応答ボディが空'

if fetch_err:
    if json_out:
        print(json.dumps({'url': url, 'final_url': final_url, 'http_code': http_code,
                          'curl_exit': curl_exit, 'size_bytes': size,
                          'fetch_ok': False, 'error': fetch_err}, ensure_ascii=False, indent=1))
    else:
        print(f"■ hp-audit: {url}")
        print(f"  ⛔ 監査不能：{fetch_err}")
        print(f"  HTTP {http_code or '—'} / curl_exit={curl_exit} / final={final_url or '—'}")
    sys.exit(3)

def tag_attr(tagre):
    return re.findall(tagre, html, re.I | re.S)

def metas(attr, key):
    # <meta {attr}="key" content="...">
    out = []
    for m in re.finditer(r'<meta\b[^>]*>', html, re.I | re.S):
        t = m.group(0)
        a = re.search(r'\b' + attr + r'\s*=\s*"([^"]*)"', t, re.I)
        c = re.search(r'\bcontent\s*=\s*"([^"]*)"', t, re.I)
        if a and a.group(1).lower() == key.lower():
            out.append(c.group(1) if c else '')
    return out

def meta_prefix(attr, prefix):
    out = {}
    for m in re.finditer(r'<meta\b[^>]*>', html, re.I | re.S):
        t = m.group(0)
        a = re.search(r'\b' + attr + r'\s*=\s*"([^"]*)"', t, re.I)
        c = re.search(r'\bcontent\s*=\s*"([^"]*)"', t, re.I)
        if a and a.group(1).lower().startswith(prefix.lower()):
            out[a.group(1).lower()] = c.group(1) if c else ''
    return out

# プレースホルダ判定（K-003: 本番に残る仮置きを検出）
PLACEHOLDER_RE = re.compile(
    r'^\s*$|^0+$|アイキャッチ|プレースホルダ|placeholder|lorem ipsum|\bdummy\b|\bsample\b|サンプル|ダミー|準備中'
    r'|ここに.{0,8}(入力|テキスト)|テキストを入力|例：|example\.com|no-?image|xxxx+|画像url|会社名$|サイト名$',
    re.I)
def is_placeholder(v):
    return bool(PLACEHOLDER_RE.search((v or '').strip()))

def first(lst):
    return lst[0] if lst else ''

# ---- 収集 ----
title = first([re.sub(r'\s+', ' ', t).strip() for t in re.findall(r'<title[^>]*>(.*?)</title>', html, re.I | re.S)])
desc = first(metas('name', 'description'))
keywords = first(metas('name', 'keywords'))
robots = first(metas('name', 'robots'))
viewport = first(metas('name', 'viewport'))
canonical = [m.group(1) for m in re.finditer(r'<link\b[^>]*\brel\s*=\s*"canonical"[^>]*\bhref\s*=\s*"([^"]*)"', html, re.I)]
if not canonical:  # href が rel より前の並びも拾う
    canonical = [re.search(r'href\s*=\s*"([^"]*)"', m.group(0), re.I).group(1)
                 for m in re.finditer(r'<link\b[^>]*\brel\s*=\s*"canonical"[^>]*>', html, re.I)
                 if re.search(r'href\s*=\s*"([^"]*)"', m.group(0), re.I)]

ogp = meta_prefix('property', 'og:')
twitter = meta_prefix('name', 'twitter:')

# JSON-LD
ldjson = []
for m in re.findall(r'<script[^>]*type\s*=\s*"application/ld\+json"[^>]*>(.*?)</script>', html, re.I | re.S):
    s = m.strip()
    types, parse_ok = [], False
    try:
        d = json.loads(s); parse_ok = True
        items = d if isinstance(d, list) else [d]
        for it in items:
            if isinstance(it, dict) and it.get('@type'):
                types.append(it['@type'])
    except Exception:
        parse_ok = False
    disabled = ('/*' in s and '*/' in s) or s.strip().startswith('<!--')
    ldjson.append({'types': types, 'parse_ok': parse_ok, 'looks_disabled': disabled})

h1 = re.findall(r'<h1\b', html, re.I)
h2 = re.findall(r'<h2\b', html, re.I)
h3 = re.findall(r'<h3\b', html, re.I)

imgs = re.findall(r'<img\b[^>]*>', html, re.I)
img_total = len(imgs)
img_no_alt = sum(1 for t in imgs if not re.search(r'\balt\s*=', t, re.I))
img_empty_alt = sum(1 for t in imgs if re.search(r'\balt\s*=\s*""', t, re.I))

a_total = len(re.findall(r'<a\b', html, re.I))
tel = len(re.findall(r'href\s*=\s*"tel:', html, re.I))
mailto = len(re.findall(r'href\s*=\s*"mailto:', html, re.I))
contact_links = len(re.findall(r'href\s*=\s*"[^"]*(contact|inquiry|toiawase|問[い]?合)', html, re.I))
cms = 'WordPress' if re.search(r'wp-content|wp-includes', html, re.I) else first(metas('name', 'generator')) or '不明'

# ---- 課題フラグ ----
issues = []
def L(v): return len(v) if v else 0
if not title: issues.append('title が無い')
elif not (10 <= len(title) <= 35): issues.append(f'title 文字数が範囲外({len(title)}字・推奨10〜35)')
if not desc: issues.append('meta description が無い')
elif not (50 <= len(desc) <= 140): issues.append(f'meta description 文字数が範囲外({len(desc)}字・推奨50〜140)')
if not canonical: issues.append('canonical が未設定')
if viewport and re.search(r'user-scalable\s*=\s*no|maximum-scale\s*=\s*1', viewport, re.I):
    issues.append('viewport がズーム禁止(user-scalable=no / maximum-scale=1)')
if not ogp: issues.append('OGP(og:*) が無い')
else:
    ph = [k for k, v in ogp.items() if is_placeholder(v)]
    if ph: issues.append('OGP がプレースホルダのまま: ' + ', '.join(sorted(ph)))
if not twitter: issues.append('Twitterカード(twitter:*) が無い')
if not ldjson: issues.append('構造化データ(JSON-LD)が無い')
else:
    if any(l['looks_disabled'] for l in ldjson): issues.append('JSON-LD がコメントアウト/無効化されている疑い')
    if any(not l['parse_ok'] for l in ldjson): issues.append('JSON-LD のパースに失敗(壊れている疑い)')
if len(h1) == 0: issues.append('h1 が無い')
elif len(h1) > 1: issues.append(f'h1 が複数({len(h1)}個・主題が曖昧)')
if img_no_alt: issues.append(f'alt欠落の img が {img_no_alt}件')
if tel + mailto + contact_links == 0: issues.append('問い合わせ動線(tel/mailto/contact)が見当たらない')

result = {
    'url': url, 'final_url': final_url, 'http_code': http_code,
    'fetch_ok': True, 'curl_exit': curl_exit,
    'size_bytes': size, 'time_sec': ttime, 'cms': cms,
    'title': title, 'title_len': L(title),
    'description': desc, 'description_len': L(desc),
    'keywords_present': bool(keywords),
    'canonical': canonical, 'robots': robots, 'viewport': viewport,
    'ogp': ogp, 'twitter': twitter, 'jsonld': ldjson,
    'headings': {'h1': len(h1), 'h2': len(h2), 'h3': len(h3)},
    'images': {'total': img_total, 'no_alt': img_no_alt, 'empty_alt': img_empty_alt},
    'links': {'total': a_total, 'tel': tel, 'mailto': mailto, 'contact': contact_links},
    'commented_meta_tags': commented_meta,
    'issues': issues,
}

if os.environ.get('JSON_OUT') == '1':
    print(json.dumps(result, ensure_ascii=False, indent=1))
    sys.exit(0)

# 人が読む要約
def yn(b): return 'あり' if b else 'なし'
print(f"■ hp-audit: {url}")
print(f"  HTTP {http_code} / final={final_url} / {size}B / {ttime}s / CMS={cms}")
print(f"  title({result['title_len']}字): {title or '—'}")
print(f"  description({result['description_len']}字): {(desc[:80]+'…') if desc and len(desc)>80 else (desc or '—')}")
print(f"  canonical: {canonical or 'なし'} / robots: {robots or 'なし'} / keywords: {yn(bool(keywords))}")
print(f"  viewport: {viewport or 'なし'}")
print(f"  OGP: {len(ogp)}件 {sorted(ogp.keys()) if ogp else ''} / Twitter: {len(twitter)}件")
print(f"  JSON-LD: {len(ldjson)}件 " + (str([l['types'] for l in ldjson]) if ldjson else ''))
print(f"  見出し: h1={result['headings']['h1']} h2={result['headings']['h2']} h3={result['headings']['h3']}")
print(f"  img: {img_total}件 (alt欠落 {img_no_alt} / alt空 {img_empty_alt})")
print(f"  リンク: a={a_total} / tel={tel} mailto={mailto} contact={contact_links}")
if commented_meta:
    print(f"  ※ HTMLコメント内の meta/og タグ {commented_meta}件 は解析から除外（＝配信されていない）")
print("")
if issues:
    print(f"  ⚠️ 課題 {len(issues)}件:")
    for i in issues:
        print(f"    - {i}")
else:
    print("  ✅ 主要なオンページ課題は検出されず")
PY
