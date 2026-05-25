---
description:
globs:
alwaysApply: false
---

## 原則

- まず、このファイルを参照したら、「ルールを確認しました」と前置きを挟む

- 実装後、ルールに沿っているか確認し、「ルールに沿っています」と入れる。

- 毎回以下を参照
  - @Laravel12
  - @Next.js15.2

## 共通

- コマンドはホスト側ではなくコンテナ側で打つ
  - 例：docker compose exec laravel php artisan migrate

## Laravel 開発の注意点

### バリデーションについて

- ルールの項目は配列形式で書く
- バリデーションはリクエストクラスに記述
- 命名規則
- メソッド(キャメル).コントローラ名 ＋ Request
  - 例：
    /src/app/Http/Controllers/api/AuthController.php(store)
    →
    /src/app/Http/Requests/api/StoreAuthRequest.php

### テストコードについて

- AAA パターンを意識して実装

- コントローラのテスト

- 命名規則
  - コントローラ名 ＋ Test
  - 例：
    /src/app/Http/Controllers/api/AuthController.php  
    →
    /src/tests/Feature/api/AuthControllerTest.php

- リクエストクラスのテスト

- まとめてテストを行う
- 命名規則
  - コントローラ名 + Request + Test
  - 例：
    /src/app/Http/Requests/api/StoreAuthRequest.php
    →
    /src/tests/Feature/api/AuthRequestTest.php

- テストコードを作成したときに、ファクトリーも作る。

### ファクトリーについて

- マイグレーションファイルを参照し構造を確認してから作成

## Nextjs 開発の注意点

- 同じような実装の場合、コンポーネント化して共通化する。
- 他の UI を必ず踏襲する
- フォームで必須の場合は必須であることをわかるようにする
- Button は mui を使う
- アイコンは mui の IconButton でラップする
- アイコンは統一する
  - 例：
    アカウント一覧の編集アイコンが pencil
    →
    新機能の編集アイコンも pencil
- アクションアイコンの場合、ツールチップで補足する
- 削除の場合、ダイアログで確認をとってください
- 一覧で表示する場合は、ソート・検索・ページネーションはセットで作成
  - UserList.tsx を参考
