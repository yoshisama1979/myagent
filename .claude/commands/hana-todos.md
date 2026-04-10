`bash bin/hana-api.sh todos $ARGUMENTS` を実行し、ToDo一覧を取得してください。

利用可能なオプション:
- `--user_id=N` — 特定ユーザーのToDoのみ（未指定時はデフォルトユーザー）
- `--work_id=N` — 特定案件のToDoのみ
- `--status=incomplete|completed|all` — ステータスで絞り込み

結果を以下の形式で見やすく整理して表示してください:
- タスク名、詳細
- 案件名（プロジェクト名）
- 次回作業日、納品日
- 完了/未完了の状態
