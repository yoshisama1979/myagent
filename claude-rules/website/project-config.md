# project-config.md

> このプロジェクト固有の定義（サイト名・ディレクトリ構成・デプロイ先・公開URL・ブランチ運用・固有の値など）の置き場。各開発エージェントが記入する。
> **テンプレートをコピーしたら、まずここを記入する**。各ルールファイルは固有値を本文に持たず、このファイルを参照する。

## 基本（`CLAUDE.md` / 各ルールが参照）

- サイト名／クライアント名：（記入。例: 株式会社サンプル コーポレートサイト）
- プロジェクトルート：（記入。例: c:/xampp/htdocs/example）
- ディレクトリ構成の要点：（記入。例: HTML直下＋`css/sass/`＋`images/`、共通部品は `include/`）
- 公開URL：（記入。例: https://www.example.com/）
- デプロイ先・手順：（記入。例: FTPで本番へ手動アップ／開発者が実施。AIはデプロイしない）
- ブランチ運用：（記入。例: main 直コミット／feature ブランチ運用）

## 環境（`.claude/rules/scss-autocompile.md` / `.claude/commands/cleanup-permissions.md` が参照）

- OS・開発環境：（記入。例: Windows + XAMPP）
- SCSS自動コンパイル環境の有無：（記入。あり=フック方式／なし。`.claude/rules/scss-autocompile.md` が参照）
- コンパイル手段：（記入。例: standalone dart-sass ／ sass.bat ／ 開発者依頼）
- コンパイル済み `.css` をコミットに含めるか：（記入。既定: 含めない。`staging.md`／`commit-pipeline.md` が参照）

## 資産の癖（`rules/modes/refactor.md` / `rules/modes/page-build.md` が参照）

- レガシー・バックアップファイルの命名パターン：（記入。例: `*_org.html` `*.BAK` `index_2017*.html`。`rules/modes/refactor.md` が「触らない対象」の判定に参照）
- 共通テンプレート機構：（記入。例: PHP インクルード・テンプレートクラス。`rules/modes/refactor.md`／`rules/modes/page-build.md` が共通化の判定に参照）

## スライド資料（デッキ）（`rules/modes/deck-format.md` が参照）

- **出力先**: （記入。既定: `documents/decks/<案件名>/`。変える場合のみ記入）
- **Chrome 実パス**: （記入。例: `/usr/bin/google-chrome`／`C:\Program Files\Google\Chrome\Application\chrome.exe`）

## HP分析ループ連携（`rules/modes/mailbox.md` / `rules/modes/hp-loop-dialogue.md` が参照）

> 外部の「はなさかAI HP分析ループ」とサイト別にやり取りするための固有ID。ループはマルチサイト化で `hp-loop-<site>` に分かれており、**無印 `hp-loop` 宛では現行ループが拾えない**。各サイトで下記を記入する。
>
> ⚠️ **未記入のまま放置しない**：ここが空欄だと、開発エージェントは報告の宛先（`hp-loop-<site>`）を確定できずメールボックス送信が成立しない（[rules/modes/mailbox.md](rules/modes/mailbox.md) §2 が「未記入なら社長に確認」と指示する）。このマシンの担当サイトが決まったら**最初に埋める**。

- サイト識別子 `<site>`：（記入。例：ycom / yoshida / fujisaka）
- 対になる分析ループのID（報告の宛先）：（記入。`hp-loop-<site>` 形式。例：hp-loop-ycom）
- 自分（実装エージェント）のID：（記入。例：web-hanasaka。※ mailbox の `from` はトークンから決まるので参考値）
