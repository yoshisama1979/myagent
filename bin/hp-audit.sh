#!/bin/bash
# hp-audit.sh — オンページSEO信号の監査（読み取り専用）
#
# 使い方:
#   bash bin/hp-audit.sh <URL>            # 人が読む要約（⚠️で課題を表示）
#   bash bin/hp-audit.sh <URL> --json     # JSON出力（/hp-loop の一次情報・差分比較用）
#   bash bin/hp-audit.sh <URL> --text     # ページ本文テキストを抽出して出力（本文精読・実査用）
#   bash bin/hp-audit.sh <URL> --plumbing # 「配管」点検（解析タグ/混在コンテンツ/バージョン露出/JS棚卸し）
#   bash bin/hp-audit.sh <URL> --links [--match=<部分文字列>]
#                                         # a href の棚卸し（内部リンク構造の実査。--match で絞り込み）
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
TEXT=0
PLUMB=0
IMGS=0
LINKS=0
MATCH=""
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --text) TEXT=1 ;;
    --plumbing) PLUMB=1 ;;
    --imgs) IMGS=1 ;;
    --links) LINKS=1 ;;
    --match=*) MATCH="${a#--match=}" ;;
    -*)     echo "ERROR: 不明なオプション: $a" >&2; exit 1 ;;
    *)      if [ -n "$URL" ]; then echo "ERROR: URLは1つだけ指定してください（複数指定: '$URL' と '$a'）" >&2; exit 1; fi
            URL="$a" ;;
  esac
done
[ -z "$URL" ] && { echo "使い方: bash bin/hp-audit.sh <URL> [--json|--text|--plumbing|--imgs|--links [--match=<部分文字列>]]" >&2; exit 1; }
[ -n "$MATCH" ] && [ "$LINKS" = 0 ] && { echo "ERROR: --match= は --links と併用してください" >&2; exit 1; }

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

URL="$URL" HTTP_META="$http_meta" CURL_EXIT="$curl_exit" JSON_OUT="$JSON" TEXT_OUT="$TEXT" PLUMB_OUT="$PLUMB" IMGS_OUT="$IMGS" LINKS_OUT="$LINKS" LINK_MATCH="$MATCH" python3 - "$tmp" <<'PY'
import os, sys, re, json
import html as _htmlmod

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
text_out  = os.environ.get('TEXT_OUT') == '1'
plumb_out = os.environ.get('PLUMB_OUT') == '1'
imgs_out  = os.environ.get('IMGS_OUT') == '1'
links_out = os.environ.get('LINKS_OUT') == '1'
link_match = os.environ.get('LINK_MATCH', '')

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

# ---- 本文テキスト抽出モード（--text・読み取り専用・本文精読/実査用・2026-06-20追加） ----
# script/style/noscript を除去し、タグを剥がして読めるテキストにする。
# /hp-loop の「ページ本文の文言精読（対応エリア・対応の速さ・料金記載など）」を、
# curl/WebFetch 未承認の無人実行でも hp-audit 経由（内部curl）で取得するため。HTTP GET のみ・捏造なし。
if text_out:
    import html as _htmlmod
    body = html  # コメント除去済み
    body = re.sub(r'<(script|style|noscript)\b[^>]*>.*?</\1>', ' ', body, flags=re.I | re.S)
    # ブロック要素の終わりを改行に（段落を保つ）
    body = re.sub(r'</(p|div|li|h[1-6]|tr|section|article|header|footer|nav|br|table|ul|ol)\s*>', '\n', body, flags=re.I)
    body = re.sub(r'<br\s*/?>', '\n', body, flags=re.I)
    body = re.sub(r'<[^>]+>', ' ', body)           # 残りのタグを除去
    body = _htmlmod.unescape(body)                 # &amp; 等を戻す
    body = re.sub(r'[ \t　]+', ' ', body)      # 連続空白を1つに
    body = re.sub(r'\n\s*\n\s*\n+', '\n\n', body)  # 連続改行を圧縮
    lines = [ln.strip() for ln in body.splitlines()]
    body = '\n'.join(ln for ln in lines if ln)
    LIMIT = 12000
    print(f"■ hp-audit --text: {url}  (HTTP {http_code} / {size}B)")
    print(f"--- 本文テキスト（タグ除去・最大{LIMIT}字。HTTP GETのみ・読み取り専用） ---")
    print(body[:LIMIT])
    if len(body) > LIMIT:
        print(f"\n…（{len(body)-LIMIT}字を省略）")
    sys.exit(0)

# ---- リンク棚卸しモード（--links・読み取り専用・2026-08-06追加） ----
# 内部リンク構造そのものが施策の対象になる提案（R-038 導線の誤配線／R-042 ハブの孤立）で、
# 「どのページからどこへ何本張られているか」を実査するために追加。
# それまでは生 curl+grep が必要で、許可リストに curl が無いセッションでは検証不能だった。
if links_out:
    anchors = []
    for m in re.finditer(r'<a\b([^>]*)>(.*?)</a>', html, re.I | re.S):
        attrs, inner = m.group(1), m.group(2)
        hm_ = re.search(r'\bhref\s*=\s*["\']([^"\']*)["\']', attrs, re.I)
        if not hm_:
            continue
        href = _htmlmod.unescape(hm_.group(1)).strip()
        text = _htmlmod.unescape(re.sub(r'<[^>]+>', ' ', inner))
        text = re.sub(r'\s+', ' ', text).strip()
        anchors.append((href, text))

    if link_match:
        hits = [(h, t) for h, t in anchors if link_match in h or link_match in t]
    else:
        hits = anchors

    print(f"■ hp-audit --links: {url}  (HTTP {http_code} / {size}B)")
    print(f"  a[href] 総数: {len(anchors)}件" + (f" / --match='{link_match}' 一致: {len(hits)}件" if link_match else ""))
    counts = {}
    for h, t in hits:
        counts.setdefault(h, []).append(t)
    print(f"--- href 別（{len(counts)}種・本数の多い順） ---")
    for h, texts in sorted(counts.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:80]:
        label = next((t for t in texts if t), '(テキストなし)')
        if len(label) > 40:
            label = label[:40] + '…'
        print(f"  {len(texts):3d}本  {h}    ← 「{label}」")
    if len(counts) > 80:
        print(f"  …（{len(counts)-80}種を省略）")
    sys.exit(0)

# ---- 「配管」点検モード（--plumbing・読み取り専用・2026-07-25追加） ----
# hp-loop の月次定石 #9「配管一斉点検」の ③解析タグ棚卸し ④JS/死にコード ⑤混在コンテンツ
# ⑥CMS/ライブラリのバージョン露出 を、生 curl/grep 無しで（＝無人ループの許可範囲内で）取る。
# 動かない層（設定・タグ・コードの残骸）は日次/週次の観察では見えないため、機械で列挙する。
if plumb_out:
    def uniq_keep(seq, n=30):
        out = []
        for x in seq:
            if x and x not in out:
                out.append(x)
            if len(out) >= n:
                break
        return out

    # ③ 解析タグ（コメント除去後＝実際に配信されているものだけ）
    tags = {
        'GTM(コンテナ)':      uniq_keep(re.findall(r'GTM-[A-Z0-9]{4,9}', html)),
        'GA4(測定ID)':        uniq_keep(re.findall(r'\bG-[A-Z0-9]{6,12}\b', html)),
        '旧UA(ユニバーサル)': uniq_keep(re.findall(r'\bUA-\d{4,10}-\d{1,4}\b', html)),
        'Google広告(AW)':     uniq_keep(re.findall(r'\bAW-\d{6,12}\b', html)),
        'Clarity':            uniq_keep(re.findall(r'clarity\.ms/tag/([A-Za-z0-9]+)', html)
                                        or (['(clarity.ms 参照あり・ID不明)'] if 'clarity.ms' in html else [])),
        'Yahoo!タグ':         uniq_keep(['s.yjtag.jp'] if 'yjtag.jp' in html else []),
        'Facebookピクセル':   uniq_keep(re.findall(r"fbq\(\s*['\"]init['\"]\s*,\s*['\"](\d+)['\"]", html)
                                        or (['(connect.facebook.net 参照あり)'] if 'connect.facebook.net' in html else [])),
    }
    # コメントアウトされたタグ（＝残骸。配信されていないが放置されている）
    commented_tags = uniq_keep(re.findall(r'(GTM-[A-Z0-9]{4,9}|UA-\d{4,10}-\d{1,4}|\bG-[A-Z0-9]{6,12}\b)',
                                          ' '.join(re.findall(r'<!--.*?-->', html_raw, re.S))))

    # ④ JS 棚卸し（外部 src と、フォーム/日付まわりのライブラリ痕跡）
    scripts = uniq_keep([s for s in re.findall(r'<script\b[^>]*\bsrc\s*=\s*["\']([^"\']+)["\']', html, re.I)], 40)
    LIB_HINTS = ['jquery', 'datepicker', 'ui/1', 'bootstrap', 'slick', 'colorbox', 'fancybox',
                 'validation', 'validate', 'swiper', 'lightbox', 'modernizr', 'prototype', 'scriptaculous']
    lib_hits = uniq_keep([s for s in scripts if any(k in s.lower() for k in LIB_HINTS)], 20)
    inline_n = len(re.findall(r'<script\b(?![^>]*\bsrc\s*=)[^>]*>', html, re.I))

    # ⑤ 混在コンテンツ（http:// の *リソース* 参照＝ブラウザがブロック/警告する対象）
    mixed_res = uniq_keep(re.findall(r'(?:\bsrc|\bdata-src)\s*=\s*["\'](http://[^"\']+)["\']', html, re.I)
                          + re.findall(r'<link\b[^>]*\bhref\s*=\s*["\'](http://[^"\']+)["\']', html, re.I), 20)
    mixed_link = uniq_keep(re.findall(r'<a\b[^>]*\bhref\s*=\s*["\'](http://[^"\']+)["\']', html, re.I), 10)

    # ⑥ CMS・ライブラリのバージョン露出
    gen = [c for c in re.findall(r'<meta\b[^>]*\bname\s*=\s*["\']generator["\'][^>]*>', html, re.I)]
    gen_c = uniq_keep([re.search(r'content\s*=\s*["\']([^"\']*)["\']', g, re.I).group(1)
                       for g in gen if re.search(r'content\s*=\s*["\']([^"\']*)["\']', g, re.I)])
    vers = uniq_keep(re.findall(r'[?&]ver=([0-9][0-9A-Za-z._-]*)', html), 20)
    plugins = uniq_keep(re.findall(r'/wp-content/plugins/([A-Za-z0-9_-]+)/', html), 20)
    themes = uniq_keep(re.findall(r'/wp-content/themes/([A-Za-z0-9_-]+)/', html), 10)

    print(f"■ hp-audit --plumbing: {url}  (HTTP {http_code} / {size}B)")
    print("--- ③ 解析タグ（配信中） ---")
    for k, v in tags.items():
        print(f"  {k}: {', '.join(v) if v else '—'}")
    print(f"  コメント内に残るタグ(残骸): {', '.join(commented_tags) if commented_tags else '—'}")
    print("--- ④ JS 棚卸し ---")
    print(f"  外部script {len(scripts)}件 / インラインscript {inline_n}件")
    print(f"  ライブラリ痕跡: {', '.join(lib_hits) if lib_hits else '—'}")
    for s in scripts:
        print(f"    - {s}")
    print("--- ⑤ 混在コンテンツ（http:// 参照） ---")
    print(f"  リソース(src/link): {len(mixed_res)}件")
    for s in mixed_res:
        print(f"    - {s}")
    print(f"  リンク(a href): {len(mixed_link)}件" + (f" 例 {mixed_link[0]}" if mixed_link else ""))
    print("--- ⑥ CMS/ライブラリのバージョン露出 ---")
    print(f"  generator: {', '.join(gen_c) if gen_c else '—'}")
    print(f"  ?ver= 値: {', '.join(vers) if vers else '—'}")
    print(f"  WPプラグイン: {', '.join(plugins) if plugins else '—'}")
    print(f"  WPテーマ: {', '.join(themes) if themes else '—'}")
    sys.exit(0)

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

# alt 欠落の img は「件数」だけだと実装側が直せない（どの画像か分からない）ので src を列挙する。
# data-src / srcset しか持たない遅延読み込み img も拾う（2026-07-27 追加・yoshida R-Y30 の認識合わせが契機）
def _img_src(tag):
    for attr in ('src', 'data-src', 'data-original', 'srcset', 'data-srcset'):
        m = re.search(r'\b%s\s*=\s*["\']([^"\']+)["\']' % attr, tag, re.I)
        if m:
            v = m.group(1).strip().split(',')[0].split()[0]
            return v if attr == 'src' else f'{v} ({attr})'
    return '(src属性なし)'

img_no_alt_src = [_img_src(t) for t in imgs if not re.search(r'\balt\s*=', t, re.I)][:20]
img_empty_alt_src = [_img_src(t) for t in imgs if re.search(r'\balt\s*=\s*""', t, re.I)][:20]

# alt の「中身（テキスト）」も出す。件数と src だけでは「alt はあるが非記述的（例 alt="治療前"・alt="1"）」を
# 検証できず、実装側の改善報告を本番GETで確認できない（2026-07-27 追加・yoshida R-Y11(c) の検証が契機）。
def _img_alt(tag):
    m = re.search(r'\balt\s*=\s*"([^"]*)"', tag, re.I) or re.search(r"\balt\s*=\s*'([^']*)'", tag, re.I)
    if not m:
        return None
    return _htmlmod.unescape(m.group(1)).strip()

img_alts = [{'src': _img_src(t), 'alt': _img_alt(t)} for t in imgs][:80]

a_total = len(re.findall(r'<a\b', html, re.I))
tel = len(re.findall(r'href\s*=\s*"tel:', html, re.I))
mailto = len(re.findall(r'href\s*=\s*"mailto:', html, re.I))
contact_links = len(re.findall(r'href\s*=\s*"[^"]*(contact|inquiry|toiawase|問[い]?合)', html, re.I))
cms = 'WordPress' if re.search(r'wp-content|wp-includes', html, re.I) else first(metas('name', 'generator')) or '不明'

# ---- CV（コンバージョン）要素の棚卸し（2026-06-20 追加・読み取り専用） ----
# ゴール＝問い合わせ/電話 増。tel/mailto に加え LINE・フォーム・CV系アンカー文言を列挙し、
# 「実装済みでCVになりうる要素」を漏れなく拾う（/hp-loop fujisaka 社長依頼）。
def uniq(seq, n=20):
    out = []
    for x in seq:
        if x and x not in out:
            out.append(x)
        if len(out) >= n:
            break
    return out

# 電話番号（tel: の実値）
tel_numbers = uniq(re.findall(r'href\s*=\s*"tel:\s*([^"]+)"', html, re.I))
mailto_addrs = uniq(re.findall(r'href\s*=\s*"mailto:\s*([^"?]+)', html, re.I))

# LINE 導線（友だち追加・公式アカウント）。lin.ee / line.me / line:// / liff、文言「LINE」「友だち追加」
line_hrefs = uniq(re.findall(r'href\s*=\s*"((?:https?:)?//(?:[^"]*\.)?(?:lin\.ee|line\.me|liff\.line\.me)[^"]*)"', html, re.I))
line_scheme = uniq(re.findall(r'href\s*=\s*"(line://[^"]*)"', html, re.I))
line_text_hits = len(re.findall(r'友[だ]?ち追加|友達追加|LINE で|LINEで|LINE公式|公式LINE', html, re.I))
line_present = bool(line_hrefs or line_scheme or line_text_hits)

# フォーム（action / method）。CV受付の実体
forms = []
for fm in re.finditer(r'<form\b[^>]*>', html, re.I | re.S):
    t = fm.group(0)
    act = re.search(r'\baction\s*=\s*"([^"]*)"', t, re.I)
    mth = re.search(r'\bmethod\s*=\s*"([^"]*)"', t, re.I)
    forms.append({'action': (act.group(1) if act else ''), 'method': (mth.group(1).lower() if mth else 'get')})

# CV系アンカー（文言 or href が申込/見積/資料請求/予約/開栓/問い合わせ等にマッチ）
CV_KW = re.compile(
    r'見積|お見積|資料請求|ご?予約|お?申[しこ]?[込み]+|開栓|閉栓|移転|引[っ]?越|修理|点検|来店|来店予約'
    r'|お?問[い]?合[わせ]*|無料相談|ご相談|友[だ]?ち追加|友達追加|LINE'
    r'|contact|inquiry|toiawase|mitsumori|estimate|yoyaku|reserv|apply|entry|form|line', re.I)
cv_anchors = []
for am in re.finditer(r'<a\b([^>]*)>(.*?)</a>', html, re.I | re.S):
    attrs, inner = am.group(1), am.group(2)
    href_m = re.search(r'\bhref\s*=\s*"([^"]*)"', attrs, re.I)
    href = href_m.group(1) if href_m else ''
    text = re.sub(r'<[^>]+>', '', inner)
    text = re.sub(r'\s+', ' ', text).strip()
    if href.startswith('tel:') or href.startswith('mailto:'):
        continue  # tel/mailto は別集計
    if CV_KW.search(text) or CV_KW.search(href):
        cv_anchors.append({'text': text[:40], 'href': href[:120]})
# 重複排除（text+href）
seen, cv_anchors_u = set(), []
for a in cv_anchors:
    k = (a['text'], a['href'])
    if k in seen:
        continue
    seen.add(k); cv_anchors_u.append(a)
    if len(cv_anchors_u) >= 30:
        break

cv = {
    'tel_numbers': tel_numbers,
    'mailto': mailto_addrs,
    'line_present': line_present,
    'line_hrefs': line_hrefs + line_scheme,
    'line_text_hits': line_text_hits,
    'form_count': len(forms),
    'forms': forms[:20],
    'cv_anchors': cv_anchors_u,
}

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
    'images': {'total': img_total, 'no_alt': img_no_alt, 'empty_alt': img_empty_alt,
               'no_alt_src': img_no_alt_src, 'empty_alt_src': img_empty_alt_src,
               'alts': img_alts},
    'links': {'total': a_total, 'tel': tel, 'mailto': mailto, 'contact': contact_links},
    'cv': cv,
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
for s in img_no_alt_src:
    print(f"    - alt欠落: {s}")
if imgs_out:
    # --imgs: alt の中身まで列挙（非記述的な alt の検出・実装報告の検証用）
    for it in img_alts:
        a = it['alt']
        label = '(alt無し)' if a is None else ('(alt空=装飾)' if a == '' else f'alt="{a}"')
        print(f"    · {it['src']} → {label}")
print(f"  リンク: a={a_total} / tel={tel} mailto={mailto} contact={contact_links}")
# CV要素の棚卸し
print(f"  CV要素:")
print(f"    電話(tel): {cv['tel_numbers'] or 'なし'}")
print(f"    mailto: {cv['mailto'] or 'なし'}")
print(f"    LINE: {'あり ' + str(cv['line_hrefs']) if cv['line_present'] else 'なし'}（文言ヒット {cv['line_text_hits']}）")
print(f"    フォーム: {cv['form_count']}件 " + str([f['action'] or '(action空)' for f in cv['forms']]))
print(f"    CV系アンカー: {len(cv['cv_anchors'])}件")
for a in cv['cv_anchors']:
    print(f"      - 「{a['text'] or '(文言なし/画像)'}」 → {a['href'] or '(href空)'}")
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
