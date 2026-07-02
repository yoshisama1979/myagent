# project-config.md

> このプロジェクト固有の定義（スタック・アカウント種別/ロール・DB名・プロジェクトルート/コマンド実行方法・主要カラー・コンテナ名など）の置き場。各開発エージェントが記入する。

## プロジェクト名／概要

- **プロジェクト名**: （記入。例: ○○受発注システム）
- **概要**: （記入。例: BtoB の受発注管理。管理画面＋カタログ画面の2面構成）

## スタック

- **バックエンド**: （記入。例: Laravel 12）
- **フロントエンド**: （記入。例: Next.js 15）
- **UIコンポーネントライブラリ**: （記入。例: shadcn/ui + lucide-react、MUI 等。`dev.md`/`ui-design.md` が正として参照）
- **共通コンポーネントの代表例**: （記入。Button・Dialog・Form 等の踏襲元。例: `next/src/components/ui/*`。`ui-design.md` が参照）
- **アイコンライブラリ**: （記入。例: `lucide-react`。`ui-design.md`/`dev.md` が参照。プロジェクトで1つに統一）

## プロジェクトルートとコマンド実行方法

- **プロジェクトルート**: （記入。例: `/path/to/project`）
- **コマンド実行方法**: （記入。例: `docker compose exec laravel php artisan ...`。`refactoring.md`/コマンド群が参照）

## コンテナ名

- **Next コンテナ名**: （記入。例: `myapp-next`。`frontend-test.md` が参照）
- **その他コンテナ**: （記入。例: `laravel` / `mysql`）

## 本番DB名の禁止リスト

（記入。`testcode.md` の SafeTestCase が参照。テストで接続を拒否する DB 名を列挙する）

- 例: `myapp_production`
- 例: `myapp_prod`

## Authenticatable 種別・ロール一覧

（記入。`testcode.md` の Policy 規約・`estimation.md` が参照）

- 例: `User`（管理画面ユーザー。ロール: `admin` / `operator` / `viewer`）
- 例: `Customer`（エンドユーザー。ロールなし）

## カラー

- **プライマリカラー**: （記入。例: `#2563eb`。`ui-design.md` が参照）
- **ホバー色**: （記入。例: `#1d4ed8`）

## 一覧コンポーネントの代表例

（記入。`dev.md` が参照。ソート・検索・ページネーションの踏襲元となる既存一覧コンポーネント）

- 例: `next/src/components/admin/UserListTable.tsx`

## フロントエンドテスト（`frontend-test.md` が参照）

- **テストランナー／ライブラリ**: （記入。例: Vitest + React Testing Library + jsdom）
- **設定ファイル**: （記入。例: `next/vitest.config.mts`）
- **テスト配置**: （記入。例: `next/src/__tests__/`）
- **実行コマンド**: （記入。例: `docker exec <next-container> npm test`）

## 仕様書の場所

- **既定**: `documents/specs/`（HTML。`spec-format.md` 準拠）
- （`document.md` しか無い既存案件はその旨をここに記入。例: 「本案件は `documents/document.md` のみ。specs/ への移行は未着手」）
