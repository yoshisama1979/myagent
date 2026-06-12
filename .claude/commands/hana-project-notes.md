hana-tools のプロジェクトメモを取得・更新します。取得は読み取り専用、**更新は共有システムへの書き込み**。

## 取得（読み取り専用）

```
# 全体共有メモ（shared）のみ
bash bin/hana-api.sh notes <project_id>

# shared ＋ 指定ユーザーの個人メモ（mine）
bash bin/hana-api.sh notes <project_id> --user_id=N
```

レスポンス `data` は `shared` と `mine` を持つ。各メモは最新 `body`（HTML）＋ `current_version`。**該当メモが無ければ `404` ではなく `null`**。バージョン履歴は含まない（最新のみ）。

## 更新（upsert・書き込み）

### ⚠️ 書き込み前の合意（automation.md §3）

メモ更新は共有システムへの書き込み。**実行前に社長へ「対象プロジェクト・visibility・本文・実行コマンド」を提示して合意を得る**。特に `shared`（全員に見える全体共有メモ）への書き込みは影響が大きい。合意なしに自動実行しない。クライアント機密を不用意に書かない。

### パラメータ

| パラメータ | 必須 | 説明 |
|----------|------|------|
| `visibility` | 必須 | `shared`（全体共有）/ `private`（個人） |
| `user_id` | private 時必須 | 個人メモの所有ユーザー ID |
| `body` | 必須 | 本文（HTML）。サーバ側で**常にサニタイズ**（`<script>` / `on*` / `javascript:` 等は除去） |
| `edit_summary` | 任意 | 編集サマリ（最大255字・履歴に記録） |
| `expected_version` | 任意 | 楽観ロック。指定時のみ `current_version` と照合し、不一致なら `409`。省略時は最新へ追記 |
| `edited_by_user_id` | 任意 | 履歴に記録する編集者 ID |

- 1 プロジェクトにつき shared 1件＋ユーザー別 private 1件。**2回目以降の同一種別 POST は更新**になる（新規=`201` / 更新=`200`）。
- 安全に上書き競合を防ぐなら：先に `notes` で取得 → `current_version` を確認 → `expected_version` を付けて更新。

### 実行コマンド

```
# 共有メモを追加/更新
bash bin/hana-api.sh update-note <project_id> '{"visibility":"shared","body":"<p>運用メモ</p>"}'

# 個人メモ（user_id 必須）
bash bin/hana-api.sh update-note <project_id> '{"visibility":"private","user_id":7,"body":"<p>個人メモ</p>"}'

# 楽観ロック付き（取得した current_version を渡す）
bash bin/hana-api.sh update-note <project_id> '{"visibility":"shared","body":"<p>...</p>","expected_version":2,"edit_summary":"運用手順を追記"}'
```

## エラー時

- `404`：存在しない `project_id`
- `409`：バージョン競合（`expected_version` ≠ 現在の `current_version`）→ `notes` で最新を読み直してから再更新
- `422`：必須不足・不正 visibility 等 → `errors` をそのまま提示
- `401`：認証失敗 → `.env` のトークン確認

## 関連

- プロジェクト特定：`/hana-projects`／ToDo：`/hana-todos`・`/hana-update-todo`
- 進行管理（task-partner）の補足記録は本来 `site/clients/.../` だが、hana-tools 側に集約したい補足はこのメモへ。
