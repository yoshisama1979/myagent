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
  - **本番 DB 名チェック**: 本番 DB 名（`production` / `prod` / `live` / `main` 等の一般名に加え、各プロジェクトの実 DB 名）への接続を拒否。**禁止する DB 名のリストは `project-config.md` を正とする**
  - **testing 環境でのみ実行許可**: `APP_ENV=testing` 必須
  - **SQLite インメモリ許可**: `DB_DATABASE=:memory:` は安全としてスキップ
  - チェックは `parent::setUp()` 前に実行されるため、`RefreshDatabase` の破壊処理が走る前に必ず検証される

#### SafeTestCase が無いプロジェクトへの導入手順（最小雛形）

`src/tests/SafeTestCase.php` が存在しないプロジェクトでは、以下の雛形を作成してから Feature テストを書き始める。ポイントは **`setUp()` の `parent::setUp()` より前** に全チェックを行うこと、かつ **fail-closed（安全側に倒す）** で判定すること（禁止 DB 名リストは `project-config.md` を正とする）。

> **fail-closed の要点**：禁止リストは「万一の保険」であって主防御ではない。主防御は「**許可された安全な接続だけを通す**」こと。`:memory:` を無条件で安全扱いにせず **`DB_CONNECTION=sqlite` のときだけ** 許可し、それ以外は `APP_ENV=testing` かつ **専用のテスト DB 名（`project-config.md` に列挙）に一致するときだけ通す**。禁止リスト一致は追加の拒否として重ねる。こうすれば「本番 DB 名を禁止リストへ転記し忘れた」場合でも通らない。

```php
<?php

namespace Tests;

use RuntimeException;

abstract class SafeTestCase extends TestCase
{
    /** 追加の拒否リスト（保険）。project-config.md の禁止 DB 名を正として列挙する */
    private const FORBIDDEN_DATABASES = [
        'production', 'prod', 'live', 'main',
        // 例: 'myapp_production'（project-config.md の実 DB 名を追加）
    ];

    /** 許可するテスト用 DB 名（project-config.md のテスト DB 名を列挙。空なら sqlite のみ許可） */
    private const ALLOWED_TEST_DATABASES = [
        // 例: 'myapp_testing'
    ];

    protected function setUp(): void
    {
        // parent::setUp() の前に検証する（RefreshDatabase の破壊処理より先に走らせるため）
        if (env('APP_ENV') !== 'testing') {
            throw new RuntimeException('テストは APP_ENV=testing でのみ実行可能です。');
        }

        $connection = env('DB_CONNECTION', '');
        $database   = env('DB_DATABASE', '');

        // 1) SQLite インメモリは、接続ドライバが sqlite のときだけ安全として許可
        $isSqliteMemory = ($connection === 'sqlite' && $database === ':memory:');

        if (! $isSqliteMemory) {
            // 2) 実 DB を使う場合は fail-closed：DB 名が空、または許可リストに無ければ拒否
            if ($database === ''
                || (self::ALLOWED_TEST_DATABASES !== [] && ! in_array($database, self::ALLOWED_TEST_DATABASES, true))) {
                throw new RuntimeException("許可されたテスト DB 以外への接続は禁止されています（DB_DATABASE={$database}）。");
            }
            // 3) 追加の保険：禁止リストに一致したら拒否
            if (in_array($database, self::FORBIDDEN_DATABASES, true)) {
                throw new RuntimeException("本番 DB（{$database}）への接続は禁止されています。");
            }
        }

        parent::setUp();
    }
}
```

> 上記は雛形。`ALLOWED_TEST_DATABASES` を空のまま運用すると sqlite 以外は全拒否になる（最も安全）。MySQL 等のテスト DB を使うプロジェクトは、専用のテスト DB 名だけを許可リストに追加する（本番 DB 名は絶対に入れない）。

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

Laravel の Policy は Gate から呼ばれるため、**プロジェクト内のあらゆる Authenticatable 種別**が `$actor` として渡される可能性がある。複数の認証主体（例：管理画面ユーザーとエンドユーザーを別モデルで扱う構成）を持つプロジェクトでは、想定外の種別が `$actor` に渡って 500 になり得る。**そのプロジェクトに実在する Authenticatable 種別とロールの一覧は `project-config.md` を正とする**（以下のコード例のモデル名・ロール名はあくまで説明用のプレースホルダ）。

#### Policy のコード規約

- **Policy / Policy トレイトのメソッド引数 `$actor` を特定モデル型で固定しない**
  - ❌ `public function viewAny(User $actor): bool` — 別種の Authenticatable で TypeError 500
  - ✅ `public function viewAny($actor): bool { ... $actor instanceof User ... }`
- 判定ヘルパー（ロール判定メソッド等）も `instanceof` でガードしてから属性アクセスする
  - 例: `return $actor instanceof User && $actor->role === UserRole::ROLE_A;`（`ROLE_A` は説明用のプレースホルダ）
- 型ヒントを示したい場合は PHPDoc で `@param User|OtherAuthModel $actor` のように複数許容を明示（`OtherAuthModel` はそのプロジェクトの第二の Authenticatable 種別に読み替える）

#### Policy のテスト規約

Policy を新規作成・シグネチャ変更したときは、**プロジェクト内の全 Authenticatable 種別**で当該エンドポイントが **500 にならないこと**を必ず確認する。

- **カバーすべき種別は `project-config.md` に列挙された全 Authenticatable 種別と全ロール**とする（モデルごとに、ロールを持つものは全ロール分）
- 期待ステータスが 200 / 403 のどちらでも構わない場合は、**500 でないことだけを保証**するテストを置く
  - 例: `->assertStatus(403);`（500 だと自動的に fail する）
- 参考実装：各プロジェクトの「種別・ロール別アクセス制御を網羅した既存テスト」を参照する（典型的には、管理画面ユーザーのロール別テストと、別 Authenticatable 種別による回帰防止テストの2系統を用意する）
