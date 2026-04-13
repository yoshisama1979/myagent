hana-toolsにToDoを登録します。

## 案件ID（work_id）の特定手順

ユーザーがクライアント名や案件名を自然言語で指定した場合、以下の手順で work_id を特定してください:

1. **まず `data/clients-cache.json` を確認**し、キーワードに該当するクライアント・プロジェクト・案件を探す
2. キャッシュにない場合のみ `bash bin/hana-api.sh search "クライアント名のキーワード"` でAPI呼び出し
3. API取得後はキャッシュを更新（既存client_idは上書き、新規は追加、updated_atを更新）
4. 結果からユーザーの意図に最も近い案件を特定
5. 候補が複数ある場合はユーザーに確認する

## 登録パラメータ

- `work_id`（必須）— 案件ID。上記手順で特定する
- `user_id`（必須）— 担当ユーザーID。未指定の場合は .env の HANA_TOOLS_DEFAULT_USER_ID を使用する
- `content`（必須）— タスク名
- `description`（任意）— 詳細
- `next_work_date`（任意）— 次回作業日（YYYY-MM-DD）
- `due_date`（任意）— 納品日（YYYY-MM-DD）

## 登録前の確認

特定した案件名・タスク内容をユーザーに提示し、確認を得てから登録してください。

確認後、以下の形式で実行:
```
bash bin/hana-api.sh create-todo '{"work_id":N,"user_id":N,"content":"タスク名","description":"詳細","next_work_date":"YYYY-MM-DD","due_date":"YYYY-MM-DD"}'
```

登録結果を表示してください。
