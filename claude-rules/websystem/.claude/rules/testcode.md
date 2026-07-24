---
paths:
  - "**/tests/**/*.php"
  - "**/*Test.php"
  - "**/phpunit.xml"
---

## 自動テストの実装について

- **DB を扱うテストは（Feature / Unit を問わず）必ず `Tests\SafeTestCase` を継承すること**（本番 DB 保護のため。DB に触れない純粋な Unit テストはこの限りでない）
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
  - **許可リストが主防御（fail-closed）**: SQLite `:memory:`（sqlite ドライバ時のみ）か、**許可リスト `ALLOWED_TEST_DATABASES`（`project-config.md` のテスト DB 許可リストを正とする）に載った DB 名だけ**を通す。**リストが空なら sqlite `:memory:` 以外は全拒否**
  - **禁止リストは保険**: 本番 DB 名（`production` / `prod` / `live` / `main` 等の一般名に加え、各プロジェクトの実 DB 名。`project-config.md` の禁止リストを正とする）への接続は許可リストに誤記されても拒否
  - **testing 環境でのみ実行許可**: `APP_ENV=testing` 必須
  - **二重関門**: 第1関門＝`parent::setUp()` 前に `env()` ベースで検証（`RefreshDatabase` の破壊処理より先）。第2関門＝`setUpTraits()` オーバーライドで **アプリ起動後・破壊処理前に、URL 解析後の実接続値（driver / database）で検証**。`config:cache` の残骸や、接続設定の `url`（`DATABASE_URL`）が database を上書きする構成で「env() は安全な値・実接続は別 DB」という乖離が起きても第2関門が止める。検査対象はデフォルト接続＋`$connectionsToTransact`
  - **保証範囲は直列実行のみ**: **`php artisan test --parallel`（並列テスト）は使わない**（ParallelTesting の DB 作成・削除コールバックは `setUpTraits()` より前に走り、関門が破壊処理より先に立てない）。また、マイグレーション・テストコード内の**明示的な別接続**（`Schema::connection('legacy')` 等）はガード対象外＝テストから明示接続で開発・本番 DB を触らない（コードレビューで見る）

#### SafeTestCase が無いプロジェクトへの導入手順（最小雛形）

`src/tests/SafeTestCase.php` が存在しないプロジェクトでは、以下の雛形を作成してから Feature テストを書き始める。ポイントは **破壊処理（`RefreshDatabase`）より先に検証する二重関門** と、**fail-closed（安全側に倒す）** で判定すること（許可・禁止 DB 名リストは `project-config.md` を正とする）。

> **fail-closed の要点**：禁止リストは「万一の保険」であって主防御ではない。主防御は「**許可された安全な接続だけを通す**」こと。`:memory:` を無条件で安全扱いにせず **`DB_CONNECTION=sqlite` のときだけ** 許可し、それ以外は `APP_ENV=testing` かつ **専用のテスト DB 名（`project-config.md` に列挙）に一致するときだけ通す**。**許可リストが空のときは sqlite `:memory:` 以外を全拒否する**（「リスト未記入＝素通り」に絶対しない。ここが fail-open だと、`APP_ENV=testing` だけ立った状態で `.env` の開発 DB に RefreshDatabase が走り全データが飛ぶ）。禁止リスト一致は追加の拒否として重ねる。こうすれば「本番 DB 名を禁止リストへ転記し忘れた」場合でも通らない。

> **さらに堅くするなら（推奨）**：このガードを `SafeTestCase` でなく **基底 `Tests\TestCase` 自体に組み込む**。全テストが構造的に保護され、「SafeTestCase を継承し忘れた1本が素通りする」という穴が概念ごと消える。その場合 `SafeTestCase` は `abstract class SafeTestCase extends TestCase {}` の空クラスとして残し、既存の継承宣言を壊さない。

```php
<?php

namespace Tests;

use Illuminate\Support\ConfigurationUrlParser;
use RuntimeException;

abstract class SafeTestCase extends TestCase
{
    /** 許可するテスト用 DB 名（主防御。project-config.md のテスト DB 許可リストを列挙。空なら sqlite :memory: のみ許可） */
    private const ALLOWED_TEST_DATABASES = [
        // 例: 'myapp_testing'
    ];

    /** 追加の拒否リスト（保険）。project-config.md の禁止 DB 名を正として列挙する */
    private const FORBIDDEN_DATABASES = [
        'production', 'prod', 'live', 'main',
        // 例: 'myapp_production'・'myapp_dev'（project-config.md の実 DB 名＝消えて困る DB を全部追加）
    ];

    protected function setUp(): void
    {
        // 第1関門（アプリ起動前・env() ベース）：RefreshDatabase の破壊処理より先に検証する
        if (env('APP_ENV') !== 'testing') {
            throw new RuntimeException('テストは APP_ENV=testing でのみ実行可能です。');
        }
        $this->assertDatabaseIsSafe((string) env('DB_CONNECTION', ''), (string) env('DB_DATABASE', ''), 'env');

        parent::setUp();
    }

    /**
     * 第2関門（アプリ起動後・URL 解析後の実接続値で検証）。
     * config:cache の残骸があると phpunit.xml の env 上書きが config に反映されず、
     * また接続設定の url（DATABASE_URL）は接続生成時に database 等を上書きするため、
     * config の生値でなく ConfigurationUrlParser で解析した後の driver / database を見る。
     * setUpTraits() は refreshApplication() の後・RefreshDatabase 実行の前に呼ばれるため、
     * ここで実接続値を破壊処理の前に検証できる（直列実行のみ。--parallel は使わない）。
     * 検査対象＝デフォルト接続＋ $connectionsToTransact（明示的な別接続は対象外）。
     */
    protected function setUpTraits()
    {
        if (! app()->environment('testing')) {
            throw new RuntimeException('実行環境（config: app.env）が testing ではありません。config:cache の残骸を疑ってください（php artisan config:clear）。');
        }

        $names = [(string) config('database.default')];
        if (property_exists($this, 'connectionsToTransact')) {
            foreach ((array) $this->connectionsToTransact as $name) {
                if (is_string($name) && $name !== '') {
                    $names[] = $name;
                }
            }
        }

        $parser = new ConfigurationUrlParser();
        foreach (array_unique($names) as $name) {
            $config   = $parser->parseConfiguration((array) (config("database.connections.{$name}") ?? []));
            $driver   = (string) ($config['driver'] ?? '');
            $database = (string) ($config['database'] ?? '');
            $this->assertDatabaseIsSafe($driver, $database, "config:{$name}");
        }

        return parent::setUpTraits();
    }

    /**
     * fail-closed：sqlite :memory: か、許可リストに載ったテスト DB だけを通す。
     * $driver には、第1関門では env('DB_CONNECTION')（慣例的にドライバ名と同名の接続名）、
     * 第2関門では URL 解析後の実ドライバ名が渡る。
     */
    private function assertDatabaseIsSafe(string $driver, string $database, string $source): void
    {
        // 1) SQLite インメモリは、ドライバが sqlite のときだけ安全として許可
        if ($driver === 'sqlite' && $database === ':memory:') {
            return;
        }
        // 2) それ以外は許可リスト一致が必須（リストが空なら全拒否＝fail-closed）
        if (! in_array($database, self::ALLOWED_TEST_DATABASES, true)) {
            throw new RuntimeException("許可されたテスト DB 以外への接続は禁止されています（{$source}: DB_DATABASE={$database}）。");
        }
        // 3) 追加の保険：許可リストに誤って本番名を書いてしまっても禁止リストで拒否
        if (in_array($database, self::FORBIDDEN_DATABASES, true)) {
            throw new RuntimeException("本番 DB（{$database}）への接続は禁止されています。");
        }
    }
}
```

> 上記は雛形。`ALLOWED_TEST_DATABASES` が空のときは **sqlite `:memory:` 以外を全拒否**する（雛形の初期状態＝最も安全）。MySQL 等のテスト DB を使うプロジェクトは、専用のテスト DB 名だけを許可リストに追加する（本番・開発 DB 名は絶対に入れない）。
>
> ⚠️ **旧雛形（2026-07-17 以前）を導入済みのプロジェクトは要修正**：旧版は許可リストが空だと「DB 名が空でない限り素通り」する fail-open バグがあり、`APP_ENV=testing` だけ立った状態で `.env` の開発 DB に RefreshDatabase が走り得た。上記の `assertDatabaseIsSafe`（空リスト＝全拒否）に差し替えること。
>
> ⚠️ **並列テスト（`php artisan test --parallel`）はこの雛形の保証範囲外＝使わない**。ParallelTesting の DB 作成・削除コールバックは `setUpTraits()` より前に走るため、関門がすべての破壊処理より先に立てない（並列用の DB 名付け替えで許可リストとも合わなくなる）。並列化が必要になったら、許可済み基底名＋並列トークンだけを通す事前検証を別途設計してから導入する。

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

1. **config キャッシュ確認**: `bootstrap/cache/config.php` が存在しないこと（あれば `php artisan config:clear`。残っていると phpunit.xml の env 上書きが効かず、実接続がキャッシュされた開発 DB になる）
2. **環境確認**: `php artisan config:show database` で DB 設定確認
3. **DB 名確認**: 本番・開発 DB 名が含まれていないか確認
4. **環境変数確認**: phpunit.xml に `APP_ENV=testing`・`DB_CONNECTION=sqlite`・`DB_DATABASE=:memory:`（または許可リスト記載のテスト DB）が **明示** されていること（`.env` 任せにしない）
5. **継承漏れ確認**: `grep -rL "SafeTestCase" src/tests/Feature src/tests/Unit --include="*Test.php"` で SafeTestCase を継承していない DB 使用テストが無いこと（DB に触れない純粋な Unit テストは対象外）。※これは**文字列一致の簡易確認**＝コメントや未使用の `use` があるだけでも通ってしまう。ガードを基底 `Tests\TestCase` に組み込めばこの確認自体が不要になる（推奨）
6. **直列実行の確認**: `--parallel` を使っていないこと（本雛形の保証範囲外＝上記 ⚠️ 参照）

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
