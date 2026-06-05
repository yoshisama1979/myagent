"""site_reader のパストラバーサル防御と機能テスト。

各テストは pytest tmp_path に擬似 site/ を作り、`_assistant.site_reader.SITE_ROOT`
を monkeypatch で差し替えて検証する。実際の myagent/site/ には触れない。
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from _assistant import site_reader
from _assistant.site_reader import (
    SiteReaderError,
    grep_site,
    list_site_files,
    read_site_file,
)


@pytest.fixture
def fake_site(tmp_path, monkeypatch):
    """tmp_path/site/ を作り、site_reader.SITE_ROOT をそこへ向ける。"""
    root = tmp_path / "site"
    root.mkdir()
    monkeypatch.setattr(site_reader, "SITE_ROOT", root)
    return root


# ---- パストラバーサル防御 -------------------------------------------------


def test_rejects_parent_traversal(fake_site, tmp_path):
    """../ で site/ 外に出ようとしたら拒否される。"""
    outside = tmp_path / "secret.md"
    outside.write_text("secret", encoding="utf-8")

    with pytest.raises(SiteReaderError):
        read_site_file("../secret.md")


def test_rejects_absolute_path(fake_site):
    with pytest.raises(SiteReaderError) as exc_info:
        read_site_file("/etc/passwd")
    assert "絶対パス" in str(exc_info.value)


def test_rejects_symlink_file(fake_site, tmp_path):
    """site/ 内に作られた symlink ファイル自体を拒否（中身が安全でも）。"""
    target = tmp_path / "outside.md"
    target.write_text("outside content", encoding="utf-8")
    link = fake_site / "link.md"
    os.symlink(target, link)

    with pytest.raises(SiteReaderError) as exc_info:
        read_site_file("link.md")
    assert "symlink" in str(exc_info.value)


def test_rejects_symlink_in_parent_dir(fake_site, tmp_path):
    """中間ディレクトリが symlink でも拒否。"""
    real_dir = tmp_path / "real"
    real_dir.mkdir()
    (real_dir / "note.md").write_text("hi", encoding="utf-8")
    link_dir = fake_site / "linked"
    os.symlink(real_dir, link_dir)

    with pytest.raises(SiteReaderError) as exc_info:
        read_site_file("linked/note.md")
    assert "symlink" in str(exc_info.value)


def test_rejects_hidden_segment(fake_site):
    """`.` 始まりは隠しファイル扱いで拒否。"""
    (fake_site / ".secret.md").write_text("x", encoding="utf-8")

    with pytest.raises(SiteReaderError) as exc_info:
        read_site_file(".secret.md")
    assert "隠し" in str(exc_info.value)


def test_rejects_hidden_dir_segment(fake_site):
    hidden_dir = fake_site / ".cache"
    hidden_dir.mkdir()
    (hidden_dir / "f.md").write_text("x", encoding="utf-8")

    with pytest.raises(SiteReaderError):
        read_site_file(".cache/f.md")


def test_rejects_disallowed_extension(fake_site):
    (fake_site / "secret.env").write_text("API_KEY=...", encoding="utf-8")
    (fake_site / "script.py").write_text("print('hi')", encoding="utf-8")

    with pytest.raises(SiteReaderError) as exc_info:
        read_site_file("secret.env")
    assert "拡張子" in str(exc_info.value)

    with pytest.raises(SiteReaderError):
        read_site_file("script.py")


def test_rejects_oversized_file(fake_site):
    """READ_SITE_FILE_MAX_BYTES を超えると拒否（途中まで読まない）。"""
    big = fake_site / "big.md"
    big.write_text("x" * (200 * 1024), encoding="utf-8")  # 200KB

    with pytest.raises(SiteReaderError) as exc_info:
        read_site_file("big.md")
    assert "ファイルサイズ" in str(exc_info.value)


def test_rejects_binary_with_nul(fake_site):
    """NUL バイトを含むファイルは「バイナリ」として拒否。"""
    binary = fake_site / "bin.txt"
    binary.write_bytes(b"hello\x00world")

    with pytest.raises(SiteReaderError) as exc_info:
        read_site_file("bin.txt")
    assert "バイナリ" in str(exc_info.value)


def test_rejects_nonexistent(fake_site):
    with pytest.raises(SiteReaderError) as exc_info:
        read_site_file("no-such.md")
    assert "存在" in str(exc_info.value)


def test_rejects_empty_path(fake_site):
    with pytest.raises(SiteReaderError):
        read_site_file("")


# ---- list_site_files ------------------------------------------------------


def test_list_finds_allowed_files(fake_site):
    (fake_site / "a.md").write_text("a", encoding="utf-8")
    (fake_site / "b.html").write_text("b", encoding="utf-8")
    sub = fake_site / "sub"
    sub.mkdir()
    (sub / "c.json").write_text("{}", encoding="utf-8")

    files = list_site_files()
    assert sorted(files) == ["a.md", "b.html", "sub/c.json"]


def test_list_excludes_disallowed_extension(fake_site):
    (fake_site / "ok.md").write_text("x", encoding="utf-8")
    (fake_site / "ng.py").write_text("x", encoding="utf-8")

    files = list_site_files()
    assert files == ["ok.md"]


def test_list_excludes_hidden(fake_site):
    (fake_site / "visible.md").write_text("x", encoding="utf-8")
    (fake_site / ".hidden.md").write_text("x", encoding="utf-8")
    hidden_dir = fake_site / ".hidden_dir"
    hidden_dir.mkdir()
    (hidden_dir / "x.md").write_text("x", encoding="utf-8")

    files = list_site_files()
    assert files == ["visible.md"]


def test_list_excludes_symlinks(fake_site, tmp_path):
    target = tmp_path / "outside.md"
    target.write_text("x", encoding="utf-8")
    os.symlink(target, fake_site / "link.md")
    (fake_site / "real.md").write_text("x", encoding="utf-8")

    files = list_site_files()
    assert files == ["real.md"]


def test_list_pattern_filter(fake_site):
    (fake_site / "memo.html").write_text("x", encoding="utf-8")
    (fake_site / "decisions.html").write_text("x", encoding="utf-8")
    (fake_site / "notes.md").write_text("x", encoding="utf-8")

    files = list_site_files(pattern="*.html")
    assert sorted(files) == ["decisions.html", "memo.html"]


def test_list_raises_when_over_cap(fake_site, monkeypatch):
    monkeypatch.setattr(site_reader, "LIST_SITE_FILES_MAX_ENTRIES", 3)
    for i in range(5):
        (fake_site / f"f{i}.md").write_text("x", encoding="utf-8")

    with pytest.raises(SiteReaderError) as exc_info:
        list_site_files()
    assert "上限" in str(exc_info.value)


# ---- read_site_file (正常系) ---------------------------------------------


def test_read_returns_utf8_text(fake_site):
    (fake_site / "doc.md").write_text("こんにちは\n世界", encoding="utf-8")
    assert read_site_file("doc.md") == "こんにちは\n世界"


# ---- grep_site ------------------------------------------------------------


def test_grep_finds_with_context(fake_site):
    (fake_site / "a.md").write_text("line1\nline2 needle here\nline3\nline4", encoding="utf-8")
    out = grep_site("needle")
    assert "a.md:2" in out
    assert "line1" in out  # 前文脈
    assert "line3" in out  # 後文脈


def test_grep_no_matches(fake_site):
    (fake_site / "a.md").write_text("nothing", encoding="utf-8")
    assert "no matches" in grep_site("xyz")


def test_grep_path_glob_filters(fake_site):
    sub = fake_site / "sub"
    sub.mkdir()
    (fake_site / "a.md").write_text("needle", encoding="utf-8")
    (sub / "b.md").write_text("needle", encoding="utf-8")

    out = grep_site("needle", path_glob="sub/*.md")
    assert "sub/b.md" in out
    assert "a.md:" not in out.replace("sub/b.md", "")


def test_grep_truncates_on_max_hits(fake_site, monkeypatch):
    monkeypatch.setattr(site_reader, "GREP_SITE_MAX_HITS", 2)
    (fake_site / "a.md").write_text("hit\nhit\nhit\nhit", encoding="utf-8")
    out = grep_site("hit")
    assert "打ち切り" in out


def test_grep_skips_binary(fake_site):
    (fake_site / "a.md").write_text("needle in text", encoding="utf-8")
    # 拡張子は許可される .txt だが NUL バイト含み → スキップされる
    (fake_site / "b.txt").write_bytes(b"needle\x00")
    out = grep_site("needle")
    assert "a.md" in out
    assert "b.txt" not in out


def test_grep_empty_query_raises(fake_site):
    with pytest.raises(SiteReaderError):
        grep_site("")


def test_grep_whitespace_only_query_raises(fake_site):
    with pytest.raises(SiteReaderError):
        grep_site("   \t  ")


def test_list_excludes_symlinked_directory_contents(fake_site, tmp_path):
    """ディレクトリ symlink 経由で外部ファイルが list に漏れないこと。"""
    real_dir = tmp_path / "real"
    real_dir.mkdir()
    (real_dir / "should-not-leak.md").write_text("secret", encoding="utf-8")
    os.symlink(real_dir, fake_site / "linked")
    (fake_site / "real.md").write_text("ok", encoding="utf-8")

    files = list_site_files()
    assert files == ["real.md"]
    assert all("should-not-leak" not in f for f in files)


def test_grep_excludes_symlinked_directory_contents(fake_site, tmp_path):
    """ディレクトリ symlink 経由の外部ファイルが grep にもマッチしないこと。"""
    real_dir = tmp_path / "real"
    real_dir.mkdir()
    (real_dir / "x.md").write_text("needle outside", encoding="utf-8")
    os.symlink(real_dir, fake_site / "linked")
    (fake_site / "inside.md").write_text("needle inside", encoding="utf-8")

    out = grep_site("needle")
    assert "inside.md" in out
    assert "linked" not in out


def test_grep_skips_oversized_file(fake_site):
    """1 ファイルが READ_SITE_FILE_MAX_BYTES を超えたら本文は読まず、注記だけ残す。"""
    (fake_site / "small.md").write_text("needle here\n", encoding="utf-8")
    big = fake_site / "big.md"
    big.write_text("needle\n" + "x" * (200 * 1024), encoding="utf-8")  # 200KB

    out = grep_site("needle")
    assert "small.md" in out
    assert "skipped: big.md" in out
    # big.md の本文中の "needle" 行は読まれない（注記だけ）
    assert "big.md:1" not in out
