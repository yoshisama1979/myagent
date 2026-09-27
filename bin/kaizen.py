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
RETIRED_MARK = "<!-- kaizen:retired -->"   # 畳んだ器の印。これがある器への追記は lint が止める
RETIRED_END = "<!-- kaizen:retired:end -->"   # 道しるべの終端。この後ろに何か足されたら追記＝lint が止める


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
    return sources_in(_LED_DIR, ledger=LEDGER, kdir=KDIR)


def sources_in(ledger_dir, ledger=None, kdir=None):
    """**その置き場の中で**原文の在処を決める（規則は _sources と同じ）。

    ROOT を差し替えて試す側（ledger-watch・pending-scan のテスト）が、この規則を写し取らずに使えるようにする。
    写し取ると「月別があるのに旧を読む」版ズレが起き、置き場を渡せないと**試験が本番の台帳を読む**
    （2026-09-20＝ledger-watch のテストが仕掛けを素通りして本番を数えた。環境変数の取り違えと同じ型）。
    """
    import glob as _g
    mf = sorted(_g.glob(os.path.join(kdir or os.path.join(ledger_dir, "kaizen"), "*.md")))
    if mf:
        return mf
    led = ledger or os.path.join(ledger_dir, "skill-kaizen.md")
    return [led] if os.path.exists(led) else []


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
    # 畳んだ器への追記を黙らない。移行の途中（旧と月別の両方に原文がある）は triage の関門が
    # 「数字が出るまで両方に持つ」と決めた**正しい状態**なので鳴らさない（鳴りっぱなしの警告は働かない
    # ＝ledger-discipline §2）。危ないのは畳んだ**後**＝道しるべに戻った器へ誰かが追記したときで、
    # これは月別を見ている道具の誰も気づけない。そこで器自身に畳んだ印を書かせ、印つきの器に
    # 項目があるときだけ止める（2026-09-20）。
    if os.path.exists(LEDGER) and RETIRED_MARK in _read(LEDGER):
        txt = _read(LEDGER)
        rel = os.path.relpath(LEDGER, ROOT)
        n = parse(txt)["count"]
        if n:
            msgs.append(f"畳んだ器（{rel}）に項目が {n}件 書かれています＝"
                        "月別を見ている道具からは見えません。`python3 bin/kaizen.py add` で足し直してください")
        # ★見出しの数だけでは足りない。旧いモードルールは今も「skill-kaizen.md に**1行**書く」と
        #   指示しており（実測 2026-09-23＝rules/modes の9本）、見出しを伴わない1行は上の count に
        #   入らないまま道しるべに残る（Codex 指摘）。そこで道しるべ自身に終端を持たせ、
        #   **その後ろに何か増えていたら**追記とみなす。終端が消えていれば書き換えられた印。
        if RETIRED_END not in txt:
            msgs.append(f"畳んだ器（{rel}）に終端の印（{RETIRED_END}）がありません＝"
                        "道しるべが書き換えられた可能性があります（git の履歴と見比べてください）")
        elif txt.split(RETIRED_END, 1)[1].strip():
            msgs.append(f"畳んだ器（{rel}）の終端より後ろに書き足されています＝"
                        "月別を見ている道具からは見えません。`python3 bin/kaizen.py add` で足し直してください")
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
        mf = _month_files()
        if not mf and os.path.exists(LEDGER) and RETIRED_MARK in _read(LEDGER):
            # 畳んだ器しか残っていない＝月別が消えている（誤削除・不完全な checkout）。ここで旧の器へ
            # 足すと道しるべを壊し、月別を見ている道具からは永久に見えない（lint は足した**後**にしか
            # 鳴らない）。0本から新しい月別を作ると「過去の月が消えたこと」を隠すので、作らずに止めて
            # 復元を求める（Codex 指摘 2026-09-23）。
            die(3, f"原文の月別（{os.path.relpath(KDIR, ROOT)}/*.md）が1本もありません＝"
                   f"{os.path.relpath(LEDGER, ROOT)} は畳んだ器なので足しません。"
                   "git から月別を復元してから足し直してください")
        target = LEDGER
        if mf:
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


# ── 索引の行を作るための読み取り（原文は無改変・ここは「読み方」だけ）
# ★原文の見出しには**3系統の書き方**がある（2026-09-23 実測）。1系統しか想定しないと静かに取りこぼす：
#     ①`### K-577: （hp-loop yokohawaii・2026-08-19 Cycle 058）｜…`  レーンが先頭・`レーン・日付`
#     ②`### K-543 — …（hp-loop rally Cycle 045・2026-09-02）`        `レーン Cycle N・日付`
#     ③`### K-678`＋本文1行目 `**（partner Cycle 168・2026-09-01）題**`  見出しに題もレーンも無い
#   実測＝254行中、題が空 26件・降ろし先が読めない 126件（50%）。データは失われておらず読み方の問題。
#   **誰の気づきか分からなければ、誰に降ろすかも決められない**ので索引としては致命的だった。
_CYCLE_RE = re.compile(r"(?:Cycle|サイクル|C)\s*\d+", re.I)
_LANE_OK_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*(?::[A-Za-z0-9_-]+)?$")
# 「<基底> <サイト>」と空白で書かれた分を `<基底>:<サイト>` に寄せる。寄せないと `hp-loop:rally` と
# `hp-loop rally` が別レーンとして並び、名寄せできない（実測＝7件と5件に割れていた）。
_LANE_BASES = ("hp-loop", "blog-loop", "blog-improve", "blog-write",
               "hp-improve", "hp-prospect", "memo-intake", "memo-triage")


# ④の書き方＝本文が「- **モード**：partner（…）｜…」の形で名乗る（実測3件）。括弧の中を見ても拾えない。
_LANE_LABEL_RE = re.compile(r"モード\**\s*[：:]\s*([^｜|（(\n]{2,40})")
# 題の前に置かれる「出自だけの区切り」＝モード名・日付・サイクル番号・🙋 の印。題ではないので落とす。
_META_SEG_RE = re.compile(r"^(?:\**モード\**\s*[：:].*|.*(?:20\d\d-\d\d-\d\d|Cycle\s*\d+).*|🙋[^｜]*)$")


_KNOWN_LANES = None


def _known_lanes():
    """実在するレーン名。**表を手で持たない**＝窓口の対応表とモードルールの置き場から引く。
    手で持つと、レーンが増えたときに索引だけ古くなる（宣言と実装の食い違い＝ledger-discipline §2）。"""
    global _KNOWN_LANES
    if _KNOWN_LANES is None:
        import glob as _g
        names = set(_LANE_BASES)
        try:
            with open(os.path.join(ROOT, "config/session-desks.json"), encoding="utf-8") as f:
                names |= set(json.load(f).get("desks", {}))
        except Exception:
            pass
        for f_ in _g.glob(os.path.join(ROOT, "rules/modes/*.md")):
            names.add(os.path.basename(f_)[:-3])
        _KNOWN_LANES = names
    return _KNOWN_LANES


def _norm_lane(tok):
    """`hp-loop rally`／`hp-loop-rally` を `hp-loop:rally` に寄せる。寄せないと名寄せできない。"""
    base, _, site = tok.partition(" ")
    if site and base in _LANE_BASES:
        return f"{base}:{site.strip()}"
    for b in sorted(_LANE_BASES, key=len, reverse=True):   # 長い基底から見る
        if tok.startswith(b + "-") and tok[len(b) + 1:]:
            return f"{b}:{tok[len(b) + 1:]}"
    return tok


def _lane_from(text):
    """レーンを1つ拾う。無ければ空。日付・サイクル番号は落としてから見る。

    ★**実在するレーン名を優先し、形だけ合う語は最後の手段**にする。先頭から形だけで採ると
      `（new/ 残存）`の `new`、`（WIP）`、`（/service/web/ …）`の `service` のような語を
      レーンとして載せてしまう（実測 2026-09-23＝254件中8件）。
    """
    m = _LANE_LABEL_RE.search(text)
    cands = [m.group(1)] if m else []
    cands += re.findall(r"[（(]([^（()）]{2,80})[)）]", text)
    # `- 🙋要・社長判断｜2026-09-15 partner Cycle 183｜本題…` のように、括弧ではなく ｜ で
    # 名乗る書き方がある。冒頭の数区切りだけ見る（本文の ｜ まで拾うと題の語をレーンにしてしまう）。
    cands += [seg for seg in text.split("\n")[0].split("｜")[:3]]
    loose = ""
    for g in cands:
        for tok in re.split(r"[・／/、,｜|]", g):
            tok = _CYCLE_RE.sub("", DATE_RE.sub("", tok)).strip(" 　-—:：")
            if not tok:
                continue
            tok = _norm_lane(tok)
            if not _LANE_OK_RE.match(tok):
                # `（hp-prospect ×2件同時再現・…）`のように、名乗りの後ろに日本語が続く書き方がある。
                # 基底だけで引き直す（それでも駄目なら諦める）。
                tok = tok.split(" ", 1)[0].split(":", 1)[0]
                if not _LANE_OK_RE.match(tok):
                    continue
            if tok in _known_lanes() or tok.split(":", 1)[0] in _known_lanes():
                return tok
            loose = loose or tok
    return loose


def _row_fields(e):
    """索引1行ぶんの (日付, レーン, 見出し)。見出しに無ければ本文の1行目まで見る。"""
    h = re.sub(r"^#+\s*", "", e["head"])
    h = re.sub(r"^" + re.escape(e["id"]) + r"\s*[—:：-]?\s*", "", h).strip()
    body = _entry_text(e)
    src, from_body = h, False
    if not h:                                  # ③の書き方＝題も出自も本文の1行目にある
        for ln in body.split("\n")[1:]:
            if ln.strip():
                src, from_body = ln.strip().strip("*").strip(), True
                break
    lane = _lane_from(src) or _lane_from(body[:600])
    m = DATE_RE.search(src) or DATE_RE.search(body)
    title = src
    if from_body:
        # 本文から題を作るときは、頭に付いている「出自」を落とす。落とさないと索引の題が
        # `- **モード**：partner（…）｜2026-09-07 Cycle 175-b` のような**名乗りだけ**になり、
        # 索引を読んでも何の話か分からない（実測 2026-09-23＝5件）。
        title = re.sub(r"^[-*・]\s*", "", title)
        title = re.sub(r"^[（(][^（()）]{0,80}[)）]\s*", "", title)
        while "｜" in title:
            head_, _, rest = title.partition("｜")
            if not rest.strip() or not _META_SEG_RE.match(head_.strip()):
                break
            title = rest.strip()
        if _META_SEG_RE.match(title.strip()):
            # 1行目が丸ごと名乗りだった（題は次の行にある）。名乗りを索引の題にすると何の話か分からない。
            for ln in body.split("\n")[1:]:
                t2 = re.sub(r"^[-*・]\s*", "", ln.strip().strip("*").strip())
                if t2 and not _META_SEG_RE.match(t2) and t2 != title.strip():
                    title = t2
                    break
    return (m.group(1) if m else ""), lane, title.replace("|", "｜").strip()


def _queue_text(entries):
    head = ("# カイゼン台帳：判断待ちの索引（生成物・手で書かない）\n\n"
            "`python3 bin/kaizen.py index --rebuild` が原文から作る。**1行＝1件・未採否の全件**（絞り込まない）。\n"
            "経緯（原文）は `python3 bin/kaizen.py show K-NNN` で全文が出る。要約し直さず見出しをそのまま載せる。\n\n"
            "| ID | 日付 | レーン | 見出し（原文のまま） | 🙋 | 原文の在処 | 照合 |\n|---|---|---|---|---|---|---|\n")
    rows = []
    for e in entries:
        date, lane, title = _row_fields(e)
        # 🙋（社長の判断が要る印）は**本文まで見て**拾う。見出しだけ見ると、実測で 147件中113件を落とし、
        # 社長に出すはずの項目が索引から消える（2026-09-16 移行直後の実測で判明）。
        ask = "🙋" in e["head"] or "🙋" in _entry_text(e)
        rows.append(f"| {e['id']} | {date} | {lane} | "
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
