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

# ── スナップショット・トレンド ─────────────────────────────────────────
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

def rotate_log(keep_days=400):
    """🟡2: jsonl の無期限成長を防ぐ（保持期間より古い行を落として書き戻す）。"""
    if not os.path.exists(LOG):
        return
    cutoff = datetime.datetime.now() - datetime.timedelta(days=keep_days)
    kept = []
    try:
        with open(LOG, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                try:
                    if datetime.datetime.fromisoformat(json.loads(ln)["ts"]) >= cutoff:
                        kept.append(ln)
                except Exception:
                    kept.append(ln)   # 判定できない行は捨てない（履歴を消さない）
    except OSError:
        return
    tmp = LOG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(kept)
    os.replace(tmp, LOG)

def main():
    no_log = "--no-log" in sys.argv
    now = datetime.datetime.now()
    al = autoload()
    states = []
    for path, th, src in STATE_FILES + hp_loop_states():
        b = size(path)
        if b is not None:
            states.append({"path": path, "bytes": b, "threshold": th, "source": src})
    fails = tick_failures()
    mbox = mailbox_backlog()
    snap = {"ts": now.isoformat(timespec="seconds"), "autoload": al,
            "states": [{"path": s["path"], "bytes": s["bytes"]} for s in states],
            "failures": fails}
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
        if fails.get("truncated"):
            warns.append(f"tick.log の保持が {cov}日分しかない（{dys}日を要求）＝切り詰めで故障件数を取りこぼしている可能性（下の件数は{cov}日分）")
        if fails.get("timeout"):
            warns.append(f"タイムアウト {fails['timeout']} 回（読めた{cov}日分）")
        if fails.get("err"):
            warns.append(f"異常終了 {fails['err']} 回（読めた{cov}日分）")
        if fails.get("alert"):
            warns.append(f"警報 {fails['alert']} 回（読めた{cov}日分）＝何かが社長に通知されている")
        if fails.get("bad_ts"):
            warns.append(f"tick.log に日付が壊れた行 {fails['bad_ts']} 件（ログ破損の疑い）")
        if fails.get("heartbeat_missing"):
            warns.append("🚨 ハートビートファイルが存在しない（tick 停止の疑い）")
        elif fails.get("heartbeat_age_min") is not None and fails["heartbeat_age_min"] > 10:
            warns.append(f"ハートビートが {fails['heartbeat_age_min']} 分更新なし（tick 停止の疑い）")
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

if __name__ == "__main__":
    main()
