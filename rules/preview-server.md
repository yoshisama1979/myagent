# プレビューサーバ運用ルール

VPS上のNginxとTailscaleを使った、社内専用のブラウザ閲覧環境の構成と運用ルール。

## 構成概要

```
[プロジェクトルート]
/home/vpsuser/projects/myagent/
├── site/          ← Nginxのドキュメントルート（公開対象）
└── rules/, bin/, data/, CLAUDE.md, ... ← 公開しない

[Nginx]
listen 100.123.104.87:80
↑ Tailscale IPのみ待ち受け（公開IPからは到達不可）

[ブラウザ]
http://100.123.104.87/<相対パス>
↑ Tailscale ONのデバイスのみアクセス可
```

- **VPS**: x210-131-217-220（Ubuntu）
- **Tailscale IP**: `100.123.104.87`
- **Webサーバ**: Nginx
- **ドキュメントルート**: `/home/vpsuser/projects/myagent/site/`

## ディレクトリ構成

| パス | 用途 |
|------|------|
| `site/index.html` | サイトトップ（全プロジェクトへの入口） |
| `site/notes.html` | プロジェクト横断メモ |
| `site/business/` | 経営トラッカー（戦略・KPI・レビュー・スキルシート） |
| `site/clients/` | クライアント・プロジェクトの記録（[memo.md](memo.md) 準拠） |
| `site/docs/` | 一般ドキュメント |
| `site/skill-sheets/` | スキルシート関連の素材 |
| `site/drafts/` | 草案・LP案・モック・検証用HTML |

### site/ 配下に置かないもの

- `CLAUDE.md`, `rules/`：AI協働用ルール（AI内部参照）
- `bin/`：開発用スクリプト
- `data/`：データソース（一部機密、`.gitignore` 対象）
- `.env`、`.git/`：機密・Git内部
- → これらは **Nginxの公開対象外** なのでブラウザでは見えない

## アクセス方法

### 自分・社内スタッフが見るとき
1. Tailscale が ON になっていることを確認
2. ブラウザで `http://100.123.104.87/` にアクセス
3. サイトトップから目的のページへ

### URL例

```
http://100.123.104.87/                                              ← トップ
http://100.123.104.87/business/kpi.html                             ← 経営KPI
http://100.123.104.87/notes.html                                    ← 横断メモ
http://100.123.104.87/clients/hanasaka/projects/hana-tool/backlog.html ← プロジェクト課題
http://100.123.104.87/drafts/                                       ← 草案一覧
```

## クライアント共有の運用方針

**「ファイルは動かさない、URLは固定、Nginx設定で公開可否を切り替える」** が基本方針。

### フェーズ1：自分でドラフト作成
- `site/drafts/<案件名>/` 配下に作成（例：`site/drafts/yamada-corp/lp.html`）
- アクセス：Tailscale経由のみ

### フェーズ2：クライアントレビュー（Basic認証付き公開）

**前提条件**：
- 独自ドメイン取得（例：`preview.hanasaka.co.jp`）
- Let's Encrypt で HTTPS化（HTTP上のBasic認証はパスワード平文流出のため必須）

**Nginx設定例（追加するserverブロック）**：
```nginx
server {
    listen 公開IP:443 ssl;
    server_name preview.hanasaka.co.jp;

    # 既定はすべて遮断
    location / { return 403; }

    # 特定の案件ディレクトリのみ Basic認証で公開
    location /drafts/yamada-corp/ {
        root /home/vpsuser/projects/myagent/site;
        auth_basic "山田商事レビュー";
        auth_basic_user_file /etc/nginx/yamada.htpasswd;
    }
}
```

**運用フロー**：
1. クライアントに `https://preview.hanasaka.co.jp/drafts/yamada-corp/lp.html` + ID/PW を共有
2. 修正は元ファイルを更新するだけ（コピーは作らない）
3. レビュー終了 → Nginxのlocationブロックを削除して閉鎖

### フェーズ3：完全公開（公開LP・公開ポートフォリオ）
- 認証を外したlocationブロックで公開
- 公開対象は機密性のないものに限定

## セキュリティ設計

### Nginx 設定の要点
- `listen 100.123.104.87:80` で Tailscale IP のみ待ち受け（公開IP では一切待ち受けない）
- 公開IPからのHTTPアクセスはTCPレベルで届かない

### 権限設定
- `/home/vpsuser` は `drwxr-x--x`（others に traverse のみ、list は不可）
- `site/` 配下は `drwxrwxr-x`（Nginxが読める）
- このVPSは単一ユーザー（vpsuser）のため、`o+x` でも実害なし
- 将来複数ユーザーを作成する場合は ACL 方式（`setfacl -m u:www-data:x`）への移行を検討

### Tailscale の利点
- 各デバイスに固定の Tailscale IP（100.x.x.x）が割り当てられる
- 実IP（ISP/キャリアの動的IP）が変わってもアクセス継続
- NAT越えを Tailscale が自動処理（ポート開放・ルーター設定不要）

## 運用上の注意

1. **`site/` 配下のファイルは原則 Git 管理する**
   - 社内ドラフト・社則・提案書なども含めて、Git履歴に残せる内容に留める
   - パスワード・APIキー・個人情報など、**Git に乗せたくない情報は `site/` に置かない**（別途 `.env` や Git管理外のディレクトリに置く）
2. **公開対象を増やしたい場合は、まず `site/` 配下に置く**
   - `site/` 外に置いたファイルはNginxから見えない（CLAUDE.mdやrules/などは意図的に外している）
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
- ドキュメントルート: `/home/vpsuser/projects/myagent/site/`
- アクセスログ: `/var/log/nginx/myagent-preview.access.log`
- エラーログ: `/var/log/nginx/myagent-preview.error.log`
