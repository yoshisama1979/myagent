`bash bin/hana-api.sh todos $ARGUMENTS` を実行し、ToDo一覧を取得してください。

## 利用可能なオプション

| オプション | 意味 |
|----------|------|
| `--user_id=N` | **作成者**（依頼者）でフィルタ |
| `--assignee_user_id=N` | **実質担当者**でフィルタ。サーバ側は `assignee_user_id = N` OR `(assignee_user_id IS NULL AND user_id = N)` で取得するので、null 正規化済みの「作成者が担当」ToDoも含まれる |
| `--work_id=N` | 特定案件のToDoのみ |
| `--status=incomplete\|completed\|all` | ステータスで絞り込み（デフォルト `all`） |

**フィルタ未指定時**は `.env` の `HANA_TOOLS_DEFAULT_USER_ID` が `assignee_user_id` に自動適用される（自分のToDoを取りに行く挙動）。

## 「自分のToDo」を取りたいときの使い方

「自分のToDo」「私のToDo」「ユーザーIDXのToDo」のような依頼では、原則 **`--assignee_user_id=N`** を使う（作成者≠担当者のケースもカバーできるため）。
明示的に「作成者がX」と指定された場合のみ `--user_id=N`。

## レスポンス構造

各ToDoは以下のネストデータを含む（eager-load 済み）：
- `user` — 作成者（id, name, email）
- `assignee` — 担当者（null = 「作成者が担当」を意味する）
- `work.project.client.company` — 案件 → プロジェクト → クライアント → 会社の階層

## 出力フォーマット

結果を以下の形式で見やすく整理して表示してください：

- **タスク名**（content）
- 詳細（description、あれば）
- **案件**：`work.project.project_name`（`work.project.client.company.company_name`）
- 担当：`assignee.name`（null の場合は `user.name`（作成者兼任）と表示）
- 期日：`next_work_date` / `due_date`
- 状態：`completed_at` が null なら未完了、それ以外は完了

## エラー時

- `422` ：パラメータ不正（不正な ID、`status` が許可値以外 等）→ エラー内容をそのまま表示
- `401` ：認証失敗 → `.env` のトークン確認を促す
