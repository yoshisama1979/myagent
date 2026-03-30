# /ai — AI活用推進部ルーター

このコマンドはAI活用・自動化関連のタスクを処理する。

## 担当エージェント
- **Ren**（`agents/ren-ai.md`）— AI戦略・実装

## 処理フロー

1. Agent toolでRenを起動する際、以下を含める:
   - `agents/ren-ai.md` の内容
   - `guidelines/company-overview.md`
   - `guidelines/output-standards.md`
   - `guidelines/security-policy.md`
   - `guidelines/tools-manual.md`
   - 具体的なタスク指示

## 対応タスク例
- AI導入の検討・提案
- プロンプト設計・最適化
- AI API連携の実装
- 業務自動化の設計・実装
- AIツールの比較・選定

## 連携が多いケース
- AI機能のシステム組み込み → Sota（システム開発部）と連携
- AI関連の技術調査 → Shun（リサーチ部）と連携
