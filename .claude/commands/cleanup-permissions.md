.claude/settings.local.json の permissions.allow リストを整理してください。

## 手順

1. 現在の settings.local.json を Read で読み込む
2. allow リストの各エントリを分析し、以下の汎用パターンでカバーできるものを特定する
3. 汎用パターンに集約し、個別エントリを削除する
4. additionalDirectories も重複を除去して整理する
5. **Edit ツール（Write ではなく）で差分のみ更新する**

## 汎用パターン（これらは維持すること）

```
Read(///wsl.localhost/Ubuntu/**)
Read(///wsl$/Ubuntu/**)
Read(//mnt/**)
Read(//c/Users/yoshi/**)
Bash(wsl -e bash -c *)
Bash(wsl -d:*)
Bash(wsl ls:*)
Bash(docker exec:*)
Bash(xargs grep:*)
Bash(git -C *)
```

## ルール

- 上記パターンでカバーできる個別エントリは削除する
  - 例: `Bash(wsl -e bash -c "cd /home/yoshi/project/earthraise && git diff --staged")` → `Bash(wsl -e bash -c *)` でカバー済み → 削除
  - 例: `Read(///wsl.localhost/Ubuntu/home/yoshi/project/earthraise/src/**)` → `Read(///wsl.localhost/Ubuntu/**)` でカバー済み → 削除
- 上記パターンでカバーできない独自のエントリは残す
- additionalDirectories は `\\\\wsl.localhost\\Ubuntu\\home\\yoshi\\project\\earthraise` 配下のみに統一する（`\\home\\...` の重複パスは削除）
- 整理後の結果を報告する（削除数・残存数）

## 安全性チェック（集約時に必ず確認）

集約によって意図しない権限が付与されないか、以下を確認してユーザーに報告すること。

### 危険なパターン（集約してはいけない）

| パターン | リスク |
|---|---|
| `Bash(*)` | 全コマンド許可 — 絶対に使わない |
| `Bash(rm *)` / `Bash(sudo *)` | 破壊的操作の許可 |
| `Read(**)` | ファイルシステム全体の読み取り許可 |
| `Write(**)` / `Edit(**)` | 全ファイルへの書き込み許可 |

### 集約時の確認事項

- **Bash の範囲**: `Bash(wsl -e bash -c *)` はWSL経由の全コマンドを許可する。プロジェクト外のファイル操作（`rm -rf /` 等）も技術的には可能。この許可は作業効率のために許容しているが、リスクがあることを認識しておく
- **Read の範囲**: `Read(///wsl.localhost/Ubuntu/**)` はWSL上の全ファイル読み取りを許可する。他プロジェクトの機密ファイルも読める点に注意
- **新しいパターンの追加**: 汎用パターンに含まれない新しいカテゴリのエントリがある場合、そのまま集約せずユーザーに「このパターンを追加してよいか」確認する

### 報告フォーマット

整理結果に加えて、以下を報告すること：
- 現在の許可範囲で潜在的にリスクがあるパターン（あれば）
- 新たに発見された、汎用パターンに含まれないエントリの一覧
