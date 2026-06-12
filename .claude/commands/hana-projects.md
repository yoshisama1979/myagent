hana-tools からプロジェクト情報を取得します（読み取り専用）。

## 用途

- プロジェクト一覧、または特定プロジェクトの詳細（紐づくクライアント・案件 works を含む）を取得する。
- `work_id` の特定、案件の全体像把握、`site_url` / `gsc_dataset` の確認に使う。

## 実行コマンド

```
# 一覧（全プロジェクト）
bash bin/hana-api.sh projects

# 特定クライアントのプロジェクトのみ
bash bin/hana-api.sh projects --client_id=N

# 詳細（単一プロジェクト）
bash bin/hana-api.sh project <project_id>
```

## レスポンス構造（フルフィールド）

各プロジェクトは以下を含む：

| フィールド | 説明 |
|-----------|------|
| `id` / `project_name` / `client_id` | プロジェクト基本情報 |
| `site_url` | プロジェクト共通の URL（旧 `gsc_site_url` をリネーム。**Search Console プロパティも兼ねる**）。`gsc_site_url` というフィールドは存在しない |
| `gsc_dataset` | GSC 一括エクスポートの BigQuery データセット名。**`bin/gsc-fetch.py --dataset <値>` にそのまま渡せる**（[[gsc-bigquery]] と連携） |
| `document_url` / `note` | 資料 URL・プロジェクトメモ（短文） |
| `client` | `{ id, client_name }` |
| `works` | 案件配列 `[{ id, name }]`。ここの `id` が ToDo の `work_id` |

## 使いどころ

- **work_id を知りたい**：`project <id>` の `works[].id`、または `projects --client_id=N`。
- **GSC 分析につなぐ**：`gsc_dataset` が入っているプロジェクトは、その値を `bin/.venv/bin/python bin/gsc-fetch.py overview --dataset <gsc_dataset>` に渡せば、そのサイトの検索データを取得できる。
- **進行管理（task-partner）**：一次情報は ToDo（`hana-api.sh todos`）。projects は案件の構造把握・補助に使う。

## エラー時

- `404`：存在しない `project_id` を指定 → ID を確認
- `422`：不正な `client_id`（exists 検証）
- `401`：認証失敗 → `.env` の `HANA_TOOLS_API_TOKEN` を確認

## 出力フォーマット

依頼に応じて、プロジェクト名・クライアント・works（案件名と id）・site_url/gsc_dataset を表で見やすく整理して提示する。一覧が長い場合は依頼の意図に絞る（全149件の生 JSON をそのまま貼らない）。
