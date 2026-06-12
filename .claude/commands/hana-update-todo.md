hana-tools の既存 ToDo を編集します（**共有システムへの書き込み**）。

## ⚠️ 書き込み前の合意（automation.md §3）

ToDo 編集は共有システムへの書き込み。**実行前に必ず社長へ「対象 ToDo・変更内容・実行コマンド」を提示して合意を得る**。特に完了化（`completed_at`）・担当変更（`assignee_user_id`）は影響が大きいので確認必須。合意なしに自動実行しない。

## 対象 ToDo の特定

1. 編集したい ToDo を `bash bin/hana-api.sh todos [--work_id=N など]` で取得し、`id` を確定する。
2. 現在値（content / due_date / completed_at / assignee_user_id 等）を把握してから差分だけ送る。

## 編集パラメータ（送ったフィールドのみ部分更新）

| パラメータ | 説明 |
|----------|------|
| `content` | タスク名（指定する場合は空文字不可） |
| `description` | 内容詳細 |
| `next_work_date` | 次回作業日（`YYYY-MM-DD`） |
| `due_date` | 納品日（`YYYY-MM-DD`） |
| `completed_at` | 完了日時（日付で完了、`null` で未完了に戻す） |
| `assignee_user_id` | 担当者。**対象 ToDo の作成者**と同値 or 未指定なら `null`（=作成者が担当）に正規化される |

- **`work_id`（案件移動）は変更できない**。
- 送っていないフィールドは保持される（部分更新）。

## 実行コマンド

```
# タスク名と完了日時を更新
bash bin/hana-api.sh update-todo <todo_id> '{"content":"確認済みに更新","completed_at":"2026-05-10"}'

# 完了を取り消す（未完了に戻す）
bash bin/hana-api.sh update-todo <todo_id> '{"completed_at":null}'

# 期日変更
bash bin/hana-api.sh update-todo <todo_id> '{"due_date":"2026-06-30"}'
```

## レスポンスの確認

- 成功時は `200 OK` と更新後の ToDo（`create-todo` と同じカラム構成）が返る。
- 意図したフィールドだけが変わったか・`assignee_user_id` の正規化結果を確認する。

## エラー時

- `404`：存在しない `id` → ToDo 一覧で id を再確認
- `422`：不正な値（空 content・不正日付・存在しない assignee 等）→ `errors` をそのまま提示
- `401`：認証失敗 → `.env` のトークン確認

## 関連

- 取得：`/hana-todos`（[[hana-todo-api]]）／登録：`/hana-create-todo`
- 進行管理（task-partner）では ToDo が一次情報。編集は「実行案→合意→実行」を挟む。
