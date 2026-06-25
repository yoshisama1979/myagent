# HP分析ループ サイト設定：ヨーコハワイ（yokohawaii）

> `/hp-loop yokohawaii` が読むサイト固有設定。共通の進め方・原則は [../config.md](../config.md)、動作ルールは `.claude/rules/hp-loop.md`。

| 項目 | 値 | 状態 |
|------|----|----|
| site-key | `yokohawaii` | ✅ |
| ループ識別子（mailbox `to:` / Slackスレッド所有者） | `hp-loop-yokohawaii` | ✅ |
| 対象サイト名 | ヨーコハワイ（client_id 92 / project_id 118 コーポレートサイト / work_id 109 運用管理） | ✅（hana-tools） |
| 対象URL | https://www.yoko-hawaii.com/ | ✅（hana-tools site_url・2026-06-25 登録・到達200確認） |
| ゴール | アクセス＋コンバージョン（問い合わせ）増 | ✅（社長確定 2026-06-25） |
| 種別/前提 | 要確認（CMS/静的・WordPress 等は初回サイクルで hp-audit と本文確認） | 🟡 要確認 |
| GSC dataset | `searchconsole_yokohawaii`（hana-tools gsc_dataset・`bin/gsc-fetch.py --dataset searchconsole_yokohawaii`）。**現状エクスポート表（`searchdata_url_impression` 等）が未生成＝連携直後でデータ未蓄積**。数日〜で蓄積される見込み。蓄積されるまで GSC 分析は「データ未取得」と明示 | 🟡 蓄積待ち |
| GA4 dataset | **BigQuery 経由（藤阪ガス等と同方式）で確定。ただし dataset 未生成＝蓄積待ち**。2026-06-25 に GA4→BigQuery エクスポート設定済（社長）。同日時点で project `myservice-219202` の `analytics_*` 13個を全てホスト名照合したが `yoko-hawaii.com` を持つものは無し＝データ未流入。**数日で `analytics_<propertyId>` が現れる見込み**。出現したら最新 intraday テーブルの `page_location` ホスト名で自動特定して登録（照合手順は確立済）。それまで GA4 分析は「データ未取得」と明示 | 🟡 蓄積待ち |
| 実装担当エージェント | `yokohawaii-dev`（拠点PC・**専用機を立てる方針**＝社長決定 2026-06-25）。**コード側の許可リストは登録済**（`bin/mailbox.sh` の SENDERS に `hp-loop-yokohawaii`／RECIPIENTS に `yokohawaii-dev`・`hp-loop-yokohawaii`）。残るは **mailbox トークン＝社長手元作業**（VPS `data/secrets/mailbox-tokens.json` に `agent_id: yokohawaii-dev` を追加＋拠点PCの `.env` に `MAILBOX_TOKEN`/`MAILBOX_URL`）。**トークン登録＆拠点機の稼働を社長が確認するまでは最新レポートを配信せず**掲示板に「配信先準備中」と明示（new/ への孤児キュー化を避ける） | 🟡 トークン登録待ち |
| 掲示板 | `site/hp-analysis/yokohawaii/index.html`（spec/archive と3層） | ✅ 新規作成 |
| 社長指示ファイル | `data/hp-loop/yokohawaii/from-president.md` | ✅ |
| サイクル生データ（任意） | `data/hp-loop/cycles/yokohawaii/` | 🟡 |
| 案件記録 | （未設定） | 参考 |

> **稼働前の確定待ち（2026-06-25 時点）**：(1) ✅ 対象URL＝hana-tools から取得済（https://www.yoko-hawaii.com/）、(2) ✅ ゴール＝アクセス＋問い合わせ増（社長確定）、(3) 🔴 GA4 dataset、(4) 🟡 `yokohawaii-dev` のトークン登録。**URLは確定したので分析自体は可能**（ただし GSC は蓄積待ち＝当面はサイト実査・hp-audit 中心）。ゴール確定後に日次 cron（`daily hp-loop-yokohawaii`）を登録する。
