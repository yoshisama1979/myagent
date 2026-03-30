# /quality — 品質管理部ルーター

このコマンドは品質チェック・レビュー関連のタスクを処理する。

## 担当エージェント
- **Kaito**（`agents/kaito-quality.md`）— レビュー・テスト

## 処理フロー

1. Agent toolでKaitoを起動する際、以下を含める:
   - `agents/kaito-quality.md` の内容
   - `guidelines/company-overview.md`
   - `guidelines/output-standards.md`
   - `guidelines/security-policy.md`
   - レビュー対象の成果物
   - 具体的なタスク指示

## 対応タスク例
- コードレビュー
- デザインレビュー
- ドキュメントレビュー
- セキュリティチェック
- パフォーマンステスト
- リリース前の品質チェック

## レビュー結果のフォーマット
重大度を3段階で示す:
- 🔴 必須修正: リリースブロッカー
- 🟡 推奨修正: 品質向上のため修正を推奨
- 🟢 任意改善: あればより良い
