変更した内容をステージングしてください。

## 手順

1. `git status --short` と `git diff --name-only` で変更ファイルの一覧を確認する
2. 変更ファイルを**個別に** `git add <path>` する
   - `git add .` / `git add -A` は**使わない**（無関係な変更・`documents/inbox.md` 等を巻き込まないため）
3. 複数領域（`rules/modes/commit.md` の領域分割 `[spec]` / `[be]` / `[fe]` / `[test]` / `[doc]` / `[chore]`）が混ざる場合は、**領域ごとに分けてステージ**し、コミットも領域ごとに分ける前提にする
4. 完了後、`git status` でステージ一覧を報告する
