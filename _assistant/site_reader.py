"""site/ 配下を読み取り専用で参照するための実装本体。

PLAN.md §4.1 の制約を満たす 3 関数を提供する:
- `list_site_files(pattern)`: ファイル一覧（パターン指定可）
- `read_site_file(path)`: 1 ファイルの本文取得
- `grep_site(query, path_glob)`: 部分文字列検索

セキュリティ要件（同 §4.1, §9）:
- SITE_ROOT 外への参照を完全拒否（resolve(strict=True) + is_relative_to）
- symlink は本人・中間ともに拒否（site/ 外の実体を指す症状を未然に防ぐ）
- 拡張子ホワイトリスト、サイズ・件数・バイナリ判定で過大／意図外を弾く
- 隠しファイル（`.` 始まり）は無視

例外は全て `SiteReaderError` に統一する（呼び出し側 tools.py で is_error 化）。

脅威モデル: site/ は社長単独運用の静的 repo を前提とする。検証後〜read までの
TOCTOU は脅威外（同一ユーザー以外が site/ に書ける／実行中に外部更新する想定なし）。
"""

from __future__ import annotations

import fnmatch
import time
from pathlib import Path

from _assistant.config import (
    ALLOWED_SITE_EXTENSIONS,
    GREP_SITE_CONTEXT_LINES,
    GREP_SITE_MAX_HITS,
    GREP_SITE_MAX_OUTPUT_BYTES,
    LIST_SITE_FILES_MAX_ENTRIES,
    READ_SITE_FILE_MAX_BYTES,
    SITE_READER_TIMEOUT_SECONDS,
    SITE_ROOT,
)


class SiteReaderError(RuntimeError):
    """site/ 参照ツールの失敗（パス検証違反 / サイズ超過 / バイナリ等）。"""


_BINARY_SAMPLE_BYTES = 8192


def _site_root() -> Path:
    """SITE_ROOT を strict で解決して返す（テスト容易性も兼ねる）。

    site/ が存在しなければ起動段階で気付ける方が良いので strict=True。
    """
    return SITE_ROOT.resolve(strict=True)


def _has_hidden_segment(rel: Path) -> bool:
    return any(part.startswith(".") for part in rel.parts)


def _has_symlink_in_chain(path: Path, root: Path) -> bool:
    """path 自身、および root に至るまでの中間ディレクトリに symlink があるか。"""
    try:
        if path.is_symlink():
            return True
    except OSError:
        return True
    for parent in path.parents:
        if parent == root:
            break
        try:
            if parent.is_symlink():
                return True
        except OSError:
            return True
        if parent == parent.parent:  # ルート到達（root より上に出た）
            return True
    return False


def _validate_path(rel_path: str, *, require_file: bool) -> Path:
    """rel_path を site/ 内の安全な実体パスに解決する。

    - `..` などで外に出たら拒否（resolve + is_relative_to）
    - 中間 / 末端に symlink があれば拒否
    - 隠しセグメントを含むなら拒否
    - require_file=True なら拡張子ホワイトリストも確認
    """
    if not rel_path or not isinstance(rel_path, str):
        raise SiteReaderError("path が空または不正です")

    root = _site_root()
    raw = Path(rel_path)
    if raw.is_absolute():
        raise SiteReaderError(f"絶対パスは不可: {rel_path}")

    # symlink チェックを resolve より先に行う。symlink が site/ 外を指す場合に
    # 「site/ 外」より先に「symlink」エラーで弾くことで原因が分かりやすくなる。
    if _has_symlink_in_chain((root / raw), root):
        raise SiteReaderError(f"symlink は読み取り対象外: {rel_path}")

    try:
        candidate = (root / raw).resolve(strict=True)
    except FileNotFoundError as exc:
        raise SiteReaderError(f"存在しないパス: {rel_path}") from exc
    except OSError as exc:
        raise SiteReaderError(f"パス解決失敗: {rel_path} ({exc})") from exc

    if not candidate.is_relative_to(root):
        raise SiteReaderError(f"site/ 外への参照を拒否: {rel_path}")

    rel = candidate.relative_to(root)
    if _has_hidden_segment(rel):
        raise SiteReaderError(f"隠しファイル/ディレクトリは対象外: {rel_path}")

    if require_file:
        if not candidate.is_file():
            raise SiteReaderError(f"ファイルではありません: {rel_path}")
        if candidate.suffix.lower() not in ALLOWED_SITE_EXTENSIONS:
            raise SiteReaderError(
                f"許可されていない拡張子: {candidate.suffix or '(なし)'} （許可: {sorted(ALLOWED_SITE_EXTENSIONS)}）"
            )

    return candidate


def _looks_binary(path: Path) -> bool:
    try:
        with path.open("rb") as fh:
            chunk = fh.read(_BINARY_SAMPLE_BYTES)
    except OSError as exc:
        raise SiteReaderError(f"読み取り失敗: {path.name} ({exc})") from exc
    return b"\x00" in chunk


def _iter_candidate_files(root: Path):
    """site/ 配下の許可拡張子ファイルを列挙する（隠し・symlink を除外）。"""
    for path in root.rglob("*"):
        try:
            if path.is_symlink() or not path.is_file():
                continue
        except OSError:
            continue
        rel = path.relative_to(root)
        if _has_hidden_segment(rel):
            continue
        if path.suffix.lower() not in ALLOWED_SITE_EXTENSIONS:
            continue
        if _has_symlink_in_chain(path, root):
            continue
        yield path, rel


def list_site_files(pattern: str | None = None) -> list[str]:
    """site/ 配下の許可拡張子ファイル一覧を返す。

    pattern は fnmatch スタイル（例: `clients/*/projects/*/memo.html`）。
    件数上限を超えた場合は例外（途中で打ち切らない）。
    戻り値はサイトルートからの相対パス文字列のリスト。
    """
    root = _site_root()
    results: list[str] = []
    for _path, rel in _iter_candidate_files(root):
        rel_str = rel.as_posix()
        if pattern and not fnmatch.fnmatch(rel_str, pattern):
            continue
        results.append(rel_str)
        if len(results) > LIST_SITE_FILES_MAX_ENTRIES:
            raise SiteReaderError(
                f"一覧件数が上限 {LIST_SITE_FILES_MAX_ENTRIES} を超えました。pattern で絞り込んでください"
            )
    results.sort()
    return results


def read_site_file(path: str) -> str:
    """site/ 内ファイルを UTF-8 文字列として返す。

    - サイズ上限超過は例外
    - バイナリ判定（NUL バイト）も例外
    """
    target = _validate_path(path, require_file=True)
    size = target.stat().st_size
    if size > READ_SITE_FILE_MAX_BYTES:
        raise SiteReaderError(
            f"ファイルサイズが上限 {READ_SITE_FILE_MAX_BYTES} バイトを超えています "
            f"(size={size}): {path}。要約読みや grep_site で範囲を絞ってください"
        )
    if _looks_binary(target):
        raise SiteReaderError(f"バイナリ判定（NUL バイト検出）: {path}")
    try:
        return target.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise SiteReaderError(f"UTF-8 で読めません: {path} ({exc})") from exc


def grep_site(query: str, path_glob: str | None = None) -> str:
    """site/ 配下から部分文字列検索（前後 N 行の文脈つき）。

    - GREP_SITE_MAX_HITS 件、GREP_SITE_MAX_OUTPUT_BYTES バイトで打ち切り
    - timeout 監視（SITE_READER_TIMEOUT_SECONDS 超過で例外）
    - バイナリは _looks_binary でスキップ
    """
    if not query or not query.strip():
        raise SiteReaderError("query が空または空白のみです")

    root = _site_root()
    started = time.monotonic()
    deadline = started + SITE_READER_TIMEOUT_SECONDS

    hits = 0
    chunks: list[str] = []
    output_size = 0
    truncated = False

    for path, rel in _iter_candidate_files(root):
        if time.monotonic() > deadline:
            raise SiteReaderError(
                f"grep_site が {SITE_READER_TIMEOUT_SECONDS} 秒以内に終わりませんでした。"
                "path_glob で対象を絞ってください"
            )

        rel_str = rel.as_posix()
        if path_glob and not fnmatch.fnmatch(rel_str, path_glob):
            continue
        # 1 ファイルあたり読み込み上限。サイレントスキップは気付きにくいので注記出力する。
        try:
            file_size = path.stat().st_size
        except OSError:
            continue
        if file_size > READ_SITE_FILE_MAX_BYTES:
            chunks.append(
                f"(skipped: {rel_str} は {file_size} バイトで上限 {READ_SITE_FILE_MAX_BYTES} 超過。"
                "read_site_file も使えません)\n---\n"
            )
            continue
        try:
            if _looks_binary(path):
                continue
        except SiteReaderError:
            continue

        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue

        lines = text.splitlines()
        for idx, line in enumerate(lines):
            if query not in line:
                continue
            start = max(0, idx - GREP_SITE_CONTEXT_LINES)
            end = min(len(lines), idx + GREP_SITE_CONTEXT_LINES + 1)
            block_lines = [
                f"{rel_str}:{i + 1}{'>' if i == idx else ' '}: {lines[i]}"
                for i in range(start, end)
            ]
            block = "\n".join(block_lines) + "\n---\n"
            if output_size + len(block.encode("utf-8")) > GREP_SITE_MAX_OUTPUT_BYTES:
                truncated = True
                break
            chunks.append(block)
            output_size += len(block.encode("utf-8"))
            hits += 1
            if hits >= GREP_SITE_MAX_HITS:
                truncated = True
                break
        if truncated:
            break

    if not chunks:
        return f"(no matches for {query!r})"

    suffix = (
        f"\n(打ち切り: hits={hits} / output_bytes={output_size}。"
        "query や path_glob を絞り込んでください)\n"
        if truncated
        else ""
    )
    return "".join(chunks) + suffix
