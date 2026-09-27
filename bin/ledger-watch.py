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
SESSION_DIR = os.environ.get("LEDGER_WATCH_SESSIONS",
                            os.path.expanduser("~/.claude/projects/-home-vpsuser-projects-myagent"))
# 社長が自分で開く窓口。cron で動くモード（partner・hp-loop 等）は「開かれた」の意味が違うので入れない。
DESKS = {"board": "会社の向かう先（月〜四半期）", "triage": "この窓口",
         "finance": "経理・資金", "intake": "走り書き・打ち合わせメモの取り込み",
         "overseer": "システム全体の健全性", "do": "何でも窓口"}
CMD_RE = re.compile(r"<command-name>/?([a-zA-Z0-9_-]+)</command-name>")
SNAP_LOG = os.path.join(ROOT, "data/overseer/ledger-watch.jsonl")
FAILURES = os.path.join(ROOT, "data/overseer/failures.jsonl")
CRON_LOG = os.path.join(ROOT, "data/overseer/cron.log")
ALERT_FALLBACK_DAYS = 7   # 前回この窓口を開いた日が分からないときの窓（★提案既定値）


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
    lost = []

    def _take(rows):
        for p, lim, src in rows:
            out[p] = (lim, src)

    # ★群ごとに独立して取り込む。1つの try でまとめると、動的な群（月数・サイト数で増える器）が
    #   落ちたときに **固定の STATE_FILES ごと** 閾値が消え、全部の器が「上限なし」扱いになる
    #   （申告はするが数字は丸ごと空＝一番効く分を落とす）。Codex 指摘 2026-09-23。
    try:
        _take(list(getattr(mod, "STATE_FILES", [])))
    except Exception as e:
        lost.append(f"STATE_FILES（{type(e).__name__}）")
    for name in ("hp_loop_states", "globbed_states"):   # 本数が増える器（サイト数・月数・モード数）
        try:
            _take(list(getattr(mod, name, lambda: [])()))
        except Exception as e:   # 読み込めても呼び出し・形で落ちうる＝同じ契約（止めずに申告する）で守る
            lost.append(f"{name}（{type(e).__name__}）")
    return out, ("閾値の一部を読めません＝" + "・".join(lost) if lost else None)


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


def pickups():
    """キュー①の裏側＝**宛先ごとに「最後に取りに来た日」**。

    便が届いていないのか、届いているのに取りに来ていないのかは、件数だけでは区別できない
    （実測＝new/ の滞留の大半が「こちら→開発側」宛て＝先方が取りに来ていない／O-082）。
    ⚠️ 取りに来た時刻は `cur/` のファイルの **ctime（改名された時刻）** で見る。mv は mtime を
      持ち越すので mtime では送信時刻しか分からない。バックアップから戻すと ctime は狂う（その旨を表示）。
    """
    today = datetime.datetime.now(JST).date()
    out = {}
    d = os.path.join(ROOT, "data/mailbox", "cur")
    for p_ in glob.glob(os.path.join(d, "*.json")):
        try:
            with open(p_, encoding="utf-8") as f:
                to = str(json.load(f).get("to", "?"))
            ct = os.stat(p_).st_ctime
        except (OSError, ValueError):
            continue
        day = datetime.datetime.fromtimestamp(ct, JST).date()
        e = out.setdefault(to, {"to": to, "count": 0, "last": None})
        e["count"] += 1
        if e["last"] is None or day > e["last"]:
            e["last"] = day
    rows = []
    for e in out.values():
        rows.append({"to": e["to"], "count": e["count"],
                     "last": e["last"].isoformat() if e["last"] else None,
                     "days": (today - e["last"]).days if e["last"] else None})
    return sorted(rows, key=lambda e: -(e["days"] if e["days"] is not None else 10 ** 6))


_KAIZEN = None


def _kaizen():
    """見出しの解釈は bin/kaizen.py が正。ROOT（テストで差し替わる）ではなく、このファイルの隣から読む。"""
    global _KAIZEN
    if _KAIZEN is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kaizen.py")
        spec = importlib.util.spec_from_file_location("_kaizen", path)
        _KAIZEN = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_KAIZEN)
    return _KAIZEN


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
    # 原文の在処は kaizen.py が決める（2026-09-20 に3層へ分割＝旧の1枚は道しるべに畳んだ）。
    # ここでパスを直書きすると、畳んだ器を数えて0件と言うか、月別を見落として黙る。
    srcs = _kaizen().sources_in(os.path.join(ROOT, "data/hp-improve"))
    if srcs:
        # ★件数の正は pending-scan、見出しの解釈の正は bin/kaizen.py（パーサを2つ持たない）。
        #   2026-09-12 版はここで `^###` だけを区切りにしたため、8/23 以降の `## K-NNN` 188件を直前に飲み込み
        #   「8KB超の9件＝サイズの主因」と誤って申告した（実測 2026-09-14＝両方で区切ると 8KB超は0件・
        #   最大 4.3KB＝791KB は約400件×2KB に均等に広がっている）。本ツールはサイズの申告だけを添える。
        # ★1本ずつ parse して足し合わせる。連結してから parse すると、**次のファイルの前文が
        #   前のファイルの最後の項目の本文になる**（項目の範囲＝次の見出しの手前まで＝kaizen.py の parse）。
        #   実測（Codex 指摘 2026-09-20）＝前文9KBのファイルを足すと、ファイル別では 8KB超0件・最大19B
        #   なのに、連結すると 8KB超1件・最大9,020B と誤報した。ここは肥大の申告が仕事なので致命的。
        r = {"count": 0, "over_8kb": 0, "max_entry_bytes": 0, "offformat": [], "duplicates": {}}
        seen = {}
        for f_ in srcs:
            with open(f_, encoding="utf-8", errors="replace") as f:
                one = _kaizen().parse(f.read())
            r["count"] += one["count"]
            r["over_8kb"] += one["over_8kb"]
            r["max_entry_bytes"] = max(r["max_entry_bytes"], one["max_entry_bytes"])
            r["offformat"] += one["offformat"]
            for e in one["entries"]:
                seen[e["id"]] = seen.get(e["id"], 0) + 1
        r["duplicates"] = {k: v for k, v in seen.items() if v > 1}   # 重複は器をまたいで見る
        n = kaizen_open if kaizen_open is not None else None
        note = f"見出し{r['count']}件・うち8KB超の肥大 {r['over_8kb']}件・最大 {r['max_entry_bytes'] // KB}KB"
        if r["offformat"]:
            note += f"・書式外（## K-）{len(r['offformat'])}件"
        if r["duplicates"]:
            note += f"・重複ID {len(r['duplicates'])}種"
        if n is None:
            note += "（件数は bin/pending-scan.py scan を流すと出ます）"
        out.append({"name": "スキル改善提案の未採否", "count": n, "note": note})
    return out


def desks():
    """窓口（社長が自分で開くモード）を最後に開いた日。

    ★「放置されている領域」は台帳にもキューにも出てこない★
      判断待ちが0件でも、その領域を何週間も開いていなければ、それ自体が合図になる
      （2026-09-12 社長ご指示＝「経営やタスク、人事、経理など、すべきことへの誘導まで」）。
      セッションログの先頭にある `<command-name>` を見るだけ＝LLM を起動しない。
    """
    last = {}
    today = datetime.datetime.now(JST).date()
    try:
        files = sorted(glob.glob(os.path.join(SESSION_DIR, "*.jsonl")))
    except OSError:
        return [], "セッションログを読めません"
    for path in files:
        try:
            with open(path, errors="replace") as f:
                head = f.read(16384)
        except OSError:
            continue
        m = CMD_RE.search(head)
        if not m or m.group(1) not in DESKS:
            continue
        day = jst_day(datetime.datetime.fromtimestamp(os.path.getmtime(path), JST).isoformat())
        if day and (m.group(1) not in last or day > last[m.group(1)]):
            last[m.group(1)] = day
    out = []
    for name, what in DESKS.items():
        d = last.get(name)
        out.append({"desk": name, "what": what, "last": str(d) if d else None,
                    "days": (today - d).days if d else None})
    # 「一度もなし」が最も放置されている＝先頭に置く（0日扱いにすると最下位に沈む）
    out.sort(key=lambda e: (0 if e["days"] is None else 1, -(e["days"] or 0)))
    return out, None


CURRENT_OPEN_WINDOW_H = 2   # ★提案既定値。この時間内の起動は「いま開いているこの回」とみなす


def desk_openings(desk):
    """その窓口を開いた**日時の履歴**（古い順）。

    ★`desks()`（【3】）はファイルの mtime と先頭16KB しか見ないので「最後に触った時刻」しか出ない。
      「前回この窓口を開いた時刻」には使えない（実測 2026-09-27＝triage の履歴は1本のセッションログに
      3回分〔08-28・09-05・09-13〕入っていて、mtime では今日しか出なかった＝Codex 指摘）。
      ここでは全行を走査して `<command-name>` の行の timestamp を拾う（全540本・1.0GB で約4秒）。
    """
    out = []
    try:
        files = sorted(glob.glob(os.path.join(SESSION_DIR, "*.jsonl")))
    except OSError:
        return out
    for path in files:
        try:
            with open(path, errors="replace") as f:
                for ln in f:
                    if "<command-name>" not in ln:
                        continue          # 1GB を正規表現に掛けないための前さばき
                    m = CMD_RE.search(ln)
                    if not m or m.group(1) != desk:
                        continue
                    try:
                        ts = json.loads(ln).get("timestamp")
                    except ValueError:
                        ts = None
                    if not ts:
                        continue
                    try:
                        out.append(datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")))
                    except ValueError:
                        continue
        except OSError:
            continue
    return sorted(out)


def previous_desk_opening(desk, now=None):
    """**前回**その窓口を開いた日時（いま開いているこの回は除く）。取れなければ None."""
    now = now or datetime.datetime.now(JST)
    hist = [d.astimezone(JST) for d in desk_openings(desk)]
    # いま開いているこの回を落とす（このコマンドは窓口の起動直後に走るので最新＝今回になる）
    cut = now - datetime.timedelta(hours=CURRENT_OPEN_WINDOW_H)
    past = [d for d in hist if d <= cut]
    return past[-1] if past else None


def alerts(days=None, desk="triage", now=None):
    """前回この窓口を開いた時刻より後の警報。**0件でも0件と言えるように**件数と入力の状態を返す（O-051）。

    出典は既存の2本だけ（`failures.jsonl`＝無人ループの異常終了・`cron.log` の警報行）＝
    外部サービス・費用・新しい依存を増やさない（2026-09-27 社長ご承認・triage.md v1.4）。
    ★`cron.log` は**ブロック形式**＝`# system-health YYYY-MM-DD HH:MM` の下に日付を持たない
      `- ⚠️ …` が並ぶ。行ごとに日付を求めると**1件も拾えない**（実測＝3,766行に対しヒット0件・Codex 指摘）。
    """
    now = now or datetime.datetime.now(JST)
    if days is None:
        last = previous_desk_opening(desk, now)
        since = last or (now - datetime.timedelta(days=ALERT_FALLBACK_DAYS))
        basis = f"前回 /{desk} を開いた {last:%Y-%m-%d %H:%M} 以降" if last \
            else f"直近{ALERT_FALLBACK_DAYS}日（前回 /{desk} を開いた記録が取れないため）"
    else:
        since = now - datetime.timedelta(days=days)
        basis = f"直近{days}日"
    rows, status, unreadable = [], {}, 0

    if not os.path.exists(FAILURES):
        status["failures.jsonl"] = "ありません＝判定不能（0件ではない）"
    else:
        status["failures.jsonl"] = "読めました"
        with open(FAILURES, encoding="utf-8", errors="replace") as f:
            for ln in f:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    r = json.loads(ln)
                except ValueError:
                    unreadable += 1
                    continue
                t = _as_dt(r.get("ts"))
                if t and t > since:
                    rows.append({"at": t, "src": "failures.jsonl",
                                 "what": str(r.get("fail") or r.get("why") or "（内容欄なし）")[:120]})

    # ★`cron.log` は毎晩の system-health の出力そのもの＝器のサイズ警告が毎日同じ顔で並ぶ。
    #   素直に ⚠️ を全部拾うと**前回から263件**になり、鳴りっぱなしで警報として働かない
    #   （実測 2026-09-27・ledger-discipline §2 と同じ型）。器のサイズは ledger-watch【1】と
    #   system-health が既に持っているので**ここでは重複させない**。この出典から取るのは2つだけ：
    #     ① OOM kill が前回から増えた（failures.jsonl には出ない・VPS ごとの危険）
    #     ② 毎晩の監視そのものが出ていない（＝監視の無言停止。2026-09-20〜27 に7日間 実在した）
    if not os.path.exists(CRON_LOG):
        status["cron.log"] = "ありません＝判定不能（0件ではない）"
    else:
        status["cron.log"] = "読めました"
        blk = re.compile(r"^#\s*system-health\s+(20\d\d-\d\d-\d\d)[ T](\d\d:\d\d)")
        oom = re.compile(r"OOM kill\s*(\d+)回（前回から \+(\d+)）")
        at, last_block = None, None
        with open(CRON_LOG, encoding="utf-8", errors="replace") as f:
            for ln in f:
                m = blk.match(ln)
                if m:
                    at = _as_dt(f"{m.group(1)}T{m.group(2)}:00+09:00")
                    last_block = at or last_block
                    continue
                if not at or at <= since:
                    continue
                mo = oom.search(ln)
                if mo and int(mo.group(2)) > 0:
                    rows.append({"at": at, "src": "cron.log",
                                 "what": f"OOM kill が前回から +{mo.group(2)}（累計{mo.group(1)}回）"})
        if last_block is None:
            rows.append({"at": now, "src": "cron.log",
                         "what": "🚨 毎晩の system-health の記録が1件もありません＝監視の無言停止"})
        else:
            gap = (now.date() - last_block.date()).days
            if gap >= 2:
                rows.append({"at": last_block, "src": "cron.log",
                             "what": f"🚨 毎晩の system-health が {gap}日 出ていません"
                                     f"（最後は {last_block:%Y-%m-%d}）＝監視の無言停止"})
    rows.sort(key=lambda e: (e["at"], e["src"]))
    return {"since": since.isoformat(timespec="minutes"), "basis": basis, "count": len(rows),
            "rows": rows, "sources": status, "unreadable": unreadable}


def _as_dt(v):
    """文字列を JST の日時に。読めなければ None（黙って今日扱いにしない）。"""
    if not v:
        return None
    try:
        d = datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None
    return d.astimezone(JST) if d.tzinfo else d.replace(tzinfo=JST)


ALERT_SHOW = 15


def report_alerts(days=None):
    a = alerts(days)
    broken = [k for k, v in a["sources"].items() if v != "読めました"]
    head = "判定不能" if broken else f"{a['count']}件"
    print(f"前回以降の警報 {head}（{a['basis']}）")
    for k in broken:
        print(f"  🚨 出典 {k} が {a['sources'][k]}")
    if a["unreadable"]:
        print(f"  ⚠️ 読めない行 {a['unreadable']}件（黙って捨てていません）")
    shown = a["rows"][-ALERT_SHOW:]
    if len(a["rows"]) > len(shown):
        print(f"  （全{len(a['rows'])}件のうち直近{len(shown)}件を表示／{len(a['rows']) - len(shown)}件は省略）")
    for r in shown:
        print(f"  {r['at']:%Y-%m-%d %H:%M}  {r['src']:<16}{r['what']}")
    return 1 if broken else 0


def fmt_kb(n):
    return f"{n/KB:,.0f}K"


def report(as_json=False):
    rows, since, n, lim_err = accumulators()
    mail, unreadable = mailbox_queues()
    dec = decision_queues()
    dk, dk_err = desks()
    pk = pickups()          # 人向けと機械向けで二度数えない（正を2つ持たない）
    if as_json:
        print(json.dumps({"generated": datetime.datetime.now(JST).isoformat(timespec="seconds"),
                          "since": str(since), "snapshots": n, "accumulators": rows,
                          "mailbox": mail, "pickups": pk, "decisions": dec, "desks": dk,
                          "unreadable": unreadable, "threshold_error": lim_err},
                         ensure_ascii=False, indent=2))
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
    if pk:
        print("  宛先が最後に取りに来た日（cur/ の改名時刻からの**推定**"
              "＝復元・cp でずれる。確定値にするには処理時刻の記録が要る／K-890）")
        print(f"  {'宛先':<26}{'最終(推定)':>12}{'経過':>7}{'処理済':>7}")
        for e in pk:
            last = e["last"] or "一度もなし"
            days = "—" if e["days"] is None else f"{e['days']}日"
            print(f"  {e['to']:<26}{last:>12}{days:>7}{e['count']:>7}")
    print()
    for e in dec:
        c = "—" if e["count"] is None else e["count"]
        print(f"  {e['name']:<34}{c:>6}          {e['note']}")

    print("\n【3】窓口（社長が自分で開くモード・最後に開いた日）")
    print(f"  {'窓口':<12}{'最終':>12}{'経過':>7}  扱うもの")
    for e in dk:
        last = e["last"] or "一度もなし"
        days = "—" if e["days"] is None else f"{e['days']}日"
        print(f"  /{e['desk']:<11}{last:>12}{days:>7}  {e['what']}")
    if dk_err:
        print(f"  ⚠️ {dk_err}")
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
    ap.add_argument("cmd", nargs="?", default="report", choices=["report", "snapshot", "alerts"])
    ap.add_argument("--days", type=int, default=None, help="alerts の窓を日数で指定（既定＝前回この窓口を開いた日以降）")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.cmd == "snapshot":
        return snapshot()
    if a.cmd == "alerts":
        return report_alerts(a.days)
    return report(a.json)


if __name__ == "__main__":
    sys.exit(main())
