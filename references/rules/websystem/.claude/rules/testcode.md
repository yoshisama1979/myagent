---
description:
globs:
alwaysApply: false
---

## 自動テストの実装について

- **Feature テストは必ず `Tests\SafeTestCase` を継承すること**（本番 DB 保護のため）
- `SafeTestCase` を継承していれば `RefreshDatabase` / `DatabaseTransactions` のいずれも使用可

---

### テスト方針

- `SafeTestCase` を継承（本番 DB 保護のガードが setUp で自動実行される）
- DB を扱うテストは `RefreshDatabase` または `DatabaseTransactions` を使用
- 絶対値アサーションは避け、相対値アサーションを使用
- **TDD 原則**: テストファースト、継続的テスト実行

---

### テスト DB 使用方法

- **SafeTestCase**: 本番 DB 保護機能付きテストベースクラス（実体: `src/tests/SafeTestCase.php`）
  - **本番 DB 名チェック**: `earthraise`, `production`, `prod`, `live`, `main` への接続を拒否
  - **testing 環境でのみ実行許可**: `APP_ENV=testing` 必須
  - **SQLite インメモリ許可**: `DB_DATABASE=:memory:` は安全としてスキップ
  - チェックは `parent::setUp()` 前に実行されるため、`RefreshDatabase` の破壊処理が走る前に必ず検証される
- **RefreshDatabase**: マイグレーションを毎テスト再実行。`SafeTestCase` 配下でのみ使用可
- **DatabaseTransactions**: 各テスト後にデータロールバック
- **相対値アサーション**: `assertGreaterThanOrEqual($initialCount + 1, $finalCount)` 等を使用
- **データ作成**: 既存データ参照 + 必要に応じて新規作成

#### 使用例

```php
namespace Tests\Feature\Api;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\SafeTestCase;

class FooControllerTest extends SafeTestCase
{
    use RefreshDatabase;

    public function test_can_create_foo(): void
    {
        // ...
    }
}
```

---

### テスト実行前の確認

1. **環境確認**: `php artisan config:show database` で DB 設定確認
2. **DB 名確認**: 本番 DB 名が含まれていないか確認
3. **環境変数確認**: `APP_ENV=testing`、`DB_DATABASE=:memory:` 設定確認

---

### テスト作成

- **ユニットテスト**: モデル、リレーション、メソッド
- **フィーチャーテスト**: API、コントローラー、認証
- エラーケース、境界値、セキュリティテストも含む
- テスト実行で失敗を確認（Red）

---

### コード実装

- テストが通る最小限のコードを実装
- テスト実行で成功を確認（Green）
- 必要に応じてリファクタリング（Refactor）

---

### TDD サイクル

仕様書 → テスト作成 → テスト失敗（Red） → コード実装 → テスト成功（Green） → リファクタリング

---

### Policy のテスト・実装規約

Laravel の Policy は Gate から呼ばれるため、**プロジェクト内のあらゆる Authenticatable 種別**が `$actor` として渡される可能性がある。本プロジェクトでは現在 `User`（管理画面）と `Customer`（カタログ画面）の 2 種別が存在する。

#### Policy のコード規約

- **Policy / Policy トレイトのメソッド引数 `$actor` を特定モデル型で固定しない**
  - ❌ `public function viewAny(User $actor): bool` — 別種の Authenticatable で TypeError 500
  - ✅ `public function viewAny($actor): bool { ... $actor instanceof User ... }`
- 判定ヘルパー（`isServiceOwner` 等）も `instanceof` でガードしてから属性アクセスする
  - 例: `return $actor instanceof User && $actor->role === UserRole::SERVICE_OWNER;`
- 型ヒントを示したい場合は PHPDoc で `@param User|Customer $actor` のように複数許容を明示

#### Policy のテスト規約

Policy を新規作成・シグネチャ変更したときは、**プロジェクト内の全 Authenticatable 種別**で当該エンドポイントが **500 にならないこと**を必ず確認する。

- 現プロジェクトでカバーすべき種別:
  - `User`（SERVICE_OWNER / AGENCY_OWNER / AGENCY_STAFF 全ロール）
  - `Customer`
- 期待ステータスが 200 / 403 のどちらでも構わない場合は、**500 でないことだけを保証**するテストを置く
  - 例: `->assertStatus(403);`（500 だと自動的に fail する）
- 参考実装:
  - `src/tests/Feature/api/controllers/MasterResourceAccessControlTest.php` — User ロール別
  - `src/tests/Feature/api/controllers/CatalogMasterResourceAccessTest.php` — Customer による回帰防止
