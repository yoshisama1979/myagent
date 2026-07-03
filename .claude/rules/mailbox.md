# 拠点横断メールボックス — 規約

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

- **サイクル先頭（Step 0 相当）で受信箱を読む**：`bash bin/mailbox.sh inbox`。自分宛 `new/` の未読を取得。
- 処理したら `bash bin/mailbox.sh done <id>` で `cur/` へ移す。**メッセージ本体は編集しない**。自分宛のメッセージだけ done にできる（admin は例外）。
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
- **トークン漏洩時の影響（自覚しておく）**：万一この登録トークンが漏れると、通常 agent 権限として `rule-kaizen` 宛 inbox の閲覧・`done`、および `from: rule-kaizen` を名乗る送信が可能になる。だから `.env` に置かず `data/secrets/` に留める（automation.md §2）。将来コードを触るなら「受信専用（`from` になれず認証もしない）sink ロール」を分離するとより堅い（現状は agent ロールで代用）。

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
| 0.1 | 2026-06-17 | 初版（スライス1）。構成・メッセージ書式・エージェントID・needs_approvalポリシー・制約・段階導入。読み取り（inbox）のみ実装 |
| 0.2 | 2026-06-17 | スライス2。`send`（投函・needs_approvalで new/⇔hold/振り分け・from はトークン由来で詐称不可・ID/tsサーバ生成）と `done`（自分宛のみ cur/ へ移動・本文編集しない）を実装。宛先存在チェック・型/空/サイズ検証・パストラバーサル防止を追加。使い捨てトークンで全経路を手動検証 |
