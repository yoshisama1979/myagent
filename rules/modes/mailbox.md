# 拠点横断メールボックス — 規約

> **北極星は置かない**＝これは通信規約であり、運ぶ中身の目的は送り手側が持つ（A-051 C・2026-08-10 社長確定）

> **version 0.2（スライス2＝読み取り＋投函/処理済み）**（2026-06-17）｜ changelog はファイル末尾。
> 別マシン（事務所・自宅・VPS）にいるエージェント同士が、Tailscale 越しに **非同期でメッセージをやり取りする共有受信箱** の書式・宛先・承認フローを定義する。
> 土台は [rules/automation.md](../../rules/automation.md)（外部送信・書き込み・秘密情報）と CLAUDE.md の行動指針。衝突したら automation.md が最優先。

---

## なぜ必要か（前提）

エージェントは**同一マシンにいない**（事務所PC・自宅PC・VPS）。ファイルシステムを共有できないので、
ネットワーク越しに全拠点から読み書きできる共有受信箱が要る。**VPS を常時起動のハブ**にして、
メールボックスを HTTP API（`site/tools/mailbox/`）として置き、各拠点は Tailscale 経由で読み書きする。

```
[事務所PCのエージェント] ─┐
[自宅PCのエージェント]  ─┼─ Tailscale ─→ [VPS] /tools/mailbox/  ─ data/mailbox/{new,cur,hold}
[VPS常駐エージェント]    ─┘
```

> **「全自動」の限界（正直に）**：常時起動できるのは VPS だけ。事務所・自宅PCのエージェントは
> **そのPCが起動し、エージェントが走っている間だけ**受信箱を処理できる。重い継続処理は VPS 常駐に寄せ、
> 拠点エージェントは「起動したとき溜まった受信箱を処理する」間欠応答が前提。

---

## 構成

| 要素 | 場所 | 備考 |
|------|------|------|
| API 本体 | `site/tools/mailbox/index.php` | Nginx + PHP-FPM。Tailscale 内からのみ到達 |
| メッセージ実体 | `data/mailbox/{new,cur,hold}/` | docroot 外・**gitignore**・1メッセージ1JSON（append-only。編集しない） |
| トークン表 | `data/secrets/mailbox-tokens.json` | token→agent_id/role。**実値は AI が読まない・表示しない**（automation.md §2） |
| クライアント | `bin/mailbox.sh` | 各拠点に配置。`.env` から `MAILBOX_URL` / `MAILBOX_TOKEN` を必要キーだけ抽出 |

### ディレクトリの意味

| dir | 意味 |
|-----|------|
| `new/` | 未読（受信箱）。宛先エージェントがサイクル先頭で読む |
| `cur/` | 処理済み（履歴）。読んだら `new/` から `mv`（**編集・削除しない＝履歴を消さない**） |
| `hold/` | **社長承認待ち**。`needs_approval: true` のメッセージはここに入り、社長が承認して初めて `new/` へ動く |

---

## メッセージ書式（1ファイル＝1メッセージ・JSON）

ファイル名：`<id>.json`（例 `M-20260617T142233-hploop-001.json`）。`id` と一致させる。

```json
{
  "id": "M-20260617T142233-hploop-001",
  "thread": "yoshida-symptom-cta",
  "from": "hp-loop",
  "to": "yoshida-dev",
  "type": "request",
  "needs_approval": false,
  "ts": "2026-06-17T14:22:33+09:00",
  "subject": "症状ページ→予約CTA の実装依頼",
  "body": "R-Y05：症状解説ページの末尾に予約CTAを設置したい。…（受け取った相手がそのまま着手できる粒度で書く）"
}
```

| フィールド | 説明 |
|-----------|------|
| `id` | `M-<UTCではなくJSTの YYYYMMDDThhmmss>-<from>-<連番>`。ファイル名と一致 |
| `thread` | 会話の束ね。返信・続報は同じ thread を使う |
| `from` / `to` | エージェントID（下記一覧）。`to` は1宛先（複数宛は複製して別ファイル） |
| `type` | `request`（依頼）/ `report`（報告）/ `ack`（受領・確認）/ `fyi`（共有） |
| `needs_approval` | **下記ポリシー**で true/false を決める。true は `hold/` 行き |
| `ts` | JST（`+09:00`）の ISO8601 |
| `subject` | 1行要約 |
| `body` | 本文。事実と推測を分ける。クライアント固有事実は捏造しない |

### エージェントID（初期・増えたらここに追記）

| agent_id | 役割 | 居場所 |
|----------|------|--------|
| `president` | 社長（admin・承認権限） | — |
| `overseer` | 統括（Overseer）モード。社長は overseer の**日報スレッドに返信**して指示を渡す（`post --as overseer` で持ち主が overseer のスレッド） | VPS |
| `hp-loop` | HP分析ループ（YCOM自社）。社長は hp-loop の**日報スレッドに返信**して指示を渡す | VPS 等 |
| `yoshida-dev` | よしだ歯科サイト実装エージェント | 拠点PC |
| `web-hanasaka` | はなさか自社サイト（y-com.info）実装エージェント。hp-loop の提案を実装し、報告・質問を hp-loop へ返す | 拠点PC |
| `hanasaka-main` | はなさか本体の業務エージェント＝**社長Slackの既定受け先**（`bin/slack-poll.py` の `DEFAULT_AGENT`）。新規トップレベル投稿＝社長との会話を `/chat` で受ける | 拠点PC / VPS |
| `partner` | 経営パートナー（右腕）。会社全体を毎朝見て「今日の一手」を出し実行まで伴走。社長が **#partner（`SLACK_PARTNER_CHANNEL_ID`）** に投げた経営情報を `slack-poll.py fetch` が `to: partner` で投函→**反応tickの `/partner`** が取り込み・スレッド返信、**毎朝7:00 の `daily partner`** が朝礼ブリーフィングを #partner と掲示板 `site/business/partner/` に出す。memo と同じく **Slack投函＋filesystem 読み＝トークン不要**（`$known_agents` 検証の対象外）。社長は朝礼スレッドへの返信／#partner への投函で情報を渡す | VPS |
| `memo` | 日常メモ取り込み（**2層**）。社長が Slack **#memo（`SLACK_MEMO_CHANNEL_ID`）** に投げたトップ投稿を `slack-poll.py fetch` が `to: memo` で投函→**日中は反応tickの `/memo-triage`** が**各メモに会話返信**（壁打ち感・曖昧なら同返信で確認）し、点検済みを `data/mailbox/memo-stock/` へ退避→**夜バッチ `daily memo` の `/memo-intake`** が memo-stock の当日分をまとめて `site/notes.html` へ追記し #memo に要約1本。triage は会話のため**返信した全メモのスレッドを日中は追跡**し、夜の intake が**当日メモスレッドをまとめて `untrack`**（threads.json は1日単位で有界・毎晩リセット／未解決は要約スレッドへ繰り越す）。**Slack 投函＋filesystem 読み＝HTTP API 不経由なのでトークン不要**（`$known_agents` 検証の対象外） | VPS |
| `rule-kaizen` | **テンプレ改善提案の受け口**（`claude-rules/` テンプレを使う **別マシンの開発エージェント**が、開発中に気づいたルールの改善を送る宛先）。**受信専用**＝誰もこの名で送らず・返信しない。中身は VPS の filesystem（`data/mailbox/new/` の `to: rule-kaizen`）を **有人の棚卸しセッションが直接読む**（memo/partner と同型の「filesystem 読み」）。ただし送信元が**別マシンからの HTTP `send`** なので、memo/partner と違い **宛先として `$known_agents` 検証を通る必要がある**＝トークン表に `agent_id: rule-kaizen` のエントリが要る（下記セットアップ）。処理は `claude-rules/README.md`「テンプレート自体の育て方」③＝受信→汎用性の選別→ `claude-rules/TEMPLATE-BACKLOG.md` へ起票→差分案→**社長承認→commit**（reviewer 型・自動反映しない） | VPS（受信箱） |

---

## `needs_approval` ポリシー（肝）

**内部調整は社長を介さず流す（false）／外部・破壊的な作用を伴うものは社長ゲート（true）**。
automation.md §3（外部送信・書き込み・破壊的操作は合意なしに自動実行しない）を、`hold/` という物理的な仕切りで担保する。

| メッセージの性質 | needs_approval | 行き先 |
|------------------|:--------------:|--------|
| 分析の引き渡し・検証依頼・進捗/完了報告・認識合わせ（純粋な内部調整） | `false` | `new/`（相手が直接拾う） |
| Chatwork / メール / クライアントへの送信を相手に促す | `true` | `hold/` |
| 本番サイト・本番システムの改変を相手に促す | `true` | `hold/` |
| hana-tools への書き込み（ToDo登録・更新・完了化）を相手に促す | `true` | `hold/` |
| 判断に迷う | `true`（安全側） | `hold/` |

> 受信した側も、実際に外部送信・書き込み・本番改変を**実行する**ときは自分のモードの automation.md ゲートに従う。
> メールボックスの `hold/` は「**社長がメッセージ自体を見てから相手に届ける**」ための前段ゲート。二重に守る。

---

## 各モードでの使い方

- **サイクル先頭（Step 0 相当）で受信箱を読む**：**VPS常駐モード（`hp-loop-<site>`・`blog-loop-<client>` 等）は `bash bin/mailbox.sh local-inbox`**（スプール直読み）。別マシンのエージェントは従来どおり `bash bin/mailbox.sh inbox`（HTTP）。
  - **なぜ分けるか（2026-09-11・実害37日）**：`inbox` は HTTP API で、**身元を決めるのは `.env` の `MAILBOX_TOKEN`** であって名乗りではない。VPS のトークンは旧来の総称 `hp-loop` のままなので、宛名がサイト別（`hp-loop-ycom` 等）へ移行したあとは **自分宛が1通も見えない**（常に `count: 0`）。一方 dispatcher（`agent-tick.sh`）は**スプールの `to:` をファイルで直接数える**ため「新着あり」と判定して起動する＝**起動はするが消費できない**無限ループになる（`hp-loop:ycom-noprogress` が14日で7回・8件が37日滞留）。`local-inbox` は dispatcher と同じ `to:` を見る＝**正が1つになる**。
- 処理したら **`bash bin/mailbox.sh local-done <id>`**（VPS常駐）／`bash bin/mailbox.sh done <id>`（別マシン）で `cur/` へ移す。**メッセージ本体は編集しない**。自分宛のメッセージだけ done にできる（admin は例外）。`local-done` は `to:` が自分でなければ拒否する＝**他レーンの起動理由を横から消さない**。
- 送信は `bash bin/mailbox.sh send --to <agent> --subject "件名" [--type ...] [--thread ...] [--needs-approval] [本文]`（本文は引数末尾 or 標準入力）。外部・破壊的作用を促すものは `--needs-approval` を付け、`hold/` に入れて社長承認を待つ。

> `approve`（`hold/` → `new/`）はスライス3以降。現在サーバが `501` を返す（社長用ブラウザビューと併せて実装）。

> **同一マシン（VPS常駐）内の内部調整は、HTTP API ではなく `new/` へのローカル投函でよい**：mailbox.sh(HTTP)の `from` はトークン由来＝1マシン1トークンなので、同じVPSに同居する複数モードは「相手の名で」送れない。そこで同一VPS内では **`bash bin/mailbox.sh local-send --from <自分> --to <相手> ...`** を使う（HTTP不経由で `new/` に **json安全・atomic(tmp→os.replace)・一意id(uuid)** で直接書く。`from` は自己申告だが**識別子検証＋登録エージェント許可リストで制限**＝`from` は VPS常駐モードのみ・**`president`(人間)不可**・`to` は実在エージェントのみ。`needs_approval` は常に false）。例：`/chat`（hanasaka-main）が社長Slackの解析依頼を hp-loop へ即時転送する（`from: hanasaka-main` / `to: hp-loop`）。**外部送信・本番改変・hana-tools書込を促すもの（`needs_approval:true`）はこの近道を使わず、必ず通常の `send`（+`--needs-approval`）で `hold/` ゲートを通す**。

---

## 厳守する制約

| 操作 | 可否 |
|------|------|
| `inbox`（自分宛の受信箱を読む） | ✅ 可 |
| メッセージを `cur/` へ移す（done・スライス2以降） | ✅ 可（mv のみ。本文は編集しない） |
| メッセージ送信（send・スライス2以降） | ✅ 可（外部・破壊的作用を促すものは `needs_approval: true`＝`hold/`） |
| **`hold/` → `new/` の承認（approve）** | **社長（admin）のみ**（スライス3以降） |
| 既存メッセージの本文を編集・削除 | ❌ 不可（append-only。履歴を消さない） |
| 他人の inbox を覗く | ❌ 不可（admin を除く） |
| `reporter` ロールでの受信・処理済み化・`rule-kaizen` 以外への送信 | ❌ 不可（投函専用） |
| 発行台帳（`data/rule-reporters.md`）を手で編集する | ❌ 不可（`bin/rule-reporter.py` が表から組み立てる） |
| `data/secrets/mailbox-tokens.json` の実値を読む・表示する | ❌ 不可（automation.md §2） |
| トークンをログ・通知・コミットに出す | ❌ 不可 |

---

## トークン表のセットアップ（社長の手元作業）

`data/secrets/mailbox-tokens.json`（`data/secrets/` は gitignore 済・`chmod 700`）を作成し、エージェントごとにランダムトークンを割り当てる。

```bash
# トークン生成例（1つずつ）
openssl rand -hex 24
```

```json
{
  "<生成したトークン1>": { "agent_id": "hp-loop",      "role": "agent" },
  "<生成したトークン2>": { "agent_id": "yoshida-dev",  "role": "agent" },
  "<生成したトークン3>": { "agent_id": "president",    "role": "admin" }
}
```

各拠点のマシンの `.env` には、**そのマシンが名乗るエージェントのトークンだけ**を `MAILBOX_TOKEN` に設定する（`MAILBOX_URL` も）。

### `rule-kaizen`（テンプレ改善の受け口）を有効にする

`claude-rules/` テンプレを使う開発エージェントからのテンプレ改善提案を受け取るには、**受信専用の宛先** `rule-kaizen` をトークン表に登録する（宛先として `$known_agents` 検証を通すため。**誰もこの名で認証しない**＝トークンは使われないが、宛先として存在させるために1エントリ要る）：

```json
  "<生成したトークン>": { "agent_id": "rule-kaizen", "role": "agent" }
```

- このトークンは**どのマシンの `.env` にも入れない**（rule-kaizen として送信・認証する主体はいない）。宛先を実在させるためだけの登録。
- 登録後、別マシンの開発エージェントが `bash bin/mailbox.sh send --to rule-kaizen …` で送れるようになる。未登録のうちは送信側が `unknown_recipient` で弾かれる（テンプレ側はその場合 `rule-improvements.md` に残して社長に伝える設計＝空振りしない）。
- 受信は VPS 常駐の local-send は経由しない（別マシンからの HTTP `send` が唯一の投函経路）。将来 VPS 内のモードから rule-kaizen へ流したくなったら `bin/mailbox.sh` の `RECIPIENTS` に追加する。
- **処理済み化（棚卸し時）**：`rule-kaizen` は認証主体を持たないため、宛先本人としての `mailbox.sh done` はできない（サーバは「宛先本人か admin のみ done 可」）。棚卸しでは **president=admin トークンの `mailbox.sh done <id>`**、または VPS 上で当該 JSON を `new/`→`cur/` へ直接移動して処理済みにする（本文は編集しない）。これらは slack 由来でないため slack-poll の追跡状態はなく、filesystem 移動で整合が崩れない。
- **この sink エントリのロールは `reporter` にする**（2026-09-11）。宛先として実在させるだけで誰も認証しないので、権限は最小でよい。万一このトークンが漏れても **`rule-kaizen` 宛に投函できるだけ**で、受信箱は読めず `done` もできない（`agent` のままだと目安箱の中身を読まれる）。`.env` に置かず `data/secrets/` に留めるのは従来どおり（automation.md §2）。

---

## ルール通知の投函専用トークン（`reporter` ロール）

`claude-rules` テンプレは多くの案件へコピー配布されるが、**その大半は解析ループと組んでいない**＝mailbox の身分（`agent` トークン）を持たない。それらの案件からも「ルールに問題がある」ことだけは届いてほしい。そのための**一方向・投函専用**の経路。

**agent トークンを配って済ませない理由**：`agent` は既知の宛先ならどこへでも送れる。通知のためだけに配ると、**解析↔開発のやり取りにゴミを入れられる経路を全案件へ開く**ことになる。目的が違うものを同じ道具にしない。

### できること・できないこと

| | `reporter`（通知専用） | `agent`（解析↔開発） |
|---|---|---|
| `send` | **`rule-kaizen` 宛のみ**（他は 403 `recipient_not_allowed`） | 既知の宛先ならどこへでも |
| `inbox` | ❌ 403（受信箱を持たない） | ✅ 自分宛のみ |
| `done` | ❌ 403 | ✅ 自分宛のみ |
| `needs_approval: true` | 無視して `new/` へ（承認待ちに埋もれさせない） | `hold/` へ |
| 投函上限 | 1日 50 件（超過は 429）。数えるのは**投函の試行**＝弾かれた分も濫用のうち | なし |
| **宛先になれるか** | ❌ なれない（受信箱を持たないので、宛先にすると誰も読まない `new/` が溜まる） | ✅ なれる |

`from` はトークン由来なので詐称できない＝**どの案件から来たかは自動で分かる**。全案件で共有する1本は作らない（誰から来たか分からなくなり、1案件だけ失効させられなくなる）。

### 発行・失効・一覧

```bash
python3 bin/rule-reporter.py issue <案件名>              # 発行（既定 365 日）。トークンを表示するのはこの1回だけ
python3 bin/rule-reporter.py revoke RR-NNN --reason "理由"  # 失効（行は消さず理由を残す）
python3 bin/rule-reporter.py list                        # 発行状況＋最終使用（日時・接続元IP）
```

配布先の `.env` に入れるのは2キーだけ（`MAILBOX_URL`/`MAILBOX_TOKEN` とは別名にして、既存の mailbox 設定と混ざらないようにする）：

```
RULE_REPORT_URL=<mailbox の URL>
RULE_REPORT_TOKEN=<issue が表示した値>
```

### 取り消せること（ホワイトリストの運用）

トークン表そのものがホワイトリストで、載っていないトークンは 403。加えて：

- **`revoked: true`** — 失効。**行は消さない**（消すと後から「そんな番号あったか」が分からない）。理由と日付が表と台帳に残る
- **`expires_at`** — 既定 365 日。切れたら自動で止まる＝**放置トークンが永久に生きる状態を構造的に作らない**。**`YYYY-MM-DD` で書く**（その日の 23:59:59 まで有効。時刻やタイムゾーン付きの文字列は解釈がぶれるので使わない）。読めない値が入っていたら「期限なし」に倒さず 500 で落とす（fail-closed）
- **最終使用** — API が投函・受信のたびに `data/mailbox/.state/seen-<agent>.json` へ日時と接続元IPを記録する。Tailscale 内からしか届かないので `100.x.x.x` で拠点の見当がつく＝**見覚えのない接続元から使われていたら、それが「把握していない場所で使われた」の合図**。`list` で並べて見る
- **投函上限** — 漏れたときの被害を「目安箱がゴミで埋まる」以下に抑える保険。記録が読めないときは通す（fail-open）＝上限は認証の代わりではなく、記録の故障で通信を止めるほうが害が大きい

**発行台帳は [`data/rule-reporters.md`](../../data/rule-reporters.md)**（git 追跡・**トークン値は載らない**ので見せても漏れない）。番号・案件・発行日・期限・状態・失効理由を持つ。台帳は表から組み立て直す写しなので**手で編集しない**（表とズレる）。

**未知のロールは `reporter` に倒れる**（最小権限）。ロール名を打ち間違えたトークンは、黙って広い権限を得るのでなく受信箱で 403 になって気づける。

**発行済みの投函専用トークンは宛先にならない**（`known_agents` から外す）。reporter は受信箱を持たないので、宛先にできてしまうと誰かが誤って送ったぶんが `new/` に永久に残る（`inbox` は `new/` を全読みするので全体のコストにもなる）。受信専用の sink（`rule-kaizen`）は `reporter_id` を持たないので、権限が `reporter` でも宛先としては残る＝この2つを分ける軸が `reporter_id` の有無。

**回帰テスト**：`bash bin/test-rule-reporter.sh`（サーバ側の権限判定と発行・失効。**既存の agent／admin の挙動が変わっていないこと**も同じスイートで見張る）。

---

## 段階導入（automation.md：小さく作って手動検証→合意→自動化）

| スライス | 内容 | 状態 |
|---------|------|------|
| 1 | 読み取り（`GET inbox`）＋本規約＋テストメッセージ。Tailscale越し疎通確認 | ✅ 完了（2026-06-17） |
| 2 | `send` / `done`（tailnet 内の内部書き込み）を追加し手動テスト | ✅ 完了（2026-06-17・使い捨てトークンで検証） |
| 3 | `approve` ＋ 社長用ブラウザビュー（`hold/` を見て承認） | ← 次 |
| 4 | hp-loop ↔ yoshida-dev の1スレッドで試運転 → 各モード Step0 に組込み → VPS常駐を `/loop` 化 | 未 |

---

## 変更履歴
| version | 日付 | 内容 |
|---------|------|------|
| — | 2026-08-10 | **冒頭に北極星1行を追記**（A-051・社長確定＝売りはファネル全層で設計 [[feedback_funnel-all-layers]]）。手順・制約は不変＝1行追記のみのため版番号は据え置き |
| 0.1 | 2026-06-17 | 初版（スライス1）。構成・メッセージ書式・エージェントID・needs_approvalポリシー・制約・段階導入。読み取り（inbox）のみ実装 |
| 0.2 | 2026-06-17 | スライス2。`send`（投函・needs_approvalで new/⇔hold/振り分け・from はトークン由来で詐称不可・ID/tsサーバ生成）と `done`（自分宛のみ cur/ へ移動・本文編集しない）を実装。宛先存在チェック・型/空/サイズ検証・パストラバーサル防止を追加。使い捨てトークンで全経路を手動検証 |
| 0.3 | 2026-09-11 | **投函専用ロール `reporter` を追加**。`claude-rules` テンプレを使う案件から「ルールの問題」だけを一方向で通知させる細い経路（`rule-kaizen` 宛の `send` のみ・`inbox`/`done` は 403・1日50件）。あわせて**ホワイトリストの取り消し手段**＝`revoked`（行を消さず理由を残す）・`expires_at`（既定365日で自動停止・読めない値は fail-closed）・**最終使用の記録**（日時と接続元IPを `data/mailbox/.state/` へ・「漏れても気づけない」を塞ぐ）。発行/失効/一覧は `bin/rule-reporter.py`、台帳は `data/rule-reporters.md`（トークン値を載せない）。未知ロールの既定を `agent` から `reporter` へ（最小権限）。`rule-kaizen` の sink エントリも `reporter` 化＝漏れても目安箱を読まれない。回帰テスト `bin/test-rule-reporter.sh` 75件（既存 agent/admin の挙動不変も同時に検証） |
