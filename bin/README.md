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

# ToDo一覧（デフォルトユーザー）
bash bin/hana-api.sh todos

# ToDo一覧（フィルタ付き）
bash bin/hana-api.sh todos --user_id=34 --status=incomplete

# ToDo登録
bash bin/hana-api.sh create-todo '{"work_id":140,"user_id":34,"content":"タスク名"}'

# Chatwork通知
bash bin/hana-api.sh chatwork '{"room_id":"123","message":"メッセージ"}'
```

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
