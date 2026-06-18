# Design.md 記入例（YCOM）

> ⚠️ **これは「記入例（サンプル）」です。** YCOM の実値で `Design.md` を書くとこうなる、という見本。
> **各プロジェクトでは、このファイルを `Design.md` としてコピーし、自分のプロジェクトの値に置き換えて使ってください。**
> ここに並ぶ色 hex・フォント・1000px幅・`1rem=1px`換算・`$m_tpl` 等は **YCOM固有の値** であり、そのまま流用しないこと。
> デザイン規約の「汎用ルール（何を守るか）」は [.claude/rules/design.md](.claude/rules/design.md)、作成手順は [.claude/rules/start.md](.claude/rules/start.md) を参照。

株式会社はなさか / YCOM (https://www.y-com.info) のデザインルール集。
**AIコーディングエージェント(Claude Code 等)と人間の両方が、UIを足し引きする前に必ず読むファイル。**

- 単一の真実の源(Single Source of Truth)はこのファイル
- このファイルと SCSS が食い違う場合 → **このファイルに揃えるよう SCSS を更新する**
- 新しいページ・コンポーネントを作るときは、ここに無い概念を勝手に増やさない(増やす場合は先にここを更新)

---

## 1. Design Principles(設計思想)

1. **「相談しやすさ」を最優先**
   サイトのコア価値は「初めてのお客様が安心して相談できる」こと。装飾より、読みやすさ・問い合わせ導線の分かりやすさを優先する。
2. **派手さより清潔感**
   緑(自然・誠実)と白を基調。グラデーション・影・派手なアニメーションは原則禁止。
3. **モバイルでも"会社案内"として成立すること**
   768px 以下でレイアウトが破綻しない。文字サイズは縮小せず行数で吸収する。
4. **PHPテンプレート(`template/page_layout.php`)前提**
   ヘッダー・フッター・メタ情報は `$m_tpl` 経由。個別ページに直書きしない。

---

## 2. Color Tokens(色)

実装は `css/sass/_color.scss` と `_define.scss`。**今後はこの表が正**。SCSS変数名は両ファイルに重複がある(`$color_main` / `$clr_main`)が、**新規実装では下表の "Canonical 変数名" を使う**。

### 2.1 ブランドカラー(緑系)

| 用途 | Token | HEX | 旧変数(参考) |
|---|---|---|---|
| ブランド・プライマリ | `$brand-primary` | `#6CAC3D` | `$clr_main_dark`, `$color_f_main` |
| プライマリ(明) | `$brand-primary-light` | `#B9EF92` | `$color_main_light` |
| プライマリ(暗) | `$brand-primary-dark` | `#537f32` | `$color_main_text` |
| 背景(極淡) | `$brand-primary-bg` | `#F2F7EE` | `$color_main_slight` |

> **注**: 既存CSSには `#7bc146` `#709D4F` `#91C16D` `#40936f` `#3e635a` `#346013` など緑のバリエーションが散在する。新規実装では上記4色のみ使用し、既存コードを触る際は機会があれば寄せていく(一括置換はしない)。

### 2.2 アクセント・補助色

| 用途 | Token | HEX |
|---|---|---|
| アクセント(強調・価格・キャンペーン) | `$accent-pink` | `#DC6486` |
| CTA ボタン(問い合わせ等) | `$btn-cta` | `#FF8000` |
| CTA ボタン hover | `$btn-cta-hover` | `#FFB000` |
| フォーム送信ボタン | `$btn-form` | `#E5B510` |
| フォーム送信ボタン hover | `$btn-form-hover` | `#F5D213` |
| リンク(本文) | `$link` | `#0044CC` |
| 強調マーカー背景 | `$highlight` | `#FFFF66` |

### 2.3 セマンティック / セクション色

| 用途 | HEX |
|---|---|
| 警告(エラー文言) | `#FF0000` |
| サブテキスト(注意書き) | `#660000` |
| ボーダー(点線区切り) | `#EEEEEE` |
| 本文グレー | `#666666` |

セクション別カラー(`_color.scss` 既存):

| セクション | HEX |
|---|---|
| デザイン系コンテンツ | `#84CCEA` |
| ブログ | `#96E1B0` |
| Q&A | `#EFAFE4` |
| フォーム | `#E5D68E` |
| スマホ系 | `#BBE58E` |
| ニュース | `#E7A2A2` |

### 2.4 アクセシビリティ

- 本文と背景のコントラスト比は **4.5:1 以上** を維持(`#666` on `#fff` = 5.74:1 ✅)
- `$brand-primary` `#6CAC3D` を**白文字の背景**として使うときはボールド推奨(コントラスト比 2.97:1 なので通常文字はNG)
- フォーカスリングは消さない(`outline: none` 単独禁止。消すなら代替の可視フォーカスを置く)

---

## 3. Typography(タイポグラフィ)

### 3.1 フォントファミリ

```scss
$f_gothic: 'Noto Sans JP', "游ゴシック Medium", "Yu Gothic Medium", "游ゴシック体", YuGothic, 'メイリオ', Meiryo, sans-serif;
$f_mincho: "Times New Roman", 'Noto Serif JP', "游明朝体", "Yu Mincho", YuMincho, "ヒラギノ明朝 ProN W6", serif;
$f_impact: "Marcellus SC", sans-serif;  // ロゴ・装飾見出しのみ
```

本文は **`$f_gothic` 一択**。明朝・装飾フォントは見出し1箇所/ページ程度の限定使用。

### 3.2 サイズスケール(重要: rem の解釈)

このサイトは `html { font-size: 6.25% }`(= 10px → 0.625px 換算)で **`1rem = 1px` として運用**。 一般的な「1rem = 16px」と違うので注意。

| 用途 | サイズ(rem = px) | 行間 |
|---|---|---|
| 本文 | `14rem` (14px) | 1.6em |
| 小見出し(h3 相当) | `18rem` (18px) | 1.4em |
| 中見出し(h2 相当) | `24rem` (24px) | 1.3em |
| 大見出し(セクションタイトル) | `36rem` (36px) | 1.3em |
| ヒーロー / メインビジュアル | `46rem`〜`50rem` | 1.3em |
| 注釈・キャプション | `12rem` (12px) | 1.5em |

SCSS mixin: `@include fontsize(14);` を使う(`_default.scss`)。

### 3.3 ウェイト

- 通常: 400
- ボールド: 700 のみ(中間ウェイトを増やさない)

---

## 4. Spacing & Layout(余白・レイアウト)

### 4.1 グリッド

- **基本単位: 10px**(本サイトは 8px グリッドではなく 10px グリッド運用)
- 推奨スペーシング: 10 / 20 / 30 / 40 / 60 / 80 / 100 px

### 4.2 コンテナ幅

| 名前 | 幅 | 用途 |
|---|---|---|
| `$main_width` | **1000px** | ページ全体の最大幅 |
| `$c1_width` | **730px** | 2カラム時の本文側 |
| `$c2_width` | **270px** | 2カラム時のサイドバー |

> 1000px固定レイアウトのまま。**幅を 1200px 等に広げない**(既存全ページが 1000px 設計のため)。

### 4.3 ブレークポイント

```scss
$mq_mobile: 768px;
```

- `@media (max-width: 768px)` の **1ブレークポイントのみ** 運用
- タブレット個別対応はしない(必要になったら本ファイルに追加して全体相談)

---

## 5. Components(コンポーネント)

### 5.1 ボタン

| 種類 | 背景 | テキスト | 使いどころ |
|---|---|---|---|
| CTA(問い合わせ・資料請求) | `$btn-cta` `#FF8000` | `#FFF` | お問い合わせ・申し込み |
| プライマリ(本文内) | `$brand-primary` `#6CAC3D` | `#FFF` | 詳細ページへの遷移など |
| セカンダリ | 白 + 1px `$brand-primary` border | `$brand-primary` | 補助動作 |
| フォーム送信 | `$btn-form` `#E5B510` | `#FFF` | `<input type="submit">` |

- 角丸: `border-radius: 4px`(揃える)
- 内側余白: `padding: 12px 24px` 基準
- hover: 背景を 1段階明るく(上表 `*-hover` を使用)
- `transition: background-color 0.2s ease;`

### 5.2 リンク

- 本文中: `color: #0044CC; text-decoration: underline;`
- 外部リンク(`target="_blank"`): 自動で 🔗 アイコン付与(`common.css` のルールあり)
- ナビ内リンクは下線なし

### 5.3 リスト

`common.css` に既存ユーティリティあり。**新規で勝手に作らない**:

| クラス | 見た目 |
|---|---|
| `ul.fa-icon` | FontAwesome の `>` アイコン付き |
| `ul.list` | 緑の四角アイコン付き |
| `ul.li_style1` | 緑の再生マーク付き、20px太字 |
| `ul.li_style2` | 緑のチェック付き、20px太字 |
| `ul.li_style_rect` | SVG の四角アイコン付き |

### 5.4 強調表現

- `<strong>`: デフォルトで黄色マーカー風(`linear-gradient(transparent 40%, #ffff66 40%)`)
- `<strong class="pink">`: ピンク文字
- `<strong class="big">`: 24px・太字
- カスタム強調を**新規で増やさない**

### 5.5 フォーム

- 入力欄: `padding: 10px 0`
- 幅クラス: `.long` (840px) / `.middle` (420px) / 指定なし(可変)
- バリデーションメッセージは `.warning`(赤・太字)

---

## 6. Iconography & Imagery(アイコン・画像)

- アイコン: **FontAwesome 6 Free** + SVG(`images/common/icons/`)を併用
- 写真: `/images/` 配下に各セクションフォルダ。圧縮済みのみコミット(オリジナルは別管理)
- 画像角丸はしない(角丸を使うのはボタン・カードのみ)
- 影は `.box-shadow` ユーティリティのみ。新規で `box-shadow` を直書きしない

---

## 7. Motion(モーション)

- トランジション: `0.2s ease`(ボタン hover 等)/ `1s ease-out`(メインビジュアル出現)
- スクロール連動: `js/parallax/jquery.imageScroll.min.js` のみ使用
- パララックス・複雑なスクロールアニメは**新規追加しない**

---

## 8. ファイル構成 / ビルド

```
css/
  sass/
    _color.scss     ← ブランド色定義
    _define.scss    ← 色・フォント・mixin
    _default.scss   ← レイアウト幅・基本mixin
    _import.scss    ← 共通import
    [page].scss     ← ページ別
  [page].css        ← ↑からコンパイル
  custom.css        ← SCSS触れない時の上書き専用(緊急用)
sass.bat            ← コンパイルスクリプト
```

### ルール
- **修正は必ず `.scss` 側のみ**。コンパイル済み `.css` を直接編集しない
- **コンパイルの実行はプロジェクトの運用に従う**（詳細は [.claude/rules/scss-autocompile.md](.claude/rules/scss-autocompile.md)）
  - **自動コンパイル環境が有効なら**：AIが `.scss` を編集した時点でフックが `.css` を自動生成する。コンパイル依頼は不要で、AIは生成結果（表示／差分）で確認する
  - **環境が無ければ（フォールバック）**：AIは手動で `sass.bat` 等を叩かず、`.scss` を編集したら「開発者側で `sass.bat` を実行してコンパイルしてください」と報告する。動作確認が必要な場合もコンパイル待ちである旨を明示する
- `.scss` が触れない緊急時のみ `custom.css` に追記(コメントで日付と理由を書く)。この場合はコンパイル不要
- 新規ページは `_import.scss` 経由で共通変数を読み込む

---

## 9. Do / Don't(AIに守ってほしいこと)

### ✅ Do
- 既存の SCSS 変数・ユーティリティクラスをまず探す
- 色を増やしたくなったら、本ファイルの近い色に寄せる
- ブレークポイントは 768px のみ
- `1rem = 1px` 換算で書く(`14rem` = 14px)
- PHP テンプレート (`$m_tpl->Header()` 等)を使う
- **CSS の修正は `.scss` ファイルのみを編集する**

### ❌ Don't
- グラデーション・ネオモーフィズム・ガラスモーフィズム等のトレンド装飾を勝手に持ち込まない
- ダークモードを勝手に追加しない(現状未対応)
- Tailwind / Bootstrap ユーティリティクラスを新規導入しない(現状の Bootstrap は古いLP用のみ)
- 1000px グリッドを崩さない
- `<strong>` のデフォルト黄マーカーが効くので、見出しに `<strong>` を入れない
- CSS変数(`--var`)を勝手に導入しない(SCSS変数で統一中)
- `!important` を新規で書かない(既存の上書きが必要なら SCSS の specificity で対処)
- `rem` 値を 16px換算で書かない(このサイトは 1rem = 1px)
- **コンパイル済みの `.css` ファイルを直接編集しない**(`.scss` を編集する。自動コンパイル環境でも不変)
- **`sass.bat` などのコンパイルコマンドを AI が手動で実行しない**。コンパイルは **自動環境ならハーネスのフック**・無ければ **開発者** が行う([scss-autocompile.md](.claude/rules/scss-autocompile.md))

---

## 10. 今後の課題(TODO)

このセクションは育てていく欄。

- [ ] 緑色のバリエーション(`#7bc146`, `#91C16D`, `#3e635a` 等)を `$brand-primary` 4色に段階的に統合
- [ ] `_color.scss` と `_define.scss` で重複している変数(`$color_main` / `$clr_main`)の一本化
- [ ] スマホ表示の文字サイズ最終確定(現状 px と rem が混在)
- [ ] アクセシビリティ監査(コントラスト・キーボード操作)

---

最終更新: 2026-05-19
