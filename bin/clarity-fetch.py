#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bin/clarity-fetch.py — Microsoft Clarity（Data Export API）から読み取り専用で行動データを取得する。

/hp-loop の実測行動データ源（T-012）。GSC が「検索まで」・hp-shot が「見た目」を担うのに対し、
Clarity は「サイト内で訪問者が実際どう動いたか」（スクロール到達・エンゲージメント時間・
レイジクリック・デッドクリック・クイックバック等）を実測で返す＝導線・CV提案の根拠を推測→実測にする。

設計（automation.md 準拠）:
  - 読み取り専用：HTTP GET のみ。外部送信・書き込み・破壊的操作はしない。
  - 秘密情報：API トークンは .env の CLARITY_API_TOKEN_<SITE>（例 CLARITY_API_TOKEN_YCOM）を
    必要キーだけ読む。値はログ・出力・エラーに一切出さない。
  - ⚠️ レート制限：Clarity の Data Export API は **1プロジェクトあたり 1日 10 リクエストまで**。
    本ツールはローカルに当日の呼び出し回数を記録し、10回に達したら実行を拒否する（--force で無視可。
    ただし API 側でも拒否されるだけなので通常は使わない）。ループでの利用は 1日1〜2回に留めること。
  - データ範囲：API 仕様上、直近 1〜3 日の集計のみ（それより過去は取れない。長期トレンドは
    日次で取得した JSON を data/hp-loop/cycles/<site>/clarity/ に蓄積して比較する）。

使い方:
  bin/.venv/bin/python3 bin/clarity-fetch.py                       # ycom・直近3日・全体サマリ
  bin/.venv/bin/python3 bin/clarity-fetch.py --days 1              # 直近1日
  bin/.venv/bin/python3 bin/clarity-fetch.py --dim1 URL            # ページ別（例：スクロール到達をURL別に）
  bin/.venv/bin/python3 bin/clarity-fetch.py --dim1 URL --dim2 Device  # ページ×デバイス
  bin/.venv/bin/python3 bin/clarity-fetch.py --json                # 生JSON（cycles/ への蓄積用）
  bin/.venv/bin/python3 bin/clarity-fetch.py --site <site>         # 他サイト（.env に CLARITY_API_TOKEN_<SITE> が要る）

主なオプション:
  --site NAME   サイトキー（既定 ycom）。トークンは .env の CLARITY_API_TOKEN_<大文字SITE>
  --days N      直近 N 日（1〜3・既定 3）
  --dim1/2/3    ディメンション（URL / Device / Country / Browser / OS / Source / Medium / Campaign / Channel）
  --json        生 JSON で出力（既定は要約表示）
  --quota       当日の残り呼び出し回数だけ表示して終了（APIは呼ばない）
"""
import argparse
import datetime
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API_URL = "https://www.clarity.ms/export-data/api/v1/project-live-insights"
DAILY_LIMIT = 10  # Clarity Data Export API の制限（1プロジェクト/日）
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
COUNT_DIR = os.path.join(ROOT, "data", "hp-loop", ".clarity-quota")  # 当日呼び出し回数の記録
VALID_DIMS = {"URL", "Device", "Country", "Browser", "OS", "Source", "Medium", "Campaign", "Channel"}


def err(msg):
    print(msg, file=sys.stderr)


def _env_from_dotenv(key):
    """.env から必要キーだけ読む（全体を読み込まない）。値は呼び出し元でもログに出さない。"""
    try:
        with open(os.path.join(ROOT, ".env"), encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s.startswith(key + "="):
                    return s[len(key) + 1:]
    except FileNotFoundError:
        pass
    return None


def load_token(site):
    key = f"CLARITY_API_TOKEN_{site.upper()}"
    token = os.environ.get(key) or _env_from_dotenv(key)
    if not token:
        err(f"ERROR: {key} が未設定です。Clarity → 設定 → データエクスポート → APIトークン生成 →"
            f" .env に {key}=<トークン> を追記してください（実値はAIが読まない・表示しない運用）。")
        sys.exit(2)
    return token


def _quota_path(site):
    today = datetime.date.today().isoformat()
    return os.path.join(COUNT_DIR, f"{site}-{today}.count")


def quota_used(site):
    try:
        with open(_quota_path(site), encoding="utf-8") as f:
            return int(f.read().strip() or 0)
    except (FileNotFoundError, ValueError):
        return 0


def quota_increment(site):
    os.makedirs(COUNT_DIR, exist_ok=True)
    used = quota_used(site) + 1
    with open(_quota_path(site), "w", encoding="utf-8") as f:
        f.write(str(used))
    return used


def fetch(site, days, dims, force=False):
    used = quota_used(site)
    if used >= DAILY_LIMIT and not force:
        err(f"ERROR: 本日の呼び出しが {used}/{DAILY_LIMIT} に達しています（Clarity API の日次上限）。"
            f" 明日まで待つか、既取得の cycles/ 蓄積 JSON を使ってください。")
        sys.exit(3)
    params = {"numOfDays": str(days)}
    for i, d in enumerate(dims, start=1):
        params[f"dimension{i}"] = d
    url = API_URL + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + load_token(site),
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        # トークンはエラーに出さない。HTTP ステータスと API の説明だけ。
        detail = ""
        try:
            detail = e.read().decode("utf-8")[:300]
        except Exception:  # noqa: BLE001
            pass
        err(f"ERROR: Clarity API が HTTP {e.code} を返しました。{detail}")
        if e.code == 401:
            err("→ トークンが無効/期限切れの可能性。Clarity の設定→データエクスポートで再発行してください。")
        if e.code == 429:
            err("→ 日次上限（10回/プロジェクト）超過。明日まで待ってください。")
        sys.exit(1)
    except urllib.error.URLError as e:
        err(f"ERROR: Clarity API に到達できません: {e.reason}")
        sys.exit(1)
    except (TimeoutError, OSError) as e:  # 読み取り途中のタイムアウト等は URLError にならない
        err(f"ERROR: Clarity API との通信がタイムアウト/切断されました: {e}（一時的なら再実行で回復）")
        sys.exit(1)
    quota_increment(site)
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        err("ERROR: Clarity API の応答が JSON ではありません（先頭300字を表示）：")
        err(body[:300])
        sys.exit(1)


def summarize(data):
    """メトリクスごとに情報行をコンパクトに表示（スキーマ変化に強いよう汎用に流す）。"""
    if not isinstance(data, list):
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return
    for metric in data:
        name = metric.get("metricName", "(不明)")
        rows = metric.get("information") or []
        print(f"\n## {name}（{len(rows)}行）")
        for row in rows[:20]:  # 表示は上位20行まで（--json なら全量）
            pairs = [f"{k}={v}" for k, v in row.items() if v not in (None, "")]
            print("  - " + " / ".join(pairs))
        if len(rows) > 20:
            print(f"  …他 {len(rows) - 20} 行（--json で全量）")


def main():
    p = argparse.ArgumentParser(description="Microsoft Clarity Data Export API（読み取り専用）")
    p.add_argument("--site", default="ycom")
    p.add_argument("--days", type=int, default=3)
    p.add_argument("--dim1")
    p.add_argument("--dim2")
    p.add_argument("--dim3")
    p.add_argument("--json", action="store_true")
    p.add_argument("--quota", action="store_true", help="当日の使用回数だけ表示（APIは呼ばない）")
    p.add_argument("--force", action="store_true", help="ローカルの日次上限ガードを無視（通常使わない）")
    args = p.parse_args()

    if not args.site.replace("-", "").isalnum():
        err(f"ERROR: 不正な site 名: {args.site!r}")
        sys.exit(2)
    if args.quota:
        print(f"{args.site}: 本日 {quota_used(args.site)}/{DAILY_LIMIT} 回使用")
        return
    if not 1 <= args.days <= 3:
        err("ERROR: --days は 1〜3（Clarity API の仕様上、直近3日まで）")
        sys.exit(2)
    dims = [d for d in (args.dim1, args.dim2, args.dim3) if d]
    for d in dims:
        if d not in VALID_DIMS:
            err(f"ERROR: 不正なディメンション: {d}（有効: {', '.join(sorted(VALID_DIMS))}）")
            sys.exit(2)

    data = fetch(args.site, args.days, dims, force=args.force)
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        summarize(data)
        print(f"\n（本日 {quota_used(args.site)}/{DAILY_LIMIT} 回使用・直近{args.days}日の集計）")


if __name__ == "__main__":
    main()
