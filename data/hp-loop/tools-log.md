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

---

## 未着手・欲しいツール（権限非依存で書く＝作れるか否かに関わらず記録）

| 仮ID | ツール | 目的 | 必要なもの | 状態 |
|------|--------|------|-----------|------|
| ~~T-002~~ | ~~GSC連携~~ | → **T-006 gsc-fetch.py で実現（✅）** | — | ✅ 完了（2026-06-12） |
| T-003? | GA4連携（流入・CV取得） | 施策の効果を数値検証 | GA4 Data API＋認証（要・社長） | ⛔ 未着手（Q-003のGA4分） |
| T-004? | 監査スナップショット差分／GSC日次蓄積 | 定期実行で「変化時のみ提案」・順位推移 | cycles/ にJSON保存＋差分ロジック | ⛔ 未着手（K-006） |
| T-005? | 表示速度/CWV計測 | 速度・Core Web Vitals の客観値 | PageSpeed Insights API 等 | ⛔ 未着手 |
