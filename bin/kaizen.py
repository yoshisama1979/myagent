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
  kaizen.py show K-NNN                 その1件の原文を全文出す（切らない）
  kaizen.py index [--rebuild]          判断待ちの索引（1件1行・未採否の全件）を原文から作り直す＝索引は生成物
  kaizen.py migrate [--apply]          旧の1枚を月別（kaizen/YYYY-MM.md）へ原文無改変で写す。前後で原文の
                                       ハッシュ集合が一致することを検算して申告する（旧の器は消さない）
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
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.environ.get("KAIZEN_LEDGER") or os.path.join(ROOT, "data", "hp-improve", "skill-kaizen.md")
# ⚠️ 環境変数は「揃えて」読む。KAIZEN_LEDGER だけを差し替えたとき、月別と索引が**本番のまま**だと、
#    テストや下見が本番の台帳へ書く（2026-09-16 に2度実際に起きた＝本番へ計18件のテスト分が混入）。
#    そこで、台帳を差し替えたら月別・索引・対応表・倉庫・ロックの5つともその隣を既定にする（Codex 指摘 2026-09-17）。
_LED_DIR = os.path.dirname(os.path.abspath(LEDGER))
KDIR = os.environ.get("KAIZEN_DIR") or os.path.join(_LED_DIR, "kaizen")
QUEUE = os.environ.get("KAIZEN_QUEUE") or os.path.join(_LED_DIR, "kaizen-queue.md")
IDMAP = os.environ.get("KAIZEN_IDMAP") or os.path.join(_LED_DIR, "skill-kaizen-id-map.md")
ARCHIVE = os.environ.get("KAIZEN_ARCHIVE") or os.path.join(_LED_DIR, "skill-kaizen-archive.md")
LOCK = os.environ.get("KAIZEN_LOCK") or os.path.join(_LED_DIR, ".skill-kaizen.lock")
JST = datetime.timezone(datetime.timedelta(hours=9))
HEAD_RE = re.compile(r"^(#{2,3})[ \t]+(K-(?:[A-Za-z]+-)?\d+[a-z]?)(?![0-9A-Za-z-])")
ANY_HEAD_RE = re.compile(r"^#{1,3}[ \t]")
PLAIN_NUM_RE = re.compile(r"^K-(\d+)[a-z]?$")
DECIDED_RE = re.compile(r"反映済み|却下")
FENCE_RE = re.compile(r"^\s*```")
LANE_RE = re.compile(r"^[A-Za-z0-9_:-]{1,40}$")
SPEC_RE = re.compile(r"^(?:(?P<file>[^:]+):)?(?P<line>\d{1,7}):(?P<hash>[0-9a-f]{12})$")
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


def _month_files():
    import glob as _g
    return sorted(_g.glob(os.path.join(KDIR, "*.md")))


def _sources():
    """原文の在処。月別ができていればそれが正＝旧の1枚は数えない（両方にあっても二重に数えない）。"""
    mf = _month_files()
    if mf:
        return mf
    return [LEDGER] if os.path.exists(LEDGER) else []


def _all_entries(paths=None):
    out = []
    for f in (paths if paths is not None else _sources()):
        for e in parse(_read(f))["entries"]:
            e["src"] = os.path.relpath(f, ROOT) if f.startswith(ROOT) else f
            e["path"] = f
            out.append(e)
    return out


def _span(lines, line):
    """見出し行（1始まり）から、次の #〜### 見出しの手前までの [start, end)。エントリの範囲の定義はここ1つ。"""
    start = line - 1
    for j in range(start + 1, len(lines)):
        if ANY_HEAD_RE.match(lines[j]):
            return start, j
    return start, len(lines)


def _entry_text(e):
    lines = _read(e["path"]).split("\n")
    start, end = _span(lines, e["line"])
    return "\n".join(lines[start:end]).rstrip("\n")


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


def _stats():
    """全部の原文を1つに見立てた集計（重複は器をまたいで数える）。"""
    es = _all_entries()
    counts = {}
    for e in es:
        counts[e["id"]] = counts.get(e["id"], 0) + 1
    return {"count": len(es), "entries": es, "ids": len(counts),
            "duplicates": {k: v for k, v in counts.items() if v > 1},
            "offformat": [{"line": e["line"], "id": e["id"], "src": e["src"]} for e in es if e["level"] != "###"],
            "over_8kb": sum(1 for e in es if e["bytes"] > BIG),
            "max_entry_bytes": max((e["bytes"] for e in es), default=0),
            "unclosed_fence": any(parse(_read(f))["unclosed_fence"] for f in _sources()),
            "sources": [os.path.relpath(f, ROOT) for f in _sources()]}


def cmd_list(a):
    r = _stats()
    for e in r["entries"]:
        e.pop("path", None)
        if not a.heads:
            e.pop("head", None)          # 見出しには取引先名が入りうる＝要るときだけ出す
    print(json.dumps(r, ensure_ascii=False, indent=2))
    return 0


QUEUE_ROW_RE = re.compile(r"^\|\s*(K-[A-Za-z0-9-]+)\s*\|.*\|\s*([0-9a-f]{12})\s*\|\s*$")


def _queue_rows():
    return {m.group(1): m.group(2) for ln in _read(QUEUE).split("\n") for m in [QUEUE_ROW_RE.match(ln)] if m}


def cmd_lint(_a):
    r = _stats()
    msgs = []
    if _month_files() and not os.path.exists(QUEUE):
        msgs.append(f"索引（{os.path.relpath(QUEUE, ROOT)}）がありません＝判断待ちが1件も見えない状態です。"
                    "`python3 bin/kaizen.py index --rebuild` で作ってください")
    if os.path.exists(QUEUE):
        rows = _queue_rows()
        undecided = {e["id"]: e["hash"] for e in r["entries"] if not e["decided"]}
        missing = [k for k in undecided if k not in rows]
        extra = [k for k in rows if k not in undecided]
        stale = [k for k, h in undecided.items() if k in rows and rows[k] != h]
        if missing or extra or stale:
            msgs.append("索引（" + os.path.relpath(QUEUE, ROOT) + "）が原文と合っていません＝"
                        f"原文にあって索引に無い {len(missing)}件{('（例 ' + ', '.join(missing[:5]) + '）') if missing else ''}・"
                        f"索引にあって原文に無い {len(extra)}件・中身が変わった {len(stale)}件"
                        "。`python3 bin/kaizen.py index --rebuild` で作り直してください")
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
        target = LEDGER
        if _month_files():
            target = os.path.join(KDIR, datetime.datetime.now(JST).strftime("%Y-%m") + ".md")
            if not os.path.exists(target):
                _write(target, MONTH_HEAD.format(m=datetime.datetime.now(JST).strftime("%Y-%m")) + "\n")
        led = _read(target)
        nums = []
        for text in [_read(f) for f in set(_sources() + [LEDGER])] + [_read(ARCHIVE)]:
            for e in parse(text)["entries"]:
                m = PLAIN_NUM_RE.match(e["id"])
                if m:
                    nums.append(int(m.group(1)))
        kid = f"K-{max(nums, default=0) + 1:03d}"
        today = datetime.datetime.now(JST).date().isoformat()
        tag = "（" + (f"{lane}・" if lane else "") + today + "）"
        block = f"### {kid} — {title.strip()}{tag}\n{body.rstrip()}\n"
        sep = "" if (not led or led.endswith("\n\n")) else ("\n" if led.endswith("\n") else "\n\n")
        _atomic_write(target, led + sep + block)
        _rebuild_queue()
    print(kid)
    return 0


def cmd_move(a):
    srcs = _sources()
    specs = []
    for sp in a.specs:
        m = SPEC_RE.match(sp)
        if not m:
            die(2, f"指定は [在処:]行:照合（list の src・line・hash）です: {sp!r}")
        f = m.group("file")
        if f:
            path = f if os.path.isabs(f) else os.path.join(ROOT, f)
        elif len(srcs) == 1:
            path = srcs[0]
        else:
            die(2, "原文が複数の器に分かれています＝在処:行:照合 の形で指してください（list の src を使う）")
        specs.append((path, int(m.group("line")), m.group("hash")))
    if len(set(specs)) != len(specs):
        die(2, "同じ指定が重複しています")
    with locked():
        current = {os.path.realpath(f) for f in _sources()}
        for path, line, h in specs:
            if os.path.realpath(path) not in current:
                die(2, f"在処 {path} は今の原文の器ではありません（移行後の旧の器など）＝何も動かしていません。"
                       "`python3 bin/kaizen.py list` の src を使ってください")
        picked = []
        for path, line, h in specs:
            by_line = {e["line"]: e for e in parse(_read(path))["entries"]}
            e = by_line.get(line)
            if not e or e["hash"] != h:
                die(3, f"{os.path.relpath(path, ROOT)}:{line}:{h} は list の時点から変わっています"
                       "（行がずれた／中身が変わった）＝何も動かしていません。もう一度 list してから指定してください")
            e["path"] = path
            picked.append(e)
        texts, drops = [], {}
        for e in picked:
            lines = _read(e["path"]).split("\n")
            start, end = _span(lines, e["line"])
            texts.append("\n".join(lines[start:end]).rstrip("\n"))
            drops.setdefault(e["path"], set()).update(range(start, end))
        arc = _read(ARCHIVE)
        sep = "" if (not arc or arc.endswith("\n\n")) else ("\n" if arc.endswith("\n") else "\n\n")
        _atomic_write(ARCHIVE, arc + sep + "\n\n".join(texts) + "\n")            # ① archive へ追記
        now = _read(ARCHIVE)
        if not all(t in now for t in texts):                                      # ② 存在確認
            die(5, "archive への書き込みを確認できません＝本体からは消していません")
        for path, drop in drops.items():                                          # ③ 本体から削除
            lines = _read(path).split("\n")
            _atomic_write(path, "\n".join(ln for i, ln in enumerate(lines) if i not in drop))
        _rebuild_queue()
    print(json.dumps({"moved": [e["id"] for e in picked]}, ensure_ascii=False))
    return 0


DATE_RE = re.compile(r"(20\d\d-\d\d-\d\d)")


def _normalize_plan(entries, arc):
    """付け替え案。先に現れた方（archive → 原文の順＝追記順）が元の番号を保つ。archive は触らない。"""
    taken = {e["id"] for e in entries} | {e["id"] for e in parse(arc)["entries"]}
    seen = {e["id"] for e in parse(arc)["entries"]}
    changes = []
    for e in entries:
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
            m = DATE_RE.search(e["head"])
            changes.append({"src": e["src"], "line": e["line"], "old": kid, "new": new,
                            "level": e["level"], "date": m.group(1) if m else ""})
    return changes


def cmd_normalize(a):
    def run():
        entries = _all_entries()
        changes = _normalize_plan(entries, _read(ARCHIVE))
        if a.apply and changes:
            by_file = {}
            for c in changes:
                by_file.setdefault(next(e["path"] for e in entries if e["src"] == c["src"]), []).append(c)
            for path, cs in by_file.items():
                lines = _read(path).split("\n")
                for c in cs:
                    i = c["line"] - 1
                    m = HEAD_RE.match(lines[i])
                    lines[i] = "### " + c["new"] + lines[i][m.end():]
                _atomic_write(path, "\n".join(lines))
            renamed = [c for c in changes if c["old"] != c["new"]]
            if renamed:
                today = datetime.datetime.now(JST).date().isoformat()
                old = _read(IDMAP)
                head = "" if old else ("# skill-kaizen 重複IDの枝番の対応表\n\n"
                                       "`bin/kaizen.py normalize` が残す。旧IDで参照している記録は、日付と行で新IDへ読み替える。"
                                       "見出しの文言は写さない（取引先名を git へ出さない）。\n\n"
                                       "| 付け替え日 | 旧ID | 新ID | 見出しの日付 | 当時の行 |\n|---|---|---|---|---|\n")
                rows = "".join(f"| {today} | {c['old']} | {c['new']} | {c['date'] or '—'} | {c['line']} |\n" for c in renamed)
                _write(IDMAP, old + head + rows)
            _rebuild_queue()
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


def cmd_show(a):
    for e in _all_entries() + _all_entries([ARCHIVE]):
        if e["id"] == a.id:
            print(_entry_text(e))
            return 0
    die(3, f"{a.id} は原文にも倉庫にも見つかりません（`python3 bin/kaizen.py list` で確かめてください）")


def _queue_text(entries):
    head = ("# カイゼン台帳：判断待ちの索引（生成物・手で書かない）\n\n"
            "`python3 bin/kaizen.py index --rebuild` が原文から作る。**1行＝1件・未採否の全件**（絞り込まない）。\n"
            "経緯（原文）は `python3 bin/kaizen.py show K-NNN` で全文が出る。要約し直さず見出しをそのまま載せる。\n\n"
            "| ID | 日付 | レーン | 見出し（原文のまま） | 🙋 | 原文の在処 | 照合 |\n|---|---|---|---|---|---|---|\n")
    rows = []
    for e in entries:
        h = re.sub(r"^#+\s*", "", e["head"])
        h = re.sub(r"^" + re.escape(e["id"]) + r"\s*[—:：-]?\s*", "", h)
        m = DATE_RE.search(h)
        lane = re.search(r"[（(]\s*([A-Za-z0-9_:\- ]{2,24})[・／/]", h)
        title = h.replace("|", "｜").strip()
        # 🙋（社長の判断が要る印）は**本文まで見て**拾う。見出しだけ見ると、実測で 147件中113件を落とし、
        # 社長に出すはずの項目が索引から消える（2026-09-16 移行直後の実測で判明）。
        ask = "🙋" in h or "🙋" in _entry_text(e)
        rows.append(f"| {e['id']} | {m.group(1) if m else ''} | {(lane.group(1).strip() if lane else '')} | "
                    f"{title} | {'🙋' if ask else ''} | {e['src']}:{e['line']} | {e['hash']} |")
    return head + "\n".join(rows) + "\n"


def cmd_index(a):
    if not a.rebuild:
        print(_queue_text([e for e in _all_entries() if not e["decided"]]))
        return 0
    with locked():                                   # ⑤ 追記と混ざらないよう、読み→作る→書くをロックの中で
        es = [e for e in _all_entries() if not e["decided"]]
        text = _queue_text(es)
        _write(QUEUE, text)
    print(json.dumps({"rows": len(es), "queue": os.path.relpath(QUEUE, ROOT),
                      "bytes": len(text.encode("utf-8"))}, ensure_ascii=False))
    return 0


def _write(path, text):
    """置き場を作ってから一時ファイル→差し替え（途中で死んでも半端なファイルを残さない）。"""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    _atomic_write(path, text)


def _rebuild_queue():
    """①（Codex 指摘）足す・移す・付け替えるたびに、同じロックの中で索引を作り直す。
    作り直しを人に任せると、その間の新顔が triage の読む索引から消える（2026-09-17 本番で5件実際に起きた）。
    月別がまだ無い（分割前）なら索引は持たない。呼ぶ側がロックを持っていること。"""
    if _month_files():
        _write(QUEUE, _queue_text([e for e in _all_entries() if not e["decided"]]))


MONTH_HEAD = "# カイゼン台帳 {m}（経緯＝原文。判断待ちの索引は kaizen-queue.md・追記は bin/kaizen.py add）\n"


def _month_of(e):
    """見出しの日付。無ければ本文の最初の日付で拾う（日付を持たない分だけ undated へ）。"""
    m = DATE_RE.search(e["head"]) or DATE_RE.search(_entry_text(e))
    return m.group(1)[:7] if m else "undated"


def _migration_plan():
    src = _read(LEDGER)
    es = parse(src)["entries"]
    if not es:
        die(3, f"{LEDGER} に原文が見つかりません")
    lines = src.split("\n")
    by_month = {}
    for e in es:
        start, end = _span(lines, e["line"])
        e["path"] = LEDGER
        by_month.setdefault(_month_of(e), []).append("\n".join(lines[start:end]).rstrip("\n"))
    return es, by_month


def cmd_migrate(a):
    if not a.apply:
        es, by_month = _migration_plan()
        print(json.dumps({"apply": False, "plan": {m: len(v) for m, v in sorted(by_month.items())},
                          "entries": len(es)}, ensure_ascii=False, indent=1))
        return 0
    staging = KDIR.rstrip("/") + ".staging"
    with locked():                                   # ② 確認も読み取りもロックの中（待つ間の追記を取りこぼさない）
        if _month_files():
            die(4, f"すでに移行済みです（{os.path.relpath(KDIR, ROOT)} に月別ファイルがある）＝もう一度写すと原文が二重になるので何もしません。"
                   "やり直すなら月別ファイルを消してから")
        es, by_month = _migration_plan()
        before = sorted(e["hash"] for e in es)
        shutil.rmtree(staging, ignore_errors=True)
        # ③ 仮置きに書き、検算が通ってから一度に公開する。_sources() は KDIR しか見ないので、
        #    途中で死んでも・検算が落ちても、旧の1枚が原文のまま使われ続ける。
        for m, texts in sorted(by_month.items()):
            _write(os.path.join(staging, f"{m}.md"), MONTH_HEAD.format(m=m) + "\n" + "\n\n".join(texts) + "\n")
        import glob as _g
        after = sorted(e["hash"] for f in sorted(_g.glob(os.path.join(staging, "*.md"))) for e in parse(_read(f))["entries"])
        result = {"apply": True, "plan": {m: len(v) for m, v in sorted(by_month.items())},
                  "entries": len(es), "identical": after == before}
        if not result["identical"]:
            shutil.rmtree(staging, ignore_errors=True)
            print(json.dumps(result, ensure_ascii=False, indent=1))
            die(5, "仮置きの原文が旧の1枚と一致しません＝公開していません（旧の1枚をそのまま使い続けます）")
        if os.path.isdir(KDIR):
            os.rmdir(KDIR)                           # 空の置き場だけ（月別があれば上で断っている）
        os.rename(staging, KDIR)                     # 公開は1回の rename
        result["files"] = [os.path.relpath(f, ROOT) for f in _month_files()]
        _rebuild_queue()
    print(json.dumps(result, ensure_ascii=False, indent=1))
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
    p = sub.add_parser("show"); p.add_argument("id"); p.set_defaults(f=cmd_show)
    p = sub.add_parser("index"); p.add_argument("--rebuild", action="store_true"); p.set_defaults(f=cmd_index)
    p = sub.add_parser("migrate"); p.add_argument("--apply", action="store_true"); p.set_defaults(f=cmd_migrate)
    p = sub.add_parser("normalize"); p.add_argument("--apply", action="store_true"); p.set_defaults(f=cmd_normalize)
    p = sub.add_parser("lock"); p.add_argument("cmd", nargs=argparse.REMAINDER); p.set_defaults(f=cmd_lock)
    a = ap.parse_args()
    return a.f(a)


if __name__ == "__main__":
    sys.exit(main())
