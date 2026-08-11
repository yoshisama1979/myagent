#!/usr/bin/env bash
# bin/wp-draft.py（ブログ本文を WordPress の下書きへ投稿・更新するツール）の回帰テスト。
#
# 契機＝2026-08-11、testing.md §7「無人ループが実行するツール 21本のうちテストが無い 13本」を
# 減らす作業の4本目。§2 の条件②③に当たる＝**外部（WP）へ書き込む**手前の変換と検証が全て。
# 守りたい不変条件：
#   (1) 生HTMLをそのまま投げない＝Gutenberg ブロックへ変換する（クラシックブロック警告＋崩れ）
#   (2) native ブロック化は「厳密な <p>/<hN>」だけ。少しでも違えば wp:html で verbatim（安全側）
#   (3) 画像の figure 包みは**実際の入れ子**で判定する（a/p/figure/見出しの中は触らない＝HTMLを壊す）
#   (4) 認証情報を画面・ログに出さない（_cred_diag は桁数だけ／_err_body は Basic を redact）
#   (5) 冪等＝二重に包まない（既にブロック区切りがある本文は変換しない）
#
# ⚠️ ネットワークへは一切出ない（_request を呼ぶ経路はテストしない）。認証情報は**架空の値を
#    環境変数で与える**。本番 .env を読ませないため、テストは一時ディレクトリへ cd してから走る
#    （_env は cwd の ".env" を見る作り）。
# 触ったら必ず流すこと：bash bin/test-wp-draft.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/wp-draft.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import contextlib, importlib.util, io, json, os, re, sys, tempfile
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("wpdraft", proj / "bin/wp-draft.py")
wp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wp)

# 本番 .env を読ませない：_env は cwd の ".env" を開くので、空の一時ディレクトリへ移る
T = Path(tempfile.mkdtemp())
if not str(T).startswith("/tmp"):
    print(f"❌ テストの作業先が /tmp の外: {T}", file=sys.stderr); sys.exit(2)
os.chdir(T)
if Path(".env").exists():
    print("❌ 一時ディレクトリに .env がある（本番を読む恐れ）", file=sys.stderr); sys.exit(2)

P = N = 0
def ok(m, d=""):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

def exits(fn, *a, **kw):
    """sys.exit の終了コードを返す（正常終了なら None）。stderr は吸う。"""
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            fn(*a, **kw)
    except SystemExit as e:
        return e.code
    return None

FAKE_USER = "wp-test-user"
FAKE_PW = "abcd efgh ijkl mnop qrst uvwx"        # 架空（WPのアプリパスワードと同じ 24文字＋空白）
GOOD_BASE = "https://example.test/wp-json/wp/v2"

print("=== 認証情報の読み込みと検証（実値は架空・ネットワークには出ない）===")
os.environ["TESTCLIENT_WP_API_BASE"] = GOOD_BASE
os.environ["TESTCLIENT_WP_USER"] = FAKE_USER
os.environ["TESTCLIENT_WP_APP_PASSWORD"] = FAKE_PW
base, user, pw = wp.load_creds("testclient")
(ok if pw == "abcdefghijklmnopqrstuvwx" else ng)("アプリパスワードの表示用スペースを詰める", len(pw))
(ok if base == GOOD_BASE and user == FAKE_USER else ng)("正しい設定は通る")
os.environ["TESTCLIENT_WP_API_BASE"] = "https://example.test/?rest_route=/wp/v2"
(ok if exits(wp.load_creds, "testclient") is None else ng)("rest_route 形式も許可")
for bad, why in [("https://example.test/wp-json/wp/v1", "バージョン違いの API_BASE を弾く"),
                 ("http://example.test/wp-json/wp/v2", "https 以外を弾く"),
                 ("https://example.test/wp-json/wp/v2/posts", "エンドポイントまで含む設定を弾く"),
                 ("example.test/wp-json/wp/v2", "スキームの無い設定を弾く")]:
    os.environ["TESTCLIENT_WP_API_BASE"] = bad
    (ok if exits(wp.load_creds, "testclient") == 3 else ng)(why, bad)
os.environ["TESTCLIENT_WP_API_BASE"] = GOOD_BASE
for bad, why in [("Bad Client", "大文字・空白の client キーを弾く"),
                 ("../etc", "パス記号の client キーを弾く（環境変数名に化ける）"),
                 ("", "空の client キーを弾く")]:
    (ok if exits(wp.load_creds, bad) == 2 else ng)(why, repr(bad))
del os.environ["TESTCLIENT_WP_APP_PASSWORD"]
(ok if exits(wp.load_creds, "testclient") == 3 else ng)("キー不足はエラーで止まる（空認証で叩かない）")
os.environ["TESTCLIENT_WP_APP_PASSWORD"] = FAKE_PW

print("\n--- URL の組み立て ---")
(ok if wp._endpoint(GOOD_BASE, "/posts") == GOOD_BASE + "/posts" else ng)("pretty 形式")
got = wp._endpoint("https://example.test/?rest_route=/wp/v2", "/posts", {"context": "edit"})
(ok if got == "https://example.test/?rest_route=/wp/v2/posts&context=edit" else ng)(
    "rest_route 形式は & で繋ぐ（? を二重に付けない）", got)
got = wp._endpoint(GOOD_BASE, "/posts", {"search": "変更前 > 変更後"})
(ok if "%E5" in got and " " not in got and ">" not in got else ng)("パラメータをURLエンコードする", got)

print("\n--- 秘密を出さない ---")
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    wp._cred_diag(FAKE_USER, "abcdefghijklmnopqrstuvwx")
diag = buf.getvalue()
(ok if "abcdefghijklmnopqrstuvwx" not in diag else ng)("★診断表示にパスワードの実値を出さない", diag)
(ok if "24" in diag else ng)("桁数だけを出す（.env の引用符混入を切り分けるため）")
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    wp._cred_diag(FAKE_USER, "'abc'")
(ok if "記号混入" in buf.getvalue() else ng)("記号が混ざっていたら引用符混入を疑わせる")
hdr = wp._auth_header("u", "p")
(ok if hdr == "Basic dTpw" else ng)("Basic 認証ヘッダの組み立て", hdr)

print("\n--- エラー本文の要約（WAF の画面や認証情報を垂れ流さない）---")
(ok if wp._err_body('{"code":"rest_forbidden","message":"権限がありません","data":{"status":403}}')
   == "code=rest_forbidden message=権限がありません status=403" else ng)("JSON は要点だけ抜く")
(ok if wp._err_body("<html><body>禁止</body></html>") == "禁止" else ng)("HTML はタグを落とす")
# 🔴→🟢 2026-08-11：この3形のうち**1つ目だけが素通りしていた**（`\S+` が "Basic" で止まり
#   トークンが裸で残る／しかも "Basic" が消えるので後段の規則にも掛からない）。実装を修正済み。
for body, why in [
    ("debug: Authorization: Basic YWJjOmRlZg== が拒否されました", "「Authorization: Basic <値>」を伏せる"),
    ("Authorization=Basic YWJjOmRlZg==", "「Authorization=Basic <値>」を伏せる"),
    ("header Basic YWJjOmRlZg== rejected", "スキーム単独の「Basic <値>」を伏せる"),
]:
    red = wp._err_body(body)
    (ok if "YWJjOmRlZg==" not in red and "[redacted]" in red else ng)("★" + why, red)
(ok if len(wp._err_body("あ" * 1000)) == 300 else ng)("長すぎる本文は切り詰める")
(ok if wp._err_body("") == "" else ng)("空でも落ちない")

print("\n=== 本文の取り出し ===")
(ok if wp._extract_body("<div>前</div><article><p>本文</p></article><div>後</div>") == "<p>本文</p>"
   else ng)("<article> の中身だけを取る")
(ok if wp._extract_body("<p>本文</p>") == "<p>本文</p>" else ng)("<article> が無ければ全体")
got = wp._extract_body("<article><p>▼ここから本文</p><p>本文</p><p>▲ここまで</p></article>")
(ok if got == "<p>本文</p>" else ng)("レビュー用マーカーの段落を落とす", got)
(ok if wp._extract_body('<ARTICLE class="x"><p>本文</p></ARTICLE>') == "<p>本文</p>" else ng)(
    "大文字・属性付きの <article> にも対応")

print("\n=== 属性の取り出し（別属性を誤って拾わない）===")
tag = '<img src="/a.png" data-src="/dummy.png" alt=' + "'説明'" + ' class="c1 c2">'
(ok if wp._tag_attr(tag, "src") == "/a.png" else ng)("data-src を src と誤認しない", wp._tag_attr(tag, "src"))
(ok if wp._tag_attr(tag, "alt") == "説明" else ng)("単引用符の属性も読む")
(ok if wp._img_class(tag) == "c1 c2" else ng)("class を読む")
(ok if wp._tag_attr(tag, "title") is None else ng)("無い属性は None")
(ok if wp._img_class("<img src=/a.png>") == "" else ng)("class が無ければ空文字")

print("\n=== トップレベルの分割 ===")
def kinds(src):
    return [(k, v.strip()) for k, v in wp._top_level_nodes(src)]
(ok if kinds("<p>a</p><p>b</p>") == [("el", "<p>a</p>"), ("el", "<p>b</p>")] else ng)("兄弟要素を分ける")
(ok if kinds("<div><p>a</p></div>") == [("el", "<div><p>a</p></div>")] else ng)("入れ子は1要素")
(ok if kinds("素のテキスト<p>a</p>") == [("raw", "素のテキスト"), ("el", "<p>a</p>")] else ng)(
    "要素の外の素片は raw として拾う")
(ok if kinds("<hr>") == [("el", "<hr>")] else ng)("void 要素（<hr>）も1要素")
(ok if kinds("<br/>") == [("el", "<br/>")] else ng)("自己終了タグも1要素")
(ok if kinds("</div>") == [("raw", "</div>")] else ng)("迷子の終了タグで壊れない")
got = kinds('<div title="a > b"><p>x</p></div>')
(ok if got == [("el", '<div title="a > b"><p>x</p></div>')] else ng)(
    "属性値の中の > で要素を切らない", got)
(ok if kinds("") == [] else ng)("空文字は空リスト")

print("\n=== 画像ブロック化（core/image）===")
b = wp._try_image_block('<img src="/a.png" class="wp-image-42 size-large alignleft" alt="説明">')
(ok if b and '"id":42' in b and '"sizeSlug":"large"' in b and '"align":"left"' in b else ng)(
    "添付ID・サイズ・配置を属性へ", b)
(ok if b and 'class="wp-block-image alignleft size-large"' in b else ng)("figure のクラスを組む", b)
(ok if b and 'class="wp-image-42"' in b and "srcset" not in b else ng)(
    "img は src/alt/class の正準形にする（srcset は WP が再生成）", b)
b2 = wp._try_image_block('<img src="/a.png" class="wp-image-7 alignnone">')
(ok if b2 and '"align"' not in b2 else ng)("alignnone は配置なしとして扱う", b2)
(ok if b2 and '"sizeSlug":"full"' in b2 else ng)("サイズ指定が無ければ full")
b3 = wp._try_image_block('<img src="/a.png" class="wp-image-7 size-my-thumb">')
(ok if b3 and '"sizeSlug":"my-thumb"' in b3 else ng)("カスタム画像サイズのハイフンも通す", b3)
b4 = wp._try_image_block('<img src="/a.png" class="wp-image-7 size-full" alt=' + "'彼は\"A\"と言った'" + '>')
(ok if b4 and "&quot;A&quot;" in b4 else ng)("alt の二重引用符を実体参照へ（属性を壊さない）", b4)
(ok if wp._try_image_block('<img src="/a.png" class="just-a-photo">') is None else ng)(
    "添付IDが無ければ画像ブロックにしない（wp:html へ回す）")
(ok if wp._try_image_block('<img src="/a.png" class="wp-image-1"><img src="/b.png" class="wp-image-2">')
   is None else ng)("2枚並んでいたら画像ブロックにしない")
(ok if wp._try_image_block('<p><img src="/a.png" class="wp-image-1 size-full"></p>') is None else ng)(
    "単独の img でなければ画像ブロックにしない")
(ok if wp._try_image_block('<img class="wp-image-1 size-full">') is None else ng)("src が無ければ None")
big = '<img src="/a.png" alt="変更前 > 変更後" class="wp-image-9 size-full">'
(ok if wp._try_image_block(big) is not None else ng)("alt の中の > で判定を諦めない")

print("\n=== 本文画像の figure 包み（入れ子で判定する）===")
w = wp._wrap_content_images('<div><img src="/a.png" class="wp-image-1 size-full"></div>')
(ok if 'figure class="wp-block-image size-full"' in w else ng)("div 直下の全幅画像は figure で包む", w)
for src, why in [
    ('<a href="#"><img src="/a.png" class="wp-image-1 size-full"></a>', "リンク画像は包まない"),
    ('<p><img src="/a.png" class="wp-image-1 size-full"></p>', "p の中は包まない（HTMLが壊れる）"),
    ('<figure><img src="/a.png" class="wp-image-1 size-full"></figure>', "figure の中は包まない"),
    ('<picture><img src="/a.png" class="wp-image-1 size-full"></picture>', "picture の中は包まない"),
    ('<h2><img src="/a.png" class="wp-image-1 size-full"></h2>', "見出しの中は包まない"),
    ('<div><img src="/a.png" class="wp-image-1 size-medium"></div>', "小サイズ画像は触らない"),
    ('<div><img src="/a.png" class="photo"></div>', "添付でない画像は触らない"),
]:
    (ok if wp._wrap_content_images(src) == src else ng)(why, wp._wrap_content_images(src))
once = wp._wrap_content_images('<div><img src="/a.png" class="wp-image-1 size-full"></div>')
(ok if wp._wrap_content_images(once) == once else ng)("冪等（2回かけても二重に包まない）")
deep = '<div><section><img src="/a.png" class="wp-image-1 size-large"></section></div>'
(ok if "wp-block-image" in wp._wrap_content_images(deep) else ng)("深い入れ子でも対象なら包む")
after_p = '<div><p>文</p><img src="/a.png" class="wp-image-1 size-full"></div>'
(ok if "wp-block-image" in wp._wrap_content_images(after_p) else ng)(
    "閉じた <p> の後ろの画像は「p の中」と誤判定しない（前後の rfind でなく入れ子で見る）")

print("\n=== ブロックへの包み方 ===")
(ok if wp._wrap_block("<p>本文</p>").startswith("<!-- wp:paragraph -->") else ng)("素の <p> は段落ブロック")
(ok if "<!-- wp:heading -->" in wp._wrap_block("<h2>見出し</h2>") else ng)("h2 は既定レベル＝メタ無し")
(ok if '{"level":3}' in wp._wrap_block("<h3>見出し</h3>") else ng)("h3 はレベルを明示")
(ok if '{"level":6}' in wp._wrap_block("<h6>見出し</h6>") else ng)("h6 まで対応")
for src, why in [("<P>本文</P>", "大文字 <P> は native にしない（検証エラー回避＝安全側）"),
                 ("<p >本文</p>", "余分な空白のある <p > は native にしない"),
                 ('<p class="lead">本文</p>', "属性付きの <p> は native にしない"),
                 ("<table><tr><td>x</td></tr></table>", "表は verbatim（レイアウトを変えない）"),
                 ("<ul><li>a</li></ul>", "リストは verbatim")]:
    (ok if wp._wrap_block(src).startswith("<!-- wp:html -->") else ng)(why, wp._wrap_block(src)[:60])
(ok if wp._wrap_block('<div><img src="/a.png" class="wp-image-1 size-full"></div>').count("wp-block-image")
   == 1 else ng)("wp:html で包むときも中の画像はブロック要素化する")

print("\n=== 全体の変換 ===")
g = wp.to_gutenberg_blocks("<p>あ</p>\n<h2>い</h2>\n<table><tr><td>う</td></tr></table>")
(ok if g.count("<!-- wp:") == 3 else ng)("要素ごとにブロックへ", g.count("<!-- wp:"))
(ok if "\n\n" in g else ng)("ブロック間は空行で区切る")
(ok if wp.to_gutenberg_blocks("<!-- 説明コメント --><p>あ</p>").count("<!-- wp:") == 1 else ng)(
    "説明用の HTML コメントは落とす（空の wp:html を作らない）")
(ok if wp.to_gutenberg_blocks("") == "" else ng)("空本文は空のまま")
(ok if wp.to_gutenberg_blocks("   \n  ") == "" else ng)("空白だけの本文も空")
(ok if wp.to_gutenberg_blocks("素のテキスト").startswith("<!-- wp:html -->") else ng)(
    "タグの無い素の本文も包む（クラシックブロックにさせない）")

print("\n--- 投稿直前の判断 ---")
c, label = wp._blockify("<p>あ</p>", True)
(ok if c.startswith("<!-- wp:paragraph") and "1 ブロック" in label else ng)("変換してブロック数を報告", label)
c, label = wp._blockify("<p>あ</p>", False)
(ok if c == "<p>あ</p>" and "スキップ" in label else ng)("--no-blocks は生HTMLのまま（警告つき）", label)
src = "<!-- wp:paragraph -->\n<p>あ</p>\n<!-- /wp:paragraph -->"
c, label = wp._blockify(src, True)
(ok if c == src and "変換なし" in label else ng)("★既にブロック区切りがある本文は二重変換しない", label)

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
