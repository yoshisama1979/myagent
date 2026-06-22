# SYSTEM — このシステムの「動くモードの地図」

> **統括者（overseer）が毎ループ冒頭に読む入口。** 変わりにくい**構造**だけをここに置く。
> 滞り・版ズレ・未回答などの**変わりやすい状態は保存しない**（統括者が都度生成する＝[.claude/rules/overseer.md](.claude/rules/overseer.md)）。
> 役割分担：`OVERVIEW.md`＝ディレクトリの地図／`AI-INDEX.md`＝site/中身の地図／**本ファイル＝動くモード同士の関係の地図**。
> version 0.1（2026-06-18）｜ changelog は末尾。

---

## このシステムの捉え方

はなさかの AI 作業環境は、いつの間にか **複数の半自律モードの集合体** になっている。
各モードは「一次情報源」「出力先」「承認ゲート」「対話相手」を持ち、**非同期チャネル経由で人やほかのエージェントと会話**して案件を前へ進める。
統括者の仕事は、このモード群が **整合して・滞りなく・安全に** 回るよう見張り、改善を**提案**すること（実装は各モード／社長判断）。

土台原則（迷ったらこの順）：
1. **[rules/automation.md](rules/automation.md) が最優先**（外部送信・書き込み・破壊的操作・秘密情報）。
2. CLAUDE.md の行動指針。
3. 各モードのルール。

横断する設計思想（全モード共通）：
- **核と肉付けの二層**：CLAUDE.md に最小の核、詳細は参照ファイルへ外出し（CLAUDE.md を太らせない）。
- **記録と反映の分離（reviewer 型）**：気づきは記録し、ルール/本体への反映は社長判断でまとめて行う。都度反映しない。
- **台帳を二重に持たない**：一次情報源は1つ。ダッシュボード等は都度生成の読み取りビューにする（保存版は腐る）。
- **責務分離**：社長の領域とAIの領域を混ぜない（例：hp-loop は from-president.md を読むだけ）。

---

## モード地図

| モード | 目的 | 起動 | 一次情報源（読む） | 出力先（書く・誰が） | 承認ゲート | 対話相手 | ルール（版） |
|--------|------|------|------------------|--------------------|-----------|---------|-------------|
| **Main（業務）** | 蓄積記録を運用・実装に反映 | 通常会話 | site/・data/・hana-tools | site/ 各所・コード | 外部送信/本番は社長 | 社長 | CLAUDE.md / rules/* |
| **Memo** | 断片メモを精度高く記録（一次入力） | `/memo` | 社長の口頭メモ | `site/notes.html`・`site/clients/*/memo.html`（AI追記のみ） | — | 社長 | [.claude/rules/memo.md](.claude/rules/memo.md) |
| **Reviewer** | プロジェクトを俯瞰レビュー→改善提案 | `/reviewer-cycle` | `ai-loop/scope.md`・`exclusions.md` | `ai-loop/conversation.md`（AIはこれ1ファイルのみ） | 実装は Dev/社長 | Dev AI（非同期） | [.claude/rules/reviewer.md](.claude/rules/reviewer.md) |
| **hp-improve** | クライアントHPの診断→改善（単発） | `/hp-improve` | 対象URL・hp-audit・GSC/GA4 | `site/drafts/`・`site/clients/*/`（合意後） | 本番改変/送信は社長 | 社長 | [.claude/rules/hp-improve.md](.claude/rules/hp-improve.md)（0.2） |
| **hp-loop** | HPを定期診断→提案→非同期会話（YCOM自社） | `/hp-loop`（+`/loop`） | `data/hp-loop/config.md`・`from-president.md`・hp-audit・GSC | `site/hp-analysis/ycom/index.html`（AIのみ）・`data/hp-loop/cycles/` | 本番改変/送信は社長 | 社長＋実装側エージェント（掲示板/mailbox 経由） | [.claude/rules/hp-loop.md](.claude/rules/hp-loop.md)（0.1） |
| **hp-reply** | 社長コメントを from-president.md へ代筆転記 | `/hp-reply` | 社長コメント | `data/hp-loop/from-president.md`（例外的に書込可） | — | 社長 | [.claude/commands/hp-reply.md](.claude/commands/hp-reply.md) |
| **task-partner（進行管理）** | ToDo駆動で案件の進行を管理・橋渡し | `/task-partner`（仮・未作成） | **hana-tools（ToDoが一次）** | `site/clients/*/`（補足追記）・`site/drafts/` | ToDo書込/通知/本番は社長 | 社長＋プロジェクト側エージェント | [.claude/rules/task-partner.md](.claude/rules/task-partner.md)（0.4） |
| **Overseer（統括）** | システム全体の整合・健全性を見張り改善提案 | `/overseer`（+`/loop`） | 本ファイル・各ルール・各掲示板・mailbox・git | `site/overseer/index.html`（AI追記・社長がWeb閲覧）・本ファイル保守（合意後） | ルール/本体改変は社長 | 社長 | [.claude/rules/overseer.md](.claude/rules/overseer.md)（0.1） |

> **claude-rules/ はこのシステムの対象外。** 弊社がクライアント向けに使う汎用 Claude ルールの置き場であり、上記モード群とは別物（混同しない）。
> **複数プロジェクトで共有・コピーして使う汎用テンプレ**なので、編集時は**固有値（エージェントID・サイト名・URL・DB名等）を本文に焼き込まず、各プロジェクトの `project-config.md` に置いて参照させる**（例：hp-loop 連携の宛先は `hp-loop-<site>` とし、実値は project-config.md。`hp-loop-ycom` 等を直書きしない）。

---

## ハンドオフ・トポロジ（誰がどのチャネルで非同期会話するか）

```
Memo ──(site/ memo追記)──▶ Main（後で運用反映）

Reviewer ⇄ Dev AI            … ai-loop/conversation.md（提案↔人判断↔実装）
hp-loop  ⇄ 実装側エージェント  … 掲示板 site/hp-analysis/ + from-president.md ＋ mailbox（社長が橋渡し）
task-partner ⇄ プロジェクト側 … hana-tools の ToDo（一次）＋ 社長橋渡し
全拠点エージェント間          … mailbox（VPS API・Tailscale・hold/=社長承認ゲート）

社長 = すべてのハブ。AIの提案は社長を介して相手へ渡り、報告は社長を介して戻る。
```

各「対話相手側ルール」（実装側の動き方）：HP は `claude-rules/website/.claude/rules/hp-loop-dialogue.md`。task-partner 相当は未整備（論点）。

---

## チャネル／一次情報の在処マップ

| チャネル | 実体 | 誰が書く | 性質 |
|---------|------|---------|------|
| 進行管理（案件タスク） | hana-tools API（`bin/hana-api.sh`） | 社長/システム（AI書込は合意後） | 一次台帳。site/に二重化しない |
| HP分析ループ会話 | `data/hp-loop/from-president.md`（社長）/ `site/hp-analysis/ycom/`（AI） | 役割で分離 | 責務分離 |
| Reviewer会話 | `ai-loop/conversation.md` | Reviewer提案・人判断 | append中心 |
| 拠点横断メッセージ | `data/mailbox/{new,cur,hold}/`（API: `site/tools/mailbox/`） | 各エージェント（append-only） | hold/=社長ゲート |
| 社長⇄エージェント（Slack双方向） | Slack専用チャンネル ⇄ `bin/slack-poll.py`（fetch/reply）⇄ mailbox。`data/slack/last-seen.json` で既読管理 | 社長(Slack)／エージェント(reply) | ループが各回 fetch。返信は元スレッドへ |
| メモ（横断/案件） | `site/notes.html` / `site/clients/*/memo.html` | Memo（追記のみ） | 履歴消さない |
| 統括所見 | `site/overseer/index.html`（統括レポート掲示板・Web閲覧） | Overseer（追記） | append・reviewer型 |

---

## ツール群（bin/・実行時は読み取り専用が原則）

| ツール | 用途 | 区分 |
|--------|------|------|
| `hana-api.sh` | hana-tools 連携（todos/projects/notes/clients/chatwork） | 読取✅／書込(create/update/chatwork)は社長合意 |
| `gsc-fetch.py` | Search Console 実データ取得（BigQuery） | 読取専用 |
| `hp-audit.sh` | オンページSEO監査（HTTP GET） | 読取専用（T-001） |
| `check-ssl.sh` | SSL有効期限チェック | 読取専用 |
| `mailbox.sh` | 拠点横断メールボックス client（inbox/send/done） | 内部書込（hold/で社長ゲート） |
| `slack.sh` | Slack Incoming Webhook 送信 | **外部送信**（automation.md準拠） |
| `slack-poll.py` | 社長Slackの双方向（fetch=新着取得→mailbox投函／post・reply=社長チャンネルへ投稿・返信） | 読取＋社長チャンネルへの内部報告。last-seenで新着だけ |
| `slack-listen.py` | Slack即時受信（Socket Mode常駐）。当面停止・将来の即時反応用に温存 | 読取（イベント受信）→mailbox投函 |
| `build-ai-index.py` | AI-INDEX.md 再生成 | 生成 |
| `build-recurring-revenue.py` / `build-skills.py` / `analyze-*.py` | 財務・案件・スキル集計 | data/ 入出力 |

詳細は [bin/README.md](bin/README.md)。

---

## 統括者が見る「健康シグナル」候補（次段で健康チェック化する種）

保存せず**都度生成**で見る対象。スクリプト化（`bin/system-health.sh` 等・読み取り専用）は次段階。

- **版ズレ**：ルールが参照するパス/コマンドが実体とズレていないか（例：掲示板パスの移設、bin名変更）。
- **滞り**：各掲示板/会話に未回答 `Q-NNN`・未処理提案・期日超過 ToDo・mailbox の `new/`/`hold/` 滞留がないか。
- **未完の型**：`/task-partner` コマンド未作成、mailbox スライス3（approve）未実装 等、設計途中の宿題。
- **相互リンク切れ**：ハブ（hp-analysis）・案件記録・ルール間のリンク整合。
- **二重台帳化の兆候**：一次情報源が複数できていないか。

---

## この地図の保守責任

モードの**追加・廃止・version 更新・一次情報源やチャネルの変更**が起きたら、**このファイルを同時に直す**（統括者の責務）。本体変更とドキュメント反映を分離しすぎてズレるのを防ぐため、構造が変わったら即・社長合意のうえ更新する。

---

## 変更履歴
| version | 日付 | 内容 |
|---------|------|------|
| 0.1 | 2026-06-18 | 初版。モード地図・ハンドオフトポロジ・チャネル/一次情報マップ・ツール一覧・健康シグナル候補・保守責任を定義 |
