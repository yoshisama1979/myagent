# /sales — 営業・顧客対応部ルーター

このコマンドは営業・提案・顧客対応関連のタスクを処理する。

## 担当エージェント
- **Aoi**（`agents/aoi-sales.md`）— 営業・提案

## 処理フロー

1. Agent toolでAoiを起動する際、以下を含める:
   - `agents/aoi-sales.md` の内容
   - `guidelines/company-overview.md`
   - `guidelines/brand-guidelines.md`
   - `guidelines/output-standards.md`
   - `guidelines/reporting-standards.md`
   - 該当テンプレート（提案書・見積書等）
   - 具体的なタスク指示

## 対応タスク例
- 提案書作成（テンプレート: `templates/proposal.md`）
- 見積書作成（テンプレート: `templates/estimate.md`）
- 顧客ヒアリング項目の設計
- 商談準備・シナリオ設計
- 契約書のドラフト作成

## 見積作成時
技術的な工数見積もりが必要な場合:
- Sota/Riku（開発部門）に工数確認を並列で依頼
- Kento（経営管理部）に原価確認を依頼
