#!/usr/bin/env bash
# 要約ガイドの追随漏れ検出（bin/check-onboarding-sync.py）の回帰テスト。
#
# 契機＝2026-09-10、TB-010「ガイドと原典の版ズレ」が起票当日に現実化した
# （website/documents/handoff.md の状態遷移の矛盾を直した際、同じ誤りが
#  website-onboarding.md §5.1 にもあった）。
#
# このツールは「何も出力しない」が正常系＝**壊れても気づけない**。
# 初版は changed_files を全テストでモックしていたため、git 出力の解析と CLI 引数処理を
# 一度も通しておらず、同日の Codex レビューで 🔴4件（対応表の網羅漏れ・リネーム未検出・
# ガイド削除を「追随済み」と誤判定・core.quotepath で非ASCIIパスを取りこぼし）が出た。
# **その反省から、実際の git リポジトリを作る統合テストを本体に据えている。**
#
# 触ったら必ず流すこと：bash bin/test-check-onboarding-sync.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/check-onboarding-sync.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import importlib.util, io, re, subprocess, sys, tempfile
from contextlib import redirect_stdout
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("cos", proj / "bin/check-onboarding-sync.py")
cos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cos)

P = N = 0
def ok(m):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}" + (f"\n     {d}" if d else ""))

GUIDE = "claude-rules/website-onboarding.md"
ORIGIN = "claude-rules/website/documents/handoff.md"
CMDDIR = "claude-rules/website/.claude/commands/"

def capture(entries=None, argv=None):
    """本体を回して標準出力を返す。entries を渡すと git を差し替える。"""
    real = cos.changed_entries
    if entries is not None:
        cos.changed_entries = lambda rng=None: entries
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            code = cos.main(argv or [])
    finally:
        cos.changed_entries = real
    return code, buf.getvalue()

# ───────── 1. 判定ロジック（git を差し替え） ─────────
print("【判定】原典を直してガイドを直していない → 警告する")
code, out = capture([("M", [ORIGIN])])
ok("終了コード 0") if code == 0 else ng(f"終了コードが {code}")
ok("警告が出る") if "🔔" in out else ng("警告が出ない", out)
ok("該当節を挙げる") if "§5.1" in out else ng("該当節が出ない", out)

print("【判定】原典とガイドを同時に直した → 警告しない")
_, out = capture([("M", [ORIGIN]), ("M", [GUIDE])])
ok("警告が出ない") if "🔔" not in out else ng("誤警告", out)
ok("追随済みと言う") if "✅" in out else ng("追随済みの表示が無い", out)

print("【判定】ガイドを削除した → 追随済みにしない（Codex 🔴3）")
_, out = capture([("M", [ORIGIN]), ("D", [GUIDE])])
ok("警告が出る") if "🔔" in out else ng("削除を追随済みと誤判定", out)
ok("削除だと言う") if "削除" in out else ng("削除の説明が無い", out)

print("【判定】ガイドを改名した → 対応表が古いと言う（Codex 🔴2）")
_, out = capture([("M", [ORIGIN]), ("R100", [GUIDE, "claude-rules/newname.md"])])
ok("警告が出る") if "🔔" in out else ng("改名を見逃す", out)
ok("改名だと言う") if "改名" in out else ng("改名の説明が無い", out)

print("【判定】原典を改名した → 旧パスでも拾う（Codex 🔴2）")
_, out = capture([("R100", [ORIGIN, "claude-rules/website/documents/h2.md"])])
ok("警告が出る") if "🔔" in out else ng("原典の改名を見逃す", out)

print("【判定】無関係な変更 → 何も言わない")
for f in ("bin/slack.sh", "claude-rules/websystem/rules/modes/director.md",
          "claude-rules/README.md", "site/index.html"):
    _, out = capture([("M", [f])])
    ok(f"沈黙: {f}") if out.strip() == "" else ng(f"余計な出力: {f}", out)

print("【判定】コマンドはディレクトリ一致で拾う（1本増えても漏れない）")
_, out = capture([("A", [CMDDIR + "NEW.md"])])
ok("未知のコマンドでも拾う") if "§8" in out else ng("拾えない", out)
_, out = capture([("M", ["claude-rules/website/.claude/commandsX/a.md"])])
ok("紛らわしい隣のパスでは鳴らない") if out.strip() == "" else ng("誤検出", out)

print("【判定】複数の原典を同時に直した → まとめて挙げる")
_, out = capture([("M", ["claude-rules/website/rules/modes/director.md"]),
                  ("M", ["claude-rules/website/rules/modes/build-progress.md"])])
ok("両方を挙げる") if out.count("   - claude-rules/") == 2 else ng("片方しか出ない", out)

print("【判定】変更なし → 何も言わない")
_, out = capture([])
ok("沈黙する") if out.strip() == "" else ng("空でも出力される", out)

# ───────── 2. 統合（実際の git リポジトリを作る） ─────────
print("【統合】実 git 出力を通す（初版はここを一度も通していなかった）")

def git(repo, *args, **kw):
    return subprocess.run(["git", "-C", str(repo), *args],
                          capture_output=True, text=True, **kw)

def make_repo(tmp):
    repo = Path(tmp)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "t@example.com")
    git(repo, "config", "user.name", "t")
    for rel in (ORIGIN, GUIDE, CMDDIR + "progress.md"):
        p = repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("初期内容\n" * 40, encoding="utf-8")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "init")
    return repo

def run_in(repo, argv=None):
    """PROJ を差し替えて、実際の git 出力経由で本体を回す。"""
    real = cos.PROJ
    cos.PROJ = repo
    try:
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = cos.main(argv or [])
        return code, buf.getvalue()
    finally:
        cos.PROJ = real

with tempfile.TemporaryDirectory() as tmp:
    repo = make_repo(tmp)

    # (a) 原典のリネーム ＝ --name-only では新名しか出ず検出できなかったケース
    git(repo, "mv", ORIGIN, "claude-rules/website/documents/handoff-renamed.md")
    code, out = run_in(repo)
    ok("原典リネームを実 git 経由で拾う") if "🔔" in out else ng("拾えない", out)
    ok("終了コード 0") if code == 0 else ng(f"終了コードが {code}")
    git(repo, "reset", "-q", "--hard", "HEAD")

    # (b) ガイドの削除
    (repo / ORIGIN).write_text("直した\n", encoding="utf-8")
    git(repo, "rm", "-q", GUIDE)
    git(repo, "add", "-A")
    _, out = run_in(repo)
    ok("ガイド削除を実 git 経由で拾う") if "🔔" in out and "削除" in out else ng("誤判定", out)
    git(repo, "reset", "-q", "--hard", "HEAD")

    # (c) 非ASCII のパス ＝ core.quotepath（既定 true）でクォートされるケース
    jp = CMDDIR + "追加コマンド.md"
    (repo / jp).write_text("新コマンド\n", encoding="utf-8")
    git(repo, "add", "-A")
    quoted = git(repo, "diff", "--cached", "--name-only").stdout
    ok("前提: git は非ASCIIをクォートして返す") if '\\' in quoted else ng("前提が崩れた", quoted)
    _, out = run_in(repo)
    ok("非ASCIIパスを拾う") if "§8" in out else ng("取りこぼす", out)
    git(repo, "reset", "-q", "--hard", "HEAD")
    (repo / jp).unlink(missing_ok=True)

    # (d) 無関係な変更しかない → 沈黙
    (repo / "readme.txt").write_text("x\n", encoding="utf-8")
    git(repo, "add", "-A")
    _, out = run_in(repo)
    ok("無関係な変更では沈黙する") if out.strip() == "" else ng("誤検出", out)
    git(repo, "reset", "-q", "--hard", "HEAD")
    (repo / "readme.txt").unlink(missing_ok=True)

    # (e) 不正な範囲 → 落ちずに 0 で返る（コミットを止めない）
    err = io.StringIO()
    real_stderr, sys.stderr = sys.stderr, err
    try:
        code, out = run_in(repo, ["--range", "nonexistent1..nonexistent2"])
    finally:
        sys.stderr = real_stderr
    ok("不正な範囲でも終了コード 0") if code == 0 else ng(f"終了コードが {code}")
    ok("黙って通さず警告する") if "⚠️" in err.getvalue() else ng("警告が出ない", err.getvalue())

print("【CLI】引数の誤りは黙らせない（Codex 🟡5）")
_stderr, sys.stderr = sys.stderr, io.StringIO()   # argparse の usage を混ぜない
try:
    cos.main(["--range", "--cached"])
    ng("--range --cached が素通りする")
except SystemExit as e:
    ok("--range の値欠落を弾く") if e.code == 2 else ng(f"終了コードが {e.code}")
finally:
    sys.stderr = _stderr

# ───────── 3. 対応表の網羅性（Codex 🔴1 の再発防止） ─────────
print("【網羅】ガイド本文が挙げる原典が、すべて対応表にあるか")

# ガイドに出てくるが**テンプレートに実体が無い**もの。除外の妥当性もここで検証する。
NOT_IN_TEMPLATE = {
    "Design.md": "案件ごとに作るファイル（テンプレートにあるのは Design.sample.md）",
    "documents/handoff-archive.md": "退避時に作るファイル（同梱していない）",
}

guide_text = (proj / GUIDE).read_text(encoding="utf-8")
refs = set(re.findall(
    r"`((?:documents|rules/modes|\.claude/commands)/[A-Za-z0-9_-]+\.md"
    r"|(?:project-config|CLAUDE|Design)\.md)`", guide_text))
keys = cos.GUIDES[GUIDE].keys()

for rel in sorted(refs):
    full = f"claude-rules/website/{rel}"
    covered = any(cos.match(full, k) for k in keys)
    if rel in NOT_IN_TEMPLATE:
        if covered:
            ng(f"除外リストにあるのに対応表にもある: {rel}")
        elif (proj / full).exists():
            ng(f"除外の理由が古い（実体がある）: {rel} — {NOT_IN_TEMPLATE[rel]}")
        else:
            ok(f"除外（{NOT_IN_TEMPLATE[rel]}）: {rel}")
    elif covered:
        ok(f"対応表にある: {rel}")
    else:
        ng(f"対応表に無い（検出漏れになる）: {rel}",
           "GUIDES に追加するか、NOT_IN_TEMPLATE に理由つきで入れてください")

print("【網羅】対応表のキーが実在する（パスの打ち間違い検出）")
for key in sorted(keys):
    ok(f"実在: {key}") if (proj / key).exists() else ng(f"存在しない原典: {key}")
ok(f"実在: {GUIDE}") if (proj / GUIDE).exists() else ng(f"ガイドが無い: {GUIDE}")

print(f"\n合計: ✅{P} ❌{N}")
sys.exit(1 if N else 0)
PYEOF
