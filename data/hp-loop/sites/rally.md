# HP分析ループ サイト設定：全国スタンプラリー（rally）

> `/hp-loop rally` が読むサイト固有設定。共通の進め方・原則は [../config.md](../config.md)、動作ルールは `.claude/rules/hp-loop.md`。

| 項目 | 値 | 状態 |
|------|----|----|
| site-key | `rally` | ✅ |
| ループ識別子（mailbox `to:` / Slackスレッド所有者） | `hp-loop-rally` | ✅ |
| 対象サイト名 | 全国スタンプラリー（株式会社はなさか 自社プロダクト・hana-tools client_id 21 / project_id 69） | ✅（hana-tools） |
| 対象URL | https://check-rally.com/ | ✅（到達200確認・2026-06-27） |
| ゴール | **参加者の利用・アクセス増**（B2Cエンドユーザーの利用拡大） | ✅（社長確定 2026-06-27） |
| 種別/前提 | **B2Cスタンプラリー Webアプリ**。アカウント作成→近くの素敵な場所を探す→スタンプ収集→バッジ図鑑／エリア・テーマ・マップで探す。**SPA（JS描画）＝配信HTMLに title/meta/h1 が無い**（hp-audit で判明）。主要導線：ホーム／エリアからさがす／テーマで探す／バッジ図鑑／マップでみる／アカウント登録／ログイン | ✅（初回サイクルで確認） |
| GSC dataset | **未連携（要設定）**。hana-tools gsc_dataset は null。Search Console 未接続。接続後 BigQuery エクスポートを設定し dataset を登録（命名は `searchconsole_*` 慣例だが未確定）。それまで GSC 分析は「データ未取得」と明示 | 🔴 未連携 |
| GA4 dataset | **未連携（接続待ち）**。社長より「Analytics データはまだ無し」。GA4→BigQuery エクスポート設定後、最新 intraday テーブルの `page_location` ホスト名（`check-rally.com`）で `analytics_<propertyId>` を自動特定して登録（yokohawaii と同手順）。それまで GA4 分析は「データ未取得」と明示 | 🔴 未連携 |
| 実装担当エージェント | `rally-dev`（拠点PC・**専用機を立てる方針**＝社長決定 2026-06-27）。**コード側の許可リストは登録済**（`bin/mailbox.sh` の SENDERS に `hp-loop-rally`／RECIPIENTS に `rally-dev`・`hp-loop-rally`）。残るは **mailbox トークン＝社長手元作業**（VPS `data/secrets/mailbox-tokens.json` に `agent_id: rally-dev` を追加＋拠点PCの `.env` に `MAILBOX_TOKEN`/`MAILBOX_URL`）。**トークン登録＆拠点機の稼働を社長が確認するまでは最新レポートを配信せず**掲示板に「配信先準備中」と明示（new/ への孤児キュー化を避ける） | 🟡 トークン登録待ち |
| 掲示板 | `site/hp-analysis/rally/index.html`（spec/archive と3層） | ✅ 新規作成 |
| 社長指示ファイル | `data/hp-loop/rally/from-president.md` | ✅ |
| サイクル生データ（任意） | `data/hp-loop/cycles/rally/` | ✅ |
| 案件記録 | （未設定） | 参考 |

> **稼働前の確定待ち（2026-06-27 時点）**：(1) ✅ 対象URL（到達確認）、(2) ✅ ゴール（参加者の利用・アクセス増）、(3) 🔴 GSC/GA4 未連携＝当面は**サイト実査・hp-audit・スクショ中心**で機会発掘（効果実測はデータ接続後）、(4) 🟡 `rally-dev` のトークン登録。**SPA で検索エンジンに中身が見えない（SSR/プリレンダ）が最重要論点**。**週次 cron（`daily hp-loop-rally`・月曜04:00）**＝2026-07-08 社長決定で日次→週次に右サイズ化（入力凍結12サイクルのため。`to: hp-loop-rally` 新着＝社長回答・データ連携・実装報告が来れば反応tickで即起動＝取りこぼしなし。データ連携後は日次へ戻す）。
