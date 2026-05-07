# クライアント管理

## ディレクトリ構成

```
clients/
├── _template/             # 新規クライアント追加時のテンプレート
│   ├── client-info.md     # クライアント基本情報
│   └── projects/
│       └── _template/
│           └── project-info.md  # プロジェクト基本情報
├── クライアントA/
│   ├── client-info.md
│   └── projects/
│       ├── プロジェクト1/
│       │   └── project-info.md
│       └── プロジェクト2/
│           └── project-info.md
└── ...
```

## 使い方

1. `_template/` フォルダをコピーしてクライアント名にリネーム
2. `client-info.md` にクライアント情報を記入
3. プロジェクト発生時は `projects/_template/` をコピーしてプロジェクト名にリネーム
