`.claude/settings.local.json` の `permissions.allow` リストを整理してください。
このプロジェクトは **Windows + XAMPP** 環境のウェブサイト制作プロジェクト。

## 手順

1. 現在の `.claude/settings.local.json` を Read で読み込む
   (存在しない場合は「整理対象なし」と報告して終了)
2. `allow` リストの各エントリを分析し、以下の汎用パターンでカバーできるものを特定する
3. 汎用パターンに集約し、個別エントリを削除する
4. `additionalDirectories` も重複を除去して整理する
5. **Edit ツール(Write ではなく)で差分のみ更新する**

## 汎用パターン(これらは維持・推奨)

ウェブサイト制作で典型的に必要になるパターン:

```jsonc
// ファイルアクセス(プロジェクト配下)
"Read(c:/xampp/htdocs/**)"
"Read(C:/xampp/htdocs/**)"

// git 系
"Bash(git status:*)"
"Bash(git diff:*)"
"Bash(git log:*)"
"Bash(git add:*)"
"Bash(git commit:*)"
"Bash(git show:*)"

// ディレクトリ・ファイル確認
"Bash(ls:*)"
"Bash(dir:*)"

// PowerShell(Windows 標準)
"PowerShell(Get-ChildItem:*)"
"PowerShell(Get-Content:*)"

// 画像最適化系(使う場合)
"Bash(cwebp:*)"
"Bash(magick:*)"  // ImageMagick
```

## 含めてはいけないもの(Don't)

このプロジェクトでは AI 側で実行しない方針のもの:

- ❌ `Bash(sass:*)` `Bash(sass.bat:*)` — コンパイルは開発者が手動実施
- ❌ `Bash(npm:*)` `Bash(node:*)` — このプロジェクトでは Node.js を使わない
- ❌ `Bash(php:*)` — XAMPP の Apache 経由で動作確認するため AI 実行不要

将来 npm/Node 等が必要になった場合のみ、その時点でユーザー確認の上で追加する。

## ルール

- 上記の汎用パターンでカバーできる個別エントリは削除する
  - 例: `Bash(git status -uall)` → `Bash(git status:*)` でカバー済み → 削除
  - 例: `Read(c:/xampp/htdocs/ycom/css/sass/_color.scss)` → `Read(c:/xampp/htdocs/**)` でカバー済み → 削除
- 汎用パターンでカバーできない独自のエントリは残す
- `additionalDirectories` は `c:/xampp/htdocs/ycom` 配下のみに統一する
- 整理後の結果を報告する(削除数・残存数)

## 安全性チェック(集約時に必ず確認)

集約によって意図しない権限が付与されないか、以下を確認してユーザーに報告すること。

### 危険なパターン(集約してはいけない)

| パターン | リスク |
|---|---|
| `Bash(*)` | 全コマンド許可 — 絶対に使わない |
| `Bash(rm *)` / `Bash(del *)` | 破壊的操作の許可 |
| `Bash(git push:*)` | push の自動許可は **しない**(明示確認運用を維持) |
| `Bash(git reset --hard:*)` | 破壊的 git 操作 |
| `Read(**)` | ファイルシステム全体の読み取り |
| `Write(**)` / `Edit(**)` | 全ファイルへの書き込み |
| `Bash(c:/**)` 系の広範な実行 | プロジェクト外のスクリプト実行リスク |

### 集約時の確認事項

- **Read の範囲**: `Read(c:/xampp/htdocs/**)` は htdocs 配下の **全プロジェクト** を読み取り可にする。他サイトの機密情報が含まれる場合は `Read(c:/xampp/htdocs/ycom/**)` のように個別プロジェクトに絞ること
- **git push の扱い**: push は明示確認運用とする(CLAUDE.md の方針)。誤って `Bash(git push:*)` を許可リストに入れない
- **新しいパターンの追加**: 汎用パターンに含まれない新しいカテゴリのエントリがある場合、そのまま集約せずユーザーに「このパターンを追加してよいか」確認する

### 報告フォーマット

整理結果に加えて、以下を報告すること:

- 整理前のエントリ数 / 整理後のエントリ数 / 削除数
- 現在の許可範囲で潜在的にリスクがあるパターン(あれば)
- 新たに発見された、汎用パターンに含まれないエントリの一覧
