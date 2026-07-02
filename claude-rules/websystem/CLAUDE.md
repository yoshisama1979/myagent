# CLAUDE.md

## プロジェクト概要

- 仕様書: `documents/specs/`（HTML + Tailwind CSS。詳細フォーマットは `.claude/rules/spec-format.md` を参照）
  - 目次: `documents/specs/index.html`
  - 旧仕様書: `documents/document.md`（既存案件の移行用。**新規プロジェクトは specs/ のみを使い、document.md は作らない**）
- テスト仕様書: `documents/test.csv`
- 残存課題: `documents/pending-issues.md`
- ルール改善メモ: `documents/rule-improvements.md`（ルールファイルへの気づき・改善案の記録先。下記「コラボレーションの原則 2」参照）
- プロジェクト固有の定義（スタック・アカウント種別・ディレクトリ等）: `project-config.md`

## 残存課題の記録ルール

会話・実装の中で**未解決のまま残った課題**は `documents/pending-issues.md` に記録すること。

- ユーザーから「残存課題として記録して」と依頼された場合は必ず `pending-issues.md` に追記
- 仕様書（`documents/specs/` の該当ページ。旧 `document.md` も同様）には**確定仕様のみ**を書き、未確定・未対応事項は混在させない
- 各課題には「経緯」「未対応」「今後の判断ポイント」を明記する
- 解決した課題は `pending-issues.md` から削除し、仕様書（`documents/specs/` の該当ページ）に通常仕様として転記する

## 環境

プロジェクトルートやコマンド実行方法は `project-config.md` を参照すること。

## ルールファイル (.claude/rules/)

**方針**: トークン消費を抑えるため、ルールファイルは**タスクに関連するもののみ必要に応じて読み込む**（全件を先読みしない）。作業のフェーズに入った時点で、下表から該当するファイルを選んで読み込むこと。

| ファイル | いつ参照するか |
|---------|--------------|
| `agent.md` | 常に（実装フロー・共通原則・モード判定の入口） |
| `dialogue-mode.md` | **仕様策定モード**。ゴール記録ファイル無し / `status: dialogue` / ユーザーが仕様検討意図を示したとき |
| `autopilot.md` | **自走モード**。`mode: autopilot` かつ `status: active`/`paused` の goals.md があるとき。`status: completed` の goals.md は原則作業対象外（追加要望なら Dialogue で再定義） |
| `inbox-mode.md` | **Inbox モード（並走型）**。`/inbox` スラッシュコマンドで起動。開発エージェント稼働中の裏で別セッションを立て、ユーザーの「次やってほしいこと」を `documents/inbox.md` に追記。実装・仕様策定には踏み込まない |
| `dev.md` | 実装時（開発規約）※スタック（Laravel/Next.js 等）・UIライブラリは `project-config.md` を正とする |
| `tdd.md` | テスト作成時（BDDシナリオ・RGBCサイクル・三者整合性チェック） |
| `testcode.md` | バックエンドテスト作成時 |
| `frontend-test.md` | フロントエンドテスト作成時 ※テストランナー・コンテナ名等のスタック固有値は `project-config.md` を正とする |
| `create-test.md` | テスト仕様書（CSV）作成時 |
| `spec-format.md` | 仕様書（`documents/specs/`配下のHTML）を作成・更新するとき |
| `refactoring.md` | リファクタリング時 |
| `coding.md` | コーディング時（CSS/Sass・HTML・PHP定数の規約）※素PHP+Sass 構成のプロジェクトのみ（スタックは `project-config.md` 参照） |
| `setup.md` | 初回セットアップ時のみ（SCSS自動コンパイル等の環境構築）※Live Sass Compiler を使うプロジェクトのみ |
| `ui-design.md`     | UI/デザインを実装・変更するとき ※UIライブラリ・カラーコードは `project-config.md` を正とする |
| `commit.md` | コミットメッセージを作成・提案するとき（汎用ガイドライン）／**ブランチ運用方針：単一AI × `develop` 直接コミット**（feature ブランチを切らない・PR とマージはユーザー手動） |
| `estimation.md` | 新機能のタスク抽出・見積もり（難易度評価）を行うとき |
| `private.md` | 環境固有の実行メモ（各マシン・各プロジェクトで記入。テンプレ時点は雛形） |

## スラッシュコマンド (.claude/commands/)

| コマンド | 用途 |
|---------|------|
| `/staging` | 変更ファイルを個別に `git add` する（`git add .` は使わない。領域が混ざる場合は分けてステージ） |
| `/commit` | ステージ済み差分を確認し、`.claude/rules/commit.md` の規約に沿ったコミットメッセージを提案する |
| `/commit-pipeline` | staging → Codex クロスレビュー → コミット → リファクタリング を一括で実行するパイプライン |
| `/refactor` | ステージ済み差分に対し `refactoring.md` に従ってリファクタリングを実施する |
| `/consistency-check` | 仕様書・テスト仕様書（test.csv）・実装コードの三者整合性チェックを行う |
| `/inbox` | Inbox モード（`inbox-mode.md`）を起動し、「次やってほしいこと」を `documents/inbox.md` に追記する |
| `/cleanup-permissions` | `.claude/settings.local.json` の permissions.allow リストを汎用パターンに整理する |

> 注記: Autopilot 自走中のコミットは `autopilot.md` の規律で自動的に行われるためコマンド不要。これらは主に都度承認モードで使う。

## 改行コード

- `.gitattributes` により全テキストファイルの改行コードは **LF** に統一されている
- Windows (CRLF) 環境でも Git チェックアウト時に LF へ変換される
- 新規ファイル作成時も LF を使用すること

## フロントエンドテスト

- 設定・テスト位置は `project-config.md` を参照（例: `next/vitest.config.*`、`next/src/__tests__/`、使い方は `next/src/__tests__/README.md`）

## コラボレーションの原則

### 1. 不明点・提案は都度質問する

ユーザーからの指示や記述をそのまま鵜呑みにして実装に進まないこと。

- **不明点があれば**：仕様の解釈に複数パターンがある、データ構造が想定と違う、既存コードとの整合性が不明、などの場合は実装前に必ず質問する。
- **より良い案があれば**：提示された方針より適切な選択肢が見える場合は、推奨案と理由を添えて提案する（最終判断はユーザー）。
- **判断が分かれる設計事項**：出力形式・ファイル構成・命名・スコープなどは、実装前に選択肢を整理して合意を取る。

推測で進めて手戻りするより、一手前で確認する方がコストが低い。

### 2. ルールファイル自体の改善も提案する

`rules/` 配下のルールファイルや `CLAUDE.md` を参照していて、以下に気付いた場合は実装作業の合間でも提案する。

- 実態と乖離している記述（例：使われていないツールへの言及、変更されたディレクトリ構成）
- 抜け落ちている運用ルール（例：実プロジェクトで頻出するパターンが明文化されていない）
- 矛盾している記述（複数のルールファイル間で食い違う指示）
- 改善できる構成・粒度（例：粒度が粗すぎる／細かすぎる、参照タイミングが曖昧）

提案時は「どのファイルの、どの記述を、どう変えるか、なぜ」を明示する。ユーザーの判断後に修正に進む。

**ユーザーが明確な回答をしなかった場合も、気づいた点はその都度 `documents/rule-improvements.md` に記録する**。提案が会話に埋もれて流れ、忘れられるのを防ぐため、「記録」と「反映」を分離する（記録は気づいた都度・反映はユーザー判断時にまとめて）。

- 提案したが判断が出ていない／会話が先に進んでしまった場合も、観察を1行でも残す
- 各エントリに「対象ファイル・どの記述・どう変えるか・なぜ」を明記する（フォーマットは `documents/rule-improvements.md` 冒頭参照）
- 反映が済んだエントリは削除する（または「反映済み」と印を付ける）
