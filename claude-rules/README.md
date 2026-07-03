# claude-rules — プロジェクト配布用 Claude Code ルールテンプレート

クライアントプロジェクトの開発で使う **Claude Code 用ルールファイル一式のテンプレート**。
プロジェクト種別に応じてどちらかをコピーして使う。

| テンプレート | 対象 | 中身の骨子 |
|---|---|---|
| [`website/`](website/) | **WEBサイト制作**（コーポレートサイト・LP・小規模サイト。静的HTML or PHP + Sass） | Design.md=SSOT、開始ゲート（start）→ 実装（page-build/page-update/design-replication）→ 公開前チェック（check）→ 運用・SEO（seo-operation）、hp-loop 連携（mailbox/hp-loop-dialogue） |
| [`websystem/`](websystem/) | **WEBシステム開発**（業務システム・管理画面。Laravel + Next.js 等） | 3モード体制（dialogue-mode ↔ autopilot ↔ inbox-mode）、TDD（tdd/testcode/frontend-test）、仕様書HTML（spec-format）、コミット規約・領域分割（commit）、見積もり（estimation） |

## 使い方（新規プロジェクトへの導入手順）

1. **フォルダごとコピー**する（`website/` または `websystem/` の中身をプロジェクトルートへ）
2. **`project-config.md` を最初に記入する**（プロジェクト固有の値はすべてここに集約。ルール本文には書かない）
3. website の場合：`Design.sample.md` を参考に、そのプロジェクトの `Design.md` を作る（`start.md` §1 の手順。Design.sample.md 自体は記入例なのでコピー先に持ち込まなくてよい）
4. `documents/pending-issues.md`・`documents/rule-improvements.md` は **空の状態から**運用を始める
5. websystem の場合：`documents/specs/_template.html` を起点に仕様書を作る（`document.md` は新規プロジェクトでは作らない）

## テンプレートの設計原則（編集時に守ること）

1. **固有値はルール本文に書かない** — クライアント名・実パス・ブランド色・スタックのバージョン等は各プロジェクトの `project-config.md`（デザイン値は `Design.md`）に置き、ルール本文は参照する。例として残す場合は「例:」と明示する
2. **重複定義しない** — 同じルールは1ファイルを本家にし、他は参照で繋ぐ（片方を直して他方が古くなる「版ズレ」を防ぐ）
3. **安全ゲートを崩さない** — 外部送信・本番改変・push・破壊的操作は合意ゲートを通す。捏造しない（要確認情報は確定しない）

## テンプレート自体の育て方（現場の声を還元するループ）

テンプレートは固定マニュアルではなく、**使う開発エージェント自身の気づきを吸い上げて育てる**。「記録と反映を分離」した上で、テンプレ級の気づきを myagent（＝ルールを更新する側）まで届け、**必ず社長ゲートを通して**反映する。

### ① 記録（現場・低摩擦）— 全プロジェクト共通

- 運用中に気づいたルールの不足・乖離・矛盾は、そのプロジェクトの `documents/rule-improvements.md` に **その都度 `RI-NNN` で1行記録**する（開発を止めない・会話に埋もれさせない）。
- そのうち「このプロジェクト固有でなく、**テンプレート全体に還元すべき**」と判断したものには **`[テンプレ還元]`** と印を付ける（プロジェクト固有の設定は `project-config.md`／`Design.md` 側の話で、テンプレ本文には持ち込まない）。

### ② 送る（テンプレ級だけ・経路はテンプレで異なる）

- **website**：拠点PCの実装エージェントは mailbox を持つ。`[テンプレ還元]` 印の気づきを **`bash bin/mailbox.sh send --to rule-kaizen`** で送る（`thread: website-kaizen`／`subject: [website/<ファイル名>] 要旨`）。手順は website の `.claude/rules/mailbox.md`「テンプレ改善提案を送る」節。
- **websystem**：mailbox インフラを前提にしない。`[テンプレ還元]` 印は `rule-improvements.md` に残し、**棚卸し時に社長が myagent へ持ち帰る**（人手キャリーバック）。プロジェクトが mailbox を配線済みなら website と同じく `rule-kaizen` へ送ってよい。
- 受け口 `rule-kaizen` は myagent VPS の **受信専用の宛先**。有効化には myagent 側でトークン表に1エントリ登録が要る（`myagent/.claude/rules/mailbox.md`「`rule-kaizen` を有効にする」）。未登録なら送信側は空振りせず `rule-improvements.md` に残す。

### ③ 選別・起票・反映（myagent 側・reviewer 型・社長ゲート必須）

myagent の**有人棚卸しセッション**で処理する（無人では反映しない＝ルール編集の社長ゲートと整合）：

1. **受信**：`to: rule-kaizen` の受信箱（`data/mailbox/new/`）と、各プロジェクトの `rule-improvements.md` の `[テンプレ還元]` 印を集める。
2. **選別**：汎用性を判定する。テンプレ級 → 次へ／そのプロジェクト固有 → 「`project-config.md` 側の話」と切り分けて差し戻す（テンプレ本文に固有値を入れない）。既存ルールとの**矛盾・重複**もここで確認する。
3. **起票**：すぐ反映しないものは [`TEMPLATE-BACKLOG.md`](TEMPLATE-BACKLOG.md) に `TB-NNN` で積む（届いたが未反映の提案の置き場）。
4. **差分案 → 社長承認 → commit**：反映する差分案を作り、**社長が承認してからコミット**する（勝手にテンプレを書き換えない）。反映後、**受信メッセージを `new/`→`cur/` へ移す**（`rule-kaizen` は認証主体を持たないため自名義の `mailbox.sh done` は不可＝**president=admin トークンの `mailbox.sh done`**、または棚卸しセッションが VPS 上で当該 JSON を `cur/` へ移動する。本文は編集しない・履歴を消さない）。あわせて `rule-improvements.md` の該当 `RI-NNN` は「反映済み」にする（現場側の記録）。

- テンプレート自体の未完課題（ツール化・定型化などの宿題）も [`TEMPLATE-BACKLOG.md`](TEMPLATE-BACKLOG.md) に置く（配布物の `pending-issues.md` には入れない）。
