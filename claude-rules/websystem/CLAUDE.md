## プロジェクト概要

- 仕様書: `documents/specs/`（HTML + Tailwind CSS。詳細フォーマットは `.claude/rules/spec-format.md` を参照）
  - 目次: `documents/specs/index.html`
  - 旧仕様書: `documents/document.md`（既存案件の移行用。**新規プロジェクトは specs/ のみを使い、document.md は作らない**）
- テスト仕様書: `documents/test.csv`（**人間が行う手動テストのみ**を書く。自動テストでカバーする項目は書かない＝テストコードが正。`rules/modes/create-test.md` 参照）
  - test.csv は**記録**。ユーザーはプロンプト画面しか見ていないため、**実装完了時・コミット提案時には今回の確認事項をチャットにも提示**する（同ルール「記録（test.csv）と提示（プロンプト）は別物」）
- 残存課題: `documents/pending-issues.md`
- ルール改善メモ: `documents/rule-improvements.md`（ルールファイルへの気づき・改善案の記録先。上の「コラボレーションの原則 2」参照）
- 見積もり台帳: `documents/estimate-log.md`（**採用された**見積もりの記録先。記録は**ユーザー確認後のみ**。`rules/modes/quotation.md` §6 参照）
- プロジェクト固有の定義（スタック・アカウント種別・ディレクトリ・確認URL等）: `project-config.md`

> **画面を確認する URL（ローカル／ステージング／本番）は `project-config.md` の「URL・確認環境」節が正**。表示確認・スクリーンショットが要るたびにユーザーへ聞かず、まずそこを読む。
> **プロジェクトの初回着手時**（最初の実装・確認に入る前）に同節を点検し、**分かるものは AI が記入して、不明な分だけまとめて一度確認する**。以後は聞かない。

## 残存課題の記録ルール

会話・実装の中で**未解決のまま残った課題**は `documents/pending-issues.md` に記録すること。

- ユーザーから「残存課題として記録して」と依頼された場合は必ず `pending-issues.md` に追記
- 仕様書（`documents/specs/` の該当ページ。旧 `document.md` も同様）には**確定仕様のみ**を書き、未確定・未対応事項は混在させない
- 各課題には「経緯」「未対応」「今後の判断ポイント」を明記する
- 解決した課題は `pending-issues.md` から削除し、仕様書（`documents/specs/` の該当ページ）に通常仕様として転記する

## 環境

プロジェクトルートやコマンド実行方法は `project-config.md` を参照すること。

## ルールファイル（3層構成）

**方針**: トークン消費を抑えるため、ルールファイルは**タスクに関連するもののみ必要に応じて読み込む**（全件を先読みしない）。作業のフェーズに入った時点で、下表から該当するファイルを選んで読み込むこと。

置き場所は**読み込まれ方**で3層に分かれる（2026-07-24 再編）：

| 層 | 置き場所 | 読み込まれ方 |
|---|---|---|
| 常時 | `.claude/rules/`（フロントマター無し） | セッション開始時に自動ロード（`.claude/rules/dev.md`・`.claude/rules/private.md` の2本のみ） |
| 条件付き | `.claude/rules/`（`paths:` フロントマター付き） | **globに合致するファイルを扱うときだけ自動適用**（読み忘れが起きない） |
| 読み込み式 | `rules/modes/` | 自動ロードされない。下表の「いつ参照するか」に該当したら **Read で読む** |

| ファイル | いつ参照するか |
|---------|--------------|
| `rules/modes/director.md` | **統括（ディレクター）の役のルール**。2窓なら `/director` で起動。**1窓でも統括の役として従う**（役は常に2つ＝同ファイル冒頭「前提：窓は1つか2つか」）。仕様策定（§5.2）・設計フェーズ・委任・**自分の手で検品**・**Codex クロスレビュー**・**コミット**・昇格の進言（実装しない・push しない） |
| `rules/modes/developer.md` | **開発（デベロッパー）の役のルール**。2窓なら `/dev` で起動。**1窓でも開発の役として従う**。**実装の流れ（§2.1）・実装中の横断確認（§2.2）・着手前のプリフライト（§1.1）・必ず止まるもの（§4.1）はここが正**。委任カードを受けて実装・テストし、**コミット材料を添えて報告**する（仕様を決めない・**コミットしない**） |
| `.claude/rules/dev.md`（常時） | 実装時（開発規約）※スタック（Laravel/Next.js 等）・UIライブラリは `project-config.md` を正とする |
| `rules/modes/tdd.md` | テスト作成時（BDDシナリオ・RGBCサイクル・三者整合性チェック） |
| `.claude/rules/testcode.md`（paths自動） | バックエンドテスト作成時 |
| `.claude/rules/frontend-test.md`（paths自動） | フロントエンドテスト作成時 ※テストランナー・コンテナ名等のスタック固有値は `project-config.md` を正とする |
| `rules/modes/create-test.md` | テスト仕様書（CSV）作成時／**実装完了・コミット提案時にユーザーへ確認事項を提示するとき**（記録＝test.csv・提示＝チャットの使い分け） |
| `.claude/rules/spec-format.md`（paths自動） | 仕様書（`documents/specs/`配下のHTML）を作成・更新するとき |
| `rules/modes/refactoring.md` | リファクタリング時 |
| `.claude/rules/coding.md`（paths自動） | コーディング時（CSS/Sass・HTML・PHP定数の規約）※素PHP+Sass 構成のプロジェクトのみ（スタックは `project-config.md` 参照） |
| `rules/modes/setup.md` | 初回セットアップ時のみ（SCSS自動コンパイル等の環境構築）※Live Sass Compiler を使うプロジェクトのみ |
| `.claude/rules/ui-design.md`（paths自動） | UI/デザインを実装・変更するとき。`Design.md`=SSOT の扱い方・UI実装原則・アクセシビリティ最低ライン・Do/Don't ※UIライブラリ・カラーコードは `Design.md`（あれば）→ `project-config.md` の順で正とする |
| `rules/modes/design-replication.md` | **デザインカンプ／モックアップ（特にAI生成画像）を渡されてUIを再現する時。** 推測を実測に変え、実ブラウザ描画で照合する周回（色の実測・同一幅スクショ・寸法は意図から設計しSSOTに記録） |
| `rules/modes/ui-check.md` | **UI実装を終えて確認するとき**（`rules/modes/developer.md` §2.1 の Step 8 動作確認・統括の検品の前）。動作・アクセシビリティ・レスポンシブ・一貫性の目視品質ゲート（自動テストとは別物） |
| `.claude/rules/config-values.md`（paths自動） | **設定値（しきい値・上限・フラグ等）を追加・変更するとき**。正を1箇所だけ決める・既定値を2箇所以上に書かない・クライアントは既定値を推測しない・最終判定はサーバー側・環境変数は文字列として検証する。config / `.env` 系を開けば自動適用されるが、**クライアント側やテスト側だけを触るときは自動適用されない**ので明示的に読む |
| `.claude/rules/api-design.md`（paths自動） | **API を実装・変更するとき**（認証系統の明示・管理用と公開用の分離・複数経路の共通化・内部表現を返さない・DB制約とバリデーションの整合・部分更新の検証・一括インポート・テストDBと本番DBの差）※実パス・middleware名・モデル名は `project-config.md` 側 |
| `rules/modes/commit.md` | コミットメッセージを作成・提案するとき（汎用ガイドライン）／**ブランチ運用方針：単一AI × 作業ブランチ直接コミット**（feature ブランチを切らない・PR とマージはユーザー手動。**ブランチ名と昇格経路は `project-config.md` を正とする**） |
| `rules/modes/deploy.md` | **本番デプロイの手順を提示するとき**。推測で手順を書かず、まず本番の実状態（`git log -1` / `git branch --show-current` / `git status`）を読む。ブランチ名を信用しない・反映に再ビルドが要るかは構成で決まる・破壊的マイグレーション時の順序。**AI は push / マージ / 本番コマンドを実行しない** |
| `rules/modes/estimation.md` | 新機能のタスク抽出・見積もり（難易度評価）を行うとき |
| `rules/modes/quotation.md` | **顧客向けの見積書**（工数・費用・但し書き）を作成・提示するとき。内部のタスク抽出は rules/modes/estimation.md、見積書への仕立ては rules/modes/quotation.md |
| `rules/modes/deck-format.md` | **クライアント向けスライド資料（提案書・報告デッキ）を HTML→PDF で作るとき**。ヘッドレスChrome→A4横PDF の手順・落とし穴（用紙が縦になる等）・検証・スクショの実データ混入防止 |
| `rules/modes/hana-memo.md` | **hana-tools のプロジェクトメモへ残存課題・重要仕様を登録・更新するとき**（`/hana-memo`）。API仕様・全置換の鉄則（GET→統合→POST）・HTMLサニタイズ制約。固有値（ベースURL・project_id）は `project-config.md` を正とする |
| `rules/modes/hp-loop-dialogue.md` | **外部の分析ループ（はなさかAI HP分析ループ）から改善提案を受け取った時**／**作業を終えて解析へ伝えるとき**（§5-4＝依頼の有無に関わらず・月次レポートの材料）。検証→対応→提案元への報告の標準フロー（R-NNN/Q-NNN の扱い、提案元の限界＝静的GETのみ・SPA/ログイン後は見えない、報告文の作り方）。対の分析ループが無いプロジェクトは出番なし |
| `rules/modes/mailbox.md` | **hp-loop など別マシンのエージェントとメールボックス（共有受信箱）でやり取りする時**。受信箱を読む／報告・質問を送る操作と、社長承認ゲート（`--needs-approval`）。報告の中身は `rules/modes/hp-loop-dialogue.md` に従う＝こちらは送受信の土管。宛名・トークン未配布のプロジェクトは出番なし |
| `rules/modes/rules-update.md` | **ルールの新しい版が出ていないか確認するとき／更新するとき**（`bash bin/rules-update.sh`）。確認は何も書き換えないので区切りごとに流してよいが、**適用は人の確認を得てから**。上書きされるもの／守られるもの（案件の記録）・戻し方・エラーの読み方。統括の持ち場で、開発は作業中に更新しない |
| `project-config.md`「固有の追加」 | **このプロジェクトだけのルール・モード・規約の一覧**。この表と合わせて必ず見る（この表は配布物＝書き足さない。§「ルールファイルの出自と改善ループ」） |
| `.claude/rules/private.md`（常時） | 環境固有の実行メモ＋**検証の落とし穴**（各マシン・各プロジェクトで記入。テンプレ時点は雛形。**2 回目に踏んだら回避手順を書く**＝セッションを分けると会話の知見は共有されない） |

## スラッシュコマンド (.claude/commands/)

| コマンド | 用途 |
|---------|------|
| `/director` | このウィンドウを **統括**として起動する（**2窓のとき**。`rules/modes/director.md` 準拠。1窓なら同ファイルを読んで統括の役として振る舞う） |
| `/dev` | このウィンドウを **開発**として起動する（同上。`rules/modes/developer.md` 準拠） |
| `/staging` | 変更ファイルを個別に `git add` する（`git add .` は使わない。領域が混ざる場合は分けてステージ） |
| `/commit` | ステージ済み差分を確認し、`rules/modes/commit.md` の規約に沿ったコミットメッセージを提案する |
| `/commit-pipeline` | staging → Codex クロスレビュー → コミット → リファクタリング を一括で実行するパイプライン |
| `/refactor` | ステージ済み差分に対し `rules/modes/refactoring.md` に従ってリファクタリングを実施する |
| `/consistency-check` | 仕様書・テスト仕様書（test.csv）・実装コードの三者整合性チェックを行う |
| `/hana-memo` | hana-tools のプロジェクトメモへ残存課題・重要仕様を登録・更新する（`rules/modes/hana-memo.md` 準拠。**POST は全置換**のため GET→統合→POST を厳守・送信前にユーザー承認） |
| `/cleanup-permissions` | `.claude/settings.local.json` の permissions.allow リストを汎用パターンに整理する |
| （このプロジェクト固有） | `project-config.md`「固有の追加」節の表を見る（この表には書き足さない＝ルールの更新で消える） |

> 🚨 **git 系コマンド（`/staging` `/commit` `/commit-pipeline` `/refactor`）は統括の役が実行する**（2窓なら統括セッションで）。 開発は `git add` / `commit` / ブランチ切替をせず、実装して報告するところまで。`push` / PR / マージはどちらもせず、ユーザーの手動作業。理由は `rules/modes/director.md` §7（🔄 2026-10-24 に持ち場を変更＝website テンプレートと同じになった）。

## デザインルールの単一の真実の源 (Design.md)

プロジェクトルートに `Design.md` がある場合、それが **デザインに関する Single Source of Truth**。
色・タイポグラフィ・余白・コンポーネント仕様は、個別実装の記述より Design.md を優先する。

- 新規 UI 実装の前に必ず `Design.md` を読む
- Design.md と既存コードが食い違う場合は Design.md に合わせて既存コードを直す（漸進的に）
- Design.md に無い概念（新しい色トークン、コンポーネント等）を勝手に増やさない。先に Design.md を更新する提案をする
- `Design.md` が存在しない場合は勝手に作らず、ユーザーに作成を提案する（手順・持つべきセクション構成は `.claude/rules/ui-design.md` の「デザインの単一の真実の源」参照）

> **汎用ルールと固有値の分離**：「Design.md をどう扱うか／どのプロジェクトでも守るデザイン規律」は `.claude/rules/ui-design.md`（汎用）にある。**各プロジェクト固有の値**（色 hex・フォント・トークン管理方式等）は、そのプロジェクトの `Design.md` 側に書く。本リポジトリには Tailwind + shadcn/ui 想定の記入例 `Design.sample.md` を同梱している（実プロジェクトではこれを `Design.md` にコピーして値を差し替える）。Design.md 未導入のプロジェクトは従来どおり `project-config.md` の UI 欄を正とする。

## 改行コード

- **方針**: リポジトリに入る改行コードは **LF**。新規ファイル作成時も LF を使用すること
- **担保しているのは `.gitattributes` と `core.autocrlf` の組み合わせ**で、**どこまでを対象にしているかはプロジェクトごとに違う**。
  `.gitattributes` が `*.sh` 等のインフラ設定だけを対象にし、`.md` / `.html` は `core.autocrlf=true`（**コミット時**に変換）で正規化している、という構成は珍しくない
- したがって **Windows のワークツリー上で CRLF に見えても、それ自体はルール違反ではない**（コミット時に LF へ正規化される）。
  CRLF を見つけても**不要な一括変換をしない**。気になる場合は `cat .gitattributes` と `git config core.autocrlf` で実際の設定を確認してから判断する

## フロントエンドテスト

- 設定・テスト位置は `project-config.md` を参照（例: `next/vitest.config.*`、`next/src/__tests__/`、使い方は `next/src/__tests__/README.md`）
