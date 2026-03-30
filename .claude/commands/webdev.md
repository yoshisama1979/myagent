# /webdev — WEB制作部ルーター

このコマンドはWEB制作関連のタスクを処理する。

## 担当エージェント
- **Sakura**（`agents/sakura-webdesign.md`）— デザイン・フロントエンド
- **Riku**（`agents/riku-webdev.md`）— バックエンド・CMS

## 処理フロー

1. タスクがフロント寄りかバック寄りか判断
2. フロント → Sakura、バック → Riku、両方 → 並列起動
3. Agent toolで起動する際、以下を含める:
   - 該当エージェントの.mdファイル
   - `guidelines/company-overview.md`
   - `guidelines/brand-guidelines.md`
   - `guidelines/output-standards.md`
   - `guidelines/security-policy.md`
   - 具体的なタスク指示

## 対応タスク例
- サイトデザイン・コーディング
- WordPress構築
- LP制作
- フォーム実装
- レスポンシブ対応

## レビューフロー
制作物は品質管理部（Kaito）にレビューを依頼する。
