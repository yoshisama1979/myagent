# hana-tools APIラッパー

## 概要

hana-tools外部APIをClaude Codeから安全に呼び出すためのラッパースクリプトです。
APIトークンは`.env`で管理し、スクリプト経由で呼び出すことでトークンが会話に露出しません。

## セットアップ

1. `.env.example`をコピーして`.env`を作成
2. `.env`にAPIトークンを設定

## コマンド一覧

```bash
# クライアント全件取得
bash bin/hana-api.sh clients

# クライアント検索（部分一致、カンマ区切りでOR検索可）
bash bin/hana-api.sh search "キーワード"

# 外注先一覧
bash bin/hana-api.sh outsources

# ToDo一覧（フィルタ未指定時は assignee_user_id=デフォルトユーザー）
bash bin/hana-api.sh todos

# ToDo一覧（作成者フィルタ）
bash bin/hana-api.sh todos --user_id=34 --status=incomplete

# ToDo一覧（担当者フィルタ：null=自分が担当の正規化済みデータも含む）
bash bin/hana-api.sh todos --assignee_user_id=34 --status=incomplete

# ToDo一覧（案件フィルタ）
bash bin/hana-api.sh todos --work_id=140

# ToDo登録（assignee_user_id 省略 = 作成者が担当）
bash bin/hana-api.sh create-todo '{"work_id":140,"user_id":34,"content":"タスク名"}'

# ToDo登録（別人を担当者にアサイン）
bash bin/hana-api.sh create-todo '{"work_id":140,"user_id":34,"assignee_user_id":51,"content":"タスク名"}'

# Chatwork通知
bash bin/hana-api.sh chatwork '{"room_id":"123","message":"メッセージ"}'
```

## ToDo API のポイント

### `assignee_user_id` の正規化規則

- 登録時に `assignee_user_id == user_id` または `assignee_user_id` 未指定 → サーバ側で `null` に正規化保存
- `null` は「作成者が担当」を意味する
- フィルタ `--assignee_user_id=N` は `assignee_user_id = N` OR `(assignee_user_id IS NULL AND user_id = N)` で取得するため、null 正規化済みデータも取りこぼさない

### user_id と assignee_user_id の使い分け

| 観点 | `--user_id=N` | `--assignee_user_id=N` |
|------|--------------|---------------------|
| 意味 | 作成者（依頼者）でフィルタ | 実質担当者でフィルタ |
| null 正規化対応 | しない | する |
| 「自分のToDo」用途 | 自分が依頼したものだけ | **自分が担当するもの全て**（推奨） |

## Windows環境での注意事項

### 日本語を含むPOSTリクエスト

curlの`-d`オプションに日本語JSONを直接渡すとエンコーディングが壊れる。
stdin経由（`echo "$json" | curl ... -d @-`）で渡すこと。

```bash
# NG: -d に直接渡す（日本語が壊れる）
curl -d "$json" ...

# OK: stdin経由で渡す
echo "$json" | curl -d @- ...
```

### 日本語を含むGETパラメータ

curlの`--data-urlencode`がWindows bashで正しく動作しない場合がある。
PHPの`rawurlencode()`でエンコードしてからURLに埋め込むこと。

```bash
# NG: --data-urlencode（環境依存で失敗する）
curl -G --data-urlencode "q=$keyword" ...

# OK: PHPでエンコード
local encoded=$(php -r "echo rawurlencode('$keyword');")
curl "$BASE_URL/api/endpoint?q=$encoded" ...
```
