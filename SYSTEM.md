# SYSTEM — このシステムの「動くモードの地図」

> **統括者（overseer）が毎ループ冒頭に読む入口。** 変わりにくい**構造**だけをここに置く。
> 滞り・版ズレ・未回答などの**変わりやすい状態は保存しない**（統括者が都度生成する＝[.claude/rules/overseer.md](.claude/rules/overseer.md)）。
> 役割分担：`OVERVIEW.md`＝ディレクトリの地図／`AI-INDEX.md`＝site/中身の地図／**本ファイル＝動くモード同士の関係の地図**。
> version 0.2（2026-06-26）｜ changelog は末尾。

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
- **重複定義しない（流用）**：共通の評価観点・進め方・カイゼン台帳は元ファイルを流用し再記述しない（一方を直して他方に古い記述が残る版ズレを防ぐ。例：hp-loop は hp-improve を流用／blog-* は hp-improve・hp-loop を流用）。

---

## モード地図

| モード | 目的 | 起動 | 一次情報源（読む） | 出力先（書く・誰が） | 承認ゲート | 対話相手 | ルール（版） |
|--------|------|------|------------------|--------------------|-----------|---------|-------------|
| **Main（業務）** | 蓄積記録を運用・実装に反映 | 通常会話 | site/・data/・hana-tools | site/ 各所・コード | 外部送信/本番は社長 | 社長 | CLAUDE.md / rules/* |
| **chat（会話窓口）** | 社長Slackの会話・相談・質問に答える＝Slack既定受け先（`hanasaka-main`） | `/chat`（反応tick・`to: hanasaka-main`） | Slack新着・site/・data/ | Slackスレッド返信・mailbox転送（解析依頼を hp-loop 等へ） | 外部送信/本番は社長 | 社長（Slack） | [.claude/commands/chat.md](.claude/commands/chat.md) |
| **Memo** | 断片メモを精度高く記録（一次入力・手動） | `/memo` | 社長の口頭メモ | `site/notes.html`・`site/clients/*/memo.html`（AI追記のみ） | — | 社長 | [.claude/rules/memo.md](.claude/rules/memo.md) |
| **memo-triage** | #memo の新着メモを日中その場で会話返信・軽く点検（曖昧点だけ確認）→memo-stock へ退避 | `/memo-triage`（反応tick・`to: memo`） | `data/mailbox/new/`（`to: memo`） | #memo スレッド返信・`data/mailbox/memo-stock/` 退避（notes は書かない） | — | 社長（#memo） | [.claude/rules/memo-triage.md](.claude/rules/memo-triage.md)（0.3） |
| **memo-intake** | 夜バッチで memo-stock の当日メモを notes.html へまとめて清書＋#memo に要約1本 | `/memo-intake`（daily memo・23:00） | `data/mailbox/memo-stock/`（＋取りこぼし救済の new/） | `site/notes.html`（AI追記のみ）・#memo に要約投稿 | — | 社長（#memo・非同期） | [.claude/rules/memo-intake.md](.claude/rules/memo-intake.md)（0.4） |
| **Reviewer** | プロジェクトを俯瞰レビュー→改善提案 | `/reviewer-cycle` | `ai-loop/scope.md`・`exclusions.md` | `ai-loop/conversation.md`（AIはこれ1ファイルのみ） | 実装は Dev/社長 | Dev AI（非同期） | [.claude/rules/reviewer.md](.claude/rules/reviewer.md) |
| **hp-improve** | クライアントHPの診断→改善（単発） | `/hp-improve` | 対象URL・hp-audit・GSC/GA4 | `site/drafts/`・`site/clients/*/`（合意後） | 本番改変/送信は社長 | 社長 | [.claude/rules/hp-improve.md](.claude/rules/hp-improve.md)（0.2） |
| **hp-loop**（マルチサイト） | HPを定期診断→提案→非同期会話。**サイト別に独立して回る** | `/hp-loop <site>`（+`/loop`・daily） | `data/hp-loop/config.md`・`sites/<site>.md`・`<site>/from-president.md`・hp-audit・GSC/GA4・`<site>/coverage.md` | `site/hp-analysis/<site>/{index,spec,archive}.html`（AIのみ・3層）・mailbox 配信（実装担当へ）・`data/hp-loop/cycles/<site>/` | 本番改変/送信は社長 | 社長＋サイト別実装担当（掲示板/mailbox `to: hp-loop-<site>` 経由） | [.claude/rules/hp-loop.md](.claude/rules/hp-loop.md)（0.5） |
| **hp-reply** | 社長コメントを from-president.md へ代筆転記 | `/hp-reply` | 社長コメント | `data/hp-loop/<site>/from-president.md`（例外的に書込可） | — | 社長 | [.claude/commands/hp-reply.md](.claude/commands/hp-reply.md) |
| **blog-loop**（マルチクライアント） | ブログ記事のコンテンツSEO診断→①既存改善 B ②新規テーマ＋構成 T を提案 | `/blog-loop <client>`（+daily・反応tick） | `data/blog-loop/config.md`・`clients/<client>.md`・`<client>/from-president.md`・GSC/GA4・記事HTML | `site/hp-analysis/<client>/blog/{index,spec,archive}.html`（AIのみ・3層）・mailbox 配信（執筆担当へ）・`drafts-log` | 本番改変/送信は社長 | 社長＋執筆/実装担当（mailbox `to: blog-loop-<client>`） | [.claude/rules/blog-loop.md](.claude/rules/blog-loop.md)（0.1） |
| **blog-write** | blog-loop の新規テーマ T に対応し**完成原稿ドラフト（本文まで）**を作成→WP下書き(draft)投稿 | `/blog-write <client>`（daily 05:30・強制専用） | blog-loop 掲示板の T／`from-president.md`／競合・既存記事（読取） | `site/drafts/blog/<client>/`・`drafts-log`・WP `status=draft`（合意・creds後） | **公開(publish)は人間**・WP書込は合意/creds後 | 執筆対象（人間レビュー） | [.claude/rules/blog-write.md](.claude/rules/blog-write.md)（0.1） |
| **blog-improve** | blog-loop の既存改善 B に対応。元記事は読むだけ・改善版を**下書き複製**で作成（本番反映は人間） | `/blog-improve <client>`（daily 06:00） | blog-loop 掲示板の B／元記事（`wp-draft.py get`・読取）／GSC | `site/drafts/blog/<client>/improve/`・`improve-log`・WP 改善版draft | **元の公開記事は不変**・公開は人間 | 執筆対象（人間レビュー） | [.claude/rules/blog-improve.md](.claude/rules/blog-improve.md)（0.1） |
| **task-partner（進行管理）** | ToDo駆動で案件の進行を管理・橋渡し | `/task-partner`（**仮・コマンド未作成**） | **hana-tools（ToDoが一次）** | `site/clients/*/`（補足追記）・`site/drafts/` | ToDo書込/通知/本番は社長 | 社長＋プロジェクト側エージェント | [.claude/rules/task-partner.md](.claude/rules/task-partner.md)（0.4） |
| **Overseer（統括）** | システム全体の整合・健全性を見張り改善提案 | `/overseer`（+`/loop`・daily 01:00） | 本ファイル・各ルール・各掲示板・mailbox・git・Slack | `site/overseer/index.html`（AI追記・社長がWeb閲覧）・本ファイル保守（合意後） | ルール/本体改変は社長 | 社長 | [.claude/rules/overseer.md](.claude/rules/overseer.md)（0.2） |

> **マルチサイト/マルチクライアント**：hp-loop は4サイト（`ycom`＝はなさか自社／`yoshida`＝よしだ歯科／`fujisaka`＝藤阪ガス／`yokohawaii`＝ヨーコハワイ）が各々独立日次で回る。blog 系は現状 `ycom` のみ。登録表は各 config（`data/hp-loop/config.md`・`data/blog-loop/config.md`）が一次。
>
> **エージェントID（mailbox／Slack スレッド所有者）とトークン登録状況**：`president`（admin）・`hanasaka-main`（Slack既定受け先）・`overseer`・`hp-loop-ycom/yoshida/fujisaka`・`blog-loop-ycom`・実装担当 `web-hanasaka`・`yoshida-dev`・`fujisaka-dev`・`yokohawaii-dev` はトークン登録済。**`hp-loop-yokohawaii` は未登録（GSC/GA4 も蓄積待ち＝yokohawaii は配信・日報が制限付き）**。`blog-write-ycom`・`blog-improve-ycom` は daily 強制専用キー（mailbox受信なし・日報は `blog-loop-ycom` スレッドに相乗り）。`memo`（#memo 窓口）は **Slack投函＋filesystem 読み＝HTTP API 不経由のためトークン不要**。旧称 `hp-loop`（無印）トークンは後方互換で残存（孤児宛名の温床なので定点監視＝統括の健康シグナル）。

> **claude-rules/ はこのシステムの対象外。** 弊社がクライアント向けに使う汎用 Claude ルールの置き場であり、上記モード群とは別物（混同しない）。
> **複数プロジェクトで共有・コピーして使う汎用テンプレ**なので、編集時は**固有値（エージェントID・サイト名・URL・DB名等）を本文に焼き込まず、各プロジェクトの `project-config.md` に置いて参照させる**（例：hp-loop 連携の宛先は `hp-loop-<site>` とし、実値は project-config.md。`hp-loop-ycom` 等を直書きしない）。

---

## 無人ディスパッチャ（cron が回す単一入口 `bin/agent-tick.sh`）

無人運用は cron が `bin/agent-tick.sh` を叩き、宛先 mailbox の新着 or daily 強制で各モードを起動する（[[project_unattended-loop-cron]]）。生存確認＝`site/overseer/last-tick.txt`。

| 種別 | スケジュール（cron） | 起動 |
|------|--------------------|------|
| 反応tick（normal） | 短間隔（例 `*/2`） | `to:` 新着があるモードだけ：`chat`(hanasaka-main)／`memo-triage`(memo)／`overseer`／`hp-loop:<4サイト>`／`blog-loop:ycom` |
| daily overseer | `0 1 * * *` | `/overseer`（精密診断） |
| daily hp-loop | `0 2`(ycom)／`0 2:30`(yoshida)／`0 3`(fujisaka)／yokohawaii（蓄積待ち） | `/hp-loop <site>`（サイト別に強制起動） |
| daily blog | `0 5`(blog-loop)／`30 5`(blog-write)／`0 6`(blog-improve)・ycom | ブログ診断→新規記事下書き→既存改善下書き |
| daily memo | `0 23 * * *` | `/memo-intake`（#memo 当日分を notes.html へまとめ） |

> daily は取りこぼすと「毎日忘れず」の規律が崩れるためロックを最大60分待つ。normal は前回稼働中なら静かにスキップ（次tickで拾う）。crontab 追加・`settings.local.json` 許可は社長作業。

---

## ハンドオフ・トポロジ（誰がどのチャネルで非同期会話するか）

```
社長(Slack) ──fetch──▶ mailbox ──▶ chat / overseer / hp-loop-<site>（各々スレッド返信で会話）

Memo / memo-triage ──(memo-stock)──▶ memo-intake ──(site/notes.html追記)──▶ Main（後で運用反映）

Reviewer ⇄ Dev AI               … ai-loop/conversation.md（提案↔人判断↔実装）
hp-loop  ⇄ サイト別実装担当       … 掲示板 site/hp-analysis/<site>/ + from-president.md ＋ mailbox to:hp-loop-<site>（社長が橋渡し）
blog-loop ⇄ 執筆/実装担当(web-hanasaka) … 掲示板 hp-analysis/<client>/blog/ ＋ mailbox to:blog-loop-<client>（fact質問も blog-loop が集約）
blog-write/blog-improve → WP下書き（公開は人間）
task-partner ⇄ プロジェクト側     … hana-tools の ToDo（一次）＋ 社長橋渡し
全拠点エージェント間              … mailbox（VPS API・Tailscale・hold/=社長承認ゲート／同一VPS内は local-send）

社長 = すべてのハブ。AIの提案は社長を介して相手へ渡り、報告は社長を介して戻る。
```

各「対話相手側ルール」（実装側の動き方）：HP は `claude-rules/website/.claude/rules/hp-loop-dialogue.md`、mailbox 作法は同 `mailbox.md`。task-partner 相当は未整備（論点）。

---

## チャネル／一次情報の在処マップ

| チャネル | 実体 | 誰が書く | 性質 |
|---------|------|---------|------|
| 進行管理（案件タスク） | hana-tools API（`bin/hana-api.sh`） | 社長/システム（AI書込は合意後） | 一次台帳。site/に二重化しない |
| HP分析ループ会話 | `data/hp-loop/<site>/from-president.md`（社長）/ `site/hp-analysis/<site>/`（AI・3層） | 役割で分離 | 責務分離 |
| HP分析の判断state | `data/hp-loop/<site>/coverage.md`（カバレッジ台帳・判断のsource of truth） | hp-loop（AI） | 掲示板は報告ビュー／台帳が正 |
| ブログ分析ループ会話 | `data/blog-loop/<client>/from-president.md`（社長）/ `site/hp-analysis/<client>/blog/`（AI・3層） | 役割で分離 | 責務分離 |
| Reviewer会話 | `ai-loop/conversation.md` | Reviewer提案・人判断 | append中心 |
| 拠点横断メッセージ | `data/mailbox/{new,cur,hold}/`（API: `site/tools/mailbox/`） | 各エージェント（append-only） | hold/=社長ゲート |
| 日常メモ窓口 | Slack **#memo**（`SLACK_MEMO_CHANNEL_ID`）→ `to: memo` → `data/mailbox/memo-stock/` → `site/notes.html` | 社長(Slack)／memo-triage退避／memo-intake清書 | 2層（日中triage・夜intake） |
| 社長⇄エージェント（Slack双方向） | Slack専用チャンネル ⇄ `bin/slack-poll.py`（fetch/post/reply）⇄ mailbox。`data/slack/last-seen.json`・`threads.json` で既読/追跡管理 | 社長(Slack)／エージェント(reply) | ループが各回 fetch。返信は元スレッドへ |
| メモ（横断/案件） | `site/notes.html` / `site/clients/*/memo.html` | Memo/memo-intake（追記のみ） | 履歴消さない |
| 統括所見 | `site/overseer/index.html`（統括レポート掲示板・Web閲覧） | Overseer（追記） | append・reviewer型 |

---

## ツール群（bin/・実行時は読み取り専用が原則）

| ツール | 用途 | 区分 |
|--------|------|------|
| `agent-tick.sh` | 無人運用の単一ディスパッチャ（cron が回す・宛先mailbox/daily で各モード起動） | 起動制御（読取＋claude -p 起動） |
| `hana-api.sh` | hana-tools 連携（todos/projects/notes/clients/chatwork/outsources） | 読取✅／書込(create/update/chatwork)は社長合意 |
| `gsc-fetch.py` | Search Console 実データ取得（BigQuery・`--dataset` 必須） | 読取専用（T-006） |
| `ga4-fetch.py` | GA4 実データ取得（BigQuery・流入/CV） | 読取専用（T-007） |
| `hp-audit.sh` | オンページSEO監査（HTTP GET） | 読取専用（T-001） |
| `hp-shot.sh` | ヘッドレスChromeでPC/SP×fold/full のPNG取得（ビジュアル評価） | 読取専用（T-008・出力はgitignore） |
| `hp-serp.sh` / `hp-compete.py` | 競合トピック発掘（Yahoo検索）／競合対比 | 読取専用（T-011／T-010） |
| `hp-diff.py` | サイクル間の差分（効果検証・変化検知） | 読取専用（T-009） |
| `wp-draft.py` | WordPress 下書き(draft)の get/post/update/check（blog-write/improve 用・公開はしない） | 外部書込（draft限定・creds/合意後） |
| `check-ssl.sh` | SSL有効期限チェック | 読取専用 |
| `mailbox.sh` | 拠点横断メールボックス client（inbox/send/done／同一VPSは local-send） | 内部書込（hold/で社長ゲート） |
| `slack.sh` | Slack Incoming Webhook 送信 | **外部送信**（automation.md準拠） |
| `slack-poll.py` | 社長Slackの双方向（fetch=新着→mailbox／post・reply=投稿・返信／stock・done・untrack=メモ運用） | 読取＋社長チャンネルへの内部報告。last-seenで新着だけ |
| `slack-listen.py` | Slack即時受信（Socket Mode常駐）。当面停止・将来の即時反応用に温存 | 読取（イベント受信）→mailbox投函 |
| `build-ai-index.py` | AI-INDEX.md 再生成 | 生成 |
| `build-recurring-revenue.py` / `build-skills.py` / `analyze-*.py` | 財務・案件・スキル集計 | data/ 入出力 |

詳細は [bin/README.md](bin/README.md)。ツール台帳（T-NNN）は `data/hp-loop/tools-log.md`。

---

## 統括者が見る「健康シグナル」候補（次段で健康チェック化する種）

保存せず**都度生成**で見る対象。スクリプト化（`bin/system-health.sh` 等・読み取り専用）は次段階。

- **版ズレ**：ルールが参照するパス/コマンドが実体とズレていないか。SYSTEM.md の版表と各ルールの実 version が一致するか。**共通部の流用整合**（hp-loop↔hp-improve、blog-*↔hp-improve/hp-loop が再記述でなく参照で繋がっているか）。
- **滞り**：各掲示板/会話に未回答 `Q-NNN`・未処理提案・期日超過 ToDo・mailbox の `new/`/`hold/` 滞留がないか。
- **往復切れ（宛名ドリフト）**：実装担当→ループの報告が**旧称 `to: hp-loop`（無印）等で孤児化**していないか（new/ に他サイト宛として滞留）。＝再発しやすい定点監視項目。
- **未完の型**：`/task-partner` コマンド未作成、mailbox スライス3（approve）未実装、`hp-loop-yokohawaii` トークン/GSC 蓄積待ち 等、設計途中の宿題。
- **地図ドリフト**：稼働モード/サイト/エージェントが SYSTEM.md に載っているか（`grep <新モード名> SYSTEM.md`＝0件で検出）。
- **相互リンク切れ／二重台帳化**：ハブ（hp-analysis）・案件記録・ルール間のリンク整合、一次情報源が複数化していないか。

---

## この地図の保守責任

モードの**追加・廃止・version 更新・一次情報源やチャネルの変更**が起きたら、**このファイルを同時に直す**（統括者の責務）。本体変更とドキュメント反映を分離しすぎてズレるのを防ぐため、構造が変わったら即・社長合意のうえ更新する。

---

## 変更履歴
| version | 日付 | 内容 |
|---------|------|------|
| 0.1 | 2026-06-18 | 初版。モード地図・ハンドオフトポロジ・チャネル/一次情報マップ・ツール一覧・健康シグナル候補・保守責任を定義 |
| 0.2 | 2026-06-26 | **O-008 反映（社長承認）＝地図を実態に同期**。①新モード追加：chat・memo-triage(0.3)・memo-intake(0.4)・blog-loop(0.1)・blog-write(0.1)・blog-improve(0.1)。②版ズレ修正：hp-loop 0.1→**0.5（マルチサイト4サイト ycom/yoshida/fujisaka/yokohawaii）**・overseer 0.1→0.2。③無人ディスパッチャ（agent-tick.sh）と cron スケジュール節を新設。④エージェントID/トークン登録状況・旧称hp-loop孤児の定点監視を明記。⑤ツール群に ga4-fetch/hp-shot/hp-serp/hp-compete/hp-diff/wp-draft/agent-tick を追加。⑥チャネルマップに coverage台帳・ブログ会話・#memo 2層を追加。⑦健康シグナルに往復切れ・地図ドリフト・流用整合を追加 |
