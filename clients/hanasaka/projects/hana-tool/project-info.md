# プロジェクト情報

## 概要

| 項目 | 内容 |
|------|------|
| プロジェクト名 | HANAツール |
| hana-tools project_id | 27 |
| 種別 | システム開発 |
| ステータス | 運用中・機能追加継続 |
| 開始日 |  |
| 納期 | - |
| 見積金額 | 自社 |

## 要件

社内の案件・プロジェクト・ToDo・日報などを一元管理する自社業務システム。
外部API（`/api/external/...`）を公開し、Claude Code等の外部ツールとも連携可能。

## 技術スタック

- PHP / Laravel
- MySQL
- Chatwork / Toggl / Todoist 連携

## サーバー情報

| 環境 | ホスト / IP | 用途 |
|------|------------|------|
| 本番 |  | 本番環境 |
| ステージング | stg.hana-tools.com | 検証環境 |

## 関連ドキュメント

- 残存課題: [backlog.md](backlog.md)
- 決定事項・確定仕様: [decisions.md](decisions.md)

## 対応履歴

| 日付 | 内容 |
|------|------|
| 2026-04-13 | 外部API（client検索・ToDo登録・Chatwork通知）を整備 |
