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
- 使い方：`bash bin/hp-audit.sh <URL>`（人が読む要約）／ `bash bin/hp-audit.sh <URL> --json`（JSON）
- 出力：HTTPステータス・title/description（文字数）・canonical・robots・viewport（ズーム禁止検出）・OGP/Twitter（**プレースホルダ検出**＝K-003）・JSON-LD（型・無効化検出）・見出しh1-h3（h1複数検出）・img/alt欠落・問い合わせ動線（tel/mailto/contact）・CMS。末尾に課題を ⚠️ で列挙
- 関連：K-001（監査ツール化）／K-005（hp-loopでも手作業依存）／K-003（仮置き残存検出）。掲示板 Cycle 001 の所見を再現
- メモ：HTTP GET のみ・読み取り専用（外部送信/書き込みなし）。1ページ単位（サイト全体クロールは未対応）。差分比較（前回JSONとの比較）は未実装＝K-006で別途
- 更新 2026-06-11：**HTMLコメント除去を追加**（バグ修正＝K-008）。コメントアウトされた meta/og タグを「配信中」と誤検出していた問題を修正。コメント内の meta 件数は `commented_meta_tags` で別途報告
- 既知の限界（社長指摘 2026-06-11）：(1)**静的HTMLのみ**。JS で後から再注入される meta（例：viewport の `user-scalable=no` 上書き）やJS描画後のDOMは見えない → 重要ページは目視/担当エージェント確認で補う。(2)**CMS判定はヒューリスティック**（`wp-content` 等の資産参照を見るだけ）。サイト全体の構成を断定しない
- 更新 2026-06-11（Codexレビュー反映）：スキームを http/https に限定（`--proto`）／**取得失敗・非2xx・空body・サイズ超過(5MB)を「監査不能」として明示**（成功を装わない・exit 3）／複数URLガード／プレースホルダ語句を調整（準備中/lorem/dummy/noimage 追加・sample等は語境界化）
- 今後の改善（Codex由来・次サイクル送り）：(a)属性解析を正規表現から `html.parser` 等の標準パーサに置換（シングルクォート/未引用/`rel="canonical alternate"`/属性順の取りこぼし対策）。(b)JSON-LD の `@graph` 内 `@type`・シングルクォート type 対応。(c)プレースホルダ判定を title/description/canonical/JSON-LD/画像URL にも適用。(d)空alt(装飾)の扱い方針を出力に明記

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

---

## 未着手・欲しいツール（権限非依存で書く＝作れるか否かに関わらず記録）

| 仮ID | ツール | 目的 | 必要なもの | 状態 |
|------|--------|------|-----------|------|
| ~~T-002~~ | ~~GSC連携~~ | → **T-006 gsc-fetch.py で実現（✅）** | — | ✅ 完了（2026-06-12） |
| ~~T-003?~~ | ~~GA4連携（流入・CV取得）~~ | → **T-007 ga4-fetch.py で実現（✅）**。GA4 は既に BigQuery エクスポート稼働中（`analytics_265729912`）と判明し、Data API 不要で SELECT 取得 | — | ✅ 完了（2026-06-18） |
| ~~T-004?~~ | ~~監査スナップショット差分／GSC日次蓄積~~ | → **T-009 hp-diff.py で実現（✅）**。スナップショット差分（順位推移・新規/消滅）を1コマンド化。日次JSON蓄積の自動保存は運用ルール側で対応 | — | ✅ 完了（2026-06-19） |
| T-005? | 表示速度/CWV計測 | 速度・Core Web Vitals の客観値 | PageSpeed Insights API 等 | ⛔ 未着手 |
