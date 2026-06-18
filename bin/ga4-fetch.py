#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bin/ga4-fetch.py — GA4（BigQuery エクスポート）から読み取り専用でイベント/CVを取得する。

/hp-loop の効果検証データ源。GA4 の BigQuery エクスポート（events_YYYYMMDD = daily /
events_intraday_YYYYMMDD = streaming）を SELECT し、イベント分布・CV（問い合わせ/見積等）の
月次トレンド・サマリを返す。title/meta 改善が「問い合わせ・見積の増加」につながったかの検証用。

設計（automation.md / gsc-fetch.py 準拠）:
  - 読み取り専用：SELECT のみ。DML・DDL・外部送信・ファイル書き込みはしない。
  - 課金安全装置：_TABLE_SUFFIX（=日付）を必須でフィルタ＋ maximum_bytes_billed で上限。
    --dry-run は「見積り」（実際の課金上限は実行時も maximum_bytes_billed が最終防衛線）。
  - daily と intraday の二重計上を防ぐ：同一日に両方ある場合は daily を優先し、
    intraday 側は「daily に存在する日」を event_date で除外する。
    さらに、存在するテーブル種別だけを UNION する（無い種別の events_intraday_* / events_* を
    参照してワイルドカードが「一致なし」で失敗するのを避ける）。
  - 秘密情報：サービスアカウント JSON は .env の GSC_SA_JSON が指すパスを参照するだけ。
    中身はライブラリと本スクリプトが読むのみで、ログ・出力には出さない。

使い方（bin/.venv/bin/python で実行）:
  bin/.venv/bin/python bin/ga4-fetch.py summary --days 28          # 期間/イベント数/ユーザー数
  bin/.venv/bin/python bin/ga4-fetch.py events  --days 28          # event_name 別の件数・人数
  bin/.venv/bin/python bin/ga4-fetch.py cv --start 2026-04-01 --end 2026-06-30  # CV を月次トレンドで
  bin/.venv/bin/python bin/ga4-fetch.py cv --events "問い合わせ,見積もりのリクエスト" --json
  bin/.venv/bin/python bin/ga4-fetch.py events --dry-run           # 課金スキャン量だけ見積り

主なオプション:
  --days N        直近 N 日（既定 28・本日を含むため範囲は N+1 日分）。--start/--end 指定時はそちら優先
  --start/--end   YYYY-MM-DD。明示的な期間指定
  --limit N       events モードの上位件数（既定 60）
  --dataset NAME  GA4 データセット（既定 analytics_265729912＝はなさか/y-com.info）
  --events LIST   cv モードで集計するイベント名（カンマ区切り。未指定なら既定CVリスト）
  --max-gb G      スキャン上限 GB（既定 8）。超えるクエリはエラーで止める
  --dry-run       スキャン量だけ見積もって表示（課金されない）
  --json          機械可読な JSON で出力
"""
import argparse
import datetime
import json
import os
import re
import sys


def err(msg):
    print(msg, file=sys.stderr)


# BigQuery 識別子はパラメータ化できず文字列補間になるため、補間前に必ず検証する（SQLi対策）。
_IDENT_DATASET = re.compile(r"^[A-Za-z0-9_]+$")
_IDENT_PROJECT = re.compile(r"^[A-Za-z][A-Za-z0-9-]*$")

# 既定の「はなさか/y-com.info」GA4 プロパティ（BigQuery 在庫メモ 2026-06-16 社長確認）
DEFAULT_DATASET = "analytics_265729912"

# cv モードの既定対象イベント（問い合わせ・見積・電話・メール・応募系。命名重複は R-023 で正規化予定）
DEFAULT_CV_EVENTS = [
    "問い合わせ", "その他お問い合わせ", "お問い合わせ完了ページ(normal)",
    "スマホからのメール問い合わせ", "mail",
    "見積もりのリクエスト", "見積り", "見積り2", "見積り依頼完了ページ(create)",
    "スマホからの電話問い合わせ", "tel",
    "コーダー応募1次完了", "コーダー応募2次完了", "デザイナー応募完了ページ(designer.html)",
]


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
    """.env から必要キーだけ読む（全体を読み込まない）。"""
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


def daterange(args):
    """YYYYMMDD（_TABLE_SUFFIX 用）の (start, end) を返す。"""
    if args.start and args.end:
        return args.start.replace("-", ""), args.end.replace("-", "")
    today = datetime.date.today()
    start = today - datetime.timedelta(days=args.days)
    return start.strftime("%Y%m%d"), today.strftime("%Y%m%d")


def table_inventory(client, project, dataset, start, end):
    """範囲内に存在する daily テーブルの日付一覧と、intraday テーブルの有無を返す。
    （無いテーブル種別を SQL で参照してワイルドカード失敗するのを防ぐための事前確認）"""
    daily_dates = []
    has_intraday = False
    try:
        tables = client.list_tables(f"{project}.{dataset}")
    except Exception as e:
        err(f"ERROR: dataset のテーブル列挙に失敗しました（列挙権限と dataset 名を確認）: {e}")
        sys.exit(3)
    for t in tables:
        md = re.match(r"^events_(\d{8})$", t.table_id)
        mi = re.match(r"^events_intraday_(\d{8})$", t.table_id)
        if md and start <= md.group(1) <= end:
            daily_dates.append(md.group(1))
        elif mi and start <= mi.group(1) <= end:
            has_intraday = True
    return sorted(daily_dates), has_intraday


def build_ga_cte(project, dataset, has_daily, has_intraday):
    """daily / intraday の存在に応じて UNION 分岐を組む。
    - daily 分岐は `events_*`（8桁日付フィルタで intraday_* を自然排除）。
    - intraday 分岐は `events_intraday_*`。daily がある日は event_date で除外（二重計上防止）。
    どちらも無ければ None（呼び出し側でエラー）。"""
    branches = []
    if has_daily:
        branches.append(
            f"  SELECT event_name, event_date, user_pseudo_id\n"
            f"  FROM `{project}.{dataset}.events_*`\n"
            f"  WHERE _TABLE_SUFFIX BETWEEN @start AND @end"
        )
    if has_intraday:
        dedup = "\n    AND event_date NOT IN UNNEST(@daily_dates)" if has_daily else ""
        branches.append(
            f"  SELECT event_name, event_date, user_pseudo_id\n"
            f"  FROM `{project}.{dataset}.events_intraday_*`\n"
            f"  WHERE _TABLE_SUFFIX BETWEEN @start AND @end{dedup}"
        )
    if not branches:
        return None
    return "WITH ga AS (\n" + "\n  UNION ALL\n".join(branches) + "\n)"


def run_query(client, sql, params, args):
    from google.cloud import bigquery

    job_config = bigquery.QueryJobConfig(
        query_parameters=params,
        maximum_bytes_billed=int(args.max_gb * (1024 ** 3)),
        dry_run=args.dry_run,
        use_query_cache=True,
    )
    job = client.query(sql, job_config=job_config)
    if args.dry_run:
        return {"dry_run": True, "estimated_scan_gb": round(job.total_bytes_processed / (1024 ** 3), 4)}
    return [dict(row.items()) for row in job.result()]


def base_params(start, end, daily_dates, include_daily_dates):
    """共通パラメータ。@daily_dates は intraday 分岐で daily を除外するときだけ束縛する
    （未参照パラメータを残さない）。"""
    from google.cloud import bigquery

    params = [
        bigquery.ScalarQueryParameter("start", "STRING", start),
        bigquery.ScalarQueryParameter("end", "STRING", end),
    ]
    if include_daily_dates:
        params.append(bigquery.ArrayQueryParameter("daily_dates", "STRING", daily_dates))
    return params


def q_summary(client, cte, params, args):
    sql = cte + """
SELECT MIN(event_date) AS first_date, MAX(event_date) AS last_date,
       COUNT(*) AS events, COUNT(DISTINCT user_pseudo_id) AS users
FROM ga
"""
    return run_query(client, sql, params, args)


def q_events(client, cte, params, args):
    from google.cloud import bigquery

    sql = cte + """
SELECT event_name, COUNT(*) AS c, COUNT(DISTINCT user_pseudo_id) AS users
FROM ga
GROUP BY event_name
ORDER BY c DESC
LIMIT @limit
"""
    params = params + [bigquery.ScalarQueryParameter("limit", "INT64", args.limit)]
    return run_query(client, sql, params, args)


def q_cv(client, cte, params, args, cv_events):
    from google.cloud import bigquery

    sql = cte + """
SELECT SUBSTR(event_date, 1, 6) AS month, event_name,
       COUNT(*) AS c, COUNT(DISTINCT user_pseudo_id) AS users
FROM ga
WHERE event_name IN UNNEST(@cv_events)
GROUP BY month, event_name
ORDER BY month, c DESC
"""
    params = params + [bigquery.ArrayQueryParameter("cv_events", "STRING", cv_events)]
    return run_query(client, sql, params, args)


def fmt_rows(rows):
    if isinstance(rows, dict):
        return json.dumps(rows, ensure_ascii=False, default=str)
    out = []
    for r in rows:
        out.append("  " + " / ".join(f"{k}={v}" for k, v in r.items()))
    return "\n".join(out) if out else "  （データなし）"


def main():
    p = argparse.ArgumentParser(description="GA4(BigQuery) 読み取り専用フェッチャ")
    p.add_argument("mode", choices=["summary", "events", "cv"], help="取得モード")
    p.add_argument("--days", type=int, default=28)
    p.add_argument("--start")
    p.add_argument("--end")
    p.add_argument("--limit", type=int, default=60)
    p.add_argument("--dataset", default=DEFAULT_DATASET)
    p.add_argument("--events", default=None, help="cv モードの対象イベント（カンマ区切り）")
    p.add_argument("--max-gb", dest="max_gb", type=float, default=8.0)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--json", dest="as_json", action="store_true")
    args = p.parse_args()
    validate_args(args)

    client, project = load_client()
    dataset = args.dataset
    validate_identifiers(project, dataset)  # 補間前に識別子を検証（SQLi対策）
    start, end = daterange(args)

    daily_dates, has_intraday = table_inventory(client, project, dataset, start, end)
    has_daily = len(daily_dates) > 0
    if not has_daily and not has_intraday:
        err(f"ERROR: {project}.{dataset} の {start}〜{end} に events_/events_intraday_ テーブルが見つかりません。")
        sys.exit(3)
    cte = build_ga_cte(project, dataset, has_daily, has_intraday)
    params = base_params(start, end, daily_dates, include_daily_dates=(has_daily and has_intraday))

    result = {"project": project, "dataset": dataset, "start": start, "end": end,
              "has_daily": has_daily, "has_intraday": has_intraday,
              "daily_dates_excluded_from_intraday": daily_dates}

    if args.mode == "summary":
        result["summary"] = q_summary(client, cte, params, args)
    elif args.mode == "events":
        result["events"] = q_events(client, cte, params, args)
    elif args.mode == "cv":
        cv_events = ([e.strip() for e in args.events.split(",") if e.strip()]
                     if args.events else DEFAULT_CV_EVENTS)
        result["cv_events"] = cv_events
        result["cv"] = q_cv(client, cte, params, args, cv_events)

    if args.as_json:
        print(json.dumps(result, ensure_ascii=False, default=str, indent=2))
        return

    print(f"■ GA4(BigQuery): {project}.{dataset} / 期間 {start}〜{end}"
          f" / daily日数={len(daily_dates)} / intraday={'有' if has_intraday else '無'}")
    for key in ("summary", "events", "cv"):
        if key in result:
            print(f"--- {key} ---")
            print(fmt_rows(result[key]))


if __name__ == "__main__":
    main()
