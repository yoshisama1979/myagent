# 実装作業の受信簿（deploy-log）— ycom（y-com.info・実装担当＝web-hanasaka）

> **何これ**：実装担当からの本番変更報告を1行ずつ時系列で記録する受信簿（hp-loop.md v0.17・2026-07-29 新設・社長指示）。
> **書き方**：`| 反映日 | R番号 | 内容1行 | 報告ID・検証 |`。R番号は対応 R-NNN、紐づかない変更（クライアント直依頼等）は **R外** と書く。**報告ID＝mailbox のメッセージID（または commit ハッシュ）を一意キーにし、追記前に同IDの既存行が無いか確認する**（mailbox 再処理での重複追記防止）。検証＝本番GET等での確認結果（未確認なら「未検証」と明示）。実装報告（mailbox）を受けた Step 1 で追記。報告が無いのに日次実査（hp-audit 差分）で変化を検出したら「報告なし・実査検出」と記録し実装担当へ照会（実査検出は補助＝完全性の保証ではない）。
> **用途**：月次定石 #12「🛠 対応実績（月次）」レポート（掲示板 index）の**原簿**（月次節は派生ビュー・本番確認済みのみ掲載）＝定額内でどれだけ作業が進んだかの可視化。
> **規律**：追記のみ（削除・改変しない＝通年の原簿）。誤記の訂正は行を書き換えず「訂正→対象報告ID」を付けた訂正行を追記。前月レポート作成後に届いた遅延報告は「YYYY-MM月分・追補」として追記。

| 反映日 | R番号 | 内容 | 報告ID・検証 |
|---|---|---|---|
| 2026-08-05 | R-037 | `/price/index.html` の旧A/Bテスト `async-hide` 一式を削除（白画面リスク解消） | M-20260805T170425-web-hanasaka-3f53125faf8a9991 / commit a5f0c18 ／**✅検証済（08-06 Cycle 086・本ループ独立GET）**＝`--plumbing` で GTM-5B5WZHG の参照消失・配信中コンテナは GTM-55DB6J6 のみ（計測は維持）。⚠️**対象URLは `/price/basic.html` ではなく `/price/`**（起票時の取り違え＝先方指摘・台帳訂正済） |
| 2026-08-05 | R-038 | トップ主要カード「WEBシステム」のリンク先を `./service/web/cms.html` → `./service/system/` へ是正 | 同上 / commit a5f0c18 ／**✅検証済（08-06 Cycle 086・`hp-audit --links` で独立確認）**＝`./service/system/` 1本（アンカー「WEBシステム…」）・`cms.html` 2→1本（共通ナビ分は維持＝孤立させていない） |
| 2026-08-05 | R-041 | `/works/` のSP表示崩れ修正（4列→2列折返し・長いURLの突き抜け解消） | 同上 / commit a5f0c18 ／**✅検証済（08-06 Cycle 086・hp-shot SP実画像を Read）**＝SP幅で2列に折返し・屋号の重なり解消・URL は折返して画面内に収まる・「制作STORY」帯の重なり解消 |
| 2026-08-05 | R-043 | サービス系カードのSP表示崩れ修正（1カラム化・アイコン float 解除・行間是正） | 同上 / commit a7b8de2 ／**✅検証済（08-06 Cycle 086・hp-shot SP実画像を Read）**＝`/service/system/` のSPで縦折れ解消・見出しが1行で判読可。⚠️**影響範囲は起票時の想定（system 単独）より広く `/service/`・`/service/ai/`・`/service/system/` の3ページ**（先方指摘・台帳訂正済） |
| 2026-08-05 | R外 | `css/sass/works.scss` の未使用mixin（radius/box-shadow）削除＝内部リファクタ | 同上 / commit 67c5ecd ／**出力CSS差分ゼロ＝見た目・DOM影響なしとの報告**。本ループ側の観測点なし（hp-audit・hp-shot とも変化なし＝報告と整合）。R外変更の報告規約（2026-07-29 依頼）が初めて履行された1件目 |
| 2026-08-06 | R外 | `/price/basic.html` の廃止済み Google Content Experiment 残骸を除去（`utmx`/`ga_exp.js`＝`document.write` による同期挿入＝レンダリングブロック要因） | M-20260811T092309-web-hanasaka-9169c3c5637e75d4 / commit 53b4d7d ／**✅検証済（08-12 Cycle 092・本ループ独立GET `--plumbing`）**＝残骸タグの表示なし・配信中コンテナは GTM-55DB6J6 のみ（計測は維持）。⚠️**R-037（`/price/` の async-hide）とは別ページ・別系統の残骸**＝台帳上も混同しない（先方明示）。Crazy Egg は契約確認待ちで意図的に残置（社長回答待ち） |
| 不明（07-23〜08-21 の間） | R-039(a) | **`robots.txt` / `sitemap.xml` を実体として設置**（従来はトップへ302＝実質未設置）。robots は `User-agent: * / Disallow: /wp_export_csv.html / Sitemap: https://y-com.info/sitemap.xml`（119B）、sitemap は **52URL・lastmod 付き**（4,727B） | **報告なし・実査検出（2026-08-21 Cycle 099・月次定石#9 配管一斉点検）** ／**✅本番GETで検証済**＝両URLとも HTTP 200・リダイレクトなし・中身を `--text` で確認（robots の Sitemap 行は R-039(a) の処方どおり）。⚠️**反映日は外形からは特定できない**（07-22 の配管点検#001 では両方とも302だったため、それ以降）→ **実装担当へ照会中**（反映日・commit・(b)(c) の予定）。R-039 は本件で **🆕提案 → 🔧一部反映** へ。(b) 旧UA `UA-2650013-1`＋crazyegg はトップに残存・(c) `/contact/normal/` の datepicker は3本ロード継続＝**いずれも未反映を同日実査で確認** |
| 2026-08-06 | R外 | `/works/` 系の WP 由来データの出力エスケープ統一（htmlspecialchars＋href の http(s) allowlist）＋**実績詳細39ページの画像 alt 是正**（`$data['NAME']` 誤参照→`$data['sitename']`）＋`count($data['SPEC'])` の PHP8 TypeError ガード | 同上 / commit 53b4d7d ／**🔧一部検証済（08-12 Cycle 092）**＝alt 是正は `?p_id=8086` で `alt=""`→`alt="GOLFZONE24"` を独立確認（39/39 は先方の全数GET報告）。**エスケープ統一・PHP8 ガードは静的GETに差分が出ない種類の変更＝本ループでは観測不能**（観測できないことを「未対応」と判定しない＝先方の明示的な申し送りを受領） |
