# プロジェクト記録フォーマット（HTML）

本プロジェクトの **記録ファイル**（`backlog` / `decisions` / `project-info` / `client-info` / `memo` / `meeting-notes/*` / `notes`）は **HTML5 + Tailwind CSS（CDN参照）** で記述する。

ルール対象外（Markdown 維持）：
- `rules/*.md`（AIが参照する内部ルール）
- `CLAUDE.md`（プロジェクト指示）
- `.claude/commands/*.md`（スキル）
- `README.md`（GitHub等で表示するメタ情報）

## 配置場所と拡張子

メモ運用ルール（`rules/memo.md`）の 4 ファイル構成・配置はそのまま、拡張子のみ `.md` → `.html` に置き換える。

```
clients/<クライアント名>/client-info.html
clients/<クライアント名>/projects/<プロジェクト名>/backlog.html
clients/<クライアント名>/projects/<プロジェクト名>/decisions.html
clients/<クライアント名>/projects/<プロジェクト名>/project-info.html
clients/<クライアント名>/projects/<プロジェクト名>/memo.html
clients/<クライアント名>/projects/<プロジェクト名>/meeting-notes/YYYY-MM-DD.html
notes.html                                    （プロジェクト横断メモ）
```

## ページのフォーマット

- **HTML5** 形式で記述する（Markdownは使わない）
- **言語属性**：`<html lang="ja">`
- **文字コード**：UTF-8
- スタイリングは **Tailwind CSS（CDN参照）**
  - `<head>` に `<script src="https://cdn.tailwindcss.com"></script>` を入れる
  - ビルド作業不要、ブラウザで直接開けることが必須要件
- テンプレート: `clients/_template/` 配下のHTMLファイルをコピーして開始する

## ページ構造（必須要素）

各記録ページは以下の要素を持つ：

| 要素 | 用途 |
|------|-----|
| `<h1>` ページタイトル | ファイル種別＋対象プロジェクトを明記（例：「残存課題 — HANAツール」） |
| 概要文（`<p>`） | 1〜2文でファイルの目的を説明 |
| セクション見出し `<h2>` → サブ `<h3>` | 階層構造で整理 |
| 表示項目は `<table>` または `<ul>` | スキャンしやすく |
| 操作フロー・手順は `<ol>` | 番号付きリスト |
| 関連リンク節 | 末尾に他ファイル（同プロジェクト内）への相互リンク |

## デザイン規約（Tailwind クラス）

### コンテナ

```html
<body class="bg-gray-50 text-gray-900">
  <div class="max-w-4xl mx-auto p-6 md:p-10">
    ...
  </div>
</body>
```

### 見出し

| 要素 | クラス |
|------|-------|
| `<h1>` | `text-3xl font-bold mb-2` |
| `<h2>` | `text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10` |
| `<h3>` | `text-lg font-semibold mb-3 mt-6` |

### テーブル

```html
<table class="w-full border-collapse text-sm mb-6">
  <thead>
    <tr class="bg-gray-100">
      <th class="text-left px-3 py-2 border border-gray-200 font-semibold">項目</th>
      <th class="text-left px-3 py-2 border border-gray-200 font-semibold">内容</th>
    </tr>
  </thead>
  <tbody>
    <tr><td class="px-3 py-2 border border-gray-200">...</td><td class="px-3 py-2 border border-gray-200">...</td></tr>
  </tbody>
</table>
```

### 状態・カテゴリ別の強調

| 種別 | クラス |
|------|-------|
| 注意・未確認 | `bg-yellow-50 border-l-4 border-yellow-400 p-4 my-4` |
| 補足・参照 | `bg-blue-50 border-l-4 border-blue-400 p-4 my-4` |
| 確定事項 | `bg-green-50 border-l-4 border-green-400 p-4 my-4` |
| 不具合・要対応 | `bg-red-50 border-l-4 border-red-400 p-4 my-4` |

### チェックボックス（backlog 用）

完了状態は記号で示す（インタラクティブにしない）：

```html
<ul class="space-y-2">
  <li class="flex items-start gap-2">
    <span class="text-gray-400">☐</span><span>未着手項目</span>
  </li>
  <li class="flex items-start gap-2">
    <span class="text-green-500">☑</span><span class="line-through text-gray-500">完了項目</span>
  </li>
</ul>
```

### 取り消し線

`<s>` または `<span class="line-through text-gray-500">` を使う。

### コード・ファイルパス

インラインは `<code class="bg-gray-100 px-1 rounded text-sm font-mono">backlog.html</code>`

### 相互リンク

```html
<a href="decisions.html" class="text-blue-600 hover:underline">decisions.html</a>
```

## ページ間リンク

HTMLの利点を活かし、関連ページは積極的にリンクで接続する：

- `backlog.html` → `decisions.html`（仕様の参照）
- `decisions.html` → `meeting-notes/YYYY-MM-DD.html`（決定の出典）
- `meeting-notes/YYYY-MM-DD.html` → 展開先の `backlog.html` / `decisions.html`
- `notes.html` → 該当プロジェクトの `backlog.html` / `decisions.html`

## インデックスページ（index.html）

各階層に **`index.html`** を置き、その階層の全ファイル・サブディレクトリへのリンクを集約する。リンクをたどるだけで全記録に到達できる状態を維持する。

### 階層と配置

```
index.html                                               … プロジェクト全体の入口
├── notes.html
└── clients/
    ├── index.html                                       … 全クライアント一覧
    └── <クライアント名>/
        ├── index.html                                   … クライアント単位の入口
        ├── client-info.html
        └── projects/
            └── <プロジェクト名>/
                ├── index.html                           … プロジェクト単位の入口
                ├── project-info.html
                ├── backlog.html
                ├── decisions.html
                ├── memo.html
                └── meeting-notes/
                    ├── index.html                       … 打ち合わせメモ一覧
                    └── YYYY-MM-DD.html
```

### index.html の必須要素

- **パンくず**（ルート以外）：`<a href="../index.html">← 親階層</a>` 形式で親階層へ戻れる
- **タイトル**（h1）：階層名（例：「カバーオールオーナーズクラブ」「コーポレートサイト制作」）
- **概要**：その階層が何を含むかを1〜2文で説明
- **リンク一覧**：その階層の全ファイル・サブディレクトリへのリンク（カード or リスト）
  - 各リンクには簡潔な説明を添える

### 更新タイミング

- 新規ファイル・ディレクトリを追加したら **必ず該当階層の index.html を更新**
- 削除した場合も同様に index.html から除外

## レビュー観点

ファイルを作成・更新した際は以下を確認：

- ブラウザで開いて表示崩れがないか（Tailwind が読まれているか）
- リンク切れがないか（`<a href="...">` のパスが正しいか）
- 内容が記録ルール（`rules/memo.md`）に沿っているか（backlog ＝ 残存課題、decisions ＝ 確定事項）

## 例外

- **AI内部処理のメモは Markdown のまま**（`rules/*.md`、`CLAUDE.md`、`.claude/commands/*.md`）
- ルール対象は **人間が見る記録ファイル** に限る
