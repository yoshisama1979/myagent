#!/usr/bin/env bash
# bin/precommit-guard.py（コミット直前の機械ゲート）の回帰テスト。
#
# 契機＝2026-08-12 社長判断「無人エージェントにコミットを許可する。ただし柵を先に作る」。
# このツールは testing.md §2 の3条件すべてに当たる＝①無人エージェントの全コミットが通る
# ②git の履歴という状態を左右する ③判定（秘密値・領域・ゲート・破損）を持つ。
#
# **このツールの失敗は二方向とも高くつく**：
#   ・緩すぎる → 秘密・実名・他人の書きかけが git に入る（取り消しても履歴に残る）
#   ・厳しすぎる → 全エージェントのコミットが止まり、成果物が git 外に溜まり続ける
#                  （＝このツールが解決しようとした問題そのものが再発する）
# だから「止めるべきものを止める」と「**通すべきものを通す**」を対で固定する。
#
# ⚠️ 本番リポジトリでは commit しない：統合テストは一時ディレクトリに使い捨ての git リポジトリを
#    作って行う。秘密値・実名は一切扱わない（架空の値と架空の名前だけ）。
# 触ったら必ず流すこと：bash bin/test-precommit-guard.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/precommit-guard.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import importlib.util, os, subprocess, sys, tempfile
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("pcguard", proj / "bin/precommit-guard.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

P = N = 0
def ok(m, d=""):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

T = Path(tempfile.mkdtemp())
if not str(T).startswith("/tmp"):
    print(f"❌ テストの作業先が /tmp の外: {T}", file=sys.stderr); sys.exit(2)

# ⚠️ 秘密値らしき文字列を**このファイルに literal で置かない**。置くと precommit-guard が
#    自分のテストを止める（検知器の自己参照＝system-health で踏んだのと同型）。
#    ただし除外リストで逃げると**本物を見逃す穴**になるので、検知器は緩めず
#    **テスト側が実行時に組み立てる**。文字列を割る位置は各パターンの先頭を跨ぐこと。
FAKE_SLACK  = "xox" + "b-12345678-ABCDEFGHIJKL"
FAKE_PEM    = "-----BEGIN " + "RSA PRIVATE KEY-----"
FAKE_GKEY   = "AIza" + "SyA1234567890abcdefghijklmnopqrstuv"
FAKE_BEARER = "Bearer " + "abcdefghijklmnopqrstuvwxyz012345"
FAKE_CSEC   = "client_" + 'secret: "s3cr3tValue0123456789"'

def S(path, added="", content=None):
    return {"path": path, "added": added, "content": content}

def run(staged, **kw):
    return g.guard(staged, **kw)

print("=== 通すべきものを通す（厳しすぎると全エージェントが止まる）===")
(ok if run([S("site/overseer/index.html", "<div>a</div>", "<div>a</div>")]) == [] else ng)(
    "普通の記録更新は通す")
(ok if run([]) == [] else ng)("ステージ空でも落ちない")
(ok if run([S("bin/x.py", 'if not tok.startswith("xox' + 'b-"):\n')]) == [] else ng)(
    "★『xoxb-』を識別子名として書いたコードは通す（値ではない）")
(ok if run([S("bin/x.py", 'v = env("REFRESH_TOKEN")\nrefresh_token = None\n')]) == [] else ng)(
    "★秘密キー名への言及だけなら通す")
(ok if run([S(".env.example", "API_TOKEN=your-chatwork-token-here\n")]) == [] else ng)(
    "★雛形ファイル（.env.example）は対象外")
(ok if run([S("cfg.json", "TODO", '{"a": 1}')]) == [] else ng)("妥当な JSON は通す")
(ok if run([S("bin/x.sh", "API_TOKEN=xxxxxxxxxxxxxxxxxxxx\n")]) == [] else ng)(
    "明らかな穴埋め文字列（xxxx…）は秘密扱いしない")

print("\n=== 秘密値を止める（値の形だけを見る）===")
cases = [
    ("Slack トークン", "bin/x.sh", f"TOKEN={FAKE_SLACK}\n"),
    ("秘密鍵",         "key.pem",  FAKE_PEM + "\n"),
    ("Google APIキー", "bin/x.py", f'K = "{FAKE_GKEY}"\n'),
    ("Bearer 実値",    "doc.md",   f"Authorization: {FAKE_BEARER}\n"),
    ("秘密値の代入",   "conf.yml", FAKE_CSEC + "\n"),
]
for label, path, added in cases:
    r = run([S(path, added)])
    (ok if r and "[秘密値]" in r[0] else ng)(f"{label} を止める", r)
r = run([S("bin/x.sh", f"TOKEN={FAKE_SLACK}\n")])
(ok if FAKE_SLACK not in " ".join(r) else ng)(
    "★エラー文に秘密値の全体を出さない（抜粋のみ）", r)

# 🔴→🟢 2026-08-12：フックを有効にした最初の本番コミットで、**このテストファイル自身が止められた**
# （秘密値らしき literal を fixture として置いていたため＝検知器の自己参照）。除外リストで逃げず
# fixture を実行時に組み立てる形へ直した。同じ罠を次の人が踏まないよう、その状態を固定する。
own = (proj / "bin/test-precommit-guard.sh").read_text(encoding="utf-8")
(ok if g.secret_hits("bin/test-precommit-guard.sh", own) == [] else ng)(
    "★このテスト自身が秘密値検知に引っかからない（検知器を緩めずに解決したことの証明）",
    g.secret_hits("bin/test-precommit-guard.sh", own))
(ok if g.secret_hits("bin/precommit-guard.py",
                     (proj / "bin/precommit-guard.py").read_text(encoding="utf-8")) == [] else ng)(
    "検知器本体も自分のパターン定義で自分を止めない")

print("\n=== 実名・取引先名（リストは git 外から読む）===")
r = run([S("site/x.html", "本日 架空商事 と打ち合わせ")], deny_names=["架空商事"])
(ok if r and "[実名]" in r[0] else ng)("リストにある固有名詞を止める", r)
(ok if "架空商事" not in " ".join(r) else ng)(
    "★★エラー文に該当語そのものを出さない（検知器が漏洩源にならない）", r)
(ok if run([S("site/x.html", "本日 架空商事 と打ち合わせ")]) == [] else ng)(
    "リストが空なら実名検査はしない（未設定で全コミットを止めない）")
(ok if g.load_deny_names(str(T / "no-such-file.txt")) == [] else ng)(
    "一覧ファイルが無くても空で返す")
f = T / "names.txt"
f.write_text("# コメント\n\n架空商事\nテスト工業\n", encoding="utf-8")
(ok if g.load_deny_names(str(f)) == ["架空商事", "テスト工業"] else ng)(
    "コメント行と空行を読み飛ばす", g.load_deny_names(str(f)))
(ok if "data/secrets/" in g.DENY_NAMES_FILE else ng)(
    "★一覧の置き場は git 外（data/secrets/ は .gitignore 済み）", g.DENY_NAMES_FILE)

print("\n=== git 外にすべきファイルの取り込み ===")
r = run([S("data/comms/rooms.md")], ignored={"data/comms/rooms.md"})
(ok if r and "[git外]" in r[0] else ng)(".gitignore 対象がステージされたら止める", r)
(ok if run([S("site/ok.html", "", "")], ignored={"data/comms/rooms.md"}) == [] else ng)(
    "ステージされていないものは関係ない")

print("\n=== 社長ゲート対象（無人実行）===")
for p in ("CLAUDE.md", "SYSTEM.md", "rules/testing.md", "rules/modes/overseer.md",
          ".claude/settings.local.json", ".claude/commands/commit-pipeline.md"):
    r = run([S(p)], unattended=True)
    (ok if r and "[社長ゲート]" in r[0] else ng)(f"無人では {p} を変更させない", r)
(ok if run([S("CLAUDE.md")], unattended=False) == [] else ng)(
    "★有人セッションなら通す（社長が承認して反映する経路を塞がない）")
(ok if run([S("site/overseer/index.html")], unattended=True) == [] else ng)(
    "無人でも記録物は通す（それが今回の目的）")

print("\n=== エージェントの領域（共有作業ツリーの巻き込み防止）===")
(ok if run([S("site/overseer/index.html")], agent="overseer") == [] else ng)("統括は自分の掲示板を書ける")
r = run([S("data/hp-loop/ycom/coverage.md")], agent="overseer")
(ok if r and "[領域外]" in r[0] else ng)("★統括は hp-loop の台帳を巻き込めない", r)
(ok if run([S("data/hp-loop/ycom/coverage.md")], agent="hp-loop-ycom") == [] else ng)(
    "hp-loop-<site> は自分の台帳を書ける（ワイルドカード照合）")
(ok if run([S("site/hp-analysis/ycom/index.html")], agent="hp-loop-yoshida") == [] else ng)(
    "hp-loop-* は解析掲示板も書ける")
r = run([S("site/business/partner/index.html")], agent="blog-loop-ycom")
(ok if r and "[領域外]" in r[0] else ng)("blog-loop はパートナーの掲示板を書けない", r)
(ok if run([S("site/business/partner/index.html")], agent="partner") == [] else ng)(
    "★未登録のエージェントは領域検査をしない（誤った許可リストで正当な作業を止めない）")
(ok if run([S("anything/at/all.md")], agent=None) == [] else ng)(
    "エージェント名が無い（有人セッション）なら領域検査をしない")
(ok if g.allowed_prefixes("hp-loop-konjaku") == g.allowed_prefixes("hp-loop-ycom") else ng)(
    "同じワイルドカードに当たるエージェントは同じ許可を持つ")
(ok if g.allowed_prefixes("partner") is None else ng)("未登録は None")

print("\n=== 壊れたファイルを保存させない ===")
r = run([S("data/x.json", "", "{壊れた")])
(ok if r and "[破損]" in r[0] and "JSON" in r[0] else ng)("壊れた JSON を止める", r)
r = run([S("site/x.html", "", "<div><div></div>")])
(ok if r and "div が釣り合わない" in r[0] else ng)("HTML の div 不釣り合いを止める", r)
(ok if run([S("site/x.html", "", "<div><span>a</span></div>")]) == [] else ng)(
    "釣り合っていれば通す")
(ok if run([S("rules/x.md", "", "<div>")]) == [] else ng)(
    "site/ 以外の .md に HTML 検査をかけない（誤検知の元）")
(ok if run([S("site/x.html", "", None)]) == [] else ng)("内容が取れなくても落ちない")

print("\n=== 複数の問題は全部並べる（1つ直すたびに再実行させない）===")
r = run([S("CLAUDE.md", f"TOKEN={FAKE_SLACK}\n")], unattended=True)
(ok if len(r) >= 2 else ng)(f"ゲート違反と秘密値の両方を報告（{len(r)}件）", r)

print("\n=== 統合：使い捨ての git リポジトリで実際にコミットを止める ===")
R = T / "repo"
(R / "bin").mkdir(parents=True)
(R / ".githooks").mkdir()
(R / "site" / "overseer").mkdir(parents=True)
(R / "data" / "hp-loop").mkdir(parents=True)
import shutil
shutil.copy(proj / "bin/precommit-guard.py", R / "bin/precommit-guard.py")
shutil.copy(proj / ".githooks/pre-commit", R / ".githooks/pre-commit")
os.chmod(R / ".githooks/pre-commit", 0o755)
(R / ".gitignore").write_text("data/secrets/\n", encoding="utf-8")

def git(*a, **kw):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.test",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.test",
               **kw.pop("env", {}))
    return subprocess.run(["git", *a], cwd=R, capture_output=True, text=True, env=env)

git("init", "-q", "-b", "main")
git("config", "core.hooksPath", ".githooks")
(R / "site/overseer/index.html").write_text("<div>初期</div>", encoding="utf-8")
git("add", "-A")
r = git("commit", "-q", "-m", "初期")
(ok if r.returncode == 0 else ng)("フックを入れても普通のコミットは通る", r.stderr[:200])

(R / "site/overseer/index.html").write_text("<div>更新</div>", encoding="utf-8")
git("add", "site/overseer/index.html")
r = git("commit", "-q", "-m", "統括の更新", env={"MYAGENT_AGENT": "overseer",
                                                "MYAGENT_UNATTENDED": "1"})
(ok if r.returncode == 0 else ng)("★無人の統括が自分の掲示板をコミットできる（今回の目的）", r.stderr[:300])

(R / "data/hp-loop/other.md").write_text("他エージェントの書きかけ", encoding="utf-8")
git("add", "data/hp-loop/other.md")
r = git("commit", "-q", "-m", "巻き込み", env={"MYAGENT_AGENT": "overseer",
                                              "MYAGENT_UNATTENDED": "1"})
(ok if r.returncode != 0 and "領域外" in r.stderr else ng)(
    "★★統括が hp-loop のファイルを巻き込もうとすると commit が失敗する", r.stderr[:300])
r = git("log", "--oneline")
(ok if r.stdout.count("\n") == 2 else ng)(
    f"止まったコミットは履歴に残っていない（{r.stdout.count(chr(10))}件）", r.stdout)

r = git("commit", "-q", "--no-verify", "-m", "緊急時の抜け道",
        env={"MYAGENT_AGENT": "overseer", "MYAGENT_UNATTENDED": "1"})
(ok if r.returncode == 0 else ng)("--no-verify なら通る（git 標準の抜け道は塞がない）", r.stderr[:200])

(R / "site/overseer/leak.html").write_text(
    f"<div>TOKEN={FAKE_SLACK}</div>", encoding="utf-8")
git("add", "site/overseer/leak.html")
r = git("commit", "-q", "-m", "秘密値", env={"MYAGENT_AGENT": "overseer"})
(ok if r.returncode != 0 and "秘密値" in r.stderr else ng)(
    "★秘密値を含むコミットは失敗する", r.stderr[:300])
git("reset", "-q")

(R / "bin/precommit-guard.py").unlink()
(R / "site/overseer/index.html").write_text("<div>フック本体が無い版</div>", encoding="utf-8")
git("add", "site/overseer/index.html")
r = git("commit", "-q", "-m", "ツールが無い版へ戻った場合")
(ok if r.returncode == 0 else ng)(
    "★ツール本体が無い版へ戻ってもコミットを塞がない（フックが人質にならない）", r.stderr[:200])

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
