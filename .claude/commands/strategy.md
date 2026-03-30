# /strategy — 経営企画部ルーター

このコマンドは経営企画・戦略関連のタスクを処理する。

## 担当エージェント
- **Haruto**（`agents/haruto-strategy.md`）— 戦略立案・経営判断支援

## 処理フロー

1. タスクの内容を分析する
2. 必要に応じてリサーチ部（Shun）や経営管理部（Kento）と連携
3. Agent toolでHarutoを起動する際、以下を含める:
   - `agents/haruto-strategy.md` の内容
   - `guidelines/company-overview.md`
   - `guidelines/output-standards.md`
   - `guidelines/reporting-standards.md`
   - 具体的なタスク指示

## 対応タスク例
- 事業戦略の立案
- 中長期計画の策定
- 新規事業の検討
- 経営方針の整理
- 事業計画書の作成（テンプレート: `templates/project-plan.md`）

## 複合タスクの場合
「来期の戦略を考えて」のような包括的な指示の場合:
- Haruto（戦略立案）+ Shun（市場調査）+ Kento（財務データ）を並列起動
