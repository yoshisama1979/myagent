# 財務データ保管ルール

経営判断のための財務データを置く場所。**`.gitignore` で除外しているため、コミットされない。**

## 配置

```
data/financial/
└── YYYY-MM/                          # マネーフォワードのエクスポート月
    ├── pl-monthly.csv                # 月次推移表（PL）
    ├── ledger-by-client.csv          # 補助元帳（取引先別）
    └── trial-balance.csv             # 試算表（BS）
```

## マネーフォワードからのエクスポート手順

1. マネーフォワード クラウド会計にログイン
2. レポート → 該当のレポートを開く
3. 「CSV出力」または「エクスポート」をクリック
4. 出力されたCSVを `data/financial/YYYY-MM/` に配置

## 取得対象（優先度順）

| # | CSV種類 | 主な用途 | 頻度 |
|---|--------|--------|------|
| 1 | 月次推移表（PL） | 売上・経費・粗利・営業利益の推移 | 月次 |
| 2 | 補助元帳（取引先別） | クライアント別売上 | 月次 or 四半期 |
| 3 | 試算表（BS） | キャッシュ残高・売掛金 | 月次 |

## セキュリティ

- 生データは **コミットしない**（.gitignore で除外済み）
- 集計結果は `business/reviews/YYYY-MM.html` や `business/kpi.html` に **数値のみ** 記載してOK
- 個別取引明細・取引先名の詳細は集計結果からは除外する（数値のみで議論）

## 分析の流れ

1. 社長が月初にマネーフォワードから CSV をエクスポート → 本ディレクトリに配置
2. AI（私）が Bash + Python でCSVを読み込み・集計
3. 結果を `business/reviews/YYYY-MM.html` の「2. KPI 実績」セクションに記入
4. KPI トレンドを `business/kpi.html` に蓄積（将来的）

## 関連

- 経営ダッシュボード理想形: `business/kpi.html`
- 月次レビュー: `business/reviews/`
- HANAツール backlog（スプレッドシートAPI連携、HANAツール経営ダッシュボード機能等の開発タスク）: `clients/hanasaka/projects/hana-tool/backlog.html`
