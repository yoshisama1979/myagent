# /sysdev — システム開発部ルーター

このコマンドはシステム開発関連のタスクを処理する。

## 担当エージェント
- **Sota**（`agents/sota-sysdev.md`）— リードエンジニア（設計・アーキテクチャ）
- **Mei**（`agents/mei-sysdev.md`）— 実装・テスト

## 処理フロー

1. 設計フェーズ → Sotaが設計、成果物をファイル出力
2. 実装フェーズ → Meiが設計書を読んで実装
3. 小規模タスクはSotaが設計と実装を兼務してもよい
4. Agent toolで起動する際、以下を含める:
   - 該当エージェントの.mdファイル
   - `guidelines/company-overview.md`
   - `guidelines/output-standards.md`
   - `guidelines/security-policy.md`
   - 具体的なタスク指示

## 対応タスク例
- システム設計・アーキテクチャ
- API開発
- データベース設計
- バックエンド実装
- テスト作成・実行

## レビューフロー
- Sotaの設計 → Kaitoがレビュー
- Meiの実装 → SotaまたはKaitoがレビュー
