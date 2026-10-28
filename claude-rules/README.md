# claude-rules — プロジェクト配布用 Claude Code ルールテンプレート

クライアントプロジェクトの開発で使う **Claude Code 用ルールファイル一式のテンプレート**。
プロジェクト種別に応じてどちらかをコピーして使う。

> 🧱 **配る単位は「プロファイル」**（＝層の組み合わせ）。一覧の正は [`profiles.json`](profiles.json) ひとつ。
> いまは `website` = [`common/`](common/) + [`website/`](website/)、`websystem` = [`common/`](common/) + [`websystem/`](websystem/) の**2層**で、
> 共通部分を `common/` へ移すたびに面レイヤーが薄くなる（[`REDESIGN.md`](REDESIGN.md) ステップ5の進行中）。
> 最終形では `website/` → `site/`・`websystem/` → `system/` に改名し、公開面と機能面の両方が必要な
> 案件向けに `full` = `common` + `site` + `system` を足す。**旧名（`website` / `websystem`）は消さない**
> ＝稼働案件のトークンがこの名前に紐づいているため。

| 層 | 対象 | 中身の骨子 |
|---|---|---|
| [`common/`](common/) | **両方（共通コア）** | 現場の配管＝ルールの更新（`bin/rules-update.sh`・`rules/modes/rules-update.md`）・テンプレ還元の投函（`bin/rule-report.sh`）・別マシンのエージェントとのやり取り（`rules/modes/mailbox.md`）・プロジェクトメモ登録（`rules/modes/hana-memo.md`・`/hana-memo`）・記録の雛形（`documents/pending-issues.md`・`documents/rule-improvements.md`）。共通部分を移すたびにここが厚くなる |
| [`website/`](website/) | **WEBサイト制作**（コーポレートサイト・LP・小規模サイト。静的HTML or PHP + Sass） | **統括＋開発の2セッション構成（director/developer＝別ウィンドウ・受け渡しは `documents/handoff.md`）**、Design.md=SSOT、開始ゲート（start）→ 制作進行＝チェックリスト駆動（build-progress）→ 実装（page-build/page-update/design-replication）→ 公開前チェック（check）→ 運用・SEO（seo-operation）、hp-loop 連携（mailbox/hp-loop-dialogue）、見積もり（estimate-format＝CSV積算・検算・過去見積との比較）、スライド資料PDF（deck-format） |
| [`websystem/`](websystem/) | **WEBシステム開発**（業務システム・管理画面。Laravel + Next.js 等） | **統括＋開発の役（director/developer）＝窓は1つか2つを `project-config.md`「エージェント構成」で選ぶ（既定は1窓＝1人が2役を兼ねる。役は消えないので順序は守る）。コミットを打つのは統括＝検品を通してから（2026-10-24 に website と同じ持ち場へ統一＝TB-014）**、TDD（tdd/testcode/frontend-test）、API実装規約（api-design）、仕様書HTML（spec-format）、コミット規約・領域分割（commit）、本番デプロイ（deploy）、見積もり（estimation=内部のタスク抽出・難易度評価／quotation=顧客向け見積書／estimate-log=採用見積もり台帳）、hp-loop 連携（mailbox/hp-loop-dialogue。対の分析ループがあるプロジェクトのみ）、スライド資料PDF（deck-format） |

## 使い方（新規プロジェクトへの導入手順）

> 🚀 **初回の配布だけを手早くやるなら [`first-time-setup.md`](first-time-setup.md)**（人間用・5分・コピペ手順）。
> 下は各手順の理由まで含めた詳細。**2回目以降の配り直しは不要**＝案件のエージェントが自分で取りに来る（下記④）。

1. **配布する**（手でコピーせず `bin/distribute-rules.py` を使う。版を刻み、配布先を記録するため）

   ```bash
   # 同じマシン上の案件へ（--yes が無ければ下見だけ）
   python3 bin/distribute-rules.py apply website /path/to/project --dest-name "案件名" --yes
   # 別マシンの案件へ（版を刻んだ tar.gz を作って渡す）
   python3 bin/distribute-rules.py pack website "案件名"
   python3 bin/distribute-rules.py list          # どこに何版を配ったか
   ```

   - **版が刻まれる**：`.claude/rules-version` に `<テンプレ>@<配布日>/<SHA>`。現場からの通知（`bin/rule-report.sh`）がこの版を件名に載せるので、受け取った側は `git log <SHA>..HEAD --oneline -- claude-rules/<テンプレ>/` で **「その指摘はもう直っているか」を機械で判定できる**。手でコピーすると版が無く、この判定ができない
   - **未コミットのまま配れない**：版の SHA と中身がズレると判定が丸ごと嘘になるため、`claude-rules/<テンプレ>/` に未コミットの変更があると止まる
   - **再配布で案件の記録を消さない**：`documents/`・`project-config.md`・`Design.sample.md`・`.claude/rules/private.md` は**既にあれば触らない**（案件が書き足していくファイル）。それ以外のルール層は毎回上書きされる＝テンプレが正
   - 配布先の一覧は [`data/rules-distribution.md`](../data/rules-distribution.md)（1案件1行・履歴は git log）
   - **トークンを1本発行して `.env` に3行入れてもらう**（`python3 bin/rule-reporter.py issue "案件名" --id <識別子> --template website`）。この1本で、その案件は「ルールの問題を送る」と「最新版を取りに来る」の両方ができる。入れないと配り直しが毎回手作業になる
2. **`project-config.md` を最初に記入する**（プロジェクト固有の値はすべてここに集約。ルール本文には書かない）。**「URL・確認環境」節**（ローカル／ステージング／本番の確認URL）は、AI が表示確認のたびにユーザーへ聞かずに済むよう**早い段階で埋める**（🚨 Basic認証等の実値は書かない）
3. website の場合：`Design.sample.md` を参考に、そのプロジェクトの `Design.md` を作る（`start.md` §1 の手順。Design.sample.md 自体は記入例なのでコピー先に持ち込まなくてよい）
4. `documents/pending-issues.md`・`documents/rule-improvements.md` は **空の状態から**運用を始める
5. website の場合：`documents/build-checklist.md` は **ひな形（標準工程の項目カタログ）**。そのまま使わず、案件に合わせて展開・追加・対象外化し、`B-NNN` を採番して台帳にする（`rules/modes/build-progress.md` §1）
6. website の場合：**2セッション構成の起動手順**（統括 `/director` と開発 `/dev` をどう開くか）を `project-config.md`「エージェント構成」節に記入する。統括が起動時の環境点検でここを読み、開発セッションが開かれていなければユーザーに開き方を提示する（1セッションで回す運用も同節で選べる）
7. websystem の場合：`documents/specs/_template.html` を起点に仕様書を作る（`document.md` は新規プロジェクトでは作らない）
8. websystem の場合：**2セッション構成を使うかを決める**。`project-config.md`「エージェント構成」節の既定は `使わない`＝**1窓**（1人が統括と開発の2役を帽子で持ち替えて最後まで回す。🚨 **役は消えない**ので「決める → 渡す → 作る → 検品する → コミットする」の順序は守る＝`rules/modes/director.md` 冒頭の読み替え）。`使う` と記入すると統括 `/director` と開発 `/dev` に分かれ、**仕様を決める役と作る役が別のウィンドウ**になる（同節に起動手順も記入する）。git の持ち場は **website と同じ**＝**コミットを打つのは統括**（検品を通してから）・開発は `git add` / `commit` / ブランチ切替をしない。**Codex クロスレビューも統括が回す**（🔄 2026-10-24 に反転。それ以前は開発側だった＝自走モードの安全装置の名残。TB-014）
9. **配布先の Claude Code のバージョンを確認する**（2026-07-24 のルール3層化以降）：ルールは「常時＝`.claude/rules/`（フロントマター無し）／条件付き＝同（`paths:` フロントマター）／読み込み式＝`rules/modes/`」の3層。**`paths:` による条件付き適用は比較的新しい機能**なので、配布先の Claude Code が古いと条件付き層が常時ロードに縮退する（動作は壊れないがトークン節約が効かない）。`claude update` で最新化しておく

## テンプレートの設計原則（編集時に守ること）

1. **固有値はルール本文に書かない** — クライアント名・実パス・ブランド色・スタックのバージョン等は各プロジェクトの `project-config.md`（デザイン値は `Design.md`）に置き、ルール本文は参照する。例として残す場合は「例:」と明示する
2. **重複定義しない** — 同じルールは1ファイルを本家にし、他は参照で繋ぐ（片方を直して他方が古くなる「版ズレ」を防ぐ）。**この原則が及ぶ範囲は「1つの配布テンプレートの中」**：`website/` と `websystem/` は別々にコピー配布され、配布先は片方しか持たない＝**テンプレート間で同じ規律が両方に書かれているのは重複ではなく必要な冗長**（一方を消すと、そのテンプレを受け取った現場では「規定なし」になる）。ただし**両テンプレに書くと決めた規律は、片方だけ直さない**（更新時は必ずもう一方も見る）
3. **安全ゲートを崩さない** — 外部送信・本番改変・push・破壊的操作は合意ゲートを通す。捏造しない（要確認情報は確定しない）
4. **ルールを削除・統合するときは「行き先」を残す** — ルールファイルの削除・再編は、**消えた事実に誰も気づけない**という特有の危険がある（以後の AI は現存ファイルを検索して無ければ「規定なし」と判断するのが自然で、これは責められない＝**仕組みの側で防ぐ**）。したがって：
   - 削除・統合するファイルは、**1本ずつ「統合先」または「意図的な廃止（理由つき）」をコミットメッセージに明記する**
   - **行き先が書けないファイルは、そのコミットでは削除しない**（書けない＝まだ判断がついていない、ということ）
   - 再編後、**旧ファイルが参照していた成果物（雛形・SSOT ファイル等）が配布物に残っているか**を確認する。ルールが存在を前提にするファイルは、**必ず雛形を同梱する**（参照先の無いルールは、現場で「推測で埋めてよい」と解釈される）

## テンプレート自体の育て方（現場の声を還元するループ）

テンプレートは固定マニュアルではなく、**使う開発エージェント自身の気づきを吸い上げて育てる**。「記録と反映を分離」した上で、テンプレ級の気づきを myagent（＝ルールを更新する側）まで届け、**必ず社長ゲートを通して**反映する。

### ① 記録（現場・低摩擦）— 全プロジェクト共通

- 運用中に気づいたルールの不足・乖離・矛盾は、そのプロジェクトの `documents/rule-improvements.md` に **その都度 `RI-NNN` で1行記録**する（開発を止めない・会話に埋もれさせない）。
- そのうち「このプロジェクト固有でなく、**テンプレート全体に還元すべき**」と判断したものには **`[テンプレ還元]`** と印を付ける（プロジェクト固有の設定は `project-config.md`／`Design.md` 側の話で、テンプレ本文には持ち込まない）。
- **現場で実際に使って問題を感じたものは「指示書」形式で書く**（2026-07-21 社長決定）：ルール開発エージェント（当該プロジェクトの文脈を知らない汎用エージェント）が**それだけ読んで修正作業に入れる自己完結の依頼文**（対象ファイル・該当記述の原文引用・現場で何が起きたか・変更案・なぜ・再現に必要なバージョン/コマンド/エラー）。書式は各配布物の `rule-improvements.md` 冒頭「指示書」節に定義済み。**運用は二段階**＝発見時は1行の仮記録でよく、送付・持ち帰りに出す前（還元状態を進める前）に指示書形式へ展開する。社長はこの指示書をそのまま myagent（ルール開発側）へ渡し、myagent は③のとおり**鵜呑みにせず検証**してから反映する。

### ② 送る（テンプレ級だけ・経路はテンプレで異なる）

- **両テンプレ共通**：`[テンプレ還元]` 印の気づきを **`bash bin/rule-report.sh --subject "[<ファイル名>] 要旨" "（指示書）"`** で送る。スクリプトはテンプレに同梱されているので、**mailbox を持たない案件でも届く**（手順は各テンプレの `rules/modes/mailbox.md` §2-3）。
- **解析↔開発の mailbox とは別の経路**：`.env` のキーも別（`RULE_REPORT_URL` / `RULE_REPORT_TOKEN`）で、権限は**投函だけ**（受信箱を持たず、他の宛先へも送れない）。通知のために `agent` トークンを配ると「どこへでも送れる」権限を全案件へ開くことになるため、目的の違うものを同じ道具にしない。
- **版は自動で載る**：`.claude/rules-version` を件名に前置するので、受け取った側は「もう直っている件か」を版で仕分けできる。現場が版を書く必要はない。
- **トークンの発行・失効は myagent 側**：`python3 bin/rule-reporter.py issue <案件名> --id <識別子> --template <website|websystem>` ／ `revoke RR-NNN --reason "…"` ／ `list`（最終使用と接続元IPが見えるので、把握していない場所から使われたら失効させる）。手順は `myagent/rules/modes/mailbox.md`「ルール通知の投函専用トークン」。
- **未発行の案件は空振りしない**：`.env` にキーが無ければスクリプトが止まり、`rule-improvements.md` に残して社長に依頼するよう促す。

### ③ 選別・起票・反映（myagent 側・reviewer 型・社長ゲート必須）

myagent の**有人棚卸しセッション**で処理する（無人では反映しない＝ルール編集の社長ゲートと整合）：

1. **受信**：`to: rule-kaizen` の受信箱（`data/mailbox/new/`）と、各プロジェクトの `rule-improvements.md` の `[テンプレ還元]` 印を集める。届いた件名には**送り主が使っているテンプレ版**が入っているので、まず `git log <版のSHA>..HEAD --oneline -- claude-rules/<テンプレ>/` を引いて**すでに直っていないかを確認する**（直っていれば「その版では未修正／現行では対処済み」と判断して、配布し直しの要否だけ見る）。
2. **選別**：汎用性を判定する。テンプレ級 → 次へ／そのプロジェクト固有 → 「`project-config.md` 側の話」と切り分けて差し戻す（テンプレ本文に固有値を入れない）。既存ルールとの**矛盾・重複**もここで確認する。
3. **起票**：すぐ反映しないものは [`TEMPLATE-BACKLOG.md`](TEMPLATE-BACKLOG.md) に `TB-NNN` で積む（届いたが未反映の提案の置き場）。
4. **差分案 → 社長承認 → commit**：反映する差分案を作り、**社長が承認してからコミット**する（勝手にテンプレを書き換えない）。反映後、**受信メッセージを `new/`→`cur/` へ移す**（`rule-kaizen` は認証主体を持たないため自名義の `mailbox.sh done` は不可＝**president=admin トークンの `mailbox.sh done`**、または棚卸しセッションが VPS 上で当該 JSON を `cur/` へ移動する。本文は編集しない・履歴を消さない）。あわせて `rule-improvements.md` の該当 `RI-NNN` は「反映済み」にする（現場側の記録）。

### ④ 届ける（配ったあとの更新・myagent 側 → 現場）

反映しただけでは現場のコピーは古いまま。**配ってよいと決めたときに公開する**と、各案件が自分で取りに来る。

```bash
python3 bin/rules-publish.py publish website   # これをするまで現場には流れない
python3 bin/rules-publish.py status            # いま何版を配信しているか／未公開の変更があるか
```

- **公開は明示操作**：編集中の版が現場へ流れないよう、`claude-rules/` を直しただけでは配信されない（未コミットがあると公開も止まる＝版と中身をズラさない）
- **取りに来るのは現場**：各案件の `bash bin/rules-update.sh`（確認だけなら何も書き換えない）。🚨 **適用はその案件の人の確認を得てから**＝ルールが変わると作業の前提が変わるため、エージェントは勝手に `--apply` しない（手順は配布物の `rules/modes/rules-update.md`、統括の起動時点検にも入っている）
- **案件の記録は上書きされない**：守る一覧（`documents/`・`project-config.md` 等）は配布物に同梱して渡すので、現場のスクリプトに同じ一覧を書き写さない＝足した日にズレない
- **誰がどの版を持っているか**は `python3 bin/rule-reporter.py list`（最後に取りに来た版が出る）。止めるときは `rule-reporter.py revoke`（1案件）／`rules-publish.py unpublish`（全案件への配信）

### 配る単位＝プロファイル（層の組み合わせ）

配布プロファイルは「`claude-rules/<層>/` を重ねた一式」で、**一覧の正は [`profiles.json`](profiles.json) ひとつ**。
読む側が Python 2本（`bin/distribute-rules.py`・`bin/rule-reporter.py`）と PHP 1本
（`site/tools/rules/index.php`）に分かれて言語をまたぐため、コードに同じ一覧を3つ書くのをやめて
データに1つ置いてある。**層を増やす・組み合わせを増やすときに触るのはこのファイルだけ。**

```jsonc
{ "profiles": { "website": ["common", "website"], "websystem": ["common", "websystem"] } }
// 最終形の想定: website=[common,site] / websystem=[common,system] / full=[common,site,system]
```

器として入っている約束：

| 約束 | なぜ |
|---|---|
| **同じ相対パスを2つの層が持っていたら、配る前にエラーで止める** | 黙って後の層で上書きすると、どちらが正かが配布先でしか分からなくなる（**設計原則②**）。面ごとの違いは別ファイル名の追補で置く |
| **版（`.claude/rules-version`）は1行目が `<プロファイル>@<配布日>/<SHA>`** | 現場（`rules-update.sh`・`rule-report.sh`）は `head -1` しか読まない＝2行目を足しても既存案件の挙動は変わらない |
| **層が2つ以上のときだけ2行目に `layers: common=<sha> site=<sha>`** | 1層のプロファイルの刻印は**従来とバイト単位で同じ**＝稼働中の案件に差分を出さない |
| **プロファイル全体の SHA は「どれかの層を最後に触ったコミット」** | 受け取り側の引き方が `git log <SHA>..HEAD -- claude-rules/<層>/…` だから、1個で足りる |
| **層が git に入っていないと既定で配らない／公開しない** | 版から変更点を引けない配布物は、現場の「もう直っているか」の判定を嘘にする（承知のうえなら `--allow-dirty`）。🚨 **SHA が無い版（`nogit`）は `--allow-dirty` でも公開させない**＝受け取り側が changelog から変更点を辿れなくなる |
| **プロファイル名・層名は形を検証する**（`[a-z0-9-]`・先頭は英数字） | 名前はコード内の定数ではなく **`profiles.json` 由来の値**。層名がそのままディレクトリ名になるので、絶対パスを書くと `claude-rules/` が丸ごと捨てられ**テンプレート外のファイルが配られる**（2026-10-28 に実証して塞いだ） |
| **`profiles.json` 自身も版の対象に入れる** | 層の追加・削除・順序の変更は**配布物の中身を変える**。層ディレクトリだけを見ていると「層を足したのに版が進まない・dirty とも言われない」＝受け取り側の判定がまるごと嘘になる |
| **壊れた定義はトレースバックでなく `❌ …` で止める**（読み取りは `distribute-rules.py` に1本化） | 読み方を2箇所に書くと判断が割れる。実際に `{"profiles": ["website"]}` という形で `distribute-rules` は落ち `rule-reporter` は通していた |
| **旧名（`website` / `websystem`）を消さない** | 稼働中の案件のトークンにこの名前が紐づいている（`rule-reporter.py` の `template`）。消すと取りに来られなくなる |
| **現場の `rule-report.sh` は許可リストを持たない** | プロファイル名は**形**（英小文字・数字・ハイフン・32文字以内）で判定する。一覧を現場に持たせると、足した日に配った先だけ古い一覧を握って報告が別スレッドへ落ちる |

機械の担保＝`bash bin/test-distribute-rules.sh`（**89項目**）・`bash bin/test-rules-publish.sh`（31項目）・
`bash bin/test-rules-update.sh`（123項目・受け口と現場スクリプトまで通す）・`bash bin/test-rule-reporter.sh`（79項目）。
🚨 **名前の形の判定は Python・PHP・配布物の bash の3箇所にある**（言語が違うので統合できない）。
同じ文字集合 `[a-z0-9-]` であることを `test-distribute-rules.sh` が見張る＝ズレると
「配布はできるのに現場の報告が別スレッドへ落ちる」が黙って起きる。

- テンプレート自体の未完課題（ツール化・定型化などの宿題）も [`TEMPLATE-BACKLOG.md`](TEMPLATE-BACKLOG.md) に置く（配布物の `pending-issues.md` には入れない）。
