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
  bin/.venv/bin/python bin/ga4-fetch.py pages --days 28 --page '?p='   # ページ別の閲覧数・人数
  bin/.venv/bin/python bin/ga4-fetch.py landing --days 28 --page '?p=6624'  # 記事別のCV寄与
  bin/.venv/bin/python bin/ga4-fetch.py sources --days 28 --page '/blog/'   # 着地面の参照元内訳（T-025）
  bin/.venv/bin/python bin/ga4-fetch.py events --dry-run           # 課金スキャン量だけ見積り

主なオプション:
  --days N        直近 N 日（既定 28・本日を含むため範囲は N+1 日分）。--start/--end 指定時はそちら優先
  --start/--end   YYYY-MM-DD。明示的な期間指定
  --limit N       events / pages / landing モードの上位件数（既定 60）
  --dataset NAME  GA4 データセット（既定 analytics_265729912＝はなさか/y-com.info）
  --events LIST   cv / landing モードで集計するイベント名（カンマ区切り。未指定なら既定CVリスト）
  --page STR      pages / landing モードでページの部分一致フィルタ（例 '?p=6624'・'/contents/'）
  --max-gb G      スキャン上限 GB（既定 8）。超えるクエリはエラーで止める
  --dry-run       スキャン量だけ見積もって表示（課金されない）
  --json          機械可読な JSON で出力

ページ別モード（pages / landing・2026-07-13 追加）:
  - pages   : ページ別の page_view 数・ユーザー数。「どの記事が読まれているか」
  - landing : セッションの**最初の page_view**（＝ランディングページ）別に、セッション数・
              CVを含んだセッション数・CV率。「どの記事が問い合わせ／見積に寄与したか」。
              記事末CTA（B-002/B-007 等）の効果検証に使う。
  - page_key はクエリ文字列のうち WordPress の `?p=NNNN` だけを残して正規化する
    （UTM 等でページが分散して見かけの数字が割れるのを防ぐ）。
"""
import argparse
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _env import env_value  # noqa: E402  .env の読み取りは bin/_env.py に集約（重複解消・相対パス事故の防止）


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

# dataset 別の既定CVイベント（サイトごとに GA4 のイベント命名が違うため）。
# ここに無い dataset は DEFAULT_CV_EVENTS にフォールバックする。
# 背景（2026-07-26 hp-loop yoshida Cycle 045）：よしだ歯科の北極星＝WEB予約だが、
# DEFAULT_CV_EVENTS は はなさか(ycom)向けの命名（問い合わせ・見積・tel 系）しか持たず
# `reservation` を含まないため、--events を付け忘れると **全ページの予約CVが 0 と表示される**
# （＝北極星が沈黙する。landing/cv モードの既定値が測定を誤らせる罠）。
DATASET_CV_EVENTS = {
    # よしだ歯科（yoshida）：WEB予約＝reservation／インターネットによるご予約（同一行動の別名2本）、
    #                        電話＝tel／スマホからの電話問い合わせ（同上）
    "analytics_287348176": [
        "reservation", "インターネットによるご予約",
        "tel", "スマホからの電話問い合わせ",
    ],
}


def cv_events_for(dataset, override):
    """CVイベント名を決める：--events 明示 > dataset 別の既定 > 全体の既定。"""
    if override:
        return [e.strip() for e in override.split(",") if e.strip()]
    return DATASET_CV_EVENTS.get(dataset, DEFAULT_CV_EVENTS)


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




def load_client():
    """サービスアカウント JSON で BigQuery クライアントを作る。中身は読まない（ライブラリに渡すだけ）。"""
    cred_path = (os.environ.get("GSC_SA_JSON") or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
                 or env_value("GSC_SA_JSON"))
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


BASE_COLS = "event_name, event_date, user_pseudo_id"

# ページ別モード用の追加列。page_location と ga_session_id を event_params から取り出す。
# page_key はパス＋WordPress の ?p=NNNN だけに正規化する（UTM 等でページが割れるのを防ぐ）。
PAGE_COLS = BASE_COLS + """,
         event_timestamp,
         (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
         CONCAT(
           IFNULL(REGEXP_EXTRACT(
             (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location'),
             r'^https?://[^/]+(/[^?#]*)'), ''),
           IFNULL(CONCAT('?p=', REGEXP_EXTRACT(
             (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location'),
             r'[?&]p=(\\d+)')), '')
         ) AS page_key,
         IFNULL(device.category, '(not set)') AS device_category"""

# 参照元モード用の追加列。イベントスコープの collected_traffic_source（セッションの実流入元に近い）を
# 一次、ユーザースコープの traffic_source（初回接触）をフォールバックに使う。
SRC_COLS = PAGE_COLS + """,
         collected_traffic_source.manual_source AS ev_source,
         collected_traffic_source.manual_medium AS ev_medium,
         traffic_source.source AS user_source,
         traffic_source.medium AS user_medium"""


def build_ga_cte(project, dataset, has_daily, has_intraday, cols=BASE_COLS):
    """daily / intraday の存在に応じて UNION 分岐を組む。
    - daily 分岐は `events_*`（8桁日付フィルタで intraday_* を自然排除）。
    - intraday 分岐は `events_intraday_*`。daily がある日は event_date で除外（二重計上防止）。
    どちらも無ければ None（呼び出し側でエラー）。
    cols は本スクリプト内の定数のみ（外部入力を渡さない＝SQLi対策）。"""
    branches = []
    if has_daily:
        branches.append(
            f"  SELECT {cols}\n"
            f"  FROM `{project}.{dataset}.events_*`\n"
            f"  WHERE _TABLE_SUFFIX BETWEEN @start AND @end"
        )
    if has_intraday:
        dedup = "\n    AND event_date NOT IN UNNEST(@daily_dates)" if has_daily else ""
        branches.append(
            f"  SELECT {cols}\n"
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


def q_pages(client, cte, params, args):
    """ページ別の page_view 数・ユーザー数（--page で部分一致フィルタ）。"""
    from google.cloud import bigquery

    sql = cte + """
SELECT page_key, COUNT(*) AS views, COUNT(DISTINCT user_pseudo_id) AS users
FROM ga
WHERE event_name = 'page_view'
  AND page_key != ''
  AND (@page IS NULL OR STRPOS(page_key, @page) > 0)
GROUP BY page_key
ORDER BY views DESC
LIMIT @limit
"""
    params = params + [
        bigquery.ScalarQueryParameter("page", "STRING", args.page),
        bigquery.ScalarQueryParameter("limit", "INT64", args.limit),
    ]
    return run_query(client, sql, params, args)


def q_landing(client, cte, params, args, cv_events):
    """ランディングページ（セッション最初の page_view）別に、セッション数・CVを含むセッション数・CV率。
    ＝「どの記事が問い合わせ／見積に寄与したか」。記事末CTAの効果検証に使う。
    --by-device 指定時は landing × デバイス種別（mobile/desktop/tablet）で割る（T-024）。
    デバイスはセッション内の最初のイベントの device.category を採用する（セッション途中で
    変わることは実質ないが、複数値が混ざっても1行に潰れないよう明示的に1つ選ぶ）。"""
    from google.cloud import bigquery

    by_device = getattr(args, "by_device", False)
    dev_select = "landing, device_category" if by_device else "landing"
    dev_group = "landing, device_category" if by_device else "landing"

    sql = cte + f"""
, sess AS (
  SELECT user_pseudo_id, session_id,
         ARRAY_AGG(IF(event_name = 'page_view' AND page_key != '', page_key, NULL)
                   IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS landing,
         ARRAY_AGG(device_category IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)]
           AS device_category,
         COUNTIF(event_name IN UNNEST(@cv_events)) AS cv_events
  FROM ga
  WHERE session_id IS NOT NULL
  GROUP BY user_pseudo_id, session_id
)
SELECT {dev_select}, COUNT(*) AS sessions,
       COUNT(DISTINCT user_pseudo_id) AS users,
       COUNTIF(cv_events > 0) AS cv_sessions,
       ROUND(SAFE_DIVIDE(COUNTIF(cv_events > 0) * 100, COUNT(*)), 2) AS cv_rate_pct
FROM sess
WHERE landing IS NOT NULL
  AND (@page IS NULL OR STRPOS(landing, @page) > 0)
GROUP BY {dev_group}
ORDER BY sessions DESC
LIMIT @limit
"""
    params = params + [
        bigquery.ArrayQueryParameter("cv_events", "STRING", cv_events),
        bigquery.ScalarQueryParameter("page", "STRING", args.page),
        bigquery.ScalarQueryParameter("limit", "INT64", args.limit),
    ]
    return run_query(client, sql, params, args)


def q_sources(client, cte, params, args, cv_events):
    """セッションの参照元（source / medium）別に、セッション数・ユーザー数・CV。
    ＝「その着地面のトラフィックはどこから来ているか」。ボット・リファラスパム等の
    機械的アクセスの切り分けに使う（--page で着地ページの部分一致フィルタ）。
    参照元はセッション内の最初の非NULL値：collected_traffic_source（イベントスコープ）を
    一次、traffic_source（ユーザー初回接触）をフォールバックにする（T-025）。"""
    from google.cloud import bigquery

    sql = cte + """
, sess AS (
  SELECT user_pseudo_id, session_id,
         ARRAY_AGG(IF(event_name = 'page_view' AND page_key != '', page_key, NULL)
                   IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS landing,
         ARRAY_AGG(ev_source IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS ev_source,
         ARRAY_AGG(ev_medium IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS ev_medium,
         ARRAY_AGG(user_source IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS user_source,
         ARRAY_AGG(user_medium IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS user_medium,
         COUNTIF(event_name IN UNNEST(@cv_events)) AS cv_events
  FROM ga
  WHERE session_id IS NOT NULL
  GROUP BY user_pseudo_id, session_id
)
SELECT COALESCE(ev_source, user_source, '(not set)') AS source,
       COALESCE(ev_medium, user_medium, '(not set)') AS medium,
       COUNT(*) AS sessions,
       COUNT(DISTINCT user_pseudo_id) AS users,
       COUNTIF(cv_events > 0) AS cv_sessions
FROM sess
WHERE landing IS NOT NULL
  AND (@page IS NULL OR STRPOS(landing, @page) > 0)
GROUP BY source, medium
ORDER BY sessions DESC
LIMIT @limit
"""
    params = params + [
        bigquery.ArrayQueryParameter("cv_events", "STRING", cv_events),
        bigquery.ScalarQueryParameter("page", "STRING", args.page),
        bigquery.ScalarQueryParameter("limit", "INT64", args.limit),
    ]
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
    p.add_argument("mode", choices=["summary", "events", "cv", "pages", "landing", "sources"], help="取得モード")
    p.add_argument("--days", type=int, default=28)
    p.add_argument("--start")
    p.add_argument("--end")
    p.add_argument("--limit", type=int, default=60)
    p.add_argument("--dataset", default=DEFAULT_DATASET)
    p.add_argument("--events", default=None, help="cv / landing モードの対象イベント（カンマ区切り）")
    p.add_argument("--by-device", dest="by_device", action="store_true",
                   help="landing モードで landing×デバイス種別（mobile/desktop/tablet）に分割（T-024）")
    p.add_argument("--page", default=None,
                   help="pages / landing モードでページの部分一致フィルタ（例 '?p=6624'）")
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
    if args.mode == "sources":
        cols = SRC_COLS
    elif args.mode in ("pages", "landing"):
        cols = PAGE_COLS
    else:
        cols = BASE_COLS
    cte = build_ga_cte(project, dataset, has_daily, has_intraday, cols=cols)
    params = base_params(start, end, daily_dates, include_daily_dates=(has_daily and has_intraday))

    result = {"project": project, "dataset": dataset, "start": start, "end": end,
              "has_daily": has_daily, "has_intraday": has_intraday,
              "daily_dates_excluded_from_intraday": daily_dates}

    if args.mode == "summary":
        result["summary"] = q_summary(client, cte, params, args)
    elif args.mode == "events":
        result["events"] = q_events(client, cte, params, args)
    elif args.mode == "cv":
        cv_events = cv_events_for(dataset, args.events)
        result["cv_events"] = cv_events
        result["cv"] = q_cv(client, cte, params, args, cv_events)
    elif args.mode == "pages":
        result["page_filter"] = args.page
        result["pages"] = q_pages(client, cte, params, args)
    elif args.mode == "landing":
        cv_events = cv_events_for(dataset, args.events)
        result["cv_events"] = cv_events
        result["page_filter"] = args.page
        result["landing"] = q_landing(client, cte, params, args, cv_events)
    elif args.mode == "sources":
        cv_events = cv_events_for(dataset, args.events)
        result["cv_events"] = cv_events
        result["page_filter"] = args.page
        result["sources"] = q_sources(client, cte, params, args, cv_events)

    if args.as_json:
        print(json.dumps(result, ensure_ascii=False, default=str, indent=2))
        return

    print(f"■ GA4(BigQuery): {project}.{dataset} / 期間 {start}〜{end}"
          f" / daily日数={len(daily_dates)} / intraday={'有' if has_intraday else '無'}")
    if "cv_events" in result:
        # どのイベントを CV として数えたかを必ず明示する（既定値のまま北極星を取りこぼす事故の防止）
        print(f"  CV対象イベント: {', '.join(result['cv_events'])}")
    for key in ("summary", "events", "cv", "pages", "landing", "sources"):
        if key in result:
            print(f"--- {key} ---")
            print(fmt_rows(result[key]))


if __name__ == "__main__":
    main()
