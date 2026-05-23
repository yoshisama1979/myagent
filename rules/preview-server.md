# プレビューサーバ運用ルール

Claude Code が生成した HTML をブラウザで確認するためのプレビュー環境の構成と運用ルール。

## 構成概要

```
[Claude Code]
  ↓ HTMLファイルを生成
/home/vpsuser/projects/myagent/preview/
  ↓ Nginx（Tailscale IPのみ待ち受け）
http://100.123.104.87/[ディレクトリ]/xxx.html
  ↑
🔒 Tailscale ON のデバイスのみアクセス可
```

- **VPS**: x210-131-217-220（Ubuntu）
- **Tailscale IP**: `100.123.104.87`
- **公開IP**: 公開アクセスは現状なし（将来クライアント共有時に使用）
- **Webサーバ**: Nginx
- **ドキュメントルート**: `/home/vpsuser/projects/myagent/preview/`

## ディレクトリ構成と公開範囲

| ディレクトリ | 公開範囲 | 用途 | URL（現状） |
|------------|---------|------|-----------|
| `preview/private/` | Tailscale経由のみ | 自分・社内スタッフの作業用（社内ドラフト・検証・草案） | `http://100.123.104.87/private/xxx.html` |
| `preview/client/` | 将来：Basic認証 + 公開IP | クライアントレビュー用（提案書・LP案・モック） | 現状は Tailscale のみ |
| `preview/public/` | 将来：公開 | 誰でも閲覧可（公開LP・ポートフォリオ） | 現状は Tailscale のみ |

### Claude が HTML を生成する際の判断基準

| 状況 | 出力先 |
|------|--------|
| 社長個人の確認用、社内議論用、ドラフト | `preview/private/` |
| クライアントに見せる前提のもの（提案書、LP案、モックアップ） | `preview/client/` |
| 公開LP・公開ポートフォリオ・OPメッセージ等 | `preview/public/` |
| 用途が不明な場合 | 確認してから決める |

ファイル名は内容がわかる英数字＋ハイフン推奨（例：`lp-yamada-corp-v1.html`、`proposal-abc-202605.html`）。

## アクセス方法

### 自分が見るとき
1. Tailscale が ON になっていることを確認（タスクトレイ／メニューバー）
2. ブラウザで `http://100.123.104.87/` にアクセス
3. ディレクトリ一覧から目的のファイルへ

### 会社スタッフを追加するとき（フェーズ2）
1. Tailscale管理画面の「Users」→「Invite users」でメール招待
2. スタッフがアカウント作成 → 各デバイスにTailscaleインストール → ログイン
3. 完了後、同じURLでアクセス可
4. 料金：複数ユーザーで使う場合は Personal Plus / Starter プランへの移行が必要

### クライアントに見せるとき（フェーズ3・未実装）
**前提条件**：
- 独自ドメイン取得（例：`preview.hanasaka.co.jp`）
- Let's Encrypt で HTTPS化（Basic認証はHTTPだとパスワード漏洩のため必須）

**実装内容**：
- Nginx に公開IP用の server ブロックを追加
- `/client/` ロケーションに Basic認証（`.htpasswd`）を設定
- `/private/` 配下は public IP からアクセス不可になるよう deny 設定
- クライアントには `https://preview.hanasaka.co.jp/client/proposal.html` + ID/PW を共有

## セキュリティ設計

### Nginx 設定の要点
- `listen 100.123.104.87:80` で Tailscale IP のみ待ち受け（公開IP では一切待ち受けない）
- 公開IP（210.131.217.220）からの HTTP アクセスは TCP レベルで届かない

### 権限設定
- `/home/vpsuser` は `drwxr-x--x`（others に traverse のみ、list は不可）
- `preview/` 配下は `drwxrwxr-x`（Nginx が読める）
- このVPSは単一ユーザー（vpsuser）のため、`o+x` でも実害なし
- 将来複数ユーザーを作成する場合は ACL 方式（`setfacl -m u:www-data:x`）への移行を検討

### Tailscale の利点
- 各デバイスに固定の Tailscale IP（100.x.x.x）が割り当てられる
- 実IP（ISP/キャリアの動的IP）が変わってもアクセス継続
- NAT越えを Tailscale が自動処理（ポート開放・ルーター設定不要）

## 運用上の注意

1. **`preview/` 配下のファイルは原則 Git 管理する**
   - 社内ドラフト・社則・提案書なども含めて、Git 履歴に残せる内容に留める
   - パスワード・APIキー・個人情報・クライアントの非公開資料など、**Git に乗せたくない情報は preview/ に置かない**（別途 `.env` や Git管理外のディレクトリに置く）
2. **`preview/public/` は将来インターネット公開される前提**
   - 機密性のある内容は置かない
3. **Tailscale のログイン状態を定期的に確認**
   - スマホアプリは OFF になっていることがある
4. **VPS の Nginx ログ**: `/var/log/nginx/myagent-preview.access.log` / `.error.log`

## トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| ブラウザがタイムアウト | Tailscale OFF | デバイスの Tailscale を ON にする |
| 403 Forbidden | パーミッション不足 | `/home/vpsuser` の `o+x` を確認 |
| 404 Not Found | パス間違い／ファイル未配置 | ディレクトリ一覧（`/`）で確認 |
| Nginx 起動失敗 | 設定文法ミス | `sudo nginx -t` で確認 |

## 関連ファイル

- Nginx設定: `/etc/nginx/sites-available/myagent-preview`
- ドキュメントルート: `/home/vpsuser/projects/myagent/preview/`
- アクセスログ: `/var/log/nginx/myagent-preview.access.log`
- エラーログ: `/var/log/nginx/myagent-preview.error.log`
