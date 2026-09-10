> 🚨 **`project-config.md`「エージェント構成」で 2セッション構成を `使う` 場合、このコマンドは開発セッション（`/dev`）で実行する。** 統括セッションは `git add` / `commit` / `push` を行わない（`rules/modes/director.md` §7 ＝ Autopilot の安全装置がコミットを開発側に前提しており、2つのウィンドウが同時に `git add` すると index が競合する）。統括セッションで呼ばれたら、実行せず**開発セッションで回すよう案内する**。`使わない`（既定）＝1セッション運用なら、この制限は適用されない。

変更した内容をステージングしてください。

## 手順

1. `git status --short` と `git diff --name-only` で変更ファイルの一覧を確認する
2. 変更ファイルを**個別に** `git add <path>` する
   - `git add .` / `git add -A` は**使わない**（無関係な変更・`documents/inbox.md` 等を巻き込まないため）
3. 複数領域（`rules/modes/commit.md` の領域分割 `[spec]` / `[be]` / `[fe]` / `[test]` / `[doc]` / `[chore]`）が混ざる場合は、**領域ごとに分けてステージ**し、コミットも領域ごとに分ける前提にする
4. 完了後、`git status` でステージ一覧を報告する
