#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bin/ads-fetch.py — Google 広告（BigQuery Data Transfer）から読み取り専用でデータを取得する。

/hp-loop の一次データ源（T-022）。Google Ads Data Transfer が YCOM_MCC データセットに吐く
テーブル群（p_ads_* ベース表＋ads_* ビュー）を SELECT し、費用・クリック・CV・検索語・
CVアクション別内訳・広告×オーガニック重なりを返す。gsc-fetch.py / ga4-fetch.py と同じ設計。

設計（automation.md 準拠）:
  - 読み取り専用：SELECT のみ。DML・DDL・外部送信・ファイル書き込みはしない。
  - 課金安全装置：日付範囲の必須フィルタ（stats 表は日付パーティション）＋
    maximum_bytes_billed でスキャン量に上限。--dry-run で実行前見積り。
  - 秘密情報：サービスアカウント JSON は .env の ADS_SA_JSON（無ければ GSC_SA_JSON）が
    指すパスを参照するだけ。中身は読まない・ログに出さない。

データ構造の前提（2026-07-27 実測で確認）:
  - MCCレベル転送＝テーブル名サフィックスは MCC ID（例 _7979056885）。
    配下アカウントは各行の customer_id 列で区別する。
  - stats 表（p_ads_*Stats_*）は「パーティション日＝segments_date」で1日1回格納＝
    期間フィルタ付き単純SUMで二重計上しない（segments_date='2026-07-10' は
    partition 2026-07-10 のみに存在することを確認済み）。
  - ディメンション表（Campaign 等）は日次スナップショット＝ads_* ビューの
    _DATA_DATE = _LATEST_DATE で最新だけ読む。
  - 単独アカウント（MCC外）対応：そのアカウント用の transfer を別データセットに作れば
    --dataset を変えるだけで同じツールで読める（サフィックスは自動検出）。

使い方:
  bin/.venv/bin/python bin/ads-fetch.py accounts                      # MCC内アカウント一覧
  bin/.venv/bin/python bin/ads-fetch.py summary  --account 1836645282 # 期間合計（費用/クリック/CV/CPA）
  bin/.venv/bin/python bin/ads-fetch.py daily    --account 1836645282 # 日別推移
  bin/.venv/bin/python bin/ads-fetch.py campaigns --account 1836645282 # キャンペーン別（名前つき）
  bin/.venv/bin/python bin/ads-fetch.py queries  --account 1836645282 # 検索語別（費用順）
  bin/.venv/bin/python bin/ads-fetch.py queries  --account 1836645282 --zero-conv  # CV0の消化語＝無駄配信候補
  bin/.venv/bin/python bin/ads-fetch.py conversions --account 1836645282 # CVアクション別内訳
  bin/.venv/bin/python bin/ads-fetch.py paid-organic --account 1836645282 # 広告×自然検索の重なり
  bin/.venv/bin/python bin/ads-fetch.py overview --account 1836645282 --json  # まとめてJSON

主なオプション:
  --account CID     customer_id で絞る（accounts 以外は必須＝省略すると別アカウントの数字が
                    混ざるため。全体俯瞰は accounts モードを使う）
  --days N          直近 N 日（既定 28）。--start/--end 指定時はそちらが優先
  --start/--end     YYYY-MM-DD
  --limit N         上位件数（既定 25）
  --dataset NAME    データセット名（既定 YCOM_MCC。単独アカウント転送はここを変える）
  --max-gb G        スキャン上限 GB（既定 2）
  --dry-run         スキャン見積りのみ（課金されない）
  --json            機械可読な JSON で出力
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
# （SQL インジェクション対策）。gsc-fetch.py と同型＋サフィックスは数字のみ。
_IDENT_DATASET = re.compile(r"^[A-Za-z0-9_]+$")
_IDENT_PROJECT = re.compile(r"^[A-Za-z][A-Za-z0-9-]*$")
_IDENT_SUFFIX = re.compile(r"^\d+$")


def validate_identifiers(project, dataset, suffix):
    if not _IDENT_PROJECT.match(project or ""):
        err(f"ERROR: 不正な project_id: {project!r}")
        sys.exit(2)
    if not _IDENT_DATASET.match(dataset or ""):
        err(f"ERROR: 不正な dataset 名: {dataset!r}")
        sys.exit(2)
    if not _IDENT_SUFFIX.match(suffix or ""):
        err(f"ERROR: 不正なテーブルサフィックス: {suffix!r}（数字のみ）")
        sys.exit(2)


def validate_args(args):
    if args.limit < 1 or args.limit > 10000:
        err(f"ERROR: --limit は 1〜10000: {args.limit}")
        sys.exit(2)
    if args.max_gb <= 0:
        err(f"ERROR: --max-gb は正の数: {args.max_gb}")
        sys.exit(2)
    if args.days < 1:
        err(f"ERROR: --days は 1 以上: {args.days}")
        sys.exit(2)
    # 片側だけの指定を黙って無視しない（入力ミスが「空データの正常終了」に化けるのを防ぐ）
    if bool(args.start) != bool(args.end):
        err("ERROR: --start と --end は両方指定してください（片側だけは不可）")
        sys.exit(2)
    for label, val in (("--start", args.start), ("--end", args.end)):
        if val is not None:
            try:
                datetime.date.fromisoformat(val)
            except ValueError:
                err(f"ERROR: {label} は YYYY-MM-DD 形式: {val}")
                sys.exit(2)
    if args.start and args.end and args.start > args.end:
        err(f"ERROR: --start({args.start}) が --end({args.end}) より後です")
        sys.exit(2)
    if args.account is not None and not re.match(r"^\d+$", str(args.account)):
        err(f"ERROR: --account は customer_id（数字）: {args.account}")
        sys.exit(2)
    # accounts 以外は --account 必須：日別・検索語・CVアクション等の集計は customer_id で
    # 分けないため、省略すると別アカウントの数字が混ざったまま正常終了してしまう（Codex指摘🔴1）
    if args.mode != "accounts" and args.account is None:
        err("ERROR: このモードでは --account <customer_id> が必須です（全体俯瞰は accounts モード）")
        sys.exit(2)


def _env_from_dotenv(key):
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
    """サービスアカウント JSON で BigQuery クライアントを作る。中身は読まない。"""
    cred_path = (os.environ.get("ADS_SA_JSON") or os.environ.get("GSC_SA_JSON")
                 or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
                 or _env_from_dotenv("ADS_SA_JSON") or _env_from_dotenv("GSC_SA_JSON"))
    if not cred_path:
        err("ERROR: 認証JSONのパス未設定。.env の ADS_SA_JSON か GSC_SA_JSON を設定してください。")
        sys.exit(2)
    if not os.path.isfile(cred_path):
        err(f"ERROR: 認証JSONが見つかりません: {cred_path}")
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


def find_suffix(client, project, dataset):
    """データセット内の p_ads_Customer_<数字> からテーブルサフィックス（MCC/アカウントID）を自動検出。"""
    suffixes = set()
    try:
        for t in client.list_tables(f"{project}.{dataset}"):
            m = re.match(r"^p_ads_Customer_(\d+)$", t.table_id)
            if m:
                suffixes.add(m.group(1))
    except Exception as e:
        err(f"ERROR: dataset={dataset} のテーブル一覧取得に失敗: {e}")
        sys.exit(3)
    if not suffixes:
        err(f"ERROR: dataset={dataset} に Google Ads 転送表（p_ads_Customer_* ）が見つかりません。")
        sys.exit(3)
    if len(suffixes) > 1:
        err(f"ERROR: サフィックス候補が複数あります: {sorted(suffixes)}（想定外の構成）")
        sys.exit(3)
    return suffixes.pop()


def daterange(args):
    if args.start and args.end:
        return args.start, args.end
    today = datetime.date.today()
    # 転送は前日分まで。end は昨日にして「今日の空データ」で日別が欠けて見えるのを防ぐ
    end = today - datetime.timedelta(days=1)
    start = end - datetime.timedelta(days=args.days - 1)
    return start.isoformat(), end.isoformat()


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
        gb = job.total_bytes_processed / (1024 ** 3)
        return {"dry_run": True, "estimated_scan_gb": round(gb, 4)}
    return [dict(row.items()) for row in job.result()]


def _params(start, end, args, extra=()):
    from google.cloud import bigquery

    params = [
        bigquery.ScalarQueryParameter("start", "DATE", start),
        bigquery.ScalarQueryParameter("end", "DATE", end),
    ]
    if args.account is not None:
        params.append(bigquery.ScalarQueryParameter("cid", "INT64", int(args.account)))
    params.extend(extra)
    return params


def _limit_param(args):
    from google.cloud import bigquery
    return (bigquery.ScalarQueryParameter("limit", "INT64", args.limit),)


# 期間＋アカウントの共通 WHERE。stats 表はパーティション日＝segments_date（実測確認済み）
# なので両方で絞る＝スキャン最小化と正しさの両立。
def _where(args):
    w = ["_PARTITIONDATE BETWEEN @start AND @end", "segments_date BETWEEN @start AND @end"]
    if args.account is not None:
        w.append("customer_id = @cid")
    return " AND ".join(w)


# 集計指標の共通 SELECT 句（cost_micros→円。CPA は CV>0 のときだけ）
_METRICS = """SUM(metrics_cost_micros)/1e6 AS cost,
       SUM(metrics_impressions) AS impressions,
       SUM(metrics_clicks) AS clicks,
       SAFE_DIVIDE(SUM(metrics_clicks), SUM(metrics_impressions)) AS ctr,
       SUM(metrics_conversions) AS conversions,
       SUM(metrics_conversions_value) AS conv_value,
       SAFE_DIVIDE(SUM(metrics_cost_micros)/1e6, NULLIF(SUM(metrics_conversions),0)) AS cpa"""


def q_accounts(client, T, args, start, end):
    """アカウント一覧（最新スナップショット）＋期間内の実績有無。"""
    sql = f"""
WITH cust AS (
  SELECT customer_id, customer_descriptive_name, customer_currency_code
  FROM `{T('ads_Customer')}`
  WHERE _DATA_DATE = _LATEST_DATE AND customer_manager = FALSE
), stats AS (
  SELECT customer_id, MAX(segments_date) AS latest_date, {_METRICS}
  FROM `{T('p_ads_AccountBasicStats')}`
  WHERE _PARTITIONDATE BETWEEN @start AND @end AND segments_date BETWEEN @start AND @end
  GROUP BY 1
)
SELECT c.customer_id, c.customer_descriptive_name, c.customer_currency_code,
       s.latest_date, s.cost, s.impressions, s.clicks, s.ctr, s.conversions, s.conv_value, s.cpa
FROM cust c LEFT JOIN stats s USING (customer_id)
ORDER BY s.cost DESC
"""
    return run_query(client, sql, _params(start, end, args), args)


def q_summary(client, T, args, start, end):
    # last_date が期間末より古い場合は転送遅延（前日分未着）＝費用急落と読まないこと
    sql = f"""
SELECT MIN(segments_date) AS first_date, MAX(segments_date) AS last_date,
       {_METRICS}
FROM `{T('p_ads_AccountBasicStats')}`
WHERE {_where(args)}
"""
    return run_query(client, sql, _params(start, end, args), args)


def q_daily(client, T, args, start, end):
    sql = f"""
SELECT segments_date AS date, {_METRICS}
FROM `{T('p_ads_AccountBasicStats')}`
WHERE {_where(args)}
GROUP BY 1 ORDER BY 1
"""
    return run_query(client, sql, _params(start, end, args), args)


def q_campaigns(client, T, args, start, end):
    sql = f"""
WITH stats AS (
  SELECT campaign_id, customer_id, {_METRICS}
  FROM `{T('p_ads_CampaignBasicStats')}`
  WHERE {_where(args)}
  GROUP BY 1, 2
), camp AS (
  SELECT campaign_id, customer_id, campaign_name, campaign_status,
         campaign_advertising_channel_type AS channel,
         campaign_budget_amount_micros/1e6 AS daily_budget
  FROM `{T('ads_Campaign')}`
  WHERE _DATA_DATE = _LATEST_DATE
)
SELECT s.customer_id, s.campaign_id, c.campaign_name, c.campaign_status, c.channel, c.daily_budget,
       s.cost, s.impressions, s.clicks, s.ctr, s.conversions, s.conv_value, s.cpa
FROM stats s LEFT JOIN camp c USING (campaign_id, customer_id)
ORDER BY s.cost DESC
LIMIT @limit
"""
    return run_query(client, sql, _params(start, end, args, _limit_param(args)), args)


def q_queries(client, T, args, start, end):
    """検索語レポート。--zero-conv で「費用を消化したのに CV 0」の語だけ＝無駄配信候補。"""
    having = "HAVING conversions = 0 AND cost > 0" if args.zero_conv else ""
    # match_type も GROUP BY に含める（ANY_VALUE だと同一検索語×複数マッチタイプで表示が不定になる）
    sql = f"""
SELECT search_term_view_search_term AS search_term,
       segments_search_term_match_type AS match_type,
       {_METRICS}
FROM `{T('p_ads_SearchQueryStats')}`
WHERE {_where(args)}
GROUP BY 1, 2
{having}
ORDER BY cost DESC, clicks DESC
LIMIT @limit
"""
    return run_query(client, sql, _params(start, end, args, _limit_param(args)), args)


def q_conversions(client, T, args, start, end):
    """CVアクション別の内訳。「何をコンバージョンとして数えているか」を見る
    （ページ閲覧CVのような計測設計の問題はここに表れる）。"""
    sql = f"""
SELECT segments_conversion_action_name AS action_name,
       ANY_VALUE(segments_conversion_action_category) AS category,
       SUM(metrics_conversions) AS conversions,
       SUM(metrics_conversions_value) AS conv_value
FROM `{T('p_ads_CampaignConversionStats')}`
WHERE {_where(args)}
GROUP BY 1
ORDER BY conversions DESC
LIMIT @limit
"""
    return run_query(client, sql, _params(start, end, args, _limit_param(args)), args)


def q_paid_organic(client, T, args, start, end):
    """広告×自然検索の重なり（同じ検索語で広告と自然検索がどう出ているか）。
    「自然検索で取れている語に広告費を使っていないか」の判断材料。"""
    sql = f"""
SELECT paid_organic_search_term_view_search_term AS search_term,
       SUM(metrics_clicks) AS paid_clicks,
       SUM(metrics_impressions) AS paid_impressions,
       SUM(metrics_organic_clicks) AS organic_clicks,
       SUM(metrics_organic_impressions) AS organic_impressions,
       SUM(metrics_organic_queries) AS organic_queries
FROM `{T('p_ads_PaidOrganicStats')}`
WHERE {_where(args)}
GROUP BY 1
ORDER BY paid_clicks DESC, organic_clicks DESC
LIMIT @limit
"""
    return run_query(client, sql, _params(start, end, args, _limit_param(args)), args)


def fmt_rows(rows):
    """人間可読の簡易表示。金額は整数円、率は%。"""
    if isinstance(rows, dict):
        return json.dumps(rows, ensure_ascii=False, default=str)
    out = []
    for r in rows:
        line = []
        for k, v in r.items():
            if v is None:
                line.append(f"{k}=-")
            elif k == "ctr":
                line.append(f"{k}={v * 100:.2f}%")
            elif k in ("cost", "cpa", "conv_value", "daily_budget"):
                line.append(f"{k}=¥{v:,.0f}")
            elif k in ("conversions",):
                line.append(f"{k}={v:.1f}")
            else:
                line.append(f"{k}={v}")
        out.append("  " + " / ".join(line))
    return "\n".join(out) if out else "  （データなし）"


MODES = {
    "accounts": q_accounts,
    "summary": q_summary,
    "daily": q_daily,
    "campaigns": q_campaigns,
    "queries": q_queries,
    "conversions": q_conversions,
    "paid-organic": q_paid_organic,
}


def main():
    p = argparse.ArgumentParser(description="Google広告(BigQuery Data Transfer) 読み取り専用フェッチャ")
    p.add_argument("mode", choices=list(MODES.keys()) + ["overview"], help="取得モード")
    p.add_argument("--account", default=None, help="customer_id（数字）で絞る")
    p.add_argument("--days", type=int, default=28)
    p.add_argument("--start")
    p.add_argument("--end")
    p.add_argument("--limit", type=int, default=25)
    p.add_argument("--dataset", default="YCOM_MCC")
    p.add_argument("--zero-conv", dest="zero_conv", action="store_true",
                   help="queries モードで CV0×費用ありの語だけ（無駄配信候補）")
    p.add_argument("--max-gb", dest="max_gb", type=float, default=2.0)
    p.add_argument("--dry-run", dest="dry_run", action="store_true")
    p.add_argument("--json", dest="as_json", action="store_true")
    args = p.parse_args()
    validate_args(args)

    client, project = load_client()
    suffix = find_suffix(client, project, args.dataset)
    validate_identifiers(project, args.dataset, suffix)
    start, end = daterange(args)

    def T(base):
        return f"{project}.{args.dataset}.{base}_{suffix}"

    if args.mode == "overview":
        result = {"project": project, "dataset": args.dataset, "suffix": suffix,
                  "account": args.account, "period": {"start": start, "end": end}}
        for m in ("summary", "campaigns", "conversions", "queries"):
            result[m] = MODES[m](client, T, args, start, end)
        print(json.dumps(result, ensure_ascii=False, default=str, indent=1))
        return

    rows = MODES[args.mode](client, T, args, start, end)
    if args.as_json:
        print(json.dumps({"mode": args.mode, "dataset": args.dataset, "account": args.account,
                          "period": {"start": start, "end": end}, "rows": rows},
                         ensure_ascii=False, default=str, indent=1))
    else:
        print(f"■ ads-fetch {args.mode} dataset={args.dataset} account={args.account or '(全アカウント)'} 期間={start}〜{end}")
        print(fmt_rows(rows))


if __name__ == "__main__":
    main()
