#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""system-health.py — システムの「固定費」と「故障」だけを測る読み取り専用ツール（T-018）

⚑ 設計原則（2026-07-24 社長決定・北極星レンズ [[feedback_north-star-lens-not-filter]] と同型）：
  測るのは【固定費】（タスクと無関係に毎回払うロード＝削っても品質に影響しないと構造的に
  言い切れるもの）と【故障】（タイムアウト・異常終了・滞留＝仕事が壊れた事実）だけ。
  【思考・探索の変動費】（プローブ・ツール実行・下書き・試行錯誤のトークン）は
  **測らない・閾値を設けない・警報を出さない**。コストは見えるが思考の質は見えない＝
  見える方だけ最適化すると探索が死ぬ。「今日のループは使用量が多い」を問題として
  起票することを禁止する。

出力：人間/統括が読む Markdown サマリ（stdout）。⚠️ 行は閾値超えと悪化トレンドだけ。
      あわせてスナップショットを data/overseer/system-health.jsonl に追記（トレンド比較用・
      ランタイムデータ＝gitignore 済み領域）。外部送信・既存ファイルの変更・削除はしない。

使い方：python3 bin/system-health.py          # サマリ表示＋スナップショット追記
        python3 bin/system-health.py --no-log # 追記せず表示のみ

閾値の出典：ledger 70KB=partner.md v0.3／coverage 100KB=hp-loop.md／掲示板 index 80KB=
  hp-loop.md v0.11。出典のない既定値（★印）は提案値＝統括が起票時に「既定値・要合意」と明記する。
"""
import json, os, re, sys, glob, datetime, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = os.path.join(ROOT, "data/overseer/system-health.jsonl")
KB = 1024

def size(path):
    p = os.path.join(ROOT, path)
    return os.path.getsize(p) if os.path.exists(p) else None

# ── 1) 固定費：セッション開始時の自動ロード ─────────────────────────────
def autoload():
    files = sorted(glob.glob(os.path.join(ROOT, ".claude/rules/**/*.md"), recursive=True))
    total = sum(os.path.getsize(f) for f in files) + (size("CLAUDE.md") or 0)
    return {"files": len(files) + 1, "bytes": total}

# ── 2) 固定費：ループが毎サイクル全読みする状態ファイル（閾値つき）──────────
STATE_FILES = [
    # (path, 閾値bytes, 出典)   ★=出典なしの提案既定値
    ("data/partner/ledger.md",            70 * KB, "partner.md v0.3"),
    ("data/partner/milestones.md",       500 * KB, "★提案既定値（cold store＝毎朝読まない追記専用台帳。超過時はローテでなく年度別ファイルへの追記先切替を提案・過去行の削除改変は不可）"),
    ("data/hp-improve/skill-kaizen.md",  100 * KB, "★提案既定値（archive 分離済みの共有台帳）"),
    ("site/notes.html",                  200 * KB, "★提案既定値"),
    ("site/overseer/index.html",          80 * KB, "hp-loop.md v0.11 と同型"),
    ("site/business/partner/index.html",  80 * KB, "hp-loop.md v0.11 と同型"),
]
# ── 2b) 形の異常：1エントリへの「飲み込み」（サイズ閾値をすり抜ける肥大）──────
# 契機＝O-019（K-330 が気づき97件を配下に飲み込み 169KB＝全体の54%）→ 2026-08-11 に
# K-405・K-422 で再発（114件・157KB＝全体の62%）。台帳のルールは「気づきは独立見出し
# `### K-NNN` で足す」だが、宣言だけで機械の担保が無く2回とも数週間気づけなかった。
# サイズ閾値は「合計」しか見ないため、1本が台帳の6割を占める形の異常は検知できない＝別に測る。
ENTRY_MAX_BYTES = 8 * KB    # 1エントリの上限（★提案既定値。実測の中央値は約1KB）
SWALLOW_MAX = 3             # 1エントリが抱えてよい「- **K-」行の数（★提案既定値）
SHAPE_TARGETS = ["data/hp-improve/skill-kaizen.md"]

def entry_shape(path):
    """台帳を見出し単位に割り、巨大エントリと飲み込みを返す（読み取り専用）。"""
    p = os.path.join(ROOT, path)
    if not os.path.exists(p):
        return None
    lines = open(p, encoding="utf-8").read().split("\n")
    heads = [i for i, l in enumerate(lines) if l.startswith("### ")]
    entries = []
    for n, i in enumerate(heads):
        j = heads[n + 1] if n + 1 < len(heads) else len(lines)
        body = "\n".join(lines[i:j])
        entries.append({
            "title": lines[i][4:64],
            "bytes": len(body.encode("utf-8")),
            "swallowed": sum(1 for l in lines[i + 1:j] if l.startswith("- **K-")),
        })
    return {"path": path, "entries": entries,
            "total": sum(e["bytes"] for e in entries)}

def shape_warnings(shape):
    """entry_shape() の結果を警告文にする。判定はここ1箇所（テストが直接叩く）。"""
    if not shape or not shape["entries"]:
        return []
    out, total = [], max(shape["total"], 1)
    for e in shape["entries"]:
        if e["swallowed"] > SWALLOW_MAX:
            out.append(f"{shape['path']} の「{e['title']}」が K 追記 {e['swallowed']}件を"
                       f"配下に飲み込み（>{SWALLOW_MAX}）＝独立見出しに数えられずローテも索引もすり抜ける"
                       f"（O-019 と同型）")
        elif e["bytes"] > ENTRY_MAX_BYTES:
            out.append(f"{shape['path']} の「{e['title']}」が単体 {e['bytes']//KB}KB "
                       f"> {ENTRY_MAX_BYTES//KB}KB（全体の{e['bytes']*100//total}%）")
    return out

# ── 2c) 故障の一種：本番ツールが git に入っていない（消えたら復元できない）──────
# 契機＝2026-08-11。ツール台帳に「運用中」と登録され日次分析が依存している bin/ の5本が、
# 最古 2026-07-12 から**1ヶ月コミットされずディスク上にしか存在しなかった**。
# git checkout / stash / reset 一発で1ヶ月分のツール開発と、それを使う分析が消える状態。
# 原因＝無人ループはツールを拡張できてもコミットする手順を持たない（コミットは有人の仕事）。
# 統括は O-009 で件数だけ挙げていたが「本番依存コードが混ざっている」質の評価が無かった。
# ⚠️ ここで測るのは**バックアップの欠落＝故障**であって、コミットの頻度や作法ではない。
TOOL_DEBT_DAYS = 3          # bin/ の未コミット変更を放置してよい日数（★提案既定値）

def uncommitted_tools():
    """bin/ の未コミット変更を [(path, 経過日数)] で返す。git が使えなければ None。

    使い捨てスクリプト（`_tmp_` 始まり）は対象外＝ルール上その場限りで消す約束のもの。
    """
    try:
        r = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--", "bin/"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
    except Exception:
        return None                      # git 不在・タイムアウト＝測れないことを隠さない
    now = datetime.datetime.now().timestamp()
    out = []
    for line in r.stdout.splitlines():
        path = line[3:].strip().strip('"')
        name = os.path.basename(path)
        if name.startswith("_tmp_"):
            continue
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            continue
        out.append((path, (now - os.path.getmtime(full)) / 86400))
    return sorted(out, key=lambda x: -x[1])

def tool_debt_warnings(entries, max_days=TOOL_DEBT_DAYS):
    """uncommitted_tools() の結果を警告文にする。判定はここ1箇所（テストが直接叩く）。"""
    if entries is None:
        return ["🚨 診断不能: bin/ の未コミット状況を git から取得できない"]
    # 「最古」を名乗る以上、呼び出し側の並び順に依存しない（テストが実装のバグを検出した箇所）
    old = sorted([(p, d) for p, d in entries if d > max_days], key=lambda x: -x[1])
    if not old:
        return []
    head = ", ".join(f"{os.path.basename(p)}({int(d)}日)" for p, d in old[:3])
    more = f" ほか{len(old)-3}本" if len(old) > 3 else ""
    return [f"bin/ の未コミットが {len(old)}本・最古 {int(old[0][1])}日放置（>{max_days}日）＝"
            f"{head}{more}。**ツールが git に無い＝消えたら復元できない**"
            f"（2026-08-11 に1ヶ月放置の本番ツール5本が実在）"]

# ── 2d) コードの層：構造の複雑度（統括の全体最適棚卸し用）────────────────────
# 契機＝2026-08-11 社長「後戻りできなくなる前に、全体の設計やコードの最適化の提案をしてくれるように
# なっていますか」。実測した答えは No＝統括の起票38件のうち79%が障害/予防で、コードの層は
# 一度も見ていなかった（bin/ 61本中、視野に入っていたのは5本）。日次の計測が「台帳のサイズ」しか
# 見ないため、コードだけが誰にも測られずに増え続けていた。
#
# ⚑ 判定の方針（既存の「床と待ち」節と同じ作法・設計原則との整合）：
#   - 増減行数・重複本数は【数字だけ】出し、閾値も⚠️も付けない。理由＝行数に閾値を付けると
#     「書かないこと」が最適化目標に化ける。refactoring.md の北極星「きれいにすること自体は
#     成果ではない」と同じ。統括が隔週の棚卸しで読んで、必要なら O-NNN に起票する。
#   - ⚠️ を出すのは【約束の違反】だけ＝①`_tmp_` は「済んだら削除」とルールに書いてある
#     （testing.md §1）②無人ループが実行するツールのテストは「必須」と書いてある（同 §2）。
#     宣言に機械の担保を対で付ける（同 §4）のがここの役目。
#   - ②は既知の積み残しを毎日鳴らさない＝**増えたときだけ**鳴らす（新しく無担保のツールが
#     無人ループに載った瞬間を捕まえる）。現在数は数字として常に出す。
TMP_MAX_DAYS = 7            # `_tmp_` を置いておいてよい日数（★提案既定値）
CHURN_DAYS = 14             # 増減を見る窓（統括の棚卸し周期に合わせる）
# ⚠️ `.env` は `os.environ` に部分一致する（最初の実装で 3本→6本 に水増しされた）。
# 数字が信用を失うと統括は起票をやめる＝後ろに英数字が続かない場合だけ拾う。
_DOTENV = re.compile(r"\.env(?![A-Za-z0-9_])")
DUP_PATTERNS = [            # (ラベル, 対象拡張子, 判定関数)  ＝ 同じ処理の再実装の"候補"を数える
    (".env の自作読み込み", (".py",),
     lambda t: bool(_DOTENV.search(t)) and "import _env" not in t and "from _env" not in t),
    (".env の自作読み込み(shell)", (".sh",), lambda t: bool(_DOTENV.search(t))),
    ("atomic write の自作(os.replace)", (".py",), lambda t: "os.replace(" in t),
    # 「flock」の素の部分一致だと、この検知器自身のパターン定義行に当たって自分を数える
    # （実際に system-health.py が誤って 7本目に入った）＝呼び出しの形で判定する
    ("flock の自作", (".py",), lambda t: "fcntl.flock(" in t),
    ("flock の自作(shell)", (".sh",), lambda t: re.search(r"\bflock\s+-", t) is not None),
]
# 対象外：`_env.py` は共有ヘルパー自身＝「重複」でなく解決側。
# `system-health.py` は**この検知器そのもの**＝ソースに判定文字列（"fcntl.flock(" 等）が
# 説明として書いてあるため、自分を走査すると必ず自分を数える（実際に2回踏んだ）。
# パターン定義ブロックだけ切っても、注記や docstring に同じ文字列が残るので根治しない。
# → 自己計測はあきらめて対象外にし、**出力にその事実を書く**（黙って外すと数字が嘘になる）。
DUP_EXCLUDE = {"_env.py", "system-health.py"}

def _bin_sources():
    """bin/ の本番ソース [(ファイル名, 本文)]。テストと使い捨ては対象外。"""
    out = []
    for f in sorted(glob.glob(os.path.join(ROOT, "bin/*"))):
        n = os.path.basename(f)
        if not os.path.isfile(f) or n.startswith(("test-", "_tmp_")):
            continue
        if not n.endswith((".py", ".sh", ".mjs")):
            continue
        try:
            out.append((n, open(f, encoding="utf-8", errors="replace").read()))
        except OSError:
            continue
    return out

def code_churn(days=CHURN_DAYS):
    """bin/ の直近 days 日の増減。git が使えなければ None（測れないことを隠さない）。"""
    try:
        r = subprocess.run(["git", "-C", ROOT, "log", f"--since={days} days ago",
                            "--numstat", "--format=", "--", "bin/"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
    except Exception:
        return None
    add = dele = 0
    files = set()
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3 or parts[0] == "-":      # "-" はバイナリ
            continue
        add += int(parts[0]); dele += int(parts[1]); files.add(parts[2])
    return {"days": days, "added": add, "removed": dele,
            "net": add - dele, "files": len(files)}

def tmp_leftovers():
    """使い捨てスクリプト（`_tmp_`）の残骸を [(名前, 経過日数)] で返す。"""
    now = datetime.datetime.now().timestamp()
    out = []
    for f in sorted(glob.glob(os.path.join(ROOT, "bin/_tmp_*"))):
        if os.path.isfile(f):
            out.append((os.path.basename(f), (now - os.path.getmtime(f)) / 86400))
    return sorted(out, key=lambda x: -x[1])

def loop_tools():
    """無人ループが実行しうる bin/ ツールの名前（crontab＋許可リストの和）。

    ⚠️ 覆えるのは testing.md §2 の条件①（無人ループから呼ばれる）だけ。
    ②状態を書く・③判定を持つ は機械では判定できない＝人の目が要る（正直に狭く名乗る）。
    """
    names = set()
    try:
        r = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                if not line.strip().startswith("#"):
                    names |= set(re.findall(r"bin/([A-Za-z0-9_.-]+\.(?:py|sh|mjs))", line))
    except Exception:
        pass                                        # crontab 不在の環境（テスト等）では許可リストだけ
    try:
        with open(os.path.join(ROOT, ".claude/settings.local.json"), encoding="utf-8") as fh:
            allow = json.load(fh).get("permissions", {}).get("allow", [])
        for a in allow:
            names |= set(re.findall(r"bin/([A-Za-z0-9_.-]+\.(?:py|sh|mjs))", str(a)))
    except Exception:
        pass
    # 実在するものだけ（許可リストには過去に消したツールの行が残ることがある）
    return sorted(n for n in names if os.path.isfile(os.path.join(ROOT, "bin", n)))

def tested_tools():
    """テストが「自分の対象」として名乗っているツール名の集合。

    判定はテストファイルの冒頭15行（＝対象を書く契機コメント。testing.md §6-7 が義務化している）。
    本文中の言及は拾わない＝写経・比較で名前が出るだけのものを「テスト済み」と誤認しないため。
    """
    named = set()
    for f in sorted(glob.glob(os.path.join(ROOT, "bin/test-*"))):
        try:
            head = "".join(open(f, encoding="utf-8", errors="replace").readlines()[:15])
        except OSError:
            continue
        named |= set(re.findall(r"bin/([A-Za-z0-9_.-]+\.(?:py|sh|mjs))", head))
    return named

def dup_impls(sources=None):
    """同じ処理の再実装の"候補"を数える。{ラベル: [ファイル名]}（grep 相当＝厳密判定ではない）。"""
    src = _bin_sources() if sources is None else sources
    out = {}
    for label, exts, pred in DUP_PATTERNS:
        hits = [n for n, t in src if n.endswith(exts) and n not in DUP_EXCLUDE and pred(t)]
        if hits:
            out[label] = sorted(hits)
    return out

def code_layer():
    """コードの層の実測値を1つの dict にまとめる（スナップショットにも入れる）。"""
    tools = loop_tools()
    tested = tested_tools()
    dups = dup_impls()
    return {
        "churn": code_churn(),
        "tmp": [{"name": n, "days": round(d, 1)} for n, d in tmp_leftovers()],
        "loop_tools": len(tools),
        "untested": [n for n in tools if n not in tested],
        "dup": {k: len(v) for k, v in dups.items()},
        "dup_files": dups,
    }

def code_layer_warnings(cur, prev=None, max_tmp_days=TMP_MAX_DAYS):
    """コードの層の警告。判定はここ1箇所（テストが直接叩く）。

    鳴らすのは「約束の違反」だけ＝残骸の放置と、無担保ツールの**増加**。量の変化は鳴らさない。
    """
    if not cur:
        return []
    out = []
    # 「最古」を名乗る以上、呼び出し側の並び順に依存しない（tool_debt_warnings と同じ轍）
    old = sorted([t for t in cur.get("tmp", []) if t["days"] > max_tmp_days],
                 key=lambda t: -t["days"])
    if old:
        head = ", ".join(f"{t['name']}({int(t['days'])}日)" for t in old[:3])
        more = f" ほか{len(old)-3}本" if len(old) > 3 else ""
        out.append(f"bin/ の使い捨てスクリプト `_tmp_` が {len(old)}本 残骸化"
                   f"（>{max_tmp_days}日・最古 {int(old[0]['days'])}日）＝{head}{more}。"
                   f"**済んだら削除する約束のもの**（testing.md §1）")
    now_un = set(cur.get("untested") or [])
    if prev is not None:
        was_un = set((prev or {}).get("untested") or [])
        added = sorted(now_un - was_un)
        if added:
            out.append(f"無人ループが実行するツールで**新たに**テスト無しが {len(added)}本"
                       f"＝{', '.join(added)}。testing.md §2 は「無人ループから呼ばれるものは"
                       f"回帰スイート必須」＝宣言に担保が付いていない（既存の積み残しは鳴らさない）")
    return out

# hp-loop の台帳・掲示板はサイト別に可変（gitignore のクライアント分含めディスク上を実測）
def hp_loop_states():
    out = []
    for f in sorted(glob.glob(os.path.join(ROOT, "data/hp-loop/*/coverage.md"))):
        out.append((os.path.relpath(f, ROOT), 100 * KB, "hp-loop.md（100KBローテ）"))
    for f in sorted(glob.glob(os.path.join(ROOT, "site/hp-analysis/*/index.html"))):
        out.append((os.path.relpath(f, ROOT), 80 * KB, "hp-loop.md v0.11（80KB堆積疑い）"))
    return out

# ── 3) 故障：tick.log（タイムアウト・異常終了・警報）────────────────────
TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
def tick_failures(days=7):
    """tick.log から故障を数える。⚠️ tick.log は 1MB 超で末尾512KBに切り詰められる設計
    （agent-tick.sh）なので、**実際に読めた期間**を covered_days として正直に返す
    （「直近7日」と断定しない＝Codex指摘 2026-07-24）。"""
    path = os.path.join(ROOT, "data/overseer/tick.log")
    if not os.path.exists(path):
        return {"error": "tick.log が存在しない（tick 自体が動いていない疑い）"}
    cutoff = datetime.datetime.now() - datetime.timedelta(days=days)
    n_timeout = n_err = n_alert = n_badts = 0
    first_ts = last_ts = None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                m = TS_RE.match(ln)
                if not m:
                    continue  # 「» 」接頭辞つきの子プロセス出力は制御行でない＝数えない
                try:
                    ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
                except ValueError:
                    n_badts += 1
                    continue  # 壊れた日付でツール全体を落とさない
                if first_ts is None or ts < first_ts:
                    first_ts = ts
                last_ts = ts
                if ts < cutoff:
                    continue
                if "[tick]" in ln:
                    if "TIMEOUT" in ln: n_timeout += 1
                    if "ERR" in ln:     n_err += 1
                if "[ALERT" in ln:      n_alert += 1
    except OSError as e:
        return {"error": f"tick.log を読めない: {e}"}
    covered = None
    if first_ts and last_ts:
        covered = round((last_ts - first_ts).total_seconds() / 86400, 1)
    hb = os.path.join(ROOT, "site/overseer/last-tick.txt")
    hb_age_min = None
    if os.path.exists(hb):
        hb_age_min = int((datetime.datetime.now().timestamp() - os.path.getmtime(hb)) / 60)
    return {"days": days, "covered_days": covered, "truncated": bool(covered is not None and covered < days),
            "timeout": n_timeout, "err": n_err, "alert": n_alert, "bad_ts": n_badts,
            "heartbeat_missing": not os.path.exists(hb), "heartbeat_age_min": hb_age_min,
            "last_control_line": last_ts.isoformat() if last_ts else None}

FAILLOG = os.path.join(ROOT, "data/overseer/failures.jsonl")

def failure_counts(days=7):
    """agent-tick.sh の fail() が追記する failures.jsonl から正確な7日集計を得る
    （tick.log は1MB切り詰めで約1.5日分しか残らないため＝Codex指摘の恒久対応）。
    ファイルが無い・読めない場合は None（呼び元が tick.log 計数へfallback）。"""
    if not os.path.exists(FAILLOG):
        return None
    cutoff = datetime.datetime.now() - datetime.timedelta(days=days)
    n_timeout = n_err = broken = 0
    oldest = None
    try:
        with open(FAILLOG, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                try:
                    ev = json.loads(ln)
                    ts = datetime.datetime.fromisoformat(ev["ts"]).replace(tzinfo=None)
                    tag = str(ev.get("fail", ""))
                except Exception:
                    broken += 1
                    continue
                if oldest is None or ts < oldest:
                    oldest = ts
                if ts < cutoff:
                    continue
                if tag.startswith("__"):
                    continue   # 開始マーカー等＝期間の起点にだけ使い件数に数えない
                if "-timeout" in tag:
                    n_timeout += 1
                else:
                    n_err += 1
    except OSError:
        return None
    covered = round((datetime.datetime.now() - oldest).total_seconds() / 86400, 1) if oldest else 0.0
    return {"days": days, "covered_days": min(covered, float(days)), "truncated": False,
            "timeout": n_timeout, "err": n_err, "broken": broken, "source": "failures.jsonl"}

# ── 4) 故障：mailbox 滞留 ───────────────────────────────────────────────
def mailbox_backlog():
    out = {}
    for dirname in ("new", "hold"):
        d = os.path.join(ROOT, "data/mailbox", dirname)
        if not os.path.isdir(d):
            out[dirname] = {"missing": True, "per_to": {}, "oldest_days": {}}
            continue
        per_to, oldest, broken = {}, {}, 0
        for f in glob.glob(os.path.join(d, "*.json")):
            try:
                msg = json.load(open(f, encoding="utf-8"))
                to = msg.get("to")
                if not isinstance(to, str) or not to:
                    raise ValueError("to が文字列でない")
            except Exception:
                broken += 1
                continue
            per_to[to] = per_to.get(to, 0) + 1
            age = (datetime.datetime.now().timestamp() - os.path.getmtime(f)) / 86400
            oldest[to] = max(oldest.get(to, 0), age)
        out[dirname] = {"missing": False, "per_to": per_to, "broken": broken,
                        "oldest_days": {k: round(v, 1) for k, v in oldest.items()}}
    return out

# ── 5) 故障：comms（Chatwork蒸留）の無言停止 ───────────────────────────
def comms_health():
    """poll カーソルの停滞・state破損・蒸留の遅れを見る（2026-07-28 Codexレビュー反映）。
    data/comms/ が無い環境（未導入）では None＝何も言わない。マーカーの単純な古さは
    見ない（新着ゼロの日はマーカーが動かないのが正常）＝「新しい raw があるのに
    マーカーが追いつかない」だけを遅れとする。"""
    d = os.path.join(ROOT, "data/comms/chatwork")
    if not os.path.isdir(d):
        return None
    out = {"state_broken": False, "poll_age_h": None, "distill_lag_h": None}
    now_ts = datetime.datetime.now().timestamp()
    st = os.path.join(d, "state.json")
    if os.path.exists(st):
        try:
            j = json.load(open(st, encoding="utf-8"))
            lp = j.get("last_poll")
            if isinstance(lp, (int, float)):
                out["poll_age_h"] = round((now_ts - lp) / 3600, 1)
            else:
                out["state_broken"] = True
        except Exception:
            out["state_broken"] = True
    raws = glob.glob(os.path.join(d, "raw", "*.jsonl"))
    if raws:
        newest_raw = max(os.path.getmtime(f) for f in raws)
        mark = os.path.join(d, ".last-distill")
        mark_ts = os.path.getmtime(mark) if os.path.exists(mark) else 0
        if newest_raw > mark_ts:
            out["distill_lag_h"] = round((now_ts - newest_raw) / 3600, 1)
    return out

# ── 6) 故障：メモリ・swap の枯渇と OOM kill ────────────────────────────
MEM_AVAIL_MIN_PCT = 15     # ★提案既定値：空き（MemAvailable）がこれを切ったら逼迫
SWAP_USED_MAX_PCT = 60     # ★提案既定値：swap をこれ以上使っていたら常態的に足りていない
PROC_HOG_PCT      = 40     # ★提案既定値：単一プロセスが RAM のこれ以上を占めたら暴走の疑い

def memory_health():
    """メモリ・swap の逼迫と OOM kill を見る（2026-07-31 社長承認・OOM対策③）。

    契機＝07-30 02:19 と 07-31 10:05 の2回、RAM 5.8GB のこのVPSでメモリが尽き、カーネルが
    user@1000.service（社長のログインセッションを束ねる systemd）を殺した＝配下の tmux が全滅した。
    当時この監視にはメモリの項目が1つも無く、事前にも事後にも気づく手段が無かった。

    OOM kill は /proc/vmstat の累計カウンタで見る（起動時0から単調増加・sudo 不要＝journal を
    読む権限が要らない）。前回スナップショットとの差＝その間に実際に殺されたプロセス数。
    カウンタが減っていたら再起動＝差分は取らない（増加分だけを故障とみなす）。
    読めない環境では None を返して何も言わない（Linux 以外・/proc 不可視）。"""
    try:
        mi = {}
        with open("/proc/meminfo", encoding="utf-8") as fh:
            for ln in fh:
                k, _, v = ln.partition(":")
                mi[k] = int(v.split()[0])          # kB
        total, avail = mi["MemTotal"], mi["MemAvailable"]
        sw_total, sw_free = mi.get("SwapTotal", 0), mi.get("SwapFree", 0)
    except Exception:
        return None
    oom = None
    try:
        with open("/proc/vmstat", encoding="utf-8") as fh:
            for ln in fh:
                if ln.startswith("oom_kill "):
                    oom = int(ln.split()[1])
                    break
    except Exception:
        pass
    # 上位プロセス（RSS）。読めないpidは黙って飛ばす＝他ユーザ/一瞬で消えたプロセス
    procs = []
    page = os.sysconf("SC_PAGE_SIZE") // 1024      # kB/page
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/statm", encoding="utf-8") as fh:
                rss_kb = int(fh.read().split()[1]) * page
            with open(f"/proc/{d}/comm", encoding="utf-8") as fh:
                name = fh.read().strip()
        except Exception:
            continue
        procs.append({"name": name, "rss_kb": rss_kb})
    procs.sort(key=lambda p: -p["rss_kb"])
    return {"total_kb": total, "avail_kb": avail,
            "avail_pct": round(100 * avail / total) if total else None,
            "swap_total_kb": sw_total, "swap_used_kb": sw_total - sw_free,
            "swap_used_pct": round(100 * (sw_total - sw_free) / sw_total) if sw_total else 0,
            "oom_kill_total": oom, "top": procs[:3]}

def mem_warnings(mem, last):
    """memory_health() の結果を警告行に変える（main から切り出し＝回帰テスト可能にするため）。
    OOM kill は「前回スナップショットからの増加分」だけを鳴らす＝同じ事故で毎日鳴り続けない。
    カウンタが減っていたら再起動とみなして黙る（負の差分を故障にしない）。"""
    if mem is None:
        return ["メモリ計測ができない（/proc が読めない＝OOM の再発を検知できない）"]
    # 判定は必ず【丸める前の実値】で行う（Codex🟡：表示用の round を使うと、空き14.6%が15%に
    # 丸まって「< 15」に該当せず、境界直下をまるごと見逃す。表示だけ丸める）。
    out = []
    po = ((last or {}).get("mem") or {}).get("oom_kill_total")
    co = mem.get("oom_kill_total")
    if isinstance(po, int) and isinstance(co, int) and co > po:
        out.append(f"🚨 前回スナップショット以降に OOM kill が {co - po} 件発生"
                   f"（メモリ枯渇でカーネルがプロセスを殺した＝tmux 全滅の再発疑い）")
    total = mem["total_kb"]
    if total:
        avail = 100 * mem["avail_kb"] / total
        if avail < MEM_AVAIL_MIN_PCT:
            out.append(f"空きメモリ {avail:.1f}% < {MEM_AVAIL_MIN_PCT}%（★提案既定値）＝枯渇寸前")
    if mem["swap_total_kb"]:
        swap = 100 * mem["swap_used_kb"] / mem["swap_total_kb"]
        if swap > SWAP_USED_MAX_PCT:
            out.append(f"swap 使用 {swap:.1f}% > {SWAP_USED_MAX_PCT}%（★提案既定値）＝RAM が恒常的に足りていない")
    for p in mem["top"]:
        pct = 100 * p["rss_kb"] / total if total else 0
        if pct > PROC_HOG_PCT:
            out.append(f"{p['name']} が RAM の {pct:.1f}% ({p['rss_kb']//KB}MB) を占有 > {PROC_HOG_PCT}%"
                       f"（★提案既定値）＝暴走の疑い")
    return out

# ── スナップショット・トレンド ─────────────────────────────────────────
def load_last(where=None):
    """**直前**のスナップショット（最新1件）。OOM kill は「前回実行から何件増えたか」を
    見るので、7日前と比べる load_prev ではなく最新と比べる必要がある。

    where を渡すと、それを満たす最新1件を返す。OOM の比較相手には「oom_kill を実際に
    読めたスナップショット」を要求する（Codex🟡：一時的な /proc/vmstat 読み取り失敗で
    oom_kill_total=None が1件挟まると、単純な最新比較ではその期間の増分を永久に
    復元できず、その間の OOM を取りこぼすため）。"""
    if not os.path.exists(LOG):
        return None
    best, best_ts = None, None
    try:
        with open(LOG, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                try:
                    snap = json.loads(ln)
                    ts = datetime.datetime.fromisoformat(snap["ts"])
                except Exception:
                    continue
                if where is not None and not where(snap):
                    continue
                if best_ts is None or ts > best_ts:
                    best, best_ts = snap, ts
    except OSError:
        return None
    return best

def has_oom_counter(snap):
    """スナップショットが「読めた oom_kill カウンタ」を持つか（load_last の where 用）。"""
    return isinstance(((snap.get("mem") or {}).get("oom_kill_total")), int)

def load_prev(days_back=6):
    """days_back 日以上前のスナップショットのうち **時刻が最も新しい** ものを返す
    （ファイル上の最後ではない＝時計巻き戻り・手動復旧・並べ替えに耐える）。"""
    if not os.path.exists(LOG):
        return None
    cutoff = datetime.datetime.now() - datetime.timedelta(days=days_back)
    best, best_ts = None, None
    try:
        with open(LOG, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                try:
                    snap = json.loads(ln)
                    ts = datetime.datetime.fromisoformat(snap["ts"])
                    if not isinstance(snap.get("states"), list):
                        continue
                except Exception:
                    continue
                if ts <= cutoff and (best_ts is None or ts > best_ts):
                    best, best_ts = snap, ts
    except OSError:
        return None
    return best

def rotate_jsonl(path, keep_days):
    """jsonl の無期限成長を防ぐ（保持期間より古い行を落として書き戻す）。"""
    if not os.path.exists(path):
        return
    cutoff = datetime.datetime.now() - datetime.timedelta(days=keep_days)
    kept = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                try:
                    ts = datetime.datetime.fromisoformat(json.loads(ln)["ts"]).replace(tzinfo=None)
                    if ts >= cutoff:
                        kept.append(ln)
                except Exception:
                    kept.append(ln)   # 判定できない行は捨てない（履歴を消さない）
    except OSError:
        return
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(kept)
    os.replace(tmp, path)

def rotate_log(keep_days=400):
    rotate_jsonl(LOG, keep_days)

def main():
    no_log = "--no-log" in sys.argv
    now = datetime.datetime.now()
    al = autoload()
    states = []
    for path, th, src in STATE_FILES + hp_loop_states():
        b = size(path)
        if b is not None:
            states.append({"path": path, "bytes": b, "threshold": th, "source": src})
    tick = tick_failures()
    fc = failure_counts()
    if fc is not None and not tick.get("error"):
        # 正確な7日集計（failures.jsonl）＋ tick.log 由来の heartbeat/alert を合成
        fails = dict(tick)
        fails.update({k: fc[k] for k in ("days", "covered_days", "truncated", "timeout", "err")})
        fails["fail_source"] = "failures.jsonl"
        if fc.get("broken"):
            fails["bad_ts"] = fails.get("bad_ts", 0) + fc["broken"]
    else:
        fails = tick
        fails.setdefault("fail_source", "tick.log(fallback)")
    mbox = mailbox_backlog()
    comms = comms_health()
    mem = memory_health()
    code = code_layer()
    snap = {"ts": now.isoformat(timespec="seconds"), "autoload": al,
            "states": [{"path": s["path"], "bytes": s["bytes"]} for s in states],
            "failures": fails, "comms": comms, "mem": mem, "code": code}
    # OOM kill の差分用。7日前と比べる prev とは別で、かつ「カウンタを読めた最新1件」を探す
    # （None が1件挟まってもその期間の増分を取りこぼさない＝Codex🟡）
    last = load_last(has_oom_counter)
    prev = load_prev()
    prev_states = {s["path"]: s["bytes"] for s in prev["states"]} if prev else {}

    warns = []
    # 固定費：自動ロード（閾値＋トレンド＝330KB事故に直接対応する監視）
    if al["bytes"] > 50 * KB:
        warns.append(f"自動ロード合計 {al['bytes']//KB}KB > 50KB（★提案既定値）＝ .claude/rules/ に何か堆積")
    elif prev and isinstance(prev.get("autoload"), dict):
        d = al["bytes"] - prev["autoload"].get("bytes", al["bytes"])
        if d > 20 * KB:
            warns.append(f"自動ロードが7日で +{d//KB}KB（{prev['autoload'].get('bytes',0)//KB}→{al['bytes']//KB}KB・閾値内だが増加が速い）")
    # 固定費：状態ファイル
    for s_ in states:
        if s_["bytes"] > s_["threshold"]:
            warns.append(f"{s_['path']} {s_['bytes']//KB}KB > {s_['threshold']//KB}KB（{s_['source']}）")
        elif s_["path"] in prev_states and s_["bytes"] - prev_states[s_["path"]] > 20 * KB:
            warns.append(f"{s_['path']} が7日で +{(s_['bytes']-prev_states[s_['path']])//KB}KB（閾値内だが増加が速い）")
    # 形の異常：サイズが閾値内でも「1本が台帳を食う」形は別に検知する（O-019 の再発防止）
    for tgt in SHAPE_TARGETS:
        warns.extend(shape_warnings(entry_shape(tgt)))
    # バックアップの欠落：本番ツールが git に入っていない（2026-08-11 の1ヶ月放置の再発防止）
    warns.extend(tool_debt_warnings(uncommitted_tools()))
    # コードの層：約束の違反だけ鳴らす（増減行数・重複本数は下の節に数字だけ出す）
    # 比較相手は「コードの層を実際に測れた最新1件」＝この機能を入れる前の古い版と比べて
    # 全件を「新規」と誤報しない（tool_debt と同じく、測れていない期間は黙る）
    last_code = load_last(lambda s: isinstance(s.get("code"), dict))
    warns.extend(code_layer_warnings(code, (last_code or {}).get("code")))
    # 故障：診断不能そのものを故障として扱う（監視の無言停止を防ぐ）
    if fails.get("error"):
        warns.append(f"🚨 診断不能: {fails['error']}")
    else:
        cov, dys = fails.get("covered_days"), fails.get("days")
        if fails.get("truncated") and fails.get("fail_source") != "failures.jsonl":
            warns.append(f"tick.log の保持が {cov}日分しかない（{dys}日を要求・failures.jsonl 未生成＝故障ゼロが続くと未生成のまま）＝下の件数は{cov}日分")
        if fails.get("timeout"):
            warns.append(f"タイムアウト {fails['timeout']} 回（読めた{cov}日分）")
        if fails.get("err"):
            warns.append(f"異常終了 {fails['err']} 回（読めた{cov}日分）")
        if fails.get("alert") and fails.get("fail_source") != "failures.jsonl":
            warns.append(f"警報 {fails['alert']} 回（読めた{cov}日分）＝何かが社長に通知されている")   # jsonl経路では timeout/err が同じ事象を正確に拾うため二重警告しない
        if fails.get("bad_ts"):
            warns.append(f"tick.log に日付が壊れた行 {fails['bad_ts']} 件（ログ破損の疑い）")
        if fails.get("heartbeat_missing"):
            warns.append("🚨 ハートビートファイルが存在しない（tick 停止の疑い）")
        elif fails.get("heartbeat_age_min") is not None and fails["heartbeat_age_min"] > 10:
            warns.append(f"ハートビートが {fails['heartbeat_age_min']} 分更新なし（tick 停止の疑い）")
    # 故障：comms（poll 停滞・state破損・蒸留の遅れ＝無言停止の検知。未導入環境では鳴らない）
    if comms is not None:
        if comms["state_broken"]:
            warns.append("🚨 comms state.json が壊れている（poll が毎回失敗している＝poll.log 確認）")
        if comms["poll_age_h"] is not None and comms["poll_age_h"] > 26:
            warns.append(f"comms poll が {comms['poll_age_h']}h 停滞（2hおき 6-22時 cron が止まっている疑い）")
        if comms["distill_lag_h"] is not None and comms["distill_lag_h"] > 6:
            warns.append(f"comms 蒸留が新着 raw から {comms['distill_lag_h']}h 遅れ（/comms の失敗が続いている疑い＝distill.log 確認）")
    # 故障：メモリ・swap の逼迫と OOM kill（2026-07-31 追加。tmux 全滅の再発検知）
    warns += mem_warnings(mem, last)
    # 故障：mailbox（欠損・壊れたJSONも故障）
    for d, info in mbox.items():
        if info.get("missing"):
            warns.append(f"🚨 mailbox {d}/ ディレクトリが存在しない")
            continue
        if info.get("broken"):
            warns.append(f"mailbox {d}/ に読めないメッセージ {info['broken']} 件（JSON破損・スキーマ不正）")
        for to, age in info["oldest_days"].items():
            limit = 2 if d == "new" else 7   # ★提案既定値：new/2日・hold/7日で滞留とみなす
            if age > limit:
                warns.append(f"mailbox {d}/ の {to} 宛が最古 {age} 日滞留（{info['per_to'].get(to,'?')}件）")

    print(f"# system-health {now.strftime('%Y-%m-%d %H:%M')}")
    print("> 測るのは固定費と故障だけ。思考・探索の変動費（実行中のトークン量）は測らない・閾値を設けない。\n")
    print(f"- 起動時自動ロード: {al['files']}ファイル / {al['bytes']//KB}KB")
    print("- 状態ファイル（毎サイクル全読み・閾値つき）:")
    for s in sorted(states, key=lambda x: -x["bytes"]):
        pct = 100 * s["bytes"] // s["threshold"]
        print(f"    {s['bytes']//KB:4d}KB /{s['threshold']//KB:4d}KB ({pct:3d}%)  {s['path']}")
    if fails.get("error"):
        print(f"- 故障: 🚨 診断不能（{fails['error']}）")
    else:
        print(f"- 故障（ログから読めた {fails.get('covered_days')}日分／要求 {fails.get('days')}日）: "
              f"timeout={fails.get('timeout')} err={fails.get('err')} alert={fails.get('alert')} "
              f"heartbeat={fails.get('heartbeat_age_min')}分前")
    for d, info in mbox.items():
        if info.get("missing"):
            print(f"- mailbox {d}/: 🚨 ディレクトリなし")
            continue
        tot = sum(info["per_to"].values())
        print(f"- mailbox {d}/: {tot}件 {info['per_to'] if tot else ''}")
    if comms is not None:
        lag = f"{comms['distill_lag_h']}h" if comms["distill_lag_h"] is not None else "なし"
        print(f"- comms: 最終poll {comms['poll_age_h']}h前 / 蒸留の未処理遅れ {lag}"
              + (" / 🚨 state破損" if comms["state_broken"] else ""))
    if mem is None:
        print("- メモリ: 🚨 計測不能（/proc が読めない）")
    else:
        d_oom, co = "", mem["oom_kill_total"]
        po = ((last or {}).get("mem") or {}).get("oom_kill_total")
        if isinstance(po, int) and isinstance(co, int):
            d_oom = f"（前回から +{max(0, co - po)}）"
        oom_s = f"{co}回{d_oom}" if isinstance(co, int) else "測定不可（このカーネルに oom_kill カウンタなし）"
        print(f"- メモリ: 空き {mem['avail_kb']//KB}MB/{mem['total_kb']//KB}MB ({mem['avail_pct']}%) / "
              f"swap 使用 {mem['swap_used_kb']//KB}MB/{mem['swap_total_kb']//KB}MB ({mem['swap_used_pct']}%) / "
              f"OOM kill {oom_s}")
        print("    上位: " + " / ".join(f"{p['name']} {p['rss_kb']//KB}MB" for p in mem["top"]))
    print()
    # ── コードの層（統括の全体最適棚卸し用・数字のみ／判定・起票はしない）──────
    print("## コードの層（数字のみ・判定なし＝統括の隔週棚卸しで読む）")
    ch = code["churn"]
    if ch is None:
        print("- bin/ の増減: 🚨 測定不能（git が使えない）")
    else:
        print(f"- bin/ の増減（直近{ch['days']}日）: +{ch['added']}行 / -{ch['removed']}行 / "
              f"純 {ch['net']:+d}行 / 触れた {ch['files']}本")
    un = code["untested"]
    print(f"- 無人ループが実行するツール: {code['loop_tools']}本 / うちテスト無し {len(un)}本"
          + (f"（{', '.join(un)}）" if un else ""))
    if code["dup"]:
        print("- 同じ処理の再実装（候補・grep 相当／`_env.py` と本ツール自身は対象外）: "
              + " / ".join(f"{k} {v}本" for k, v in sorted(code["dup"].items())))
    print(f"- `_tmp_` 残骸: {len(code['tmp'])}本"
          + (f"（最古 {int(code['tmp'][0]['days'])}日）" if code["tmp"] else ""))
    print("> ⚑ 行数・本数に閾値は置かない（置くと「書かないこと」が目標に化ける）。"
          "⚠️ を出すのは約束の違反＝残骸の放置と、無担保ツールの<u>増加</u>だけ。\n")
    if warns:
        print("## ⚠️ 閾値超え・悪化トレンド（統括の起票対象はここだけ）")
        for w in warns:
            print(f"- ⚠️ {w}")
    else:
        print("## ✅ 閾値超え・悪化トレンドなし（起票不要・鳴らさない）")
    if prev:
        print(f"\n（トレンド比較元: {prev['ts']} のスナップショット）")
    else:
        print("\n（トレンド比較元なし＝初回または7日分の履歴未蓄積）")

    if not no_log:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(snap, ensure_ascii=False) + "\n")
        rotate_log()
        rotate_jsonl(FAILLOG, keep_days=60)

if __name__ == "__main__":
    main()
