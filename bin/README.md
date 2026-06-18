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

# ToDo編集（部分更新。work_id変更不可。completed_at で完了/未完了）
bash bin/hana-api.sh update-todo 5 '{"content":"確認済み","completed_at":"2026-05-10"}'

# プロジェクト一覧（client/works・site_url・gsc_dataset 含む）
bash bin/hana-api.sh projects
bash bin/hana-api.sh projects --client_id=5

# プロジェクト詳細
bash bin/hana-api.sh project 130

# プロジェクトメモ取得（shared ＋ user_id 指定で mine）
bash bin/hana-api.sh notes 130 --user_id=34

# プロジェクトメモ追加・更新（upsert。visibility=shared|private）
bash bin/hana-api.sh update-note 130 '{"visibility":"shared","body":"<p>運用メモ</p>"}'

# Chatwork通知
bash bin/hana-api.sh chatwork '{"room_id":"123","message":"メッセージ"}'
```

> **書き込み系（create-todo / update-todo / update-note / chatwork）は共有システムへの書き込み・外部送信**。社長合意の上で実行する（[rules/automation.md](../rules/automation.md) §3）。`gsc_dataset` は `bin/gsc-fetch.py --dataset` にそのまま渡せる。
>
> スキル（スラッシュコマンド）：`/hana-clients` `/hana-todos` `/hana-create-todo` `/hana-update-todo` `/hana-projects` `/hana-project-notes` `/hana-outsources` `/hana-chatwork`

## Slack 通知（bin/slack.sh）

Slack Incoming Webhook へメッセージを送る独立スクリプト（`.env` の `SLACK_WEBHOOK_URL` を使用）。
定期通知の送信土台。安全に作る・回す際の作法は [rules/automation.md](../rules/automation.md) を参照。

```bash
# 単純なメッセージ
bash bin/slack.sh "メッセージ"

# チェック処理の出力をそのまま送る（標準入力）
some-check | bash bin/slack.sh

# 装飾付き（生JSON：blocks 等）
bash bin/slack.sh --raw '{"text":"...","blocks":[...]}'
```

## オンページSEO監査（bin/hp-audit.sh）

ホームページのオンページSEO信号を**読み取り専用**で監査する独立スクリプト（HTTP GETのみ・外部送信なし）。
`/hp-loop`（HP分析ループ）の一次情報用。作成履歴は [data/hp-loop/tools-log.md](../data/hp-loop/tools-log.md) の T-001。

```bash
# 人が読む要約（末尾に課題を ⚠️ で列挙）
bash bin/hp-audit.sh https://example.com/

# JSON出力（サイクル比較・機械処理用）
bash bin/hp-audit.sh https://example.com/ --json
```

取得：title/description（文字数）・canonical・robots・viewport（ズーム禁止検出）・OGP/Twitter（**プレースホルダ検出**）・JSON-LD（型・無効化検出）・見出しh1-h3（h1複数検出）・img/alt欠落・問い合わせ動線・CMS。

## 拠点横断メールボックス（bin/mailbox.sh）

別マシン（事務所・自宅・VPS）にいるエージェント同士が、Tailscale 経由で非同期にメッセージをやり取りする共有受信箱のクライアント。
VPS の API（`site/tools/mailbox/`）を叩く。`.env` の `MAILBOX_URL` / `MAILBOX_TOKEN` を必要キーだけ抽出して使う（トークンは画面・ログに出さない）。
規約・メッセージ書式・`needs_approval`ポリシーは [.claude/rules/mailbox.md](../.claude/rules/mailbox.md)。

```bash
# 自分宛の未読(new/)を取得
bash bin/mailbox.sh inbox

# メッセージ投函（本文は引数末尾 or 標準入力。外部送信/本番改変/書込を促すものは --needs-approval）
echo "本文" | bash bin/mailbox.sh send --to yoshida-dev --subject "件名" --thread t1

# 自分宛メッセージを処理済み(cur/)へ移動
bash bin/mailbox.sh done <id>
```

> スライス2まで実装（inbox / send / done）。`approve`（hold/ の社長承認）はスライス3で社長用ブラウザビューと併せて実装。

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
