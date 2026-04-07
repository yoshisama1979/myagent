# /project — プロジェクト管理部ルーター

このコマンドはクライアント案件の管理・進捗確認・案件立ち上げ関連のタスクを処理する。

## 担当エージェント
- **Tsubasa**（`agents/tsubasa-pm.md`）— プロジェクトマネージャー

## 処理フロー

1. Agent toolでTsubasaを起動する際、以下を含める:
   - `agents/tsubasa-pm.md` の内容
   - `guidelines/project-management.md`
   - `guidelines/output-standards.md`
   - `guidelines/reporting-standards.md`
   - `guidelines/collaboration-protocol.md`
   - 関連するクライアント情報（`clients/{クライアント名}.md` があれば）
   - 関連する案件情報（`projects/{案件名}.md` があれば）
   - 具体的なタスク指示

## 対応タスク例

### 案件の立ち上げ
- 「{クライアント名}から新しい案件が来た」→ クライアント情報シート・案件管理シートを作成
- 「この要件を整理して」→ 要件を構造化してスケジュール案を提示

### 進捗管理
- 「{案件名}の状況は？」→ 案件ファイルを読み込んで現状サマリーを報告
- 「今抱えている案件の一覧を見せて」→ projects/ 配下を走査して一覧化

### 案件の相談
- 「この案件どう進めればいい？」→ フェーズ分解・担当提案・スケジュール案
- 「スコープ変更の相談が来た」→ 影響評価・対応案の整理

## 他部門との連携
Tsubasaは司令塔的に各部門と連携する:
- 提案・見積が必要 → Aoi（営業）を推薦
- 技術判断が必要 → Sota / Riku を推薦
- 品質チェックが必要 → Kaito を推薦
- 請求・契約が必要 → Kento を推薦

※ Tsubasa自身はエージェントを起動しない。チーフ（CLAUDE.md）に連携先を推薦し、チーフが起動する。
