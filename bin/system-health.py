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
import json, os, re, sys, glob, datetime

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
    snap = {"ts": now.isoformat(timespec="seconds"), "autoload": al,
            "states": [{"path": s["path"], "bytes": s["bytes"]} for s in states],
            "failures": fails, "comms": comms, "mem": mem}
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
