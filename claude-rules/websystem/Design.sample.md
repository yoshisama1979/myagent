# Design.md 記入例（Web システム / Next.js + Tailwind 想定）

> ⚠️ **これは「記入例（サンプル）」です。** 一般的な業務管理システム（Laravel + Next.js + Tailwind + shadcn/ui）を想定した見本。
> **各プロジェクトでは、このファイルを `Design.md` としてコピーし、自分のプロジェクトの値に置き換えて使ってください。**
> ここに並ぶ色 hex・フォント・ブレークポイント等は **説明用のプレースホルダ** であり、そのまま流用しないこと。
> デザイン規約の「汎用ルール（何を守るか）」と Design.md の扱い方は [.claude/rules/ui-design.md](.claude/rules/ui-design.md) を参照。

○○管理システムのデザインルール集。
**AIコーディングエージェント（Claude Code 等）と人間の両方が、UIを足し引きする前に必ず読むファイル。**

- 単一の真実の源（Single Source of Truth）はこのファイル
- このファイルと実装（tailwind.config / globals.css / components/ui）が食い違う場合 → **このファイルに揃えるよう実装を更新する**（漸進的に）
- 新しい画面・コンポーネントを作るときは、ここに無い概念を勝手に増やさない（増やす場合は先にここを更新）

---

## 1. Design Principles（設計思想）

1. **業務効率が最優先**
   毎日使う管理画面。装飾より、一覧性・操作の速さ・誤操作の防止を優先する。
2. **迷わせない一貫性**
   同じ目的の操作は常に同じ場所・同じ色・同じアイコン。画面ごとに流儀を変えない。
3. **状態が常に見えること**
   読み込み中・成功・失敗・未保存が一目で分かる。無言のUIを作らない。

---

## 2. Color Tokens（色）

実装は `tailwind.config.ts` の theme 拡張（または任意値）。**今後はこの表が正**。

### 2.1 プライマリ

| 用途 | Token | HEX |
|---|---|---|
| プライマリ（ボタン・リンク・アクション） | `primary` | `#2563EB` |
| プライマリ hover | `primary-hover` | `#1D4ED8` |
| プライマリ淡背景（選択行・バッジ） | `primary-light` | `#EFF6FF` |

### 2.2 セマンティック

| 用途 | Token | HEX |
|---|---|---|
| 成功（保存完了・有効） | `success` | `#16A34A` |
| 警告（注意・保留） | `warning` | `#D97706` |
| エラー（失敗・削除・必須） | `danger` | `#DC2626` |
| 本文 | — | `#111827`（`text-gray-900`） |
| サブテキスト | — | `#6B7280`（`text-gray-500`） |
| ボーダー | — | `#E5E7EB`（`border-gray-200`） |

### 2.3 アクセシビリティ

- 本文と背景のコントラスト比は **4.5:1 以上** を維持
- `primary` `#2563EB` は白文字ボタン背景として使用可（コントラスト比 4.5:1 以上）
- フォーカスリングは消さない（`focus:outline-none` を使うなら `focus:ring-2 focus:ring-primary` 等の代替を必ず置く）

---

## 3. Typography（タイポグラフィ）

- フォントファミリ: `Inter, "Noto Sans JP", sans-serif`（`font-sans` に設定済み）
- サイズは Tailwind の既定スケールを使う（任意値で中間サイズを作らない）：

| 用途 | クラス |
|---|---|
| 本文・フォーム | `text-sm` |
| 注釈・キャプション | `text-xs` |
| カード見出し・セクション小見出し | `text-base font-semibold` |
| ページタイトル | `text-2xl font-bold` |

- ウェイトは 400 / 500 / 600 / 700 のみ（Tailwind の `font-normal`〜`font-bold`）

---

## 4. Spacing & Layout（余白・レイアウト）

- スペーシングは Tailwind 既定スケール（4px 刻み）。推奨: `p-2 / p-4 / p-6`、セクション間 `space-y-6`
- コンテンツ最大幅: `max-w-7xl mx-auto px-4`
- ブレークポイント: Tailwind 既定（`md` 768px / `lg` 1024px）。**モバイルは1カラム、`md` 以上で分割** が基本形（`grid-cols-1 md:grid-cols-2`）
- 角丸: `rounded-md` で統一（カード・入力欄・ボタン）。`rounded-full` はアバター・バッジのみ

---

## 5. Components（コンポーネント）

実装は `components/ui/*`（shadcn/ui ベース）。**同等品を独自に作らない**。

| 種類 | 仕様 |
|---|---|
| プライマリボタン | `bg-primary text-white hover:bg-primary-hover`、`rounded-md px-4 py-2 text-sm` |
| セカンダリボタン | 白背景 + `border border-gray-300`、`text-gray-700` |
| 破壊ボタン（削除） | `bg-danger text-white`。**必ず確認ダイアログを挟む** |
| 入力欄 | `border rounded-md px-3 py-2 text-sm`。必須は label に赤い「*」 |
| テーブル | ヘッダ `bg-gray-50 text-xs text-gray-500`、行ホバー `hover:bg-gray-50`。一覧はソート・検索・ページネーションをセットで |
| 通知 | 共通 FlashMessage（成功=success / 失敗=danger）。独自トーストを増やさない |

---

## 6. Iconography & Imagery（アイコン・画像）

- アイコン: **lucide-react のみ**。サイズは `w-4 h-4`（ボタン内）/ `w-5 h-5`（単独）
- 操作とアイコンの対応を固定: 編集=`Pencil`、削除=`Trash2`、追加=`Plus`、検索=`Search`、閉じる=`X`
- アクションアイコンにはツールチップで補足を付ける
- 影は `shadow-sm`（カード）のみ。`shadow-lg` 以上はモーダル・ドロップダウン限定

---

## 7. Motion（モーション）

- トランジション: `transition-colors duration-150`（ホバー等）
- モーダル・ドロップダウンの開閉は shadcn/ui 既定のアニメーションに従う
- 装飾目的のアニメーション（パララックス・スクロール連動等）は導入しない

---

## 8. ファイル構成 / トークンの管理方式

```
next/
  tailwind.config.ts   ← カラートークン（theme.extend.colors）・フォント定義
  src/app/globals.css  ← ベーススタイル（最小限。ユーティリティで書けるものは書かない）
  src/components/ui/   ← 共通コンポーネント（shadcn/ui ベース。UIはここを踏襲）
```

### ルール

- 色は **theme 拡張のトークン名**（`bg-primary` 等）で使う。任意値（`bg-[#2563EB]`）の直書きはしない（トークン未整備の移行期のみ可・TODO に記録）
- `globals.css` にコンポーネント固有のスタイルを書かない（コンポーネント側のクラスで完結させる）
- ビルド生成物（`.next/` 等）は編集しない

---

## 9. Do / Don't（AIに守ってほしいこと）

### ✅ Do

- 既存の `components/ui/*` とトークンをまず探す
- 色を増やしたくなったら、本ファイルの近い色に寄せる
- 一覧画面はソート・検索・ページネーションをセットで（既存の一覧コンポーネントを踏襲）
- モバイルは1カラムに畳む（`grid-cols-1 md:grid-cols-2` の型）

### ❌ Don't

- グラデーション・ネオモーフィズム・ガラスモーフィズム等のトレンド装飾を勝手に持ち込まない
- ダークモードを勝手に追加しない（現状未対応）
- 別のUIライブラリ（MUI・Bootstrap 等）を勝手に混ぜない
- 任意値（`p-[13px]` / `text-[15px]`）で既定スケール外の値を作らない
- `!important`（`!` 修飾子）を新規で使わない
- 同じ目的の操作に画面ごとに違うアイコン・色を使わない

---

## 10. 今後の課題（TODO）

このセクションは育てていく欄。

- [ ] 旧画面に残る任意値カラー（`bg-[#3B82F6]` 等）を `primary` トークンへ段階的に統合
- [ ] FlashMessage の表示位置がページによって揺れている（統一方針の確定待ち）

---

最終更新: YYYY-MM-DD
