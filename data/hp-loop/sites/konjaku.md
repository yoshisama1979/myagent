# HP分析ループ サイト設定：今昔写語（konjaku）

> `/hp-loop konjaku` が読むサイト固有設定。共通の進め方・原則は [../config.md](../config.md)、動作ルールは `.claude/rules/hp-loop.md`。

| 項目 | 値 | 状態 |
|------|----|----|
| site-key | `konjaku` | ✅ |
| ループ識別子（mailbox `to:` / Slackスレッド所有者） | `hp-loop-konjaku` | ✅ |
| 対象サイト名 | 今昔写語（株式会社はなさか 自社プロダクト・hana-tools client_id 21 / project_id 36 / work_id 26 今昔写語開発） | ✅（hana-tools） |
| 対象URL | https://konjaku-photo.jp/ | ✅（到達200確認・2026-06-27） |
| ゴール | **アクセス（閲覧）増を主軸に全方位**（投稿ユーザー増・SEO流入増も重点。社長「まずは1（アクセス）からだが、すべて重点にしたい」） | ✅（社長確定 2026-06-27） |
| 種別/前提 | **昔↔今 写真比較ギャラリー**（同じ場所の昔の写真と今を見比べる）。ログイン・検索・多数の比較投稿。ダークテーマ。**配信HTMLに画像1件のみ＝ギャラリー本体もJS描画**（hp-audit）。title/description は有り、canonical/OGP/JSON-LD/h1 は無し | ✅（初回サイクルで確認） |
| GSC dataset | **未連携（要設定）**。hana-tools gsc_dataset は null。Search Console 未接続。接続後 BigQuery エクスポートを設定し dataset を登録（命名は `searchconsole_*` 慣例だが未確定）。それまで GSC 分析は「データ未取得」と明示 | 🔴 未連携 |
| GA4 dataset | **未連携（接続待ち）**。社長より「Analytics データはまだ無し」。GA4→BigQuery エクスポート設定後、最新 intraday テーブルの `page_location` ホスト名（`konjaku-photo.jp`）で `analytics_<propertyId>` を自動特定して登録（yokohawaii と同手順）。それまで GA4 分析は「データ未取得」と明示 | 🔴 未連携 |
| 実装担当エージェント | `konjaku-dev`（拠点PC・**専用機を立てる方針**＝社長決定 2026-06-27）。**コード側の許可リストは登録済**（`bin/mailbox.sh` の SENDERS に `hp-loop-konjaku`／RECIPIENTS に `konjaku-dev`・`hp-loop-konjaku`）。残るは **mailbox トークン＝社長手元作業**（VPS `data/secrets/mailbox-tokens.json` に `agent_id: konjaku-dev` を追加＋拠点PCの `.env` に `MAILBOX_TOKEN`/`MAILBOX_URL`）。**トークン登録＆拠点機の稼働を社長が確認するまでは最新レポートを配信せず**掲示板に「配信先準備中」と明示（new/ への孤児キュー化を避ける） | 🟡 トークン登録待ち |
| 掲示板 | `site/hp-analysis/konjaku/index.html`（spec/archive と3層） | ✅ 新規作成 |
| 社長指示ファイル | `data/hp-loop/konjaku/from-president.md` | ✅ |
| サイクル生データ（任意） | `data/hp-loop/cycles/konjaku/` | ✅ |
| 案件記録 | （未設定） | 参考 |

> **稼働前の確定待ち（2026-06-27 時点）**：(1) ✅ 対象URL（到達確認）、(2) ✅ ゴール（アクセス増主軸＋全方位）、(3) 🔴 GSC/GA4 未連携＝当面は**サイト実査・hp-audit・スクショ中心**で機会発掘（効果実測はデータ接続後）、(4) 🟡 `konjaku-dev` のトークン登録。**ビジュアル product なのに OGP 無し＝SNS シェアで映えない**・**ギャラリーがJS描画で個別ページがインデックスされにくい**が初期の重要論点。**週次 cron（`daily hp-loop-konjaku`・月曜04:30）**＝2026-07-08 社長決定で日次→週次に右サイズ化（入力凍結12サイクルのため。`to: hp-loop-konjaku` 新着が来れば反応tickで即起動＝取りこぼしなし。データ連携後は日次へ戻す）。
