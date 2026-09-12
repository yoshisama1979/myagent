#!/usr/bin/env python3
"""ledger-watch — 器（台帳・掲示板・キュー）の状態を数える（LLM なし・良し悪しは判断しない）。

契機＝2026-09-12 社長ご指示「消化すべき台帳の容量の推移を見守り、増え続けているものに
アラートを出す仕組みが要る。一覧があれば判断しやすい」。

**なぜ「超過」でなく「超過かつ悪化中」で鳴らすか**：
2026-09-12 時点で計測対象23本のうち9本が上限超過＝**アラートは既に鳴りっぱなし**で、
毎日 system-health.py が出力し overseer も毎週読んでいたのに誰も動かなかった。
常時点灯する警告は警告ではない。効くのは「超過していて、かつ増え続けているもの」。

**2種類を分けて数える**（性質が違うので混ぜない）：
- **蓄積**（育つ器）＝coverage.md・台帳・掲示板。正常でも増える。上限内に**退避**で収める。
- **キュー**（消化すべきもの）＝mailbox の未処理・判断待ち・未採否。正常なら**減る**。
  減らないこと自体が異常で、サイズでは捕まらない（件数と滞留日数で見る）。
  2026-09-11 の実害（実装報告8通が37日読まれず解析が毎晩空回り）はこちら側だった。

閾値は **bin/system-health.py の定義を読み込む**（正を2つにしない＝版ズレを作らない）。
出典は rules/ledger-discipline.md。

  ledger-watch.py [report]   人が読む1枚
  ledger-watch.py --json     機械可読（ダッシュボード生成用）
  ledger-watch.py snapshot   キューの件数を data/overseer/ledger-watch.jsonl に追記
"""
import argparse
import datetime
import glob
import importlib.util
import json
import os
import re
import sys

ROOT = os.environ.get("LEDGER_WATCH_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KB = 1024
JST = datetime.timezone(datetime.timedelta(hours=9))
HEALTH_LOG = os.path.join(ROOT, "data/overseer/system-health.jsonl")
SNAP_LOG = os.path.join(ROOT, "data/overseer/ledger-watch.jsonl")


def thresholds():
    """閾値は system-health.py が正。ここでは定義せず読み込む（★=出典なしの提案既定値）."""
    path = os.path.join(ROOT, "bin", "system-health.py")
    spec = importlib.util.spec_from_file_location("_sh", path)
    if spec is None or spec.loader is None:
        return {}, "system-health.py を読み込めません"
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)          # __main__ ガードがあるので実行はされない
    except Exception as e:                    # 壊れていても本ツールは止めない（数字は出す）
        return {}, f"閾値を読み込めません（{type(e).__name__}）"
    out = {}
    for p, lim, src in list(getattr(mod, "STATE_FILES", [])) + list(getattr(mod, "hp_loop_states", lambda: [])()):
        out[p] = (lim, src)
    return out, None


def jst_day(ts):
    if not ts:
        return None
    try:
        dt = datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=JST)
    return dt.astimezone(JST).date()


def history():
    """system-health.jsonl の states（path→bytes）を日付つきで古い順に返す."""
    snaps = []
    if not os.path.exists(HEALTH_LOG):
        return snaps
    with open(HEALTH_LOG, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            day = jst_day(d.get("ts"))
            if day and d.get("states"):
                snaps.append((day, {s["path"]: s["bytes"] for s in d["states"] if "path" in s}))
    snaps.sort(key=lambda x: x[0])
    return snaps


def accumulators():
    """蓄積（育つ器）＝サイズ・上限・推移。履歴が無いファイルも実測して必ず出す."""
    lim, lim_err = thresholds()
    snaps = history()
    today = datetime.datetime.now(JST).date()

    def at(days):
        t = today - datetime.timedelta(days=days)
        c = [s for s in snaps if s[0] <= t]
        return c[-1] if c else (snaps[0] if snaps else (today, {}))

    w_day, w = at(7)

    def baseline(rel):
        """その path を含む最古の記録まで遡る。30日固定にすると **履歴の無い新しい器が
        「横ばい」に化ける**（2026-09-12 実測：shigatoyota は7日で+62KBなのに週あたり0.0Kと出た）。"""
        for day, st in snaps:
            if rel in st and (today - day).days >= 3:   # 3日未満は傾きが暴れるので使わない
                return day, st[rel]
        return None, None
    rows = []
    for rel, (limit, src) in sorted(lim.items()):
        full = os.path.join(ROOT, rel)
        if not os.path.exists(full):
            continue
        now = os.path.getsize(full)
        d7 = now - w.get(rel, now)
        b_day, b_bytes = baseline(rel)
        if b_day is None:
            d30, per_week = 0, None       # 記録が1本も無い＝傾きを「0」と名乗らない（不明は不明と出す）
        else:
            span = max((today - b_day).days, 1)
            d30 = now - b_bytes
            per_week = d30 / span * 7
        over = now > limit
        rows.append({
            "path": rel, "bytes": now, "limit": limit, "ratio": now / limit if limit else 0,
            "d7": d7, "d30": d30, "per_week": per_week,
            # 🔴＝超過かつ悪化中／🟡＝超過だが増えていない／🆕＝超過だが傾き不明（計測開始直後）／✅＝上限内
            "flag": ("🆕" if per_week is None else "🔴" if per_week > 0 else "🟡") if over else "✅",
            "src": src, "tracked": rel in (snaps[-1][1] if snaps else {}),
        })
    rows.sort(key=lambda r: (r["flag"] != "🔴", -(r["per_week"] or 0) if r["flag"] == "🔴" else -r["ratio"]))
    return rows, (snaps[0][0] if snaps else None), len(snaps), lim_err


def mailbox_queues():
    """キュー①＝mailbox の未処理。宛先別の件数と最古の滞留日数."""
    today = datetime.datetime.now(JST).date()
    out, unreadable = {}, 0
    for box in ("new", "hold"):
        d = os.path.join(ROOT, "data/mailbox", box)
        for p in glob.glob(os.path.join(d, "*.json")):
            try:
                with open(p, encoding="utf-8") as f:
                    msg = json.load(f)
            except (OSError, ValueError):
                unreadable += 1
                continue
            to = str(msg.get("to", "?"))
            day = jst_day(msg.get("ts"))
            age = (today - day).days if day else None
            k = (box, to)
            e = out.setdefault(k, {"box": box, "to": to, "count": 0, "oldest": None})
            e["count"] += 1
            if age is not None:
                e["oldest"] = age if e["oldest"] is None else max(e["oldest"], age)
    return sorted(out.values(), key=lambda e: (-(e["oldest"] or 0), -e["count"])), unreadable


def decision_queues():
    """キュー②＝判断待ち。triage の索引と skill-kaizen の未採否を数える（本文は読まない）."""
    out = []
    kaizen_open = None
    st = os.path.join(ROOT, "data/triage/state.json")
    if os.path.exists(st):
        try:
            with open(st, encoding="utf-8") as f:
                d = json.load(f)
            items = d.get("items", d) if isinstance(d, dict) else {}
            c = {"open": 0, "asked": 0}
            kaizen_open = 0
            for v in (items.values() if isinstance(items, dict) else []):
                s = str(v.get("status", "")) if isinstance(v, dict) else ""
                if s in c:
                    c[s] += 1
                if s == "open" and isinstance(v, dict) and v.get("lane") == "skill-kaizen":
                    kaizen_open += 1
            note = "bin/pending-scan.py list"
            if kaizen_open:
                note += f"／うち スキル改善提案 {kaizen_open}件（下段と同じもの・二重に数えない）"
            out.append({"name": "社長の判断待ち（未提示）", "count": c["open"], "note": note})
            out.append({"name": "社長へ提示済み・未決", "count": c["asked"], "note": "同上 --status asked"})
        except (OSError, ValueError):
            out.append({"name": "社長の判断待ち", "count": None, "note": "state.json を読めません"})
    sk = os.path.join(ROOT, "data/hp-improve/skill-kaizen.md")
    if os.path.exists(sk):
        # ★件数の正は pending-scan（triage と同じ数を言う＝パーサを2つ持たない）。
        #   ここで独自に数えると、同じものを2つの道具が違う数で言う（2026-09-12 に実際に起きた
        #   ＝見出し184 と 異なるID156 で食い違った。原因は ID の重複21種）。
        #   本ツール固有の関心は「サイズの主因」だけ＝8KB超の肥大エントリ数を添える。
        with open(sk, encoding="utf-8", errors="replace") as f:
            body = f.read()
        parts = re.split(r"(?m)^(### .*?K-[A-Za-z0-9-]+.*)$", body)
        ents = [parts[i] + parts[i + 1] for i in range(1, len(parts), 2)]
        big = sum(1 for e in ents if len(e.encode()) > 8 * KB)
        n = kaizen_open if kaizen_open is not None else None
        note = f"見出し{len(ents)}件・うち8KB超の肥大 {big}件＝**サイズの主因はこの{big}件**"
        if n is None:
            note += "（件数は bin/pending-scan.py scan を流すと出ます）"
        out.append({"name": "スキル改善提案の未採否", "count": n, "note": note})
    return out


def fmt_kb(n):
    return f"{n/KB:,.0f}K"


def report(as_json=False):
    rows, since, n, lim_err = accumulators()
    mail, unreadable = mailbox_queues()
    dec = decision_queues()
    if as_json:
        print(json.dumps({"generated": datetime.datetime.now(JST).isoformat(timespec="seconds"),
                          "since": str(since), "snapshots": n, "accumulators": rows,
                          "mailbox": mail, "decisions": dec, "unreadable": unreadable,
                          "threshold_error": lim_err}, ensure_ascii=False, indent=2))
        return 0
    print(f"■ 器の状態（{datetime.datetime.now(JST).date()}／サイズ履歴 {since}〜・{n}回分）")
    print("  数えるだけで良し悪しは判断しない。🔴＝超過かつ増え続けている／🟡＝超過だが横ばい〜減少／🆕＝超過だが傾き不明（計測開始直後）／✅＝上限内\n")
    if lim_err:
        print(f"  ⚠️ {lim_err}\n")

    print("【1】蓄積（育つ器＝退避で上限内に収めるもの）")
    print(f"  {'':2}{'ファイル':<40}{'現在':>8}{'上限':>7}{'超過':>7}{'7日':>8}{'週あたり':>10}")
    bad = 0
    for r in rows:
        if r["flag"] == "✅":
            continue
        bad += 1
        over = f"{r['ratio']:.1f}倍"
        pw = "  傾き不明" if r["per_week"] is None else f"{r['per_week']/KB:>+8.1f}K"
        print(f"  {r['flag']}{r['path']:<40}{fmt_kb(r['bytes']):>8}{fmt_kb(r['limit']):>7}{over:>7}"
              f"{r['d7']/KB:>+7.0f}K{pw:>9}")
    ok = len(rows) - bad
    print(f"  … 上限内 {ok} 本は省略（全 {len(rows)} 本）")
    untracked = [r["path"] for r in rows if not r["tracked"]]
    if untracked:
        print(f"  ℹ️ 履歴に無い（＝今回から計測）: {', '.join(untracked)}")

    print("\n【2】キュー（消化すべきもの＝減らないこと自体が異常）")
    print(f"  {'置き場':<34}{'件数':>6}{'最古(日)':>10}")
    for e in mail:
        if e["count"] == 0:
            continue
        label = f"mailbox {e['box']}/ → {e['to']}"
        print(f"  {label:<34}{e['count']:>6}{(e['oldest'] if e['oldest'] is not None else '—'):>10}")
    if unreadable:
        print(f"  ⚠️ 読めなかったメッセージ {unreadable} 件")
    print()
    for e in dec:
        c = "—" if e["count"] is None else e["count"]
        print(f"  {e['name']:<34}{c:>6}          {e['note']}")
    return 0


def snapshot():
    _, _, _, _ = accumulators()
    mail, _ = mailbox_queues()
    dec = decision_queues()
    rec = {"ts": datetime.datetime.now(JST).isoformat(timespec="seconds"),
           "mailbox": {f"{e['box']}/{e['to']}": e["count"] for e in mail},
           "decisions": {e["name"]: e["count"] for e in dec}}
    os.makedirs(os.path.dirname(SNAP_LOG), exist_ok=True)
    with open(SNAP_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"追記しました: {os.path.relpath(SNAP_LOG, ROOT)}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cmd", nargs="?", default="report", choices=["report", "snapshot"])
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    return snapshot() if a.cmd == "snapshot" else report(a.json)


if __name__ == "__main__":
    sys.exit(main())
