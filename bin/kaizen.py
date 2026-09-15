#!/usr/bin/env python3
"""kaizen — 共有カイゼン台帳（data/hp-improve/skill-kaizen.md）の見出し解釈・ロック付き採番・退避・書式検査（LLM なし）。

契機＝2026-09-14 triage 依頼（data/triage/handoff-dev-skill-kaizen-20260914.md）。3つの壊れ方を同じ道具で塞ぐ：
① **数え落とし**：台帳の型は「`### K-NNN` の独立見出し」だが、8/23 以降 188件が `## K-NNN` で書かれ、
   `###` しか項目にしない道具が**直前エントリに飲み込んで**件数を半分に・「8KB超の9件」を捏造した
   （O-019・O-035 と同型の3回目。実測 2026-09-14＝## と ### の両方で区切ると 8KB超は0件・最大 4.3KB）。
② **採番の衝突**：9系統（hp-loop 各サイト・blog-loop・partner・overseer…）がロック無しで「最大番号+1」を
   取りに行く read-modify-write で、ID が62種衝突した（O-077・K-637）。
③ **退避と追記の衝突**：全ループが毎日追記するので、手作業で丸ごと書き換えると追記を上書きして消す。

  kaizen.py list [--heads]            JSON（件数・ID・書式外・重複・8KB超・閉じていないコードブロック）
  kaizen.py lint                      書式外（## K-）・重複・閉じていないコードブロックがあれば非0で名指し
  kaizen.py add --title T [--lane L]  本文は標準入力。ロックを取り、台帳＋archive の素の K 番号の最大+1 を採り、
                                      `### K-NNN — T（L・日付）` を末尾に足して ID を出す
  kaizen.py move LINE:HASH [...]      ロックを取り、list の時点から中身が変わっていなければ原文のまま archive へ移す
                                      （①archive へ追記 →②存在確認 →③本体から削除。1つでも合わなければ何もしない）
  kaizen.py lock -- CMD [ARGS...]     ロックを持ったまま CMD を実行（手作業の書き換えを追記と衝突させない）
  kaizen.py normalize [--apply]       重複IDの後の方に英小文字の枝番（K-577→K-577b）・`## K-` を `### K-` へ。既定は下見。
                                      --apply でロックを取って見出し行だけ書き換え、対応表（旧ID→新ID・行・日付）を残す。
                                      振り直さない＝既存の参照（178ファイル・台帳内76箇所）を壊さない（2026-09-15 社長ご決定）

設計：
- **見出しの解釈はこのファイルが正**。bin/pending-scan.py と bin/ledger-watch.py はここを import する（二重に持たない）。
- 項目＝行頭の `##` または `###` の直後に K-ID（数字を含む）がある行。**見本の `K-NNN` は数字が無いので数えない**。
- **コードブロックの中身は読み飛ばさない**＝実物の台帳は「エントリ形式」の ``` が閉じていない（2026-09-14 実測）。
  読み飛ばすとその後の見出しが全部コードブロック扱いになり0件になる。代わりに lint で「閉じていない」と申告する。
- エントリの範囲＝その見出しから、次の `#`〜`###` 見出し（K か否かを問わない）の手前まで。
- 書き込みは一時ファイル→os.replace（途中で死んでも半端なファイルを残さない）。
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.environ.get("KAIZEN_LEDGER") or os.path.join(ROOT, "data", "hp-improve", "skill-kaizen.md")
IDMAP = os.environ.get("KAIZEN_IDMAP") or os.path.join(ROOT, "data", "hp-improve", "skill-kaizen-id-map.md")
ARCHIVE = os.environ.get("KAIZEN_ARCHIVE") or os.path.join(ROOT, "data", "hp-improve", "skill-kaizen-archive.md")
LOCK = os.environ.get("KAIZEN_LOCK") or os.path.join(ROOT, "data", "hp-improve", ".skill-kaizen.lock")
JST = datetime.timezone(datetime.timedelta(hours=9))
HEAD_RE = re.compile(r"^(#{2,3})[ \t]+(K-(?:[A-Za-z]+-)?\d+[a-z]?)(?![0-9A-Za-z-])")
ANY_HEAD_RE = re.compile(r"^#{1,3}[ \t]")
PLAIN_NUM_RE = re.compile(r"^K-(\d+)[a-z]?$")
DECIDED_RE = re.compile(r"反映済み|却下")
FENCE_RE = re.compile(r"^\s*```")
LANE_RE = re.compile(r"^[A-Za-z0-9_:-]{1,40}$")
SPEC_RE = re.compile(r"^(\d{1,7}):([0-9a-f]{12})$")
BIG = 8 * 1024


def die(code, msg):
    print(f"kaizen: {msg}", file=sys.stderr)
    sys.exit(code)


def parse(text):
    """台帳の本文 → 項目の一覧と書式の申告。本文そのものは返さない（head は見出し行だけ）。"""
    lines = text.split("\n")
    heads = []
    fences = 0
    for i, ln in enumerate(lines):
        if FENCE_RE.match(ln):
            fences += 1
        m = HEAD_RE.match(ln)
        if m:
            heads.append((i, m.group(1), m.group(2)))
    entries = []
    for i, level, kid in heads:
        end = len(lines)
        for j in range(i + 1, len(lines)):
            if ANY_HEAD_RE.match(lines[j]):
                end = j
                break
        body = "\n".join(lines[i:end])
        raw = body.encode("utf-8")
        entries.append({"id": kid, "line": i + 1, "level": level, "bytes": len(raw),
                        "hash": hashlib.sha1(raw).hexdigest()[:12],
                        "decided": bool(DECIDED_RE.search(body)), "head": lines[i][:120]})
    counts = {}
    for e in entries:
        counts[e["id"]] = counts.get(e["id"], 0) + 1
    return {"count": len(entries), "entries": entries,
            "ids": len(counts),
            "duplicates": {k: v for k, v in counts.items() if v > 1},
            "offformat": [{"line": e["line"], "id": e["id"]} for e in entries if e["level"] != "###"],
            "over_8kb": sum(1 for e in entries if e["bytes"] > BIG),
            "max_entry_bytes": max((e["bytes"] for e in entries), default=0),
            "unclosed_fence": fences % 2 == 1}


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def _atomic_write(path, text):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".kaizen-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        try:
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
        except OSError:
            pass
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def locked():
    wait = float(os.environ.get("KAIZEN_LOCK_WAIT", "60"))
    os.makedirs(os.path.dirname(os.path.abspath(LOCK)), exist_ok=True)
    fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o644)
    deadline = time.time() + wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.time() >= deadline:
                os.close(fd)
                die(4, f"台帳のロックを {wait:g}秒待っても取れません（別の追記・退避が進行中）＝何もしていません")
            time.sleep(0.05)
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def cmd_list(a):
    r = parse(_read(LEDGER))
    if not a.heads:
        for e in r["entries"]:
            e.pop("head", None)          # 見出しには取引先名が入りうる＝要るときだけ出す
    print(json.dumps(r, ensure_ascii=False, indent=2))
    return 0


def cmd_lint(_a):
    r = parse(_read(LEDGER))
    msgs = []
    if r["offformat"]:
        top = ", ".join(f"{o['id']}@{o['line']}行" for o in r["offformat"][:10])
        msgs.append(f"書式外 {len(r['offformat'])}件（`## K-` で書かれている＝`### K-NNN` の独立見出しにする）: {top}")
    if r["duplicates"]:
        top = ", ".join(f"{k}×{v}" for k, v in list(r["duplicates"].items())[:10])
        msgs.append(f"重複 ID {len(r['duplicates'])}種（決めたとき、どの項目に効いたか言えない）: {top}")
    if r["unclosed_fence"]:
        msgs.append("閉じていないコードブロックがあります（``` の数が奇数）")
    print("\n".join(msgs) if msgs else f"書式・ID とも問題なし（{r['count']}件）")
    return 1 if msgs else 0


def cmd_add(a):
    title = a.title or ""
    if not title.strip() or "\n" in title or "\r" in title:
        die(2, "--title は1行で必須です（見出しを壊さないため改行は入れない）")
    lane = a.lane or os.environ.get("MYAGENT_AGENT", "")
    if lane and not LANE_RE.match(lane):
        die(2, f"--lane は英数字・_・:・- で40字まで: {lane!r}")
    body = sys.stdin.read()
    if not body.strip():
        die(2, "本文（標準入力）が空です＝足していません")
    with locked():
        led = _read(LEDGER)
        nums = []
        for text in (led, _read(ARCHIVE)):
            for e in parse(text)["entries"]:
                m = PLAIN_NUM_RE.match(e["id"])
                if m:
                    nums.append(int(m.group(1)))
        kid = f"K-{max(nums, default=0) + 1:03d}"
        today = datetime.datetime.now(JST).date().isoformat()
        tag = "（" + (f"{lane}・" if lane else "") + today + "）"
        block = f"### {kid} — {title.strip()}{tag}\n{body.rstrip()}\n"
        sep = "" if (not led or led.endswith("\n\n")) else ("\n" if led.endswith("\n") else "\n\n")
        _atomic_write(LEDGER, led + sep + block)
    print(kid)
    return 0


def cmd_move(a):
    specs = []
    for s in a.specs:
        m = SPEC_RE.match(s)
        if not m:
            die(2, f"指定は LINE:HASH（list の line と hash）です: {s!r}")
        specs.append((int(m.group(1)), m.group(2)))
    if len(set(specs)) != len(specs):
        die(2, "同じ指定が重複しています")
    with locked():
        led = _read(LEDGER)
        r = parse(led)
        by_line = {e["line"]: e for e in r["entries"]}
        picked = []
        for line, h in specs:
            e = by_line.get(line)
            if not e or e["hash"] != h:
                die(3, f"{line}:{h} は list の時点から変わっています（行がずれた／中身が変わった）＝何も動かしていません。"
                       "もう一度 list してから指定してください")
            picked.append(e)
        lines = led.split("\n")
        texts, drop = [], set()
        for e in picked:
            start = e["line"] - 1
            end = len(lines)
            for j in range(start + 1, len(lines)):
                if ANY_HEAD_RE.match(lines[j]):
                    end = j
                    break
            texts.append("\n".join(lines[start:end]).rstrip("\n"))
            drop.update(range(start, end))
        arc = _read(ARCHIVE)
        sep = "" if (not arc or arc.endswith("\n\n")) else ("\n" if arc.endswith("\n") else "\n\n")
        _atomic_write(ARCHIVE, arc + sep + "\n\n".join(texts) + "\n")            # ① archive へ追記
        now = _read(ARCHIVE)
        if not all(t in now for t in texts):                                      # ② 存在確認
            die(5, "archive への書き込みを確認できません＝本体からは消していません")
        _atomic_write(LEDGER, "\n".join(ln for i, ln in enumerate(lines) if i not in drop))  # ③ 本体から削除
    print(json.dumps({"moved": [e["id"] for e in picked]}, ensure_ascii=False))
    return 0


DATE_RE = re.compile(r"(20\d\d-\d\d-\d\d)")


def _normalize_plan(led, arc):
    """付け替え案。先に現れた方（archive → 台帳の行順＝追記順）が元の番号を保つ。archive は触らない。"""
    taken = {e["id"] for t in (led, arc) for e in parse(t)["entries"]}
    seen = {e["id"] for e in parse(arc)["entries"]}
    lines = led.split("\n")
    changes = []
    for e in parse(led)["entries"]:
        i = e["line"] - 1
        kid, new = e["id"], e["id"]
        if kid in seen:
            base = kid[:-1] if kid[-1].isalpha() and kid[-2].isdigit() else kid
            for c in "bcdefghijklmnopqrstuvwxyz":
                if base + c not in taken:
                    new = base + c
                    break
            else:
                die(6, f"{kid} の枝番が z まで埋まっています")
            taken.add(new)
        seen.add(new)
        if new != kid or e["level"] != "###":
            m = DATE_RE.search(lines[i])
            changes.append({"line": e["line"], "old": kid, "new": new, "level": e["level"],
                            "date": m.group(1) if m else ""})
    return changes


def cmd_normalize(a):
    def run():
        led, arc = _read(LEDGER), _read(ARCHIVE)
        changes = _normalize_plan(led, arc)
        if a.apply and changes:
            lines = led.split("\n")
            for c in changes:
                i = c["line"] - 1
                m = HEAD_RE.match(lines[i])
                lines[i] = "### " + c["new"] + lines[i][m.end():]
            renamed = [c for c in changes if c["old"] != c["new"]]
            if renamed:
                today = datetime.datetime.now(JST).date().isoformat()
                old = _read(IDMAP)
                head = "" if old else ("# skill-kaizen 重複IDの枝番の対応表\n\n"
                                       "`bin/kaizen.py normalize` が残す。旧IDで参照している記録は、日付と行で新IDへ読み替える。"
                                       "見出しの文言は写さない（取引先名を git へ出さない）。\n\n"
                                       "| 付け替え日 | 旧ID | 新ID | 見出しの日付 | 当時の行 |\n|---|---|---|---|---|\n")
                rows = "".join(f"| {today} | {c['old']} | {c['new']} | {c['date'] or '—'} | {c['line']} |\n" for c in renamed)
                _atomic_write(IDMAP, old + head + rows) if old or head else None
            _atomic_write(LEDGER, "\n".join(lines))
        summary = {"apply": bool(a.apply),
                   "renamed": sum(1 for c in changes if c["old"] != c["new"]),
                   "relevel": sum(1 for c in changes if c["level"] != "###"),
                   "changes": changes}
        print(json.dumps(summary, ensure_ascii=False, indent=1))
    if a.apply:
        with locked():
            run()
    else:
        run()
    return 0


def cmd_lock(a):
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    if not cmd:
        die(2, "lock -- <コマンド> の形で指定してください")
    with locked():
        return subprocess.call(cmd)


def main():
    ap = argparse.ArgumentParser(description="共有カイゼン台帳の見出し解釈・採番・退避")
    sub = ap.add_subparsers(dest="c", required=True)
    p = sub.add_parser("list"); p.add_argument("--heads", action="store_true"); p.set_defaults(f=cmd_list)
    p = sub.add_parser("lint"); p.set_defaults(f=cmd_lint)
    p = sub.add_parser("add"); p.add_argument("--title"); p.add_argument("--lane"); p.set_defaults(f=cmd_add)
    p = sub.add_parser("move"); p.add_argument("specs", nargs="+"); p.set_defaults(f=cmd_move)
    p = sub.add_parser("normalize"); p.add_argument("--apply", action="store_true"); p.set_defaults(f=cmd_normalize)
    p = sub.add_parser("lock"); p.add_argument("cmd", nargs=argparse.REMAINDER); p.set_defaults(f=cmd_lock)
    a = ap.parse_args()
    return a.f(a)


if __name__ == "__main__":
    sys.exit(main())
