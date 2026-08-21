#!/usr/bin/env python3
"""bin/build-system-map.py の回帰テスト（rules/testing.md 準拠・test-build-command-map.py と同じ型）。

守りたい約束：
1. 壊れた SYSTEM.md からは黙って壊れた HTML を出さない（生成を失敗させる）
2. 地図ドリフトは機械で検出する＝SYSTEM.md に新モードが増えたのに GROUPS 未分類なら
   赤い「未分類」枠に出る／このテストも落ちて GROUPS 更新を促す
3. SYSTEM.md を直したあとの「生成忘れ」を検出する

使い方: python3 bin/test-build-system-map.py
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("bsm", ROOT / "bin" / "build-system-map.py")
bsm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bsm)

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


MODES_MD = "| モード | 目的 | 起動 | 読む | 書く |\n|---|---|---|---|---|\n"


def want_raises(md, word):
    try:
        bsm.parse(md)
    except bsm.SourceError as e:
        assert word in str(e), f"想定と違うエラー: {e}"
        return
    raise AssertionError("失敗すべきところで成功した")


print("=== パーサ（壊れた正から壊れたHTMLを出さない） ===")

check("モード地図の表が無ければ失敗する",
      lambda: want_raises("# t\n\n| A | B |\n|---|---|\n| x | y |\n", "モード"))
check("列数ずれは失敗する",
      lambda: want_raises(MODES_MD + "| a | b |\n", "列数"))
check("区切り行の列数ずれも失敗する",
      lambda: want_raises("| A | B | C |\n|---|---|\n| a | b | c |\n", "区切り"))
check("閉じないコードブロックは失敗する",
      lambda: want_raises(MODES_MD + "| a | b | c | d | e |\n\n```\nx\n", "閉じられていない"))
check("「モード」表が2つあれば失敗する",
      lambda: want_raises(MODES_MD + "| a | b | c | d | e |\n\n" + MODES_MD + "| f | g | h | i | j |\n", "2つ"))
check("「目的」列が無いモード表は失敗する",
      lambda: want_raises("| モード | 内容 |\n|---|---|\n| a | b |\n", "目的"))
check("短名の重複は失敗する（カードの黙った上書き防止）",
      lambda: want_raises(MODES_MD + "| Main | a | x | x | x |\n| Main（別） | b | x | x | x |\n", "重複"))
check("短名が空になる行は失敗する",
      lambda: want_raises(MODES_MD + "| （かっこだけ） | a | x | x | x |\n", "空"))


def t_pipe():
    tokens, _ = bsm.parse(MODES_MD + "| a \\| b | x | x | x | x |\n")
    modes = next(p for k, p in tokens if k == "modes")
    assert modes["rows"][0][0] == "a | b", "エスケープした | が文字として復元されていない"


check("セル内の \\| で列がずれない", t_pipe)


def t_code_vs_bold():
    out = bsm.inline("`**not bold**`")
    assert "<strong>" not in out, "コード内の ** が強調になった"
    assert "**not bold**" in out, "コードの中身が失われた"


check("コード内の ** が強調に化けない", t_code_vs_bold)


def t_short():
    assert bsm.short_name("**hp-loop**（マルチサイト）") == "hp-loop"
    assert bsm.short_name("Main（業務）") == "Main"
    assert bsm.short_name("Overseer") == "Overseer"


check("モードの短名の切り出し", t_short)


def t_escape():
    """<script> がどの経路（本文・SVG・カード）でも生きたタグにならないこと。"""
    assert bsm.inline("<script>x</script>") == "&lt;script&gt;x&lt;/script&gt;"
    md = MODES_MD + "| <img src=x> | <script>alert(1)</script> | x | x | x |\n"
    _, modes = bsm.parse(md)
    svg, groups = bsm.build_svg(modes)
    assert "<img" not in svg and "&lt;img src=x&gt;" in svg, "SVGのモード名が素通り"
    cards = bsm.build_cards(modes, groups)
    assert "<script>" not in cards and "&lt;script&gt;" in cards, "カードの目的セルが素通り"


check("HTMLエスケープは3経路（本文・SVG・カード）とも維持", t_escape)


print("=== 地図ドリフト（未分類の見える化） ===")


def t_leftover_visible():
    tokens, modes = bsm.parse(MODES_MD + "| 新モードX | x | x | x | x |\n")
    svg, groups = bsm.build_svg(modes)
    left = [g for g in groups if "未分類" in g[0]]
    assert left and "新モードX" in left[0][2], "GROUPS 未分類のモードが図から消えた"
    assert "新モードX" in svg, "未分類モードが SVG に描かれていない"


check("GROUPS 未分類のモードは赤い未分類枠に出る（黙って消えない）", t_leftover_visible)


def t_ghost_in_groups():
    """逆方向のドリフト＝廃止・改名済みモードが GROUPS に残ったら生成を止める。"""
    try:
        bsm.check_groups(["Main"], [("g", "sky", ["Main", "廃止済みモード"])])
    except bsm.SourceError as e:
        assert "廃止済みモード" in str(e)
        return
    raise AssertionError("失敗すべきところで成功した")


check("GROUPS に残った廃止モード名で失敗する", t_ghost_in_groups)


def t_double_membership():
    """同じ短名が2グループに居たら生成を止める（カードの重複描画防止）。"""
    try:
        bsm.check_groups(["Main"], [("g1", "sky", ["Main"]), ("g2", "amber", ["Main"])])
    except bsm.SourceError as e:
        assert "両方" in str(e)
        return
    raise AssertionError("失敗すべきところで成功した")


check("GROUPS の二重所属で失敗する", t_double_membership)


def t_svg_scales():
    """グループ数が増えたら SVG は全体幅を広げる（見切れ・負のチップ幅を作らない）。"""
    md = ("| モード | 目的 |\n|---|---|\n"
          + "".join(f"| m{i:02d} | x |\n" for i in range(10)))
    _, modes = bsm.parse(md)
    old = bsm.GROUPS
    bsm.GROUPS = [(f"グループ{i}", "sky", [f"m{i:02d}"]) for i in range(10)]
    try:
        svg, groups = bsm.build_svg(modes)
    finally:
        bsm.GROUPS = old
    w = int(svg.split('viewBox="0 0 ')[1].split(" ")[0])
    assert w >= 20 * 2 + 10 * 210 + 9 * 16, f"10グループなのに幅が広がっていない（{w}px）"
    assert 'width="-' not in svg and 'font-size="-' not in svg, "負のサイズが出た"


check("グループ数が増えたら SVG の全体幅が広がる（見切れ防止）", t_svg_scales)


print("=== いまの SYSTEM.md ===")


def t_current_all_classified():
    """SYSTEM.md の全モードが GROUPS に分類済みか＝新モード追加時にここが落ちて更新を促す。"""
    tokens, modes = bsm.parse(bsm.SRC.read_text(encoding="utf-8"))
    _, groups = bsm.build_svg(modes)
    left = [g for g in groups if "未分類" in g[0]]
    assert not left, (
        f"SYSTEM.md に GROUPS 未分類のモードがある: {left[0][2]}"
        "（bin/build-system-map.py の GROUPS に追加して再生成する）"
    )
    bsm.check_groups([bsm.short_name(r[0]) for r in modes["rows"]])   # 逆方向（廃止残存・二重所属）も


check("SYSTEM.md の全モードが GROUPS 分類済み（双方向）", t_current_all_classified)


def t_generated_fresh():
    """生成物が正と一致するか＝SYSTEM.md を直したあとの生成忘れを検出する。

    ★本番の生成物には書かない★＝generate() をメモリ上で呼んで比較するだけ
    （テストが site/ を書き換えて2回目に自己治癒する穴を塞ぐ。2026-08-21 Codexレビュー🔴）。
    """
    out = ROOT / "site" / "docs" / "system-map.html"
    assert out.exists(), "生成物が無い＝python3 bin/build-system-map.py を一度も流していない"
    doc = bsm.generate(bsm.SRC.read_text(encoding="utf-8"))
    assert out.read_text(encoding="utf-8") == doc, \
        "生成物が古い＝SYSTEM.md か GROUPS を直したあと build-system-map.py を流していない"


check("生成物が正と一致している（生成忘れの検出・本番へ書かない）", t_generated_fresh)

print(f"\n合計: 合格 {ok} ／ 不合格 {ng}")
sys.exit(1 if ng else 0)
