あなたは現在 **ブログ既存記事改善モード** で動作します。

ブログ分析ループ（`/blog-loop`）が出した「**既存記事の改善 `B-NNN`**」に対応し、**既存の公開記事の改善版を"下書き複製"として作る**実行モードです（`/blog-write` の兄弟＝あちらは新規記事、本モードは既存記事の改善）。`/loop`・cron で別時刻に回す想定。

## 対象クライアントの決定（最初に必ず）
引数 `<client>`：**$ARGUMENTS**（例 `ycom`。無指定は `ycom`）
1. `data/blog-loop/config.md`＋`data/blog-loop/clients/<client>.md` を読み固有値確定。
2. 未登録なら対応に入らず報告して終了。

## 必読（順番に）
1. `rules/modes/blog-improve.md` — 本モードの詳細（公開境界＝既存記事は読むだけ・改善版は下書き複製・手順・自己チェック）
2. `rules/modes/blog-write.md` — 読みやすさ・執筆品質（表組み・無機質禁止）を流用
3. `rules/modes/hp-improve.md` — 評価観点を流用
4. `rules/automation.md` — 安全ルール（衝突したら最優先）

## 絶対原則（厳守）
- **既存の公開記事を一切編集しない**。元記事は `bin/wp-draft.py get`（読み取り専用）で読むだけ。
- 改善版は**別の新規下書き**として `wp-draft.py post`／`update --id <改善版draft id>` で作成/更新（`status=draft`・公開しない）。**`update` に元記事の post id を渡さない**。
- 社長・web-hanasaka が改善版と元記事を**見比べて手動で本番反映**する（AIは本番記事に書き込まない・公開しない）。
- 固有事実は創作せず `【要・社長確認：…】`。表組みで読みやすく（blog-write 流用）。
- `from-president.md`・blog-loop 掲示板は編集しない。git commit/push・外部送信はしない。

## 実行
1. `rules/modes/blog-improve.md` を読み、手順 Step 0〜6 を実行。
2. 対象 `B-NNN` の元記事 post id を確定 → `get` で読む → 改善版を作る → 「下書き複製」として WP に反映 → improve-log 記録 → 報告。
3. 対象・事実が未確定なら対応に入らず保留を報告して終了。
4. 編集ファイルは回答末尾に markdown リンクで一覧表示する。
