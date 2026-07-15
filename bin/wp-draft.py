#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bin/wp-draft.py — WordPress に「下書き(status=draft)」を作るだけの最小クライアント。

blog-write モードの Phase 2 用。blog-loop/blog-write が作った記事ドラフトを、対象クライアントの
WordPress REST API に **下書きとして** 投稿する（公開はしない）。

設計（automation.md 準拠）:
  - 本文は投稿前に Gutenberg ブロック化する（生HTMLのままだと WP が全体を「クラシック
    (freeform)ブロック」に包み『非推奨のクラシックブロックを使おうとしています』の検証
    エラー＋レイアウト崩れになるため）。属性なしの p / h1-h6 は native ブロック、
    それ以外（スタイル付きの表・囲み等）は wp:html でレイアウトを変えず包む。
    --no-blocks で無効化可（既に <!-- wp: --> を含む本文は二重変換しない）。
  - 書き込みは status=draft のみ。publish は不可（--status は draft 固定。他値はエラーで停止）。
  - 既存記事の本番上書きはしない（このスクリプトは新規 draft の作成だけ。post 更新機能は持たない）。
  - 秘密情報：ユーザー名・アプリパスワードは .env の <CLIENT>_WP_USER / <CLIENT>_WP_APP_PASSWORD を
    読むだけ。ログ・標準出力・エラーには出さない（Authorization ヘッダも表示しない）。
  - 依存ゼロ：標準ライブラリ（urllib）のみ。
  - check サブコマンドは読み取り専用（GET /users/me）で、書き込み前に認証だけ検証する。

使い方:
  bin/wp-draft.py check  --client ycom
      認証を検証（書き込みなし）。誰として・どんな権限で繋がるかを表示。
  bin/wp-draft.py get    --client ycom --id 2082
      投稿/下書きの内容を取得（読み取り専用）。既存記事の改善（blog-improve）の素材に。
  bin/wp-draft.py post   --client ycom --title "タイトル" --html-file path/to/body.html [--dry-run]
      本文HTMLファイルを status=draft で新規投稿。--dry-run は送信内容の要約だけ表示して投稿しない。
  bin/wp-draft.py update --client ycom --id 8311 --html-file path/to/body.html [--title "…"] [--dry-run]
      既存の「下書き(draft)」を更新（重複を作らずデザイン改訂を反映）。対象が draft でなければ更新しない（公開済みは触らない）。

.env に必要なキー（クライアント別・接頭辞はクライアントキーの大文字）:
  YCOM_WP_API_BASE=https://y-com.info/contents/?rest_route=/wp/v2
  YCOM_WP_USER=＜アプリパスワードを発行したWPユーザーのログイン名＞
  YCOM_WP_APP_PASSWORD=＜発行されたアプリケーションパスワード（スペース有無どちらでも可）＞
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser


def err(msg):
    print(msg, file=sys.stderr)


def _env(key):
    """環境変数 → .env の順で必要キーだけ読む（全体は読み込まない・gsc-fetch.py と同作法）。"""
    v = os.environ.get(key)
    if v:
        return v
    try:
        with open(".env", encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s.startswith(key + "="):
                    val = s[len(key) + 1:].strip()
                    # 値を囲む引用符は誤って認証情報に混入するので除去
                    if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                        val = val[1:-1]
                    return val
    except FileNotFoundError:
        pass
    return None


_CLIENT_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


# API_BASE は次の2形式のみ許可（誤設定・更新エンドポイント化けを防ぐ）
_BASE_RE = re.compile(r"^https://\S+?(?:/wp-json/wp/v2|\?rest_route=/wp/v2)$")
# 投稿ID：ASCII の正整数（1〜10桁）。全角数字・符号・空白・巨大値を弾く
_ID_RE = re.compile(r"^[1-9][0-9]{0,9}$")


def load_creds(client):
    if not _CLIENT_RE.match(client or ""):
        err(f"ERROR: 不正な client キー: {client!r}（英小文字・数字・_・- のみ）")
        sys.exit(2)
    prefix = re.sub(r"[^A-Z0-9]", "_", client.upper()) + "_WP_"
    base = _env(prefix + "API_BASE")
    user = _env(prefix + "USER")
    pw = _env(prefix + "APP_PASSWORD")
    missing = [prefix + k for k, v in
               (("API_BASE", base), ("USER", user), ("APP_PASSWORD", pw)) if not v]
    if missing:
        err("ERROR: .env に未設定のキーがあります: " + ", ".join(missing))
        err("       （blog-write のルール参照。アプリケーションパスワードを発行して設定してください）")
        sys.exit(3)
    # アプリパスワードはスペース区切りで表示されるが認証時は詰めてよい
    pw = pw.replace(" ", "")
    base = base.strip()
    if not _BASE_RE.match(base):
        err(f"ERROR: 不正な API_BASE 形式です（許可: .../wp-json/wp/v2 または .../?rest_route=/wp/v2）: {base!r}")
        sys.exit(3)
    return base, user, pw


def _auth_header(user, pw):
    token = base64.b64encode(f"{user}:{pw}".encode("utf-8")).decode("ascii")
    return "Basic " + token


def _endpoint(base, path, params=None):
    """rest_route 形式（?rest_route=/wp/v2）と pretty 形式（/wp-json/wp/v2）の両対応で URL を組む。"""
    url = base.rstrip("/") + path  # 例: ".../wp/v2" + "/posts"
    if params:
        sep = "&" if "?" in url else "?"
        url += sep + "&".join(f"{k}={urllib.parse.quote(str(v))}" for k, v in params.items())
    return url


def _request(url, user, pw, method="GET", payload=None, timeout=20):
    data = None
    headers = {"Authorization": _auth_header(user, pw), "Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        return e.code, body
    except urllib.error.URLError as e:
        err(f"ERROR: 接続失敗: {e.reason}")
        sys.exit(4)


def _err_body(body, limit=300):
    """エラー本文を安全に要約：JSONなら code/message/status のみ、非JSONはタグ除去して短く。
    HTML（WAF/デバッグ画面）や予期せぬ文字列をそのまま大量に出さない。"""
    try:
        j = json.loads(body)
        if isinstance(j, dict):
            st = (j.get("data") or {}).get("status") if isinstance(j.get("data"), dict) else None
            return f"code={j.get('code')} message={j.get('message')} status={st}"
    except ValueError:
        pass
    text = re.sub(r"<[^>]+>", "", body or "")      # タグ除去
    # 秘密の漏れ防止：WAF/プロキシ等が混ぜ得る認証情報を redact（Authorization / Basic <token>）
    text = re.sub(r"(?i)authorization\s*[:=]\s*\S+", "Authorization=[redacted]", text)
    text = re.sub(r"(?i)\bbasic\s+[A-Za-z0-9+/=]+", "Basic [redacted]", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def _cred_diag(user, pw):
    """秘密を出さずに桁数・形式だけ表示（.env 混入や引用符の切り分け用）。"""
    only_alnum = bool(re.fullmatch(r"[A-Za-z0-9]+", pw or ""))
    err("       --- 認証情報の形式（実値は出しません） ---")
    err(f"       USER: 長さ {len(user)} 文字")
    err(f"       APP_PASSWORD: 長さ {len(pw)} 文字（スペース除去後）"
        + "／WPの正しい値は通常 24 文字" + ("" if len(pw) == 24 else " ← ここが24でないと値が不正の疑い"))
    err(f"       APP_PASSWORD は英数字のみか: {only_alnum}"
        + ("" if only_alnum else " ← 記号混入＝引用符などの可能性"))


def cmd_check(args):
    base, user, pw = load_creds(args.client)
    url = _endpoint(base, "/users/me", {"context": "edit"})
    status, body = _request(url, user, pw, "GET")
    if status != 200:
        err(f"ERROR: 認証チェック失敗 HTTP {status}")
        err("       詳細: " + _err_body(body))
        _cred_diag(user, pw)
        err("       → 桁数が正常(24)なら、サーバが Authorization ヘッダを PHP に渡していない疑い。")
        sys.exit(5)
    try:
        me = json.loads(body)
    except ValueError:
        err("ERROR: レスポンスがJSONでない（API_BASE が違う可能性）。詳細: " + _err_body(body))
        sys.exit(5)
    caps = me.get("capabilities", {}) or {}
    print("✅ 認証OK（書き込みはしていません）")
    print(f"  接続ユーザー: {me.get('name')} (slug={me.get('slug')}, id={me.get('id')})")
    print(f"  ロール: {', '.join(me.get('roles', [])) or '不明'}")
    print(f"  下書き作成可(edit_posts): {bool(caps.get('edit_posts'))} / 公開可(publish_posts): {bool(caps.get('publish_posts'))}")
    print(f"  API_BASE: {base}")
    if caps.get("publish_posts") or caps.get("edit_published_posts"):
        print("  ⚠️ このユーザーは公開/公開記事編集の権限を持ちます。無人ループ用には"
              " publish 権限の無い専用ユーザー（例：寄稿者=Contributor）でアプリパスワードを発行するのを推奨"
              "（万一の TOCTOU でも公開記事の誤上書き・誤公開を WP 権限で物理的に防ぐ）。")


def _extract_body(html):
    """ドラフトHTMLから <article>…</article> の中身を取り出す。無ければ全体を返す。
    レビュー用マーカー（▼ここから/▲ここまで の注記）は除去する。"""
    m = re.search(r"<article\b[^>]*>(.*?)</article>", html, re.S | re.I)
    content = m.group(1) if m else html
    # レビュー用の注記段落を除去
    content = re.sub(r"<p[^>]*>\s*[▼▲][^<]*</p>", "", content)
    return content.strip()


# --- Gutenberg ブロック化 --------------------------------------------------
# 生HTMLをそのまま content で投げると、WP のブロックエディタが記事全体を1つの
# 「クラシック(freeform)ブロック」に包み、『非推奨のクラシックブロックを使おうと
# しています』の検証エラー＋レイアウト崩れになる。これを防ぐため、投稿前に
# トップレベル要素をブロック区切り(<!-- wp:... -->)で包んでから送る。
_VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input",
              "link", "meta", "param", "source", "track", "wbr"}


class _TopLevelSplitter(HTMLParser):
    """HTML を「トップレベル要素」ごとの (start, end) スパンに分割する（stdlibのみ）。
    ネストは depth で数え、depth が 0→1→…→0 に戻った所を1要素の境界とする。"""

    def __init__(self, src):
        super().__init__(convert_charrefs=False)
        self.src = src
        # 行頭の絶対オフセット表（getpos の (line,col) を絶対位置に直すため）
        self.line_off = [0]
        for i, ch in enumerate(src):
            if ch == "\n":
                self.line_off.append(i + 1)
        self.depth = 0
        self.cur_start = None
        self.spans = []

    def _off(self):
        line, col = self.getpos()
        return self.line_off[line - 1] + col

    def _close_span_from(self, start):
        # 終了タグ（`</tag>`＝属性を持たない）の位置から、その '>' の直後までを終端とする。
        # 開始タグには使わない（属性値内に '>' があると誤って切れるため。_open_tag_span を使う）。
        gt = self.src.find(">", start)
        return (gt + 1) if gt != -1 else len(self.src)

    def _open_tag_span(self):
        # 開始タグ／自己終了タグは、その実テキスト長で終端を出す
        # （属性値内の '>' 例: <img alt="変更前 > 変更後"> で切れないよう find('>') を使わない）。
        s = self._off()
        raw = self.get_starttag_text() or ""
        return (s, s + len(raw))

    def handle_starttag(self, tag, attrs):
        if tag.lower() in _VOID_TAGS:
            if self.depth == 0:
                self.spans.append(self._open_tag_span())
            return
        if self.depth == 0:
            self.cur_start = self._off()
        self.depth += 1

    def handle_startendtag(self, tag, attrs):
        if self.depth == 0:
            self.spans.append(self._open_tag_span())

    def handle_endtag(self, tag):
        if self.depth == 0:
            return  # 迷子の終了タグは無視
        self.depth -= 1
        if self.depth == 0 and self.cur_start is not None:
            self.spans.append((self.cur_start, self._close_span_from(self._off())))
            self.cur_start = None


def _top_level_nodes(src):
    """src を [("el", 要素HTML) | ("raw", 素の断片)] のトップレベル列に分割。"""
    sp = _TopLevelSplitter(src)
    sp.feed(src)
    sp.close()
    spans = sorted(sp.spans)
    nodes, cursor = [], 0
    for s, e in spans:
        between = src[cursor:s]
        if between.strip():
            nodes.append(("raw", between))
        nodes.append(("el", src[s:e]))
        cursor = e
    tail = src[cursor:]
    if tail.strip():
        nodes.append(("raw", tail))
    return nodes


def _wrap_block(html):
    """1つのトップレベル要素を適切な Gutenberg ブロックで包む。
    属性なしの p / h1-h6 だけ native ブロック（管理画面でリッチ編集可）に、
    それ以外（スタイル付きの表・囲み・リスト等）は wp:html で verbatim に包む
    （レイアウトを変えず・クラシック警告も検証エラーも出さない）。"""
    body = html.strip()
    # native 化は「厳密な <p> / <hN>（小文字・属性なし・余分な空白なし）」だけに限定する。
    # <P>（大文字）・<p >（空白）・<p class=…>（属性）は Gutenberg の再生成マークアップと
    # 差が出て検証エラーになり得るので、native にせず wp:html で verbatim に包む（安全側）。
    m = re.match(r"<(p|h[1-6])>", body)
    if m:
        tag = m.group(1)
        if tag == "p":
            return "<!-- wp:paragraph -->\n%s\n<!-- /wp:paragraph -->" % body
        level = int(tag[1])
        meta = "" if level == 2 else ' {"level":%d}' % level  # 既定レベルは2
        return "<!-- wp:heading%s -->\n%s\n<!-- /wp:heading -->" % (meta, body)
    return "<!-- wp:html -->\n%s\n<!-- /wp:html -->" % body


def to_gutenberg_blocks(content):
    """生HTML本文を Gutenberg ブロックマークアップへ変換して返す。"""
    nodes = _top_level_nodes(content)
    if not nodes:
        c = content.strip()
        return "<!-- wp:html -->\n%s\n<!-- /wp:html -->" % c if c else ""
    out = []
    for kind, raw in nodes:
        if kind == "raw":
            # 説明用HTMLコメント等を除去し、実体が残るものだけ wp:html で包む
            cleaned = re.sub(r"<!--.*?-->", "", raw, flags=re.S).strip()
            if cleaned:
                out.append("<!-- wp:html -->\n%s\n<!-- /wp:html -->" % cleaned)
        else:
            out.append(_wrap_block(raw))
    return "\n\n".join(out)


def _blockify(content, enable):
    """投稿直前に content をブロック化。戻り値 (content, 説明ラベル)。
    既にブロック区切りを含む場合と --no-blocks 指定時は変換しない。"""
    if not enable:
        return content, "スキップ(--no-blocks・生HTMLのまま=クラシックブロック警告の恐れ)"
    if "<!-- wp:" in content:
        return content, "変換なし(既にブロック区切りあり)"
    blocks = to_gutenberg_blocks(content)
    n = blocks.count("<!-- wp:")   # 開きデリミタ数＝ブロック数（"<!-- /wp:" は一致しない）
    return blocks, "%d ブロックに変換(クラシックブロック回避)" % n


def cmd_post(args):
    base, user, pw = load_creds(args.client)
    try:
        with open(args.html_file, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        err(f"ERROR: 本文HTMLが見つかりません: {args.html_file}")
        sys.exit(2)
    had_article = bool(re.search(r"<article\b", raw, re.I)) if args.extract else None
    content = _extract_body(raw) if args.extract else raw.strip()
    if not args.title.strip() or not content:
        err("ERROR: タイトルか本文が空です。")
        sys.exit(2)
    content, block_note = _blockify(content, not args.no_blocks)

    posts_url = _endpoint(base, "/posts")   # 常にコレクション（/posts/<id> は作らない＝既存記事の更新に化けない）
    payload = {"title": args.title, "content": content, "status": "draft"}
    print(f"投稿先: {posts_url}")
    print(f"タイトル: {args.title}")
    print(f"本文: {len(content)} 文字（元HTML {len(raw)} 文字）/ status=draft（下書き・非公開）")
    print(f"  ブロック化: {block_note}")
    if args.extract:
        print(f"  抽出(--extract)：<article>検出={had_article}")
    if args.dry_run:
        print("※ --dry-run のため送信しません。内容を確認してください。")
        print("--- 変換後 content の先頭プレビュー（最大800字）---")
        print(content[:800])
        return

    status, body = _request(posts_url, user, pw, "POST", payload)
    if status not in (200, 201):
        err(f"ERROR: 投稿失敗 HTTP {status}")
        err("       詳細: " + _err_body(body))
        sys.exit(6)
    try:
        post = json.loads(body)
    except ValueError:
        err("ERROR: レスポンスがJSONでない。詳細: " + _err_body(body))
        sys.exit(6)
    new_id, new_status = post.get("id"), post.get("status")
    if not new_id or new_status != "draft":
        err(f"ERROR: 下書き化を確認できません: id={new_id} status={new_status!r}")
        err("       publish 等に化けた可能性。WP管理画面で当該投稿を確認し、必要なら削除してください。")
        sys.exit(7)
    print("✅ 下書きを作成しました（status=draft を確認・publish していません）")
    print(f"  投稿ID: {new_id} / status: {new_status}")
    print(f"  プレビュー(link): {post.get('link')}")
    print(f"  編集URL: 管理画面 → 投稿 → 下書き（ID {new_id}）")


def cmd_get(args):
    """投稿/下書きの内容を取得（読み取り専用）。既存記事の改善（blog-improve）の素材に使う。"""
    base, user, pw = load_creds(args.client)
    pid = str(args.id).strip()
    if not _ID_RE.match(pid):
        err("ERROR: --id は正の整数（投稿ID・1〜10桁・半角）で指定してください。")
        sys.exit(2)
    url = _endpoint(base, f"/posts/{pid}", {"context": "edit"})
    status, body = _request(url, user, pw, "GET")
    if status != 200:
        err(f"ERROR: 投稿ID {pid} の取得に失敗 HTTP {status}")
        err("       詳細: " + _err_body(body))
        sys.exit(6)
    try:
        post = json.loads(body)
    except ValueError:
        err("ERROR: レスポンスがJSONでない。詳細: " + _err_body(body))
        sys.exit(6)
    title = (post.get("title") or {})
    content = (post.get("content") or {})
    print(f"# id={post.get('id')} status={post.get('status')} link={post.get('link')}")
    print(f"# title: {title.get('raw') or title.get('rendered')}")
    print("# ---- content (raw) ----")
    print(content.get("raw") or content.get("rendered") or "")


def cmd_update(args):
    base, user, pw = load_creds(args.client)
    pid = str(args.id).strip()
    if not _ID_RE.match(pid):
        err("ERROR: --id は正の整数（投稿ID・1〜10桁・半角）で指定してください。")
        sys.exit(2)
    # 1) 対象を取得し「現在 draft」であることを確認（公開済み等の本番記事は絶対に上書きしない）
    get_url = _endpoint(base, f"/posts/{pid}", {"context": "edit"})
    status, body = _request(get_url, user, pw, "GET")
    if status != 200:
        err(f"ERROR: 投稿ID {pid} の取得に失敗 HTTP {status}")
        err("       詳細: " + _err_body(body))
        sys.exit(6)
    try:
        cur = json.loads(body)
    except ValueError:
        err("ERROR: レスポンスがJSONでない。詳細: " + _err_body(body))
        sys.exit(6)
    cur_status = cur.get("status") if isinstance(cur, dict) else None
    if cur_status != "draft":
        err(f"ERROR: 対象ID {pid} は status={cur_status!r}＝下書きではありません。")
        err("       安全のため更新しません（公開済み等の本番記事は上書きしない）。")
        sys.exit(7)
    # 2) 本文を読み、status=draft を保ったまま更新
    try:
        with open(args.html_file, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        err(f"ERROR: 本文HTMLが見つかりません: {args.html_file}")
        sys.exit(2)
    content = _extract_body(raw) if args.extract else raw.strip()
    if not content:
        err("ERROR: 本文が空です。")
        sys.exit(2)
    content, block_note = _blockify(content, not args.no_blocks)
    payload = {"content": content, "status": "draft"}   # status は draft を明示維持
    if args.title.strip():
        payload["title"] = args.title
    upd_url = _endpoint(base, f"/posts/{pid}")
    print(f"更新先: {upd_url}（現在 status=draft を確認済み）")
    print(f"本文: {len(content)} 文字 / status=draft 維持")
    print(f"  ブロック化: {block_note}")
    if args.dry_run:
        print("※ --dry-run のため送信しません。")
        print("--- 変換後 content の先頭プレビュー（最大800字）---")
        print(content[:800])
        return
    status, body = _request(upd_url, user, pw, "POST", payload)
    if status not in (200, 201):
        err(f"ERROR: 更新失敗 HTTP {status}")
        err("       詳細: " + _err_body(body))
        sys.exit(6)
    try:
        post = json.loads(body)
    except ValueError:
        err("ERROR: レスポンスがJSONでない。詳細: " + _err_body(body))
        sys.exit(6)
    if post.get("status") != "draft":
        err(f"ERROR: 更新後 status が draft でない: {post.get('status')!r}。WP管理画面で確認してください。")
        sys.exit(7)
    print(f"✅ 下書きID {post.get('id')} を更新しました（status=draft 維持・publish していません）")
    print(f"  プレビュー(link): {post.get('link')}")


def main():
    p = argparse.ArgumentParser(description="WordPress 下書き(draft)専用クライアント")
    sub = p.add_subparsers(dest="cmd", required=True)

    pc = sub.add_parser("check", help="認証を検証（書き込みなし）")
    pc.add_argument("--client", required=True)
    pc.set_defaults(func=cmd_check)

    pg = sub.add_parser("get", help="投稿/下書きの内容を取得（読み取り専用・改善の素材に）")
    pg.add_argument("--client", required=True)
    pg.add_argument("--id", required=True, help="取得する投稿ID")
    pg.set_defaults(func=cmd_get)

    pp = sub.add_parser("post", help="本文HTMLを status=draft で投稿")
    pp.add_argument("--client", required=True)
    pp.add_argument("--title", required=True)
    pp.add_argument("--html-file", required=True)
    pp.add_argument("--extract", action="store_true",
                    help="HTMLから <article> の中身だけ抽出して投稿する")
    pp.add_argument("--no-blocks", action="store_true",
                    help="Gutenbergブロック化を無効化（生HTMLのまま投稿＝クラシックブロック警告の恐れ）")
    pp.add_argument("--dry-run", action="store_true", help="送信せず内容の要約だけ表示")
    pp.set_defaults(func=cmd_post)

    pu = sub.add_parser("update", help="既存の下書き(draft)を更新（公開済みは更新しない）")
    pu.add_argument("--client", required=True)
    pu.add_argument("--id", required=True, help="更新する投稿ID（draft のみ）")
    pu.add_argument("--title", default="", help="省略時は既存タイトルを維持")
    pu.add_argument("--html-file", required=True)
    pu.add_argument("--extract", action="store_true",
                    help="HTMLから <article> の中身だけ抽出して更新する")
    pu.add_argument("--no-blocks", action="store_true",
                    help="Gutenbergブロック化を無効化（生HTMLのまま更新＝クラシックブロック警告の恐れ）")
    pu.add_argument("--dry-run", action="store_true", help="送信せず内容の要約だけ表示")
    pu.set_defaults(func=cmd_update)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
