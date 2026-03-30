# /admin — 経営管理部ルーター

このコマンドは経理・労務・契約関連のタスクを処理する。

## 担当エージェント
- **Kento**（`agents/kento-admin.md`）— 経理・労務・契約

## 処理フロー

1. Agent toolでKentoを起動する際、以下を含める:
   - `agents/kento-admin.md` の内容
   - `guidelines/company-overview.md`
   - `guidelines/output-standards.md`
   - `guidelines/escalation-rules.md`
   - `guidelines/security-policy.md`
   - 該当テンプレート（経費チェックリスト等）
   - 具体的なタスク指示

## 対応タスク例
- 経費確認・チェック（テンプレート: `templates/expense-checklist.md`）
- 請求書の確認
- 見積書の原価チェック
- 契約書のレビュー
- 月次数値の整理

## 注意事項
- 金額の最終決定は必ず社長にエスカレーション
- 税務・法務の専門判断が必要な場合も社長にエスカレーション
