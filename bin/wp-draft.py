#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bin/wp-draft.py — WordPress に「下書き(status=draft)」を作るだけの最小クライアント。

blog-write モードの Phase 2 用。blog-loop/blog-write が作った記事ドラフトを、対象クライアントの
WordPress REST API に **下書きとして** 投稿する（公開はしない）。

設計（automation.md 準拠）:
  - 書き込みは status=draft のみ。publish は不可（--status は draft 固定。他値はエラーで停止）。
  - 既存記事の本番上書きはしない（このスクリプトは新規 draft の作成だけ。post 更新機能は持たない）。
  - 秘密情報：ユーザー名・アプリパスワードは .env の <CLIENT>_WP_USER / <CLIENT>_WP_APP_PASSWORD を
    読むだけ。ログ・標準出力・エラーには出さない（Authorization ヘッダも表示しない）。
  - 依存ゼロ：標準ライブラリ（urllib）のみ。
  - check サブコマンドは読み取り専用（GET /users/me）で、書き込み前に認証だけ検証する。

使い方:
  bin/wp-draft.py check  --client ycom
      認証を検証（書き込みなし）。誰として・どんな権限で繋がるかを表示。
  bin/wp-draft.py post   --client ycom --title "タイトル" --html-file path/to/body.html [--dry-run]
      本文HTMLファイルを status=draft で投稿。--dry-run は送信内容の要約だけ表示して投稿しない。

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


def _extract_body(html):
    """ドラフトHTMLから <article>…</article> の中身を取り出す。無ければ全体を返す。
    レビュー用マーカー（▼ここから/▲ここまで の注記）は除去する。"""
    m = re.search(r"<article\b[^>]*>(.*?)</article>", html, re.S | re.I)
    content = m.group(1) if m else html
    # レビュー用の注記段落を除去
    content = re.sub(r"<p[^>]*>\s*[▼▲][^<]*</p>", "", content)
    return content.strip()


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

    posts_url = _endpoint(base, "/posts")   # 常にコレクション（/posts/<id> は作らない＝既存記事の更新に化けない）
    payload = {"title": args.title, "content": content, "status": "draft"}
    print(f"投稿先: {posts_url}")
    print(f"タイトル: {args.title}")
    print(f"本文: {len(content)} 文字（元HTML {len(raw)} 文字）/ status=draft（下書き・非公開）")
    if args.extract:
        print(f"  抽出(--extract)：<article>検出={had_article}")
    if args.dry_run:
        print("※ --dry-run のため送信しません。内容を確認してください。")
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


def main():
    p = argparse.ArgumentParser(description="WordPress 下書き(draft)専用クライアント")
    sub = p.add_subparsers(dest="cmd", required=True)

    pc = sub.add_parser("check", help="認証を検証（書き込みなし）")
    pc.add_argument("--client", required=True)
    pc.set_defaults(func=cmd_check)

    pp = sub.add_parser("post", help="本文HTMLを status=draft で投稿")
    pp.add_argument("--client", required=True)
    pp.add_argument("--title", required=True)
    pp.add_argument("--html-file", required=True)
    pp.add_argument("--extract", action="store_true",
                    help="HTMLから <article> の中身だけ抽出して投稿する")
    pp.add_argument("--dry-run", action="store_true", help="送信せず内容の要約だけ表示")
    pp.set_defaults(func=cmd_post)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
