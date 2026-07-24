# Reviewer のレビュー範囲

このファイルは Reviewer AI が「何を見るか」「何を見ないか」「今サイクルの重点」を定義する。

## 含む（レビュー対象）

| パス | 内容 |
|------|------|
| `CLAUDE.md` | プロジェクト全体指示書 |
| `rules/` | 運用ルール群（partnership, memo, document-format, development, preview-server） |
| `site/index.html` | サイトトップ |
| `site/notes.html` | 横断メモ |
| `site/business/` | 経営トラッカー（focus, goals, kpi, strategy, reviews, internal-meetings, skill-sheet） |
| `site/clients/` | クライアント・プロジェクト記録 |
| `site/docs/` | ドキュメント類 |
| `site/skill-sheets/` | スキルシート関連 |

## 含まない（対象外・理由付き）

| パス | 理由 |
|------|------|
| `bin/` | スクリプト本体は別レイヤー（コード品質は Codex 担当） |
| `data/` | 機密データを含む |
| `references/` | 外部から持ち込んだ参照資料（編集対象外） |
| `site/drafts/` | 一時的な草案、変更頻度高くレビュー意義薄い |
| `.git/`, `.env`, `.claude/settings.local.json` | 機密・Git内部 |
| `ai-loop/` | 本基盤自体（メタループ防止） |
| `.claude/commands/*`, `rules/modes/*` | 既存スキル・ルール（必要時のみ、別途指示で対象に） |

## 観点（何を見るか）

Reviewer は以下の観点で気づきを出す：

1. **UX / 使いやすさ** — ページの導線・情報設計・閲覧性
2. **Feature / 機能の抜け漏れ** — あるべき機能が無い、無くてもよい機能がある
3. **Process / 運用プロセス** — ルール・運用フローの抜け、形骸化、矛盾
4. **Doc / ドキュメント品質** — 整合性、最新性、誤記
5. **Architecture / 構造** — ディレクトリ構成、命名、責務分離

## 観点で取らないもの（Codex / Devの領分）

- 関数名・変数名のレベル
- インデント・空白・コードスタイル
- 細かいバグ修正（コード本体は VPS にない）
- 個別のタイポ修正

## 今サイクルの重点テーマ

```
Cycle 001: 全方位・浅く広く（初回。Reviewer のアウトプット品質を見る）
```

**今後の運用**：
- 重点テーマは1サイクル1つに絞る（全方位は初回のみ）
- 例：「フォーカスダッシュボードの定着度」「クライアント記録の整合性」「ルールファイル群の整理」
- 重点を変えるときは、上記の `Cycle NNN:` 行を更新

## 提案数の目安

- 1サイクル **5-7提案**（多すぎず少なすぎず）
- High 1-2件、Medium 2-4件、Low 0-2件 のバランス
- カテゴリも分散（UX, Feature, Process, Doc, Architecture から複数）

## サイクル頻度の方針

- Phase A：手動トリガー（人間が「始めて」と言う）
- Phase B：週次（土曜10時、cron で自動化）
- 日次は過剰（提案を消化できない）
