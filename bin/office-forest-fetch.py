#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bin/office-forest-fetch.py — 3Dオフィス「クライアントの森」用の日次指標を取得する。

3Dダッシュボード（site/office/）のオフィス裏に育つ「サイトの木」のデータ源。
木の大きさ＝直近7日のGSCクリック、実がなる＝CVの翌日、地面の花＝全サイト総合値
（社長指示 2026-08-10）。BigQuery を読み取り専用で叩き、集計値だけを
data/office/forest.json（gitignore 済み）へ書き出す。

設計（gsc-fetch.py / ga4-fetch.py 準拠）:
  - 読み取り専用：SELECT のみ。DML・DDL・外部送信はしない。書くのはローカル JSON 1つ。
  - 課金安全装置：日付フィルタ必須＋ maximum_bytes_billed（サイトごとに上限）。
  - 秘密情報：サービスアカウント JSON は .env の GSC_SA_JSON のパスを渡すだけ・中身は読まない。
    出力 JSON は集計値とダッシュボード表示名のみ＝URL・クエリ文字列・個人情報は書かない。
  - 部分故障に強く：あるサイトのクエリが失敗しても他サイトは更新し、失敗サイトは
    前回 forest.json の値を持ち越す（fetched_date が古いままになる＝鮮度で見分ける）。
  - GSC/GA4 エクスポートは2〜3日遅れる＝「昨日」ではなく「取得できた最新日」を使い、
    latest_date として明示する（見る側が鮮度を判断できる）。

使い方:
  bin/.venv/bin/python bin/office-forest-fetch.py          # 取得して forest.json を更新
  bin/.venv/bin/python bin/office-forest-fetch.py --dry-run # スキャン見積りのみ（書かない）

ロジック（build_payload / bloom 判定）を触るときは bin/test-office-forest.sh を先に流すこと
（rules/testing.md：状態書き込みツールは回帰テスト必須）。
"""
import argparse
import datetime
import json
import os
import re
import sys
import tempfile

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# live/ ではなく office/ 直下＝live/ はビーコンのTTL掃除（office-beacon.sh が
# 60分超の *.json を消す）の領域なので、日次スナップショットを置くと消される（2026-08-11 実発生）
OUT_PATH = os.path.join(PROJ, "data", "office", "forest.json")

# 森に植えるサイト。label は 3D の島名・机名と同じ表示名（クライアント実名の露出を増やさない）。
# gsc=None は「データ未接続」＝3D側で支柱つきの苗木になる。
# ga4 は CVイベントが定義できているサイトだけ（ga4-fetch.py の DATASET_CV_EVENTS と同源）。
SITES = [
    {"id": "ycom",       "label": "自社YCOM",       "gsc": "searchconsole_ycom",
     "ga4": "analytics_265729912",
     "cv_events": ["問い合わせ", "その他お問い合わせ", "お問い合わせ完了ページ(normal)",
                   "スマホからのメール問い合わせ", "mail",
                   "見積もりのリクエスト", "見積り", "見積り2", "見積り依頼完了ページ(create)",
                   "スマホからの電話問い合わせ", "tel"]},
    {"id": "yoshida",    "label": "よしだ歯科",     "gsc": "searchconsole_yoshida",
     "ga4": "analytics_287348176",
     "cv_events": ["reservation", "インターネットによるご予約",
                   "tel", "スマホからの電話問い合わせ"]},
    {"id": "fujisaka",   "label": "藤阪ガス",       "gsc": "searchconsole_fujisaka",
     "ga4": None, "cv_events": None},
    {"id": "yokohawaii", "label": "ヨーコハワイ",   "gsc": "searchconsole_yokohawaii",
     "ga4": None, "cv_events": None},
    {"id": "rally",      "label": "スタンプラリー", "gsc": None, "ga4": None, "cv_events": None},
    {"id": "konjaku",    "label": "今昔写語",       "gsc": None, "ga4": None, "cv_events": None},
]

_IDENT = re.compile(r"^[A-Za-z0-9_]+$")


def err(msg):
    print(msg, file=sys.stderr)


def _env_from_dotenv(key):
    try:
        with open(os.path.join(PROJ, ".env"), encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s.startswith(key + "="):
                    return s[len(key) + 1:]
    except FileNotFoundError:
        pass
    return None


def load_client():
    """サービスアカウント JSON で BigQuery クライアントを作る（gsc-fetch.py と同型・中身は読まない）。"""
    cred_path = (os.environ.get("GSC_SA_JSON") or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
                 or _env_from_dotenv("GSC_SA_JSON"))
    if not cred_path or not os.path.isfile(cred_path):
        err("ERROR: 認証JSONのパス未設定または不存在（.env の GSC_SA_JSON）")
        sys.exit(2)
    from google.cloud import bigquery
    from google.oauth2 import service_account
    creds = service_account.Credentials.from_service_account_file(
        cred_path, scopes=["https://www.googleapis.com/auth/bigquery"])
    return bigquery.Client(credentials=creds, project=creds.project_id), creds.project_id


def run_query(client, sql, params, dry_run, max_bytes=256 * 1024 * 1024):
    # 上限はクエリ単位（Codex🟡 2026-08-11）＝サイトが増えると合計も増えるので1本を小さく保つ。
    # 実測は1本 0.1〜0.2MB＝256MB は千倍以上の余裕
    from google.cloud import bigquery
    job = client.query(sql, job_config=bigquery.QueryJobConfig(
        query_parameters=params, maximum_bytes_billed=max_bytes,
        dry_run=dry_run, use_query_cache=True))
    if dry_run:
        return {"dry_run_gb": round(job.total_bytes_processed / (1024 ** 3), 4)}
    return [dict(row.items()) for row in job.result()]


def fetch_gsc(client, project, dataset, today, dry_run):
    """直近10日ぶんの日別クリックを取る（site_impression＝サイト合計の小さい表）。"""
    from google.cloud import bigquery
    if not _IDENT.match(dataset):
        raise ValueError(f"bad dataset: {dataset!r}")
    sql = f"""SELECT data_date, SUM(clicks) AS clicks
              FROM `{project}.{dataset}.searchdata_site_impression`
              WHERE data_date >= @start
              GROUP BY data_date ORDER BY data_date"""
    start = (today - datetime.timedelta(days=10)).isoformat()
    return run_query(client, sql, [bigquery.ScalarQueryParameter("start", "DATE", start)], dry_run)


def fetch_cv(client, project, dataset, events, today, dry_run):
    """直近5日ぶんの日別CVイベント数。events_* のうち daily だけを見る
    （_TABLE_SUFFIX の BETWEEN 'YYYYMMDD' は 'intraday_...' に一致しない＝自然に除外）。"""
    from google.cloud import bigquery
    if not _IDENT.match(dataset):
        raise ValueError(f"bad dataset: {dataset!r}")
    sql = f"""SELECT event_date, COUNT(*) AS n
              FROM `{project}.{dataset}.events_*`
              WHERE _TABLE_SUFFIX BETWEEN @s AND @e AND event_name IN UNNEST(@events)
              GROUP BY event_date ORDER BY event_date"""
    s = (today - datetime.timedelta(days=5)).strftime("%Y%m%d")
    e = today.strftime("%Y%m%d")
    params = [bigquery.ScalarQueryParameter("s", "STRING", s),
              bigquery.ScalarQueryParameter("e", "STRING", e),
              bigquery.ArrayQueryParameter("events", "STRING", events)]
    return run_query(client, sql, params, dry_run)


def _valid_cv_rows(rows):
    """CV行を [(date_iso, int), ...] に正規化する。壊れた行は黙って捨てる
    （前回JSONの持ち越し経路から型崩れが入っても cron を落とさない＝Codex🔴 2026-08-11）。"""
    out = []
    if not isinstance(rows, (list, tuple)):
        return out
    for r in rows:
        try:
            d, n = r[0], r[1]
            datetime.date.fromisoformat(d)
            out.append((d, int(n)))
        except Exception:
            continue
    return out


def build_payload(prev, today_iso, gsc_by_site, cv_by_site):
    """集計行 → forest.json の中身（純関数＝bin/test-office-forest.sh の対象）。

    gsc_by_site: {site_id: [(date_iso, clicks), ...] | None=取得失敗}
    cv_by_site:  {site_id: [(date_iso, n), ...] | None=取得失敗/未接続}
    失敗(None)のサイトは prev の値を持ち越す（fetched_date が古いまま
    ＝読み手はサイト単位で鮮度を判定できる。Codex🔴 2026-08-11）。
    bloom＝今日から3日以内の日にCVが1件以上（CVが無い日はSQLの結果に行が無いので、
    「最新2行」でなく日付そのもので判定する＝Codex🟡 2026-08-11）。
    prev は構造ごと壊れていても例外にしない（壊れた部分だけ捨てる＝Codex🔴）。
    """
    today = datetime.date.fromisoformat(today_iso)
    prev_sites = prev.get("sites") if isinstance(prev, dict) else None
    if not isinstance(prev_sites, dict):
        prev_sites = {}
    out = {}
    for site in SITES:
        sid = site["id"]
        prev_e = prev_sites.get(sid)
        if not isinstance(prev_e, dict):
            prev_e = None
        if site["gsc"] is None:
            out[sid] = {"label": site["label"], "connected": False}
            continue
        rows = gsc_by_site.get(sid)
        if rows is None:                      # 取得失敗＝前回値を持ち越し
            out[sid] = prev_e if prev_e and prev_e.get("connected") is True else \
                {"label": site["label"], "connected": False}
            continue
        rows = sorted(rows)
        latest_date, latest_clicks = (rows[-1] if rows else (None, 0))
        week = [c for d, c in rows if latest_date and
                (datetime.date.fromisoformat(latest_date) -
                 datetime.date.fromisoformat(d)).days < 7]
        entry = {"label": site["label"], "connected": True,
                 "clicks7d": int(sum(week)), "clicks_latest": int(latest_clicks or 0),
                 "latest_date": latest_date, "fetched_date": today_iso,
                 "has_cv_feed": site["cv_events"] is not None}
        cv_rows = cv_by_site.get(sid)
        if cv_rows is None and site["cv_events"] is not None and prev_e:
            cv_rows = prev_e.get("cv_rows")   # CVだけ失敗→前回のCV行を持ち越し
        cv_rows = _valid_cv_rows(cv_rows)
        if cv_rows:
            cv_rows = sorted(cv_rows)[-5:]
            entry["cv_rows"] = [[d, n] for d, n in cv_rows]
            recent = [(d, n) for d, n in cv_rows
                      if (today - datetime.date.fromisoformat(d)).days <= 3]
            entry["bloom"] = any(n > 0 for _, n in recent)
            entry["cv_recent"] = int(sum(n for _, n in recent))
        else:
            entry["bloom"] = False
            entry["cv_recent"] = 0
        out[sid] = entry
    return {"generated_at": None, "sites": out}   # generated_at は書き込み直前に押す


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    client, project = load_client()
    today = datetime.date.today()

    prev = None
    try:
        with open(OUT_PATH, encoding="utf-8") as f:
            prev = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    if not isinstance(prev, dict):            # JSONとして有効でも構造が違えば捨てる（Codex🔴）
        prev = None

    gsc_by_site, cv_by_site, fails = {}, {}, []
    for site in SITES:
        sid = site["id"]
        if site["gsc"]:
            try:
                rows = fetch_gsc(client, project, site["gsc"], today, args.dry_run)
                if args.dry_run:
                    print(f"{sid} gsc: {rows}")
                else:
                    gsc_by_site[sid] = [(r["data_date"].isoformat(), r["clicks"] or 0) for r in rows]
            except Exception as e:
                fails.append(f"{sid}/gsc:{type(e).__name__}")
                gsc_by_site[sid] = None
        if site["ga4"] and site["cv_events"]:
            try:
                rows = fetch_cv(client, project, site["ga4"], site["cv_events"], today, args.dry_run)
                if args.dry_run:
                    print(f"{sid} cv: {rows}")
                else:
                    cv_by_site[sid] = [(datetime.datetime.strptime(r["event_date"], "%Y%m%d")
                                        .date().isoformat(), r["n"]) for r in rows]
            except Exception as e:
                fails.append(f"{sid}/cv:{type(e).__name__}")
                cv_by_site[sid] = None
    if args.dry_run:
        return

    payload = build_payload(prev, today.isoformat(), gsc_by_site, cv_by_site)
    payload["generated_at"] = int(datetime.datetime.now().timestamp())
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT_PATH), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.chmod(tmp, 0o644)                      # mkstemp は 600＝Webサーバ（読み手）が読めるように
    os.replace(tmp, OUT_PATH)                 # atomic＝読み手（status.php）が途中を見ない
    ok = [s for s, e in payload["sites"].items() if e.get("connected")]
    blooms = [s for s, e in payload["sites"].items() if e.get("bloom")]
    print(f"forest fetch done: connected={len(ok)}/{len(SITES)} bloom={','.join(blooms) or 'なし'}"
          + (f" 失敗={';'.join(fails)}" if fails else ""))
    # GSC設定サイトが全滅＝認証切れ等の系統故障の疑い。持ち越しは書いたうえで非0終了
    # ＝cron ログと system-health で気づける（静かに新鮮なふりをしない。Codex🔴 2026-08-11）
    gsc_sites = [s["id"] for s in SITES if s["gsc"]]
    if gsc_sites and all(gsc_by_site.get(s) is None for s in gsc_sites):
        err("ERROR: 全GSCサイトの取得に失敗（認証・ネットワークの系統故障の疑い）")
        sys.exit(1)


if __name__ == "__main__":
    main()
