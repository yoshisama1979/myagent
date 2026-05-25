hana-tools にToDoを登録します。

## 案件ID（work_id）の特定手順

ユーザーがクライアント名や案件名を自然言語で指定した場合、以下の手順で work_id を特定してください:

1. **まず `data/clients-cache.json` を確認**し、キーワードに該当するクライアント・プロジェクト・案件を探す
2. キャッシュにない場合のみ `bash bin/hana-api.sh search "クライアント名のキーワード"` でAPI呼び出し
3. API取得後はキャッシュを更新（既存client_idは上書き、新規は追加、updated_atを更新）
4. 結果からユーザーの意図に最も近い案件を特定
5. 候補が複数ある場合はユーザーに確認する

## 登録パラメータ

| パラメータ | 必須 | 説明 |
|----------|------|------|
| `work_id` | 必須 | 案件ID（上記手順で特定） |
| `user_id` | 必須 | 登録対象ユーザーID（= **依頼者・作成者**）。未指定時は `.env` の `HANA_TOOLS_DEFAULT_USER_ID` を使用 |
| `assignee_user_id` | 任意 | **担当者**ユーザーID。**`user_id` と同じ値 or 未指定 の場合はサーバ側で `null` に正規化保存される**（=作成者が担当） |
| `content` | 必須 | タスク名 |
| `description` | 任意 | 詳細 |
| `next_work_date` | 任意 | 次回作業日（`YYYY-MM-DD`） |
| `due_date` | 任意 | 納品日（`YYYY-MM-DD`） |

## 担当者の決め方

- ユーザーが「自分のToDo」「私のToDo」として登録 → `assignee_user_id` 省略（=作成者が担当）
- ユーザーが「Aさんにお願いしたい」と指定 → `assignee_user_id` に A さんのIDを設定
- 「ABCの件を私がやる」など作成者と担当者が同一 → `assignee_user_id` 省略（明示しない方が正規化に乗る）

## 登録前の確認

特定した **案件名 / タスク内容 / 担当者** をユーザーに提示し、確認を得てから登録してください。
特に **担当者が作成者と異なる場合**は必ず確認する（誤ったアサインのリスクが高いため）。

## 実行コマンド

```
bash bin/hana-api.sh create-todo '{"work_id":N,"user_id":N,"content":"タスク名","description":"詳細","next_work_date":"YYYY-MM-DD","due_date":"YYYY-MM-DD"}'
```

担当者を別人に振る場合:
```
bash bin/hana-api.sh create-todo '{"work_id":N,"user_id":1,"assignee_user_id":2,"content":"タスク名"}'
```

## レスポンスの確認

成功時は `201 Created` と作成されたToDoが返る。**`assignee_user_id` の値**を確認：
- 期待通り（指定したIDまたは null）であることを確認
- 想定外なら正規化規則に該当している可能性を疑う

## エラー時

- `422` ：バリデーションエラー（必須パラメータ不足、不正な ID 等）→ `errors` フィールドをそのまま表示
- `401` ：認証失敗 → `.env` のトークン確認を促す
