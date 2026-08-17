# project-config.md

> このプロジェクト固有の定義（スタック・アカウント種別/ロール・DB名・プロジェクトルート/コマンド実行方法・主要カラー・コンテナ名など）の置き場。各開発エージェントが記入する。

## プロジェクト名／概要

- **プロジェクト名**: （記入。例: ○○受発注システム）
- **概要**: （記入。例: BtoB の受発注管理。管理画面＋カタログ画面の2面構成）

## スタック

- **バックエンド**: （記入。例: Laravel 12）
- **フロントエンド**: （記入。例: Next.js 15）
- **UIコンポーネントライブラリ**: （記入。例: shadcn/ui + lucide-react、MUI 等。`.claude/rules/dev.md`/`.claude/rules/ui-design.md` が正として参照）
- **共通コンポーネントの代表例**: （記入。Button・Dialog・Form 等の踏襲元。例: `next/src/components/ui/*`。`.claude/rules/ui-design.md` が参照）
- **アイコンライブラリ**: （記入。例: `lucide-react`。`.claude/rules/ui-design.md`/`.claude/rules/dev.md` が参照。プロジェクトで1つに統一）

## プロジェクトルートとコマンド実行方法

- **プロジェクトルート**: （記入。例: `/path/to/project`）
- **コマンド実行方法**: （記入。例: `docker compose exec laravel php artisan ...`。`rules/modes/refactoring.md`/コマンド群が参照）

## ブランチ運用・デプロイ（`rules/modes/deploy.md` / `rules/modes/commit.md` / `rules/modes/autopilot.md` が参照）

> ⚠️ **ルール本文の `develop` / `staging` / `main` は既定の例。ここに記入した値が正。**
> 未記入のままだと、AI が名前から昇格経路を推測し、**使われていない古いブランチへマージさせる事故**になる。

- **AI の作業ブランチ**: （記入。例: `develop`。AI は他ブランチへ切替・コミット・マージしない）
- **昇格経路（デプロイ順）**: （記入。例: `develop` → `staging` → `main` ／ `develop` → `staging` 止まり）
- **本番が動いているブランチ**: （記入。例: `staging`。**最終コミット日を確認して決める**。古いブランチが残っていることがある）
- **本番サーバーの構成（サービスごとに「即反映」か「要再ビルド」か）**: （記入。例: `laravel`=ソースをバインドマウント（pull で即反映）／`next`=イメージ焼き込み（**再ビルド必須**））
- **メンテナンスモードの入切**: （記入。例: `php artisan down` / `up`。無ければ「無し」と明記）
- **DB バックアップの取得コマンド・置き場**: （記入。破壊的マイグレーション前に必須）
- **AI がやらないこと**: `git push` / PR 作成・マージ / 本番サーバーでのコマンド実行（すべてユーザー）

## 既知のテスト失敗（ベースライン）（`rules/modes/tdd.md` 1.6 が参照）

- **一覧の置き場**: （記入。例: `documents/pending-issues.md` の「既知のテスト失敗」節）
- **リグレッション判定**: 新規失敗が 0 件であること（件数だけ数えず、**今回触る領域に関係する失敗は中身を読む**）

## コンテナ名

- **Next コンテナ名**: （記入。例: `myapp-next`。`.claude/rules/frontend-test.md` が参照）
- **その他コンテナ**: （記入。例: `laravel` / `mysql`）

## テストDB 許可リスト／本番DB名の禁止リスト

（記入。`.claude/rules/testcode.md` の SafeTestCase が参照。**許可リストが主防御**＝ここに載った DB 名と sqlite `:memory:` 以外への接続をテストは全拒否する）

- **許可リスト（`ALLOWED_TEST_DATABASES`・テスト専用 DB 名だけ）**:
  - 例: `myapp_testing`
  - sqlite `:memory:` だけで回すプロジェクトは「なし（sqlite のみ）」と明記
- **禁止リスト（`FORBIDDEN_DATABASES`・保険。本番に加え「消えて困る開発 DB」も入れる）**:
  - 例: `myapp_production`
  - 例: `myapp_prod`
  - 例: `myapp_dev`

## Authenticatable 種別・ロール一覧

（記入。`.claude/rules/testcode.md` の Policy 規約・`rules/modes/estimation.md` が参照）

- 例: `User`（管理画面ユーザー。ロール: `admin` / `operator` / `viewer`）
- 例: `Customer`（エンドユーザー。ロールなし）

## カラー

- **プライマリカラー**: （記入。例: `#2563eb`。`.claude/rules/ui-design.md` が参照）
- **ホバー色**: （記入。例: `#1d4ed8`）

## 一覧コンポーネントの代表例

（記入。`.claude/rules/dev.md` が参照。ソート・検索・ページネーションの踏襲元となる既存一覧コンポーネント）

- 例: `next/src/components/admin/UserListTable.tsx`

## フロントエンドテスト（`.claude/rules/frontend-test.md` が参照）

- **テストランナー／ライブラリ**: （記入。例: Vitest + React Testing Library + jsdom）
- **設定ファイル**: （記入。例: `next/vitest.config.mts`）
- **テスト配置**: （記入。例: `next/src/__tests__/`）
- **実行コマンド**: （記入。例: `docker exec <next-container> npm test`）
- **本番ビルド相当の静的チェック**: （記入。例: `docker exec <next-container> npx next lint`。**本番ビルドが内部で走らせる lint / 型チェックをコミット前に通す**ためのコマンド。テストランナーや開発サーバーはこれを通らないので、ここを省くとデプロイ時に初めてビルドが落ちる）

## スライド資料（デッキ）（`rules/modes/deck-format.md` が参照）

- **出力先**: （記入。既定: `documents/decks/<案件名>/`。変える場合のみ記入）
- **Chrome 実パス**: （記入。例: `/usr/bin/google-chrome`／`C:\Program Files\Google\Chrome\Application\chrome.exe`）

## hana-tools プロジェクトメモ連携（`rules/modes/hana-memo.md` が参照）

> 残存課題・重要仕様を hana-tools のプロジェクトメモへ登録する連携（`/hana-memo`）。使わないプロジェクトは空欄のままでよい。

- **ベースURL**: （記入。例: `https://stg.hana-tools.com`。本番へ書く場合は本番URL）
- **project_id**: （記入。調べ方は `rules/modes/hana-memo.md` §5。一度調べたらここに記録し毎回問い合わせない）
- **visibility 既定**: （記入。既定: `shared`＝全体共有）
- **API トークンの置き場**: （記入。例: 環境変数 `HANASAKA_API_TOKEN`。**実値をこのファイル・リポジトリに書かない**）

## HP分析ループ連携（`rules/modes/mailbox.md` / `rules/modes/hp-loop-dialogue.md` が参照）

> 外部の「はなさかAI HP分析ループ」とサイト別にやり取りするための固有ID。ループはマルチサイト化で `hp-loop-<site>` に分かれており、**無印 `hp-loop` 宛では現行ループが拾えない**。対の分析ループがあるプロジェクトで記入する（無いプロジェクトは空欄のままでよい）。

> ⚠️ **連携するのに未記入のまま放置しない**：ここが空欄だと、開発エージェントは報告の宛先（`hp-loop-<site>`）を確定できずメールボックス送信が成立しない（[rules/modes/mailbox.md](rules/modes/mailbox.md) §2 が「未記入なら社長に確認」と指示する）。このマシンの担当プロジェクトが決まったら**最初に埋める**。

- 対になる分析ループのID（報告の宛先）：（記入。`hp-loop-<site>` 形式。例：hp-loop-ycom）
- 自分（実装エージェント）のID：（記入。例：web-hanasaka。※ mailbox の `from` はトークンから決まるので参考値）

## 仕様書の場所

- **既定**: `documents/specs/`（HTML。`.claude/rules/spec-format.md` 準拠）
- （`document.md` しか無い既存案件はその旨をここに記入。例: 「本案件は `documents/document.md` のみ。specs/ への移行は未着手」）
