# クライアント管理

## ディレクトリ構成

```
clients/
├── _template/                          # 新規クライアント追加時のテンプレート
│   ├── client-info.html                # クライアント基本情報
│   └── projects/
│       └── _template/
│           ├── project-info.html       # プロジェクト基本情報
│           ├── backlog.html            # 残存課題
│           ├── decisions.html          # 決定事項・確定仕様
│           ├── memo.html               # 雑記帳（無指示時のメモ）
│           └── meeting-notes/
│               └── _template.html      # 打ち合わせメモのテンプレート
├── クライアントA/
│   ├── client-info.html
│   └── projects/
│       ├── プロジェクト1/
│       │   ├── project-info.html
│       │   ├── backlog.html
│       │   ├── decisions.html
│       │   └── meeting-notes/
│       │       └── YYYY-MM-DD.html
│       └── プロジェクト2/
│           └── project-info.html
└── ...
```

## 使い方

1. `_template/` フォルダをコピーしてクライアント名（英小文字＋ハイフン）にリネーム
2. `client-info.html` にクライアント情報を記入
3. プロジェクト発生時は `projects/_template/` をコピーしてプロジェクト名にリネーム
4. 必要に応じて `backlog.html` / `decisions.html` / `meeting-notes/` を活用

## ファイルフォーマット

- 全ての記録ファイルは **HTML5 + Tailwind CSS（CDN参照）** で記述（ブラウザで直接開ける）
- 詳細は `rules/document-format.md` 参照
- メモ運用ルールは `rules/memo.md` 参照
