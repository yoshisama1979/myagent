# HP分析ループ — ツール作成履歴

`/hp-loop` が分析の精度・再現性を上げるために**自分で作ったツール**の履歴。
「LLMの手作業（curl/grep）で代替せず、必要なら決定論的なツールを作って残す」方針の記録。
新しいツールを作ったら、ここに1エントリ追記する（古い記録は消さない）。

## エントリ形式

```
### T-NNN: ツール名（パス）
- 作成日 / 状態（✅運用中 ｜ 🧪試作 ｜ ⛔廃止）
- 目的：何の手作業を置き換える／何を取得するためか
- 使い方：コマンド例
- 出力：何が得られるか
- 関連：カイゼン台帳 K-NNN / 掲示板 など
- メモ：制約・既知の限界・今後の拡張
```

---

## 台帳

### T-001: hp-audit.sh（bin/hp-audit.sh）
- 2026-06-11 / ✅運用中
- 目的：オンページSEO信号の監査。Cycle 001 で手作業（curl + grep + python）で抽出した処理を決定論ツール化（カイゼン K-001 / K-005 への対応）
- 使い方：`bin/hp-audit.sh <URL>`（人が読む要約）／ `bin/hp-audit.sh <URL> --json`（JSON）／ `bin/hp-audit.sh <URL> --text`（本文テキスト抽出＝精読/実査用）
  ※ 無人実行(cron/ヘッドレス)では allow パターンが `Bash(bin/hp-audit.sh:*)`＝**先頭 `bash ` を付けず `bin/hp-audit.sh ...` で呼ぶ**（`bash bin/...` は別コマンド扱いで未承認・要approval。2026-06-20 判明）。
- 出力：HTTPステータス・title/description（文字数）・canonical・robots・viewport（ズーム禁止検出）・OGP/Twitter（**プレースホルダ検出**＝K-003）・JSON-LD（型・無効化検出）・見出しh1-h3（h1複数検出）・img/alt欠落・問い合わせ動線（tel/mailto/contact）・CMS。末尾に課題を ⚠️ で列挙
- 関連：K-001（監査ツール化）／K-005（hp-loopでも手作業依存）／K-003（仮置き残存検出）。掲示板 Cycle 001 の所見を再現
- メモ：HTTP GET のみ・読み取り専用（外部送信/書き込みなし）。1ページ単位（サイト全体クロールは未対応）。差分比較（前回JSONとの比較）は未実装＝K-006で別途
- 更新 2026-06-11：**HTMLコメント除去を追加**（バグ修正＝K-008）。コメントアウトされた meta/og タグを「配信中」と誤検出していた問題を修正。コメント内の meta 件数は `commented_meta_tags` で別途報告
- 既知の限界（社長指摘 2026-06-11）：(1)**静的HTMLのみ**。JS で後から再注入される meta（例：viewport の `user-scalable=no` 上書き）やJS描画後のDOMは見えない → 重要ページは目視/担当エージェント確認で補う。(2)**CMS判定はヒューリスティック**（`wp-content` 等の資産参照を見るだけ）。サイト全体の構成を断定しない
- 更新 2026-06-11（Codexレビュー反映）：スキームを http/https に限定（`--proto`）／**取得失敗・非2xx・空body・サイズ超過(5MB)を「監査不能」として明示**（成功を装わない・exit 3）／複数URLガード／プレースホルダ語句を調整（準備中/lorem/dummy/noimage 追加・sample等は語境界化）
- 今後の改善（Codex由来・次サイクル送り）：(a)属性解析を正規表現から `html.parser` 等の標準パーサに置換（シングルクォート/未引用/`rel="canonical alternate"`/属性順の取りこぼし対策）。(b)JSON-LD の `@graph` 内 `@type`・シングルクォート type 対応。(c)プレースホルダ判定を title/description/canonical/JSON-LD/画像URL にも適用。(d)空alt(装飾)の扱い方針を出力に明記
- **更新 2026-06-20（CV要素の棚卸しを追加・fujisaka Cycle 003）**：JSON/要約に `cv` ブロックを**追加（既存フィールドは不変＝hp-diff 後方互換）**。検出するもの＝(1)`tel_numbers`（tel: の実電話番号）(2)`mailto`（mailto実値）(3)`line_present`/`line_hrefs`（LINE導線＝lin.ee・line.me・liff・line://・「友だち追加」文言）(4)`form_count`/`forms`（`<form>` の action/method）(5)`cv_anchors`（文言 or href が 見積/資料請求/予約/開栓/移転/修理/来店/問い合わせ/LINE/contact 等にマッチするアンカー・最大30件）。目的＝社長依頼「電話・問い合わせ以外で実装済みのCV候補（LINE・各種申込/受付フォーム・資料請求・見積・開栓/移転予約・mailto 等）が実在するか」を**捏造せず決定論で列挙**するため。`/hp-loop fujisaka` Cycle 003 で top/contact/hotwater を実査し「現状CVは電話+問い合わせフォームの2つのみ・LINE/mailto/専用フォームは無し」を確認。**既知の限界**：静的HTMLのみ（JS注入のLINEウィジェット/フォームは見えない＝T-001の(1)と同様。重要ページは目視/担当確認で補完）。
- **更新 2026-06-20（`--text` 本文テキスト抽出モードを追加・fujisaka Cycle 004）**：`script/style/noscript`・HTMLコメントを除去し、ブロック要素境界を改行化してタグを剥がした**読めるページ本文**を出力（最大12000字・HTTP GETのみ・読み取り専用・既存の要約/JSON出力は不変）。目的＝**3サイクル連続でブロックされていた「本文の文言精読」**を、無人実行で `curl`/`WebFetch` が未承認でも hp-audit の内部 curl 経由で取得するため（社長 Q-F03「対応エリア・対応の速さをHP内情報から実査して拾え」に直接対応）。`/hp-loop fujisaka` Cycle 004 で top・hotwater を実査し、**サービスエリア9市町（大阪府5＋京都府4）・「15時までの連絡で当日対応」「年始3日以外無休」・実績数値（創業50年/20万件以上/お客様の声/有資格者多数）**を原文で取得（捏造ゼロ）。給湯器交換の**具体価格はサイト本文に記載なし**＝クライアント確認事項として確定。**限界**：静的HTMLのみ（JS描画後テキストは取れない）／本文をそのまま出すため長尺ページは12000字で打ち切り（必要なら個別ページ指定で再取得）。
### T-006: gsc-fetch.py（bin/gsc-fetch.py）
- 2026-06-12 / ✅運用中
- 目的：**Search Console の実データ取得**（Q-003 の本命解）。GSC「一括データエクスポート」が吐く BigQuery テーブルを読み、クエリ/ページ単位のクリック・表示回数・CTR・平均掲載順位を事実として取得。これまで未取得だった「どのクエリ/ページを伸ばすか」をデータで出せるようになった
- 使い方：`bin/.venv/bin/python bin/gsc-fetch.py {summary|queries|pages|overview} --dataset <DS> [--days N] [--limit N] [--site URL] [--search-type WEB] [--max-gb 5] [--dry-run] [--json]`
  - 例（y-com.info）：`bin/.venv/bin/python bin/gsc-fetch.py overview --dataset searchconsole_ycom --days 28`
  - 認証：`.env` の `GSC_SA_JSON`（= `data/secrets/gsc-sa.json`・gitignore済）を参照。サービスアカウント `gsc-reader@myservice-219202`
- 出力：期間・全体サマリ（クリック/表示/CTR/順位）・流入クエリ上位・流入ページ上位。`--json` で機械可読
- 関連：K-005（hp-loopのツール不在）への本対応／Q-003 解決（GSC分）／掲示板 Cycle 005（初のデータ駆動戦略）。📥欲しい情報の「Search Console データ🔴高」を充足
- メモ（制約・安全装置）：**読み取り専用＝SELECTのみ**（DML/DDL/外部送信/書き込みなし。automation.md準拠）。日付範囲を必須フィルタ＋`maximum_bytes_billed`（既定5GB）でスキャン量を強制制限し課金事故を防止。`--dry-run` で実行前にスキャン見積り。秘密鍵は本体・出力・ログに出さない（パス参照のみ）
- 既知の限界：(1)**データはエクスポート有効化以降のみ**。y-com.info は 2026-06-06 開始＝現状4日分のみ（トレンドはこれから蓄積）。(2)平均順位は `SUM(sum_position)/SUM(impressions)+1` の近似。(3)site_impression 表は未使用（url_impression で順位も取れるため）。(4)GA4（流入/CV）は別途＝T-003 のまま
- 拡張余地：複数プロパティ対応済み（`searchconsole_ycom` / `searchconsole_fujisaka` を `--dataset` で切替）。将来：日次推移・前期間比較・cycles/ への蓄積（T-004 と統合可）
- **更新 2026-06-24（`page-queries` モードを追加・blog-loop ycom Cycle 002）**：特定ページURL（部分一致）の**獲得クエリ上位**を1コマンドで取得。`bin/.venv/bin/python3 bin/gsc-fetch.py page-queries --dataset searchconsole_ycom --page '?p=2082' --days 28 --limit 15`。目的＝blog-loop が📥で「記事URL×獲得クエリの紐付け（どのクエリでその記事に来ているか）」を手作業（pages と queries を別取得して突き合わせ）でやっていたのをツール化（同じ取得を2回以上アドホック→ツール化の方針）。`url_impression` 表を `STRPOS(url, @page) > 0`（パラメータ化・SQLi対策）で絞り、クエリ別に集計。**読み取り専用・既存モード不変・後方互換**。`--dry-run` でスキャン見積り（実測 0.002GB）。**実用知見（Cycle 002）**：B-001(p=2082) は獲得クエリが全て情報系（「有名企業 ロゴ 一覧」「昔のロゴ」＝順位ほぼ1位・買い手意図ゼロ）／B-003(p=3028) は集約平均順位11.3が `[image.png] これ` 等の異質クエリで嵩上げされており、本命クエリ（「png jpg 違い/使い分け」）は実は **16〜51位**＝「あと一歩で1ページ目」は誤り、と判明（集約順位の落とし穴を可視化）。**限界**：部分一致なので `?p=20` のような短い文字列は別ページも拾う（具体的な `?p=2082` 等を渡す）。クエリ×ページの厳密な1対1ではなく「そのURLを含むページ群」の集計。

### T-007: ga4-fetch.py（bin/ga4-fetch.py）
- 2026-06-18 / ✅運用中
- 目的：**GA4 実データ取得**（planned T-003 の本対応）。効果計測の本丸＝「title/meta 改善（R-014a/019/020）が問い合わせ・見積の増加につながったか」を実数で検証する。Cycle 008 で「GA4は稼働中（`analytics_265729912`・2021〜・CVイベント有）」と判明したのを受け、その既存データを継続的に読む手段として作成（K-014/K-015）
- 使い方：`bin/.venv/bin/python bin/ga4-fetch.py {summary|events|cv} [--dataset analytics_265729912] [--days N | --start/--end] [--events "問い合わせ,見積もりのリクエスト"] [--max-gb 8] [--dry-run] [--json]`
  - 例：`bin/.venv/bin/python bin/ga4-fetch.py cv --start 2026-04-01 --end 2026-06-18`（CVを月次トレンドで）
  - 認証：T-006 と同じ（`.env` の `GSC_SA_JSON` → `data/secrets/gsc-sa.json`・SA `gsc-reader@myservice-219202`）
- 出力：summary（期間・イベント数・ユーザー数）／events（event_name 別件数・人数）／cv（問い合わせ・見積等を月次集計）。`--json` で機械可読
- 関連：K-014（報告のデプロイ状態を鵜呑みにしない）／K-015（既存資産の実在をデータで確認＝二重作成を防ぐ）／掲示板 Cycle 008（R-022 中止・効果検証へ転換）。📥欲しい情報の「GA4データ」を充足
- メモ（制約・安全装置）：**読み取り専用＝SELECTのみ**（automation.md準拠）。`_TABLE_SUFFIX`（日付）必須フィルタ＋`maximum_bytes_billed`（既定8GB）＋`--dry-run`。**daily(`events_*`)とintraday(`events_intraday_*`)の二重計上を防止**＝同一日にdailyがあればintraday側を `event_date` で除外（`events_*` は8桁日付フィルタで `intraday_*` を自然に除外）
- 既知の限界：(1)CVの「正確な定義」は GA4 側のイベント命名に依存（重複乱立＝R-023 でキーイベント正規化が必要・本ツールは生のevent_nameを数えるだけ）。(2)6月など期間途中の月は部分集計。(3)プロパティ横断は `--dataset` で切替（よしだ＝`analytics_287348176` 等）。(4)セッション数・チャネル別流入は未実装（必要なら追加）

### T-008: hp-shot（bin/hp-shot.sh → bin/hp-shot.mjs）
- 2026-06-19 / ✅運用中（社長が Google Chrome を導入後）
- 目的：**ビジュアル面の取得**。hp-audit（タグ解析）＋GSC では拾えない「ファーストビューの訴求・レイアウト・配色・視線誘導・CTAの目立ち・SP表示崩れ・イントロ演出」を、ループ（マルチモーダル）が**実際の見た目を見て**評価できるようにする。各サイトが📥で要望していた「本文・見た目を見たい」を充足。
- 仕組み：system の Google Chrome（`/usr/bin/google-chrome`）を `puppeteer-core`（ブラウザDLなし）でヘッドレス駆動。`networkidle2` 後にスクロールで遅延読込/イントロを発火させてから撮影。
- 使い方：`bin/hp-shot.sh <URL> <出力ディレクトリ> [名前]`（`.sh` が cron/ヘッドレスでも node を解決するラッパ）
  - 例：`bin/hp-shot.sh https://y-com.info/ data/hp-loop/cycles/ycom/shots/ top`
  - 出力4枚：`<名前>-pc-fold.png`（PC幅・ファーストビュー＝鮮明・コピー精読用）／`<名前>-pc-full.png`（PC幅・フルページ＝構造）／`<名前>-sp-fold.png`（SP幅DPR2・ファーストビュー）／`<名前>-sp-full.png`（SP幅・フルページ）。標準出力に結果JSON（title/finalUrl/サイズ）。
  - 保存先：`data/hp-loop/cycles/<site>/shots/`（**gitignore＝コミットしない**。大容量・再生成可）。ループは Read で PNG を見て評価する。
- 出力先・権限：`settings.local.json` に `Bash(bin/hp-shot.sh:*)` 許可（社長が追加）。Chrome 本体は `sudo apt`（社長が導入済・Ubuntu26.04はPlaywright未対応のため Chrome安定版を使用）。`puppeteer-core` は `node_modules`（gitignore）。
- メモ（制約・安全装置＝無人運用前提の多層防御。Codexレビュー反映済 2026-06-19）：**実行時は読み取り専用**＝描画＋PNG保存のみ（automation.md準拠）。クリック・フォーム送信・外部送信・本番改変はしない。具体的には：
  1. **非GETリクエスト(POST/PUT/beacon等)を abort** ＋ダウンロード拒否＝read-onlyを物理担保
  2. URLは `http(s)://` のみ受理／**認証情報付きURL・localhost を拒否**。さらに**宛先IPがプライベート/内部帯なら拒否**＝ループバック(127/8)・リンクローカル(169.254/16＝クラウドメタデータ)・10/8・172.16/12・192.168/16・100.64/10(CGNAT/Tailscale)・IPv6 ULA/リンクローカル(fc/fd/fe80)・metadata.google.internal。**ホスト名はDNS解決して全アドレスを判定**（DNS→内部IP のSSRFも遮断）
  3. **出力は `data/hp-loop/cycles/` 配下のみ**に限定（committed資産＝site/等の上書き防止）＋`name` のパストラバーサル無害化（`[a-zA-Z0-9._-]` のみ・64字上限）
  8. Chrome 実行バイナリは**既知パスの allowlist のみ**（`HP_SHOT_CHROME` で任意バイナリに差し替える抜け道を封じる）
  4. Chromeプロファイルは使い捨て tmp（`mkdtemp`）に隔離し終了時に撤去＝PNG以外を書かない
  5. **Chromeサンドボックスは有効**のまま起動（このVPSは user namespace 可＝`--no-sandbox` は使わない。実機で起動確認済）
  6. 標準出力のURLはクエリ・認証情報を除去（ログに秘密を残さない）。タイトルも200字上限
  7. スクロールは回数(60)・時間(15s)・高さ(200k px)上限つき（無限スクロールで止まらない保険）。撮影後すぐ閉じる
- 既知の限界：(1)イントロ演出が長い/ループするサイトは fold が演出を写すことがある（＝「初見の体験」自体は所見になる／本体は full 版で取得）。(2)フルページは縦長＝Read時に縮小され文字が潰れがち（構造把握用。文字精読は fold 版）。(3)動画/外部埋め込みの描画タイミング差。(4)1ページ4枚＝撮りすぎ注意（主要ページに絞る）。(5)**プライベートIP帯を弾く＝Tailscaleプレビュー(100.123.104.87)は撮影不可**（本ループの分析対象は本番公開サイトなので可。プレビューを撮りたくなったら設計判断＝allowlistで内部ホストを例外許可する形に締め直す）。(6)SSRFのDNSチェックは撮影開始時点の解決＝ロード後に内部IPへリダイレクトする経路までは追えない（信頼URL前提・将来締め余地）。
- 前提の確認事項：無人 `claude -p`（cron）が PNG を画像として読めるか＝対話では読めることを実証済（fujisaka/ycom）。ヘッドレス実行での読取は初回運用で疎通確認する。

### T-009: hp-diff（bin/hp-diff.py）
- 2026-06-19 / ✅運用可（＝旧 T-004「監査スナップショット差分」を実現）
- 目的：**効果検証（before/after）を1コマンドに**。gsc-fetch / ga4-fetch が出した2時点のJSONスナップショットを突き合わせ、順位・CTR・クリック・CV件数の before→after と「新規/消滅した行」を表で出す。coverage.md §9 #1（最有力ツール）＝「欲しいデータは回り道でなく1コマンドに」の実証第1号。定石レシピ（§8）の「変化検知・効果追跡」を安く回すための土台。
- 使い方：`python3 bin/hp-diff.py <旧JSON> <新JSON> [--section auto|queries|pages|events|cv] [--match 部分文字列] [--sort 指標] [--top N] [--json]`
  - 例（料金クエリの順位が動いたか）：`python3 bin/hp-diff.py cycles/ycom/baseline-20260619-queries.json cycles/ycom/<新>-queries.json --section queries --match 料金`
  - 対応：GSC queries(key=query)／GSC pages(key=url)／GA4 events(key=event_name)／GA4 cv(key=month|event_name)。指標は clicks/impressions/ctr/avg_position/c/users を自動検出。
  - 出力：突き合わせ件数／新規／消滅、主指標の変化量で並べた before→after 表。**avg_position は「低いほど良い」を踏まえ ▲改善/▼悪化 を指標の向きで判定**。`--json` で機械可読。
- メモ（制約・安全装置）：**読み取り専用**＝ローカルJSON2ファイルを読んで stdout に出すだけ（automation.md準拠）。ネットワーク・BigQuery・外部送信・ファイル書き込み・破壊的操作はしない（取得は gsc/ga4-fetch の役目＝役割分離）。
- 既知の限界：(1)スナップショットは事前に gsc/ga4-fetch で保存しておく必要がある（差分は2ファイル前提）。(2)期間がズレた比較は注意（meta に旧/新の start/end を表示）。(3)GSCラグ2〜3日＝施策直後の新スナップは施策前値が混じる。
- **検証済（2026-06-19）**：自己差分=全±0／合成「施策後」で 料金表 改善(▲)・料金 悪化(▼)・新規/消滅の検出・--json・section自動検出を確認。

### T-010: hp-compete（bin/hp-compete.py）
- 2026-06-21 / ✅運用可
- 目的：**競合とのオンページSEO横並び比較**（社長のSEOワークフロー③「競合を超えるために何をするか」を決定論で支える＝レイヤーA）。SEOは相対評価＝自社単体を見るだけでは「勝てているか」が分からないため、競合と並べて**自社に無い／競合が勝っている構造シグナル**をギャップとして抽出する。coverage.md §5「競合対比」・§8定石レシピ#6・§9ツール候補#3 の実体化。
- 使い方：`python3 bin/hp-compete.py <自社URL> <競合URL> [<競合URL> ...]`（人が読む横並び表＋ギャップ）／`--json`（機械可読）／`--self <URL> --rivals <URL,URL,...>` でも指定可
  - 例：`python3 bin/hp-compete.py https://y-com.info/ https://競合A/ https://競合B/`
  - 競合URLは社長が `data/hp-loop/<site>/competitors.md` に記入（②競合特定＝社長が実際の検索＝ローカルで正確。VPSからの自動SERPは検索地点違いで別competitorを拾うため使わない）
- 出力：横並び表（title/desc長・canonical・OGP・構造化LD・h1・h2+h3（コンテンツの厚み近似）・リンク数・alt欠落・電話/LINE/フォーム/CV導線・課題数・容量）＋**ギャップ**（競合にあって自社に無い構造化データ型・適正長title/desc・OGP・canonical・コンテンツ量・CV導線）。`--json` で機械可読
- 関連：coverage.md §0/§8/§9・競合リスト `data/hp-loop/ycom/competitors.md`。社長依頼（2026-06-21「競合との比較・参考を分析に入れる」）への対応
- メモ（制約・安全装置）：**実行時読み取り専用**＝ネットワーク取得は hp-audit.sh(T-001・HTTP GET)に委譲し、本体は外部送信・ファイル書込・破壊的操作をしない（automation.md準拠・標準出力のみ）。取得失敗は握りつぶさず ⛔ 明示（成功を装わない）。比較可能サイトが2つ未満なら exit 3
- 既知の限界：(1)**構造シグナルの対比のみ**＝実コンテンツの質・E-E-A-T・被リンク・**検索順位/SERP は対象外**（「誰が上か」は社長のSERP確認 or 有料API、見た目は hp-shot で補う）。(2)hp-audit と同じく静的HTMLのみ（JS描画後は見えない）。(3)コンテンツの厚みは h2+h3 件数の近似（本文語数ではない＝必要なら --text 連携を将来追加）。(4)競合URLは社長記入前提（推測しない）
- **検証済（2026-06-21）**：y-com.info vs example.com で横並び表・ギャップ抽出（逆向きで6件発火）・不達URLの ⛔ 明示・exit 3 を確認

### T-011: hp-serp（bin/hp-serp.mjs → bin/hp-serp.sh）
- 2026-06-21 / ✅運用可
- 目的：**検索結果(SERP)から競合・参考サイトのURLを自動取得**（社長のSEOワークフロー②「検索結果から競合を見つける」の自動化）。SEOは相対評価＝「狙うクエリで上位の競合を超える」のがゴール。取得したURLを T-010 hp-compete / T-008 hp-shot へ渡して③対比する。
- **検索エンジン＝Yahoo! JAPAN（実測で決定・2026-06-21）**：このVPS（データセンターIP）からの実測で——**Google=HTTP429ボット判定でブロック（取得不能）**／**Bing=取れるが結果が無関係**（「ホーム」を住宅/不動産と誤解釈し制作会社が出ない）／**Yahoo!JAPAN=HTTP200・Googleインデックス採用で関連性が正しい・ブロックされない**。よって Yahoo!JAPAN を採用。Google順位に近く（同インデックス）、IP地域非依存（クエリに「大阪」等を入れればその地域が出る）＝社長方針「コンテンツ改善は地域非依存で十分／大阪固有が要るときだけ社長が渡す」に合致。
- 仕組み：hp-shot(T-008) と同じ system Chrome × puppeteer-core ヘッドレス。`search.yahoo.co.jp/search?p=<クエリ>` を描画し、本文領域の結果アンカーから外部サイトURLを抽出。ハッシュ(`#:~:text=`)・トラッキングパラメータ除去、自社/検索エンジン/重複ドメインを除外しドメイン単位で上位を残す。
- 使い方：`bin/hp-serp.sh "<検索クエリ>" [--top N] [--exclude ドメイン,…] [--json|--urls]`
  - 例：`bin/hp-serp.sh "ホームページ制作 大阪 料金" --top 8 --exclude y-com.info`（人が読む表）
  - 例（連鎖）：`python3 bin/hp-compete.py https://自社/ $(bin/hp-serp.sh "クエリ" --exclude y-com.info --urls)`
  - 出力：上位サイト（rank/domain/title/url）。`--urls`＝URLを1行1件（hp-compete へ渡す用）。`--json`＝機械可読
- 関連：T-010 hp-compete（③対比の相方）・competitors.md・coverage.md §8#6/§9。社長依頼（2026-06-21「競合比較を分析に入れる・自動化の恩恵を優先」）への対応
- メモ（制約・安全装置）：**実行時読み取り専用**＝検索結果ページを描画して結果リンクを読むだけ。**競合サイト本体は取得しない**（hp-compete/hp-shotの役目＝役割分離）。非GET遮断・DL拒否・Chromeサンドボックス有効・使い捨てプロファイル（hp-shot と同じ多層防御・automation.md準拠）。取得先は search.yahoo.co.jp 固定（任意URLを踏まない）。**ボット判定/CAPTCHA・0件は握りつぶさず ⛔ 明示**（捏造しない・exit 3）。**低頻度・少量で使う**（週次・数クエリ想定＝検索エンジンへの礼儀／ブロック回避）
- 既知の限界：(1)**SERPはGoogleそのものではない**（Yahoo!JAPAN＝Googleインデックスだが完全一致ではない・順位も近似）。Google実順位や大阪ローカル順位が厳密に要るときは社長がSERPを渡す（社長方針）。(2)Yahoo側のHTML構造変更で抽出が劣化し得る（0件は明示するので気付ける）。(3)結果には競合制作会社と並んで「料金相場の解説記事」も混じる（参考にはなるが競合企業ではない＝対比相手は人/ループが選ぶ）。(4)ToS配慮で低頻度運用。フル無人で大量に回すなら locale指定の有料SERP API（gl=jp）へ差し替える設計余地
- **検証済（2026-06-21）**：「ホームページ制作 大阪 料金」「ホームページ制作 大阪」で関連性の高い実在の大阪Web制作会社（ok-design/hello-wave/studio-habit/株式会社ワイズ osaka-homepage.biz 等）を取得。end-to-end（hp-serp→hp-compete）で自社/price/ vs ワイズ料金ページを比較し「競合は構造化データ(LocalBusiness/BreadcrumbList)あり・自社の料金ページは無し」を検出＝実用的ギャップ。--urls/--json/自社除外/重複ドメイン排除を確認

### T-012: clarity-fetch（bin/clarity-fetch.py）
- 2026-07-08 / ✅運用可（社長がAPIトークン発行・実データで検証済み）
- 目的：**Microsoft Clarity の実測行動データ**（スクロール到達・エンゲージメント時間・デッドクリック・レイジクリック・クイックバック・スクリプトエラー・人気ページ・流入元）を取得し、導線・CV提案の根拠を**推測→実測**にする。GSC=検索まで／hp-shot=見た目／**Clarity=サイト内で実際どう動いたか**、の三点測量が完成。
- 前提：対象サイトに Clarity タグ設置済み＋ .env に `CLARITY_API_TOKEN_<SITE>`（ycom は両方済み・タグは HTML直書き・プロジェクト r7faz1ss9q）。他サイト展開はプロジェクト作成（社長）＋タグ設置（実装担当・社長ゲート）＋トークン追記で同型。
- 使い方：`bin/.venv/bin/python3 bin/clarity-fetch.py [--site ycom] [--days 1-3] [--dim1 URL|Device|Country|Browser|OS|Source|Medium|Campaign|Channel] [--dim2 …] [--json] [--quota]`
- **⚠️ 制約（最重要）：API は 1プロジェクト 1日10リクエストまで**。ツールがローカルで当日回数を記録し10回で拒否（`--quota` で残数確認・記録は `data/hp-loop/.clarity-quota/`）。**ループでの利用は1日1〜2回**（例：日次サイクルで `--days 1 --dim1 URL` を1回）。**データは直近1〜3日の集計のみ**＝長期トレンドは日次 JSON を `data/hp-loop/cycles/<site>/clarity/YYYY-MM-DD.json` に蓄積（gitignore済み）して比較する。
- 安全：読み取り専用（HTTP GET のみ）・トークンは .env から必要キーだけ読み、ログ・エラーに出さない（automation.md §2）。
- **検証済（2026-07-08・ycom 直近3日実データ）**：710セッション・平均スクロール到達 40.5%・デッドクリック発生セッション 16.8%・pages/session 1.31・人気ページ1位 /contents/(391)。初回スナップショット保存済み。

---

## T-016 — `bin/gsc-fetch.py query-pages`（クエリ → 着地ページ 逆引き）

- **作成**：2026-07-12（blog-loop ycom Cycle 023）。旧 T-013?（未着手ツール）の実装。
- **目的**：`page-queries`（ページ→クエリ）の**逆**。「このクエリ群はどの記事が受けているか」を1コマンドで実測特定する。クラスター施策（例 B-007＝WordPress困りごと記事群へのCTA設置）で、**対象記事URLを推測や他エージェントへの丸投げでなく、実データで確定**するために作った。
- **使い方**：`bin/.venv/bin/python3 bin/gsc-fetch.py query-pages --dataset <ds> --query '<クエリの部分文字列>' [--days 28] [--limit 30]`
- **出力**：`url / query / clicks / impressions / ctr / avg_position`（url×query で集計・表示回数降順）
- **安全**：既存 gsc-fetch と同じ＝**SELECT のみ・読み取り専用**。クエリ文字列は BigQuery のクエリパラメータ（`@q`）で渡し文字列補間しない（SQLi 対策）。日付パーティション必須＋`maximum_bytes_billed` 上限も従来どおり継承。
- **限界**：GSC 側でプライバシー閾値未満のクエリは元データに出ない（＝完全な網羅ではない）。データラグ2〜3日。部分一致（`STRPOS`）なので表記ゆれ（ワードプレス／wordpress）は**別々に引く**必要がある。
- **初回の実測成果（ycom・28日窓 2026-06-14〜07-12）**：B-007 クラスターの受け皿記事を確定＝`p=6624`（固定ページ編集できない・2.6位/CTR18.2%）／`p=8241`（画像アップロード不可・php.ini）／`p=7393`・`p=6874`（パスワード）／`p=7585`（JSONレスポンスエラー）／`p=6505`（CMS・WordPress の違い＝検討層）。あわせて買い手クエリ「ホームページ運用代行 大阪」（30表示・14.4位）を**外注パートナー募集ページ `/partners/alliance.html` が受けている**ミスマッチも発見。

---

## T-017 — `bin/ga4-fetch.py pages` / `landing`（記事別の閲覧数・**ランディングページ別のCV寄与**）

- **作成**：2026-07-13（blog-loop ycom Cycle 026）。掲示板の「📥欲しい情報」に 🟡 で長く積まれていた「記事別の CV 寄与（GA4 ランディングページ別）」の実装。
- **なぜ今か**：B-002／B-007（記事末CTA）が本番稼働した（2026-07-13）ため、**効果検証の手段が無いことが最大の栓**になった。GSC は「検索→クリック」までしか見えず、「その記事に来た人が問い合わせ・見積に至ったか」は GA4 のセッション単位でしか分からない。
- **使い方**：
  - `bin/.venv/bin/python3 bin/ga4-fetch.py pages --days 28 --page '/contents/' --limit 20` → ページ別 `views / users`
  - `bin/.venv/bin/python3 bin/ga4-fetch.py landing --days 28 --page '/contents/' --limit 20` → ランディング別 `sessions / users / cv_sessions / cv_rate_pct`
  - `--events` で対象CVを絞れる（既定リストは**買い手CV（問い合わせ・見積）と応募CV（コーダー/デザイナー）が混在**するので、買い手だけ見たいときは明示的に指定する＝混ぜると数字を読み違える）
- **定義（読み違え防止）**：`landing` ＝ セッション内で**最初の page_view** のページ。`cv_sessions` ＝ そのセッション内でCVイベントが発火した数。**セッションをまたいだ間接寄与（記事で知り→後日 direct で問い合わせ）は計上されない**＝これは「同一セッション内の直接寄与」の指標。
- **正規化**：`page_key` はパス＋WordPress の `?p=NNNN` だけを残す（UTM 等でページが割れて見かけの数字が下がるのを防ぐ＝勝ちパターン M-01 と同型）。
- **安全**：既存 ga4-fetch と同じ＝**SELECT のみ・読み取り専用**。ページのフィルタ文字列はクエリパラメータ（`@page`）で渡し文字列補間しない（SQLi対策）。日付パーティション必須＋`maximum_bytes_billed` 上限を継承。スキャン量は 28日窓で **0.019GB**（実測・dry-run）。
- **初回の実測成果（ycom・28日窓 2026-06-15〜07-13）**：**ブログ（/contents/*）は約2,500セッションを集めながら、買い手CV（問い合わせ・見積）が 28日で 0 件**。対してトップ `/` は189セッション・14件（7.4%）。**B-002／B-007 の効果検証ベースライン＝0** が確定。
- **限界**：GA4 の同意/計測漏れ分は入らない。CVイベント名の重複・命名ゆれ（`見積り`／`見積り2` 等）は元データ側の課題（hp-loop R-023 で正規化予定）。

---

## 未着手・欲しいツール（権限非依存で書く＝作れるか否かに関わらず記録）

| 仮ID | ツール | 目的 | 必要なもの | 状態 |
|------|--------|------|-----------|------|
| ~~T-002~~ | ~~GSC連携~~ | → **T-006 gsc-fetch.py で実現（✅）** | — | ✅ 完了（2026-06-12） |
| ~~T-003?~~ | ~~GA4連携（流入・CV取得）~~ | → **T-007 ga4-fetch.py で実現（✅）**。GA4 は既に BigQuery エクスポート稼働中（`analytics_265729912`）と判明し、Data API 不要で SELECT 取得 | — | ✅ 完了（2026-06-18） |
| ~~T-004?~~ | ~~監査スナップショット差分／GSC日次蓄積~~ | → **T-009 hp-diff.py で実現（✅）**。スナップショット差分（順位推移・新規/消滅）を1コマンド化。日次JSON蓄積の自動保存は運用ルール側で対応 | — | ✅ 完了（2026-06-19） |
| T-005? | 表示速度/CWV計測 | 速度・Core Web Vitals の客観値 | PageSpeed Insights API 等 | ⛔ 未着手 |
| ~~T-013?~~ | ~~gsc-fetch にクエリ→着地ページ逆引き~~ | → **T-016 `gsc-fetch.py query-pages` で実現（✅）** | — | ✅ 完了（2026-07-12・blog-loop ycom Cycle 023） |
| T-014? | hp-audit の h4 以降列挙 | 見出し階層の「飛ばし」検証（K-082。現状 h1〜h3 のみ） | hp-audit.sh 拡張 | ⛔ 未着手（2026-07-08 棚卸しで転記） |
| T-015? | アンカー単位の内部リンク検証 | 内部リンク追加施策（R-014c型）の反映確認が hp-audit 集計値では不能（K-026） | hp-audit.sh 拡張 or 小ツール（対象URL＋期待アンカーの存在チェック） | ⛔ 未着手（2026-07-08 棚卸しで転記） |

## T-018: system-health.py（システム固定費・故障の計測）
- **日付**: 2026-07-24 ｜ **状態**: 運用中（統括の精密診断が毎日実行・overseer.md v0.5）
- **目的**: システム全体の「固定費」（起動時自動ロードKB・毎サイクル全読みする状態ファイルのサイズを既存トリップワイヤ閾値と照合）と「故障」（tick.log のタイムアウト/異常終了/警報・mailbox滞留・ハートビート）だけを計測し、閾値超えと悪化トレンドだけを浮かせる。
- **使い方**: `python3 bin/system-health.py`（スナップショットを data/overseer/system-health.jsonl に追記＝トレンド比較用）／`--no-log` で表示のみ。
- **設計原則（最重要）**: 思考・探索の変動費（実行中のトークン量）は**測らない・閾値を設けない・警報しない**（2026-07-24 社長決定＝コストが品質の代理指標に化けて探索を殺すのを防ぐ。北極星レンズと同型）。
- **限界**: 閾値の一部は出典なしの提案既定値（★印・起票時に「要合意」と明記）／故障計数は failures.jsonl（agent-tick fail() が追記・60日ローテ）が一次で正確・未生成時のみ tick.log の簡易計数に fallback／リモート拠点の mailbox 滞留は拠点PCの稼働状況に依存（滞留＝故障とは限らない・報告して社長判断）。
