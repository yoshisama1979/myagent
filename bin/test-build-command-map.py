#!/usr/bin/env python3
"""bin/build-command-map.py の回帰テスト（rules/testing.md 準拠）。

★なぜ要るか★＝2026-08-19 の Codex レビューで、自作の簡易 Markdown レンダラが
**黙って壊れた HTML を出す**ことが実測で判明した（セル内の `|` で 2列の表が 3列になる／
コード内の `**` が強調に化ける）。社長が見る一次資料の生成器なので、
**気づけないズレを作るくらいなら生成を止める**方針へ変えた。その方針をここで固定する。

使い方: python3 bin/test-build-command-map.py
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("bcm", ROOT / "bin" / "build-command-map.py")
bcm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bcm)

ok = ng = 0


def check(name, fn):
    global ok, ng
    try:
        fn()
        print(f"  ✅ {name}")
        ok += 1
    except Exception as e:  # noqa: BLE001 — テストなので全部拾って報告する
        print(f"  ❌ {name} — {e}")
        ng += 1


def want_raises(md, word):
    try:
        bcm.render(md)
    except bcm.SourceError as e:
        assert word in str(e), f"想定と違うエラー: {e}"
        return
    raise AssertionError("生成が失敗すべきところで成功した")


print("=== レンダラ ===")


def t_pipe():
    out = bcm.render("| A | B |\n|---|---|\n| x \\| y | z |\n")
    assert out.count("<td") == 2, f"列数={out.count('<td')}（期待2）"
    assert "x | y" in out, "エスケープした | が文字として復元されていない"


check("セル内の \\| で列がずれない", t_pipe)
def t_code_vs_bold():
    out = bcm.render("| A | B |\n|---|---|\n| `**not bold**` | z |\n")
    assert "<strong>" not in out, "コード内の ** が強調になった"
    assert "**not bold**" in out, "コードの中身が失われた"


check("コード内の ** が強調に化けない", t_code_vs_bold)
check("列数不一致は生成失敗", lambda: want_raises("| A | B |\n|---|---|\n| x |\n", "列数"))
check("空の表は生成失敗", lambda: want_raises("| A | B |\n|---|---|\n", "1行も無い"))
check("コードブロックは生成失敗", lambda: want_raises("```\ncode\n```\n", "コードブロック"))


def t_escape():
    out = bcm.render("| A |\n|---|\n| <script>alert(1)</script> |\n")
    assert "<script>" not in out and "&lt;script&gt;" in out, "HTMLエスケープが漏れている"


check("HTMLエスケープは維持", t_escape)


print("=== 早見表そのもの ===")


def t_all_classified():
    """全コマンドが早見表のどこかに載っているか＝振り分けの取りこぼし防止。

    ★2026-08-19 の Codex レビューで、14コマンドが一度も載っていないことが判明した★
    （/hana-todos・/questions-deck・/reviewer-cycle 等）。載っていないものへは振り分けられない。
    """
    src = (ROOT / "rules" / "command-map.md").read_text(encoding="utf-8")
    missing = [
        p.stem for p in sorted((ROOT / ".claude" / "commands").glob("*.md"))
        if f"/{p.stem}" not in src
    ]
    assert not missing, f"早見表に未掲載: {', '.join('/' + m for m in missing)}"


check("全コマンドが早見表に分類されている", t_all_classified)


def t_generated_fresh():
    """生成物が正と一致するか＝command-map.md を直したあとの生成忘れを検出する。"""
    out = ROOT / "site" / "docs" / "command-map.html"
    before = out.read_text(encoding="utf-8") if out.exists() else None
    rc = subprocess.run([sys.executable, str(ROOT / "bin" / "build-command-map.py")],
                        capture_output=True, text=True).returncode
    assert rc == 0, "生成に失敗した"
    assert out.read_text(encoding="utf-8") == before, \
        "生成物が古い＝rules/command-map.md を直したあと build-command-map.py を流していない"


check("生成物が正と一致している（生成忘れの検出）", t_generated_fresh)

print(f"\n{ok} 件成功 / {ng} 件失敗")
sys.exit(1 if ng else 0)
