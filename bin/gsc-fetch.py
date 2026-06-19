#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bin/gsc-fetch.py — Search Console（BigQuery 一括エクスポート）から読み取り専用でデータを取得する。

/hp-loop の一次データ源（Q-003 の本命）。GSC の「一括データエクスポート」が吐く
BigQuery テーブル（searchdata_url_impression / searchdata_site_impression）を SELECT し、
クエリ・ページ単位のクリック / 表示回数 / CTR / 平均掲載順位を返す。

設計（automation.md 準拠）:
  - 読み取り専用：SELECT のみ。DML・DDL・外部送信・ファイル書き込みはしない。
  - 課金安全装置：日付範囲を必須でフィルタ（テーブルは data_date でパーティション）＋
    maximum_bytes_billed でスキャン量に上限。--dry-run で実行前にスキャン見積り。
  - 秘密情報：サービスアカウント JSON は .env の GSC_SA_JSON が指すパスを参照するだけ。
    中身は本スクリプトと BigQuery クライアントが読むのみで、ログ・出力には出さない。

使い方:
  bin/.venv/bin/python bin/gsc-fetch.py summary            # 全体サマリ（期間/クリック/表示/CTR/順位）
  bin/.venv/bin/python bin/gsc-fetch.py queries --days 28  # 流入クエリ上位
  bin/.venv/bin/python bin/gsc-fetch.py pages   --days 28  # 流入ページ上位
  bin/.venv/bin/python bin/gsc-fetch.py overview --json    # サマリ＋クエリ＋ページをまとめて JSON で
  bin/.venv/bin/python bin/gsc-fetch.py queries --dry-run  # 課金されるスキャン量だけ見積り（実行しない）

主なオプション:
  --days N           直近 N 日（既定 28）。--start/--end 指定時はそちらが優先
  --start/--end      YYYY-MM-DD。明示的な期間指定
  --limit N          上位件数（既定 25）
  --site URL         site_url で絞り込み（ドメインプロパティで複数サイトがある時）
  --search-type T    WEB(既定)/IMAGE/VIDEO/NEWS/DISCOVER/ALL
  --dataset NAME     データセット名（未指定なら GSC エクスポート表を持つ DS を自動検出）
  --max-gb G         スキャン上限 GB（既定 5）。超えるクエリはエラーで止める
  --dry-run          スキャン量だけ見積もって表示（課金されない）
  --json             機械可読な JSON で出力
"""
import argparse
import datetime
import json
import os
import re
import sys


def err(msg):
    print(msg, file=sys.stderr)


# BigQuery 識別子はクエリパラメータ化できず文字列補間になるため、補間前に必ず検証する
# （SQL インジェクション対策）。dataset は英数字＋_、project は英字始まりの英数字＋ハイフン。
_IDENT_DATASET = re.compile(r"^[A-Za-z0-9_]+$")
_IDENT_PROJECT = re.compile(r"^[A-Za-z][A-Za-z0-9-]*$")


def validate_identifiers(project, dataset):
    if not _IDENT_PROJECT.match(project or ""):
        err(f"ERROR: 不正な project_id: {project!r}（英字始まり・英数字とハイフンのみ）")
        sys.exit(2)
    if not _IDENT_DATASET.match(dataset or ""):
        err(f"ERROR: 不正な dataset 名: {dataset!r}（英数字とアンダースコアのみ）")
        sys.exit(2)


def validate_args(args):
    if args.limit < 1 or args.limit > 10000:
        err(f"ERROR: --limit は 1〜10000 で指定してください: {args.limit}")
        sys.exit(2)
    if args.max_gb <= 0:
        err(f"ERROR: --max-gb は正の数で指定してください: {args.max_gb}")
        sys.exit(2)
    for label, val in (("--start", args.start), ("--end", args.end)):
        if val is not None:
            try:
                datetime.date.fromisoformat(val)
            except ValueError:
                err(f"ERROR: {label} は YYYY-MM-DD 形式で指定してください: {val}")
                sys.exit(2)
    if args.start and args.end and args.start > args.end:
        err(f"ERROR: --start({args.start}) が --end({args.end}) より後です")
        sys.exit(2)


def _env_from_dotenv(key):
    """.env から必要キーだけ読む（全体を読み込まない）。cron 等で環境変数が無いとき用。"""
    try:
        with open(".env", encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s.startswith(key + "="):
                    return s[len(key) + 1:]
    except FileNotFoundError:
        pass
    return None


def load_client():
    """サービスアカウント JSON で BigQuery クライアントを作る。中身は読まない（ライブラリに渡すだけ）。"""
    cred_path = (os.environ.get("GSC_SA_JSON") or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
                 or _env_from_dotenv("GSC_SA_JSON"))
    if not cred_path:
        err("ERROR: 認証JSONのパス未設定。.env に GSC_SA_JSON=data/secrets/gsc-sa.json を設定してください。")
        sys.exit(2)
    if not os.path.isfile(cred_path):
        err(f"ERROR: 認証JSONが見つかりません: {cred_path}（配置とパスを確認）")
        sys.exit(2)
    try:
        from google.cloud import bigquery  # noqa: F401
        from google.oauth2 import service_account
    except ImportError:
        err("ERROR: google-cloud-bigquery 未導入。bin/.venv/bin/python で実行してください。")
        sys.exit(2)
    creds = service_account.Credentials.from_service_account_file(
        cred_path, scopes=["https://www.googleapis.com/auth/bigquery"]
    )
    from google.cloud import bigquery
    client = bigquery.Client(credentials=creds, project=creds.project_id)
    return client, creds.project_id


# GSC 一括エクスポートが作るテーブル名
URL_TABLE = "searchdata_url_impression"
SITE_TABLE = "searchdata_site_impression"

# 集計指標の共通 SELECT 句（summary/queries/pages で共通。1か所で定義して重複を排除）
# avg_position は sum_position が0始まりのため +1 して実掲載順位に揃える近似値
_METRICS = """SUM(clicks) AS clicks, SUM(impressions) AS impressions,
       SAFE_DIVIDE(SUM(clicks), SUM(impressions)) AS ctr,
       SAFE_DIVIDE(SUM(sum_position), SUM(impressions)) + 1 AS avg_position"""


def find_dataset(client, project, explicit):
    """GSC エクスポート表を含むデータセットを特定する。明示指定があればそれを使う。"""
    if explicit:
        return explicit
    found = []
    for ds in client.list_datasets(project=project):
        try:
            tables = {t.table_id for t in client.list_tables(ds.reference)}
        except Exception:
            continue
        if URL_TABLE in tables or SITE_TABLE in tables:
            found.append(ds.dataset_id)
    if not found:
        err(f"ERROR: project={project} に GSC エクスポート表（{URL_TABLE} 等）を持つデータセットが見つかりません。")
        err("       GSC の『一括データエクスポート』が有効か、サービスアカウントに権限があるか確認してください。")
        sys.exit(3)
    if len(found) > 1:
        err(f"ERROR: 候補データセットが複数あります: {found} 。--dataset で指定してください。")
        sys.exit(3)
    return found[0]


def daterange(args):
    if args.start and args.end:
        return args.start, args.end
    today = datetime.date.today()
    end = today
    start = today - datetime.timedelta(days=args.days)
    return start.isoformat(), end.isoformat()


def run_query(client, sql, params, args):
    """SELECT を実行。--dry-run なら見積りだけ。maximum_bytes_billed で上限を強制。"""
    from google.cloud import bigquery

    job_config = bigquery.QueryJobConfig(
        query_parameters=params,
        maximum_bytes_billed=int(args.max_gb * (1024 ** 3)),
        dry_run=args.dry_run,
        use_query_cache=True,
    )
    job = client.query(sql, job_config=job_config)
    if args.dry_run:
        gb = job.total_bytes_processed / (1024 ** 3)
        return {"dry_run": True, "estimated_scan_gb": round(gb, 4)}
    return [dict(row.items()) for row in job.result()]


def _date_params(start, end, search_type, site):
    from google.cloud import bigquery

    params = [
        bigquery.ScalarQueryParameter("start", "DATE", start),
        bigquery.ScalarQueryParameter("end", "DATE", end),
    ]
    if search_type and search_type.upper() != "ALL":
        params.append(bigquery.ScalarQueryParameter("stype", "STRING", search_type.upper()))
    if site:
        params.append(bigquery.ScalarQueryParameter("site", "STRING", site))
    return params


def _where(search_type, site, extra=""):
    w = ["data_date BETWEEN @start AND @end"]
    if search_type and search_type.upper() != "ALL":
        w.append("search_type = @stype")
    if site:
        w.append("site_url = @site")
    if extra:
        w.append(extra)
    return " AND ".join(w)


def q_summary(client, fq, args, start, end):
    sql = f"""
SELECT MIN(data_date) AS first_date, MAX(data_date) AS last_date,
       {_METRICS}
FROM `{fq}`
WHERE {_where(args.search_type, args.site)}
"""
    return run_query(client, sql, _date_params(start, end, args.search_type, args.site), args)


def q_queries(client, fq, args, start, end):
    sql = f"""
SELECT query,
       {_METRICS}
FROM `{fq}`
WHERE {_where(args.search_type, args.site, "query IS NOT NULL")}
GROUP BY query
ORDER BY clicks DESC, impressions DESC
LIMIT @limit
"""
    from google.cloud import bigquery

    params = _date_params(start, end, args.search_type, args.site)
    params.append(bigquery.ScalarQueryParameter("limit", "INT64", args.limit))
    return run_query(client, sql, params, args)


def q_pages(client, fq, args, start, end):
    sql = f"""
SELECT url,
       {_METRICS}
FROM `{fq}`
WHERE {_where(args.search_type, args.site)}
GROUP BY url
ORDER BY clicks DESC, impressions DESC
LIMIT @limit
"""
    from google.cloud import bigquery

    params = _date_params(start, end, args.search_type, args.site)
    params.append(bigquery.ScalarQueryParameter("limit", "INT64", args.limit))
    return run_query(client, sql, params, args)


def fmt_rows(rows):
    """人間可読の簡易表示。順位は小数1桁、CTRは%。"""
    if isinstance(rows, dict):  # dry-run / summary(単一行はリスト)
        return json.dumps(rows, ensure_ascii=False, default=str)
    out = []
    for r in rows:
        line = []
        for k, v in r.items():
            if k == "ctr" and v is not None:
                line.append(f"{k}={v * 100:.2f}%")
            elif k == "avg_position" and v is not None:
                line.append(f"{k}={v:.1f}")
            else:
                line.append(f"{k}={v}")
        out.append("  " + " / ".join(line))
    return "\n".join(out) if out else "  （データなし）"


def main():
    p = argparse.ArgumentParser(description="GSC(BigQuery) 読み取り専用フェッチャ")
    p.add_argument("mode", choices=["summary", "queries", "pages", "overview"], help="取得モード")
    p.add_argument("--days", type=int, default=28)
    p.add_argument("--start")
    p.add_argument("--end")
    p.add_argument("--limit", type=int, default=25)
    p.add_argument("--site", default=None)
    p.add_argument("--search-type", dest="search_type", default="WEB")
    p.add_argument("--dataset", default=None)
    p.add_argument("--max-gb", dest="max_gb", type=float, default=5.0)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--json", dest="as_json", action="store_true")
    args = p.parse_args()
    validate_args(args)

    client, project = load_client()
    dataset = find_dataset(client, project, args.dataset)
    validate_identifiers(project, dataset)  # 補間前に識別子を検証（SQLi対策）
    fq = f"{project}.{dataset}.{URL_TABLE}"
    start, end = daterange(args)

    result = {"project": project, "dataset": dataset, "table": URL_TABLE,
              "start": start, "end": end, "search_type": args.search_type}

    if args.mode == "summary":
        result["summary"] = q_summary(client, fq, args, start, end)
    elif args.mode == "queries":
        result["queries"] = q_queries(client, fq, args, start, end)
    elif args.mode == "pages":
        result["pages"] = q_pages(client, fq, args, start, end)
    elif args.mode == "overview":
        result["summary"] = q_summary(client, fq, args, start, end)
        result["queries"] = q_queries(client, fq, args, start, end)
        result["pages"] = q_pages(client, fq, args, start, end)

    if args.as_json:
        print(json.dumps(result, ensure_ascii=False, default=str, indent=2))
        return

    print(f"■ GSC(BigQuery): {project}.{dataset} / 期間 {start}〜{end} / search_type={args.search_type}")
    if args.dry_run:
        for key in ("summary", "queries", "pages"):
            if key in result:
                print(f"[{key}] dry-run: {fmt_rows(result[key])}")
        return
    for key in ("summary", "queries", "pages"):
        if key in result:
            print(f"--- {key} ---")
            print(fmt_rows(result[key]))


if __name__ == "__main__":
    main()
