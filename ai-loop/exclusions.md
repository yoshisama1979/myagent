# 提案対象外リスト

Reviewer が **再提案してはいけない論点** をここに蒸留する。
却下・保留・確定済みの決定を1行で記録する。

## 仕様確定済み（変更提案NG）

これらは既に decisions として確定しているので、Reviewer は提案対象から外す。

- ブラウザ閲覧HTMLは `site/` 配下に集約（commit 11888cd、2026-05-24 確定）
- preview/private,client,public のサブ構造は廃止、公開範囲は Nginx 設定で都度切り出す（rules/preview-server.md 参照）
- 評価制度は5段階・半期1回・自己評価＋社長レビューの二段（clients/hanasaka/projects/hana-tool/decisions.html 参照）
- スキルシートの最初のカテゴリは「PC操作・作業効率」（同 decisions.html 参照）
- 経営方針：システム制作・運用をメイン事業へ転換（site/business/strategy.html、2026-05-08 確定）
- 目標管理機能の設計方針：OKR-Lite + 達成ログ併走型（clients/hanasaka/projects/hana-tool/decisions.html 参照）

## 却下済み（Reviewer 提案の結果、不採用となったもの）

形式：`- 提案サマリ（YYYY-MM-DD 却下：理由）`

（初期状態）まだ却下提案はなし

## 保留中（次回再評価日付き）

形式：`- 提案サマリ（YYYY-MM-DD 保留：再評価YYYY-MM-DD、理由）`

（初期状態）まだ保留提案はなし

## 対象外領域（永続的に提案しない）

- HANAツール本体コード（PHP/Laravel）— セキュリティ上 VPS に置かない、コード品質は別途 Codex 担当
- 個別のタイポ・コードスタイル — 範囲外
- 個別ユーザーの個人情報・機密情報の編集 — 別レイヤー

## 運用ルール

- Reviewer は必ずこのファイルを読む
- 該当する論点は提案しない
- 微妙にバリエーションを変えての再提案もNG
- 却下後の追加は人間が手動で行う（Reviewer は書き込みしない）
- 保留期限が来たものは、人間が「保留中」から「却下」または「再提案OK」に手動分類

## 関連

- 確定事項のフル仕様: `site/clients/<client>/projects/<project>/decisions.html`
- 横断的な決定事項: `site/business/strategy.html`
