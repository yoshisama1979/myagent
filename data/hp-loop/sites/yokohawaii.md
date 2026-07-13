# HP分析ループ サイト設定：ヨーコハワイ（yokohawaii）

> `/hp-loop yokohawaii` が読むサイト固有設定。共通の進め方・原則は [../config.md](../config.md)、動作ルールは `.claude/rules/hp-loop.md`。

| 項目 | 値 | 状態 |
|------|----|----|
| site-key | `yokohawaii` | ✅ |
| ループ識別子（mailbox `to:` / Slackスレッド所有者） | `hp-loop-yokohawaii` | ✅ |
| 対象サイト名 | ヨーコハワイ（client_id 92 / project_id 118 コーポレートサイト / work_id 109 運用管理） | ✅（hana-tools） |
| 対象URL | https://www.yoko-hawaii.com/ | ✅（hana-tools site_url・2026-06-25 登録・到達200確認） |
| ゴール（北極星） | **「ハワイ×日本人オーナー・手数料0」で選ぶ旅行者からの問い合わせ・予約を増やす**（下記「北極星」参照） | ✅ 確定（2026-07-13 更新・AI起草＝文言修正歓迎。原型＝社長確定 2026-06-25） |
| 種別/前提 | 要確認（CMS/静的・WordPress 等は初回サイクルで hp-audit と本文確認） | 🟡 要確認 |
| GSC dataset | `searchconsole_yokohawaii`（hana-tools gsc_dataset・`bin/gsc-fetch.py --dataset searchconsole_yokohawaii`）。**現状エクスポート表（`searchdata_url_impression` 等）が未生成＝連携直後でデータ未蓄積**。数日〜で蓄積される見込み。蓄積されるまで GSC 分析は「データ未取得」と明示 | 🟡 蓄積待ち |
| GA4 dataset | **BigQuery 経由（藤阪ガス等と同方式）で確定。ただし dataset 未生成＝蓄積待ち**。2026-06-25 に GA4→BigQuery エクスポート設定済（社長）。同日時点で project `myservice-219202` の `analytics_*` 13個を全てホスト名照合したが `yoko-hawaii.com` を持つものは無し＝データ未流入。**数日で `analytics_<propertyId>` が現れる見込み**。出現したら最新 intraday テーブルの `page_location` ホスト名で自動特定して登録（照合手順は確立済）。それまで GA4 分析は「データ未取得」と明示 | 🟡 蓄積待ち |
| 実装担当エージェント | `yokohawaii-dev`（拠点PC・**専用機を立てる方針**＝社長決定 2026-06-25）。**コード側の許可リストは登録済**（`bin/mailbox.sh` の SENDERS に `hp-loop-yokohawaii`／RECIPIENTS に `yokohawaii-dev`・`hp-loop-yokohawaii`）。残るは **mailbox トークン＝社長手元作業**（VPS `data/secrets/mailbox-tokens.json` に `agent_id: yokohawaii-dev` を追加＋拠点PCの `.env` に `MAILBOX_TOKEN`/`MAILBOX_URL`）。**トークン登録＆拠点機の稼働を社長が確認するまでは最新レポートを配信せず**掲示板に「配信先準備中」と明示（new/ への孤児キュー化を避ける） | 🟡 トークン登録待ち |
| 掲示板 | `site/hp-analysis/yokohawaii/index.html`（spec/archive と3層） | ✅ 新規作成 |
| 社長指示ファイル | `data/hp-loop/yokohawaii/from-president.md` | ✅ |
| サイクル生データ（任意） | `data/hp-loop/cycles/yokohawaii/` | 🟡 |
| 案件記録 | （未設定） | 参考 |

> **稼働前の確定待ち（2026-06-25 時点）**：(1) ✅ 対象URL＝hana-tools から取得済（https://www.yoko-hawaii.com/）、(2) ✅ ゴール＝アクセス＋問い合わせ増（社長確定）、(3) 🔴 GA4 dataset、(4) 🟡 `yokohawaii-dev` のトークン登録。**URLは確定したので分析自体は可能**（ただし GSC は蓄積待ち＝当面はサイト実査・hp-audit 中心）。ゴール確定後に日次 cron（`daily hp-loop-yokohawaii`）を登録する。

## 北極星（このループが収束させる成果・2026-07-13 制定）

> ループの原則（hp-loop.md「北極星ファースト」v0.12）：提案はこの北極星を動かせるものだけが席を得る。

- **狙う成果はただ一つ**：**「ハワイ・ワイキキのコンドミニアムに、日本人オーナー・オーナー直接契約（仲介手数料0円）で泊まりたい」旅行者からの問い合わせ・予約**。USP（日本人オーナー対応・手数料0）で選ばれることが軸＝一般のハワイ観光情報での量的流入は追わない。
- **既に実証済みの勝ち筋を太らせる**：「ハワイ バケーションレンタル 日本人オーナー」系クエリが順位1.7〜2.2位でサイト全クリックの約68%（Cycle 020 確定）＝この束の露出拡大（W-01 勝ち筋語 title 等）と、そこから5物件の問い合わせ・予約への導線が本丸。
- **提案の席次基準**：「測れる窓（GSC＝勝ち筋・買い手意図クエリのクリック/順位。GA4 は蓄積後に問い合わせCV）で北極星を動かせるか」。言えない提案は起票しない。
- **剪定の義務**：効果検証で動かないと確定したレバーは足さずに剪定・方向転換。
- **新規が無い日の本業**：効果検証・在庫の剪定・実装済みの再監査（無理に起票しない）。
