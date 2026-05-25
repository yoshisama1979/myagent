# 開発環境セットアップルール

このファイルは**プロジェクトの初回セットアップ時のみ参照**する。一度設定すれば以降は読み込む必要はない。

## SCSS 自動コンパイル環境（必須）

VS Code 拡張の **Live Sass Compiler** を使用してファイル監視・自動コンパイルを行う。

- ユーザー・AI いずれの編集にも反応してコンパイルされる
- VS Code のステータスバーから「Watch Sass」をクリックして監視を開始する
- 対象ファイル: `public/css/users/sass/*.scss`, `public/css/admin/sass/*.scss`
