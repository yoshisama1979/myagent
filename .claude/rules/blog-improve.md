# ブログ既存記事改善モード — 動作ルール

> **version 0.1**（2026-06-23・初版）｜ changelog はファイル末尾。
> このモードは **使いながら育てる**。気づきは `data/hp-improve/skill-kaizen.md` に溜める。

このファイルは、**ブログ分析ループ（`/blog-loop`）が出した「既存記事の改善 `B-NNN`」に対応し、既存の公開記事の改善版を"下書き複製"として作る** 実行モードの **手順・制約・出力・自己チェック** を定義する。

`/blog-improve <client>` スラッシュコマンドから呼ばれる（`/blog-write` の兄弟＝新規記事ではなく**既存記事の改善**側。`/loop`・cron で別時刻に回す）。
土台は CLAUDE.md と [rules/automation.md](../../rules/automation.md)（**衝突したら automation.md 最優先**）。

---

## ⚑ 位置づけ（blog-write の兄弟・最初に把握）

- 診断は **blog-loop が B/T 両方**を出す（共通）。実行を2本に分ける：**blog-write＝新規記事(T)**／**本モード blog-improve＝既存記事の改善(B)**。
- **公開境界の本質的な違い**：新規(T)は「まだ無い記事の下書き」を作る＝低リスク。既存(B)は**公開中の本番記事**が対象＝高リスク。よって本モードは「**既存の公開記事を一切編集しない**」を絶対原則とする（社長決定 2026-06-23）。
- **適用モデル＝「下書き複製」**：元の公開記事は **読み取り専用(`wp-draft.py get`)** で読むだけ。改善版は **別の新規下書き**として作成/更新し（`wp-draft.py post`／`update`）、**社長・web-hanasaka が見比べて手動で本番記事に反映**する（AIは本番記事に書き込まない）。
- **重複定義しない**：安全＝automation.md、読みやすさ・執筆品質＝[blog-write.md](blog-write.md)（表組み・無機質禁止 等）、評価観点＝[hp-improve.md](hp-improve.md)、クライアント固有値＝`data/blog-loop/clients/<client>.md`、診断の B-NNN ＝blog-loop 掲示板。本ファイルは **既存記事改善の実行**固有だけを定義する。

## ⚑ マルチクライアント読み替え

`/blog-improve <client>` でクライアント別に動く。`data/blog-loop/config.md`＋`clients/<client>.md` を読んで固有値を確定。読み替え表：

| 表記 | 読み替え |
|---|---|
| 入力（改善提案） | blog-loop 掲示板 `site/hp-analysis/<client>/blog/index.html` の `B-NNN`（＋ `from-president.md`） |
| 改善版ドラフト出力先 | `site/drafts/blog/<client>/improve/`（ローカル草案）＋ WP の**改善版下書き**（元記事とは別の post） |
| 対応ログ | `data/blog-loop/<client>/improve-log.md`（B-NNN／元記事post id／改善版draft id／状態） |

---

## 公開の境界（絶対原則）

| 操作 | 可否 |
|------|------|
| 元の公開記事を `wp-draft.py get`（GET・読み取り）で読む | ✅ 可（改善の素材） |
| 改善版を**新規下書き**として作る `wp-draft.py post`（status=draft） | ✅ 可（元記事とは別の post） |
| 自分が作った**改善版下書き**を `wp-draft.py update --id <改善版draft id>` で更新 | ✅ 可（draft限定ガードあり） |
| **元の公開記事（post）を編集・上書き・公開状態変更** | **❌ 絶対不可**。`update` に**元記事の id を渡さない**（渡しても draft でないため tool 側で拒否されるが、運用上も渡さない） |
| 本番記事の公開・削除 | ❌ 不可（公開も差し替えも人間） |

> 二重の安全：①ルールで「元記事idをupdateに渡さない」②`wp-draft.py update` は対象が draft のときだけ実行（公開済みは拒否）。改善版は常に別draftなので、元の公開記事は不変。

---

## 厳守する制約

| 操作 | 可否 |
|------|------|
| Read / Grep / Glob / git status・log・diff | ✅ 可 |
| blog-loop 掲示板・from-president・clients/<client>.md・improve-log を読む | ✅ 可（入力） |
| `wp-draft.py get`（元記事の読み取り）／`curl`・`hp-audit`（読み取り） | ✅ 可 |
| Write: `site/drafts/blog/<client>/improve/`（改善版ローカル草案） | ✅ 可 |
| Write: `data/blog-loop/<client>/improve-log.md`（対応ログ） | ✅ 可 |
| `wp-draft.py post`／`update --id <改善版draft>`（改善版下書きの作成/更新） | ✅ 可（status=draft 専用・公開しない） |
| **元の公開記事の編集・公開・削除** | ❌ 絶対不可 |
| 固有事実（料金・実績数値・お客様の声）の創作 | ❌ 不可（`【要・社長確認：…】` で要求） |
| `from-president.md`・blog-loop 掲示板の編集 | ❌ 不可（責務分離。対応の事実は improve-log と報告で渡す） |
| 外部送信・`.env`実値の表示・git commit/push | ❌ 不可（automation.md・社長判断） |

---

## 手順（1サイクル）

### Step 0: 前提読み込み
1. `data/blog-loop/config.md`＋`clients/<client>.md` を読む。**未登録なら報告して終了**。
2. blog-loop 掲示板の未完了 `B-NNN`（🔧進行中）を把握。`from-president.md`（優先・回答済み事実）を読む。
3. `data/blog-loop/<client>/improve-log.md`（あれば）を読み、**対応済み・進行中を二重に作らない**。

### Step 1: 対象 B を選ぶ
- 社長の優先指示があれば従う。無ければ blog-loop の優先度（🔴→🟡）順に **1サイクル 1〜2件**（やり過ぎない）。
- 対象記事の **post id** を確定（GSC/掲示板の URL `…?p=NNNN` の NNNN ＝ post id）。

### Step 2: 元記事を読む（読み取り専用）
- `bin/wp-draft.py get --client <client> --id <元記事post id>` で現行の title・本文（raw）を取得。必要なら GSC（`gsc-fetch.py`）で当該記事の順位・CTR・獲得クエリを確認し、「何を直すと効くか」を事実で裏取り（惜しい順位/低CTR/鮮度落ち）。

### Step 3: 改善版を作る（本文まで・表組みで読みやすく）
- B-NNN の改善内容を適用：title/meta の改善・検索意図に不足した見出しの追記・内部リンク（受け皿ページへ）・鮮度更新・**表組みで読みやすく**（[blog-write.md](blog-write.md)「読みやすさの作り込み」を流用＝箇条書き羅列にしない）。
- 元の良い部分は活かす（全書き換えにしない）。固有事実は `【要・社長確認：…】`。
- ローカル草案 `site/drafts/blog/<client>/improve/<slug>.html` に保存（元記事ID・狙うクエリ・**変更点サマリ**＝何をどう直したか、をメタに明記）。

### Step 4: 改善版を「下書き複製」としてWPに反映
- improve-log にこの B（元記事）の**改善版draft id** が無ければ `wp-draft.py post`（新規下書き作成）。**タイトル先頭に「【改善版】」**等を付け、元記事と区別（誤公開・取り違え防止）。返ってきた id を improve-log に記録。
- 既にあれば `wp-draft.py update --id <改善版draft id>`（同じ改善版下書きを更新）。**元記事の id は絶対に使わない**。
- creds/許可未整備なら投稿せず「保留」と明示（捏造・空振りしない）。

### Step 5: 報告
- 社長に1〜3行：対応した `B-NNN`・元記事URL・**改善版下書きのプレビューURL**・変更点の要約・「見比べて手動で本番反映してください」。Slack日報は `post --as blog-loop-<client>`（同じブログスレッドに相乗り。鳴らしすぎない）。
- 停止条件：対象未確定／事実待ち／社長の停止指示 → 一旦停止。

### Step 6: 自己改善（軽く）
- 「今回足りなかったものは？」を `data/hp-improve/skill-kaizen.md` に1行（無ければ「特記なし」）。

---

## 出力フォーマット（改善版ローカル草案 + WP改善版下書き）

改善版草案 `site/drafts/blog/<client>/improve/<slug>.html`：
- **メタ**：対応 `B-NNN`／元記事URL・post id／狙うクエリ／**変更点サマリ**（before→after の要点）／`【要・社長確認】`の事実
- **改善後の本文**（WordPress 貼り付け想定の素直なHTML・表組みで読みやすく）

WP には「【改善版】<元タイトル>」等の区別できるタイトルで `status=draft` 投稿。**元記事は不変**。

---

## やってはいけないこと

| NG | なぜ |
|----|------|
| ❌ 元の公開記事を編集・上書き・公開状態変更 | 本番記事を来訪者が見ている。改善は別draftで作り人間が反映 |
| ❌ `update` に元記事の post id を渡す | 元記事を触る行為。改善版draftのidだけ使う（toolも公開済みは拒否） |
| ❌ 固有事実の創作 | 捏造禁止。`【要・社長確認】`で要求 |
| ❌ 全書き換えで元の良さを壊す | 改善であって作り直しではない |
| ❌ 箇条書きの羅列で無機質 | 表組み・構造変化で読みやすく（blog-write 流用） |
| ❌ from-president/掲示板の編集・本番公開・外部送信を合意なく | 責務分離・automation.md |

---

## 自己チェック（改善版を出す前に）
- [ ] config/掲示板(B)/from-president/improve-log を読んだか？二重作成していないか？
- [ ] 元記事を `get` で読んでから改善したか？（現状を見ずに直さない）
- [ ] **元記事の id を編集系に渡していないか？** 改善版は別draftか？
- [ ] 固有事実を創作せず `【要・社長確認】` にしたか？表組みで読みやすくしたか？
- [ ] 変更点サマリ（before→after）を明記したか？
- [ ] improve-log に B-NNN／元記事id／改善版draft id／状態を記録したか？
- [ ] 本番記事の編集・公開・外部送信をしていないか？
- [ ] 編集ファイルを回答末尾に markdown リンクで一覧表示したか？

すべて ✅ なら出力、1つでも ❌ なら見直し。

---

## 変更履歴
| version | 日付 | 内容 |
|---------|------|------|
| 0.1 | 2026-06-23 | 初版。blog-write の兄弟＝既存記事改善(B)の実行モード。適用モデル＝「下書き複製」（元の公開記事は読み取りのみ・改善版は別draftで作成/更新・人間が手動で本番反映）。`wp-draft.py get`(読取)を追加。読みやすさ・品質は blog-write を流用 |
