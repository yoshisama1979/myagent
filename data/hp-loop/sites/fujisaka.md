# HP分析ループ サイト設定：藤阪ガス（fujisaka）

> `/hp-loop fujisaka` が読むサイト固有設定。共通の進め方・原則は [../config.md](../config.md)、動作ルールは `.claude/rules/hp-loop.md`。

| 項目 | 値 | 状態 |
|------|----|----|
| site-key | `fujisaka` | ✅ |
| ループ識別子（mailbox `to:` / Slackスレッド所有者） | `hp-loop-fujisaka` | ✅ |
| 対象サイト名 | 藤阪ガスセンター（client_id 11 / project_id 14 コーポレートサイト / work_id 16 運用管理） | ✅ |
| 対象URL | https://fujisakagas.com/ | ✅（hana-tools site_url） |
| ゴール | アクセス＋コンバージョン（問い合わせ）増 | ✅ |
| 種別/前提 | 要確認（CMS/静的・WordPress 等は初回サイクルで hp-audit と本文確認） | 🟡 要確認 |
| GSC dataset | `searchconsole_fujisaka`（`bin/gsc-fetch.py --dataset searchconsole_fujisaka`） | ✅ 取得可 |
| GA4 dataset | `analytics_316110295`（2026-06-16 設定・蓄積中＝初期はデータ少。`bin/ga4-fetch.py --dataset analytics_316110295`） | 🟡 蓄積中 |
| 実装担当エージェント | `fujisaka-dev`（拠点PC）※mailbox トークン未登録＝社長登録待ち | 🟡 |
| 掲示板 | `site/hp-analysis/fujisaka/index.html` | 🟡 新規作成 |
| 社長指示ファイル | `data/hp-loop/fujisaka/from-president.md` | ✅ |
| サイクル生データ（任意） | `data/hp-loop/cycles/fujisaka/` | 🟡 |
| 案件記録 | Notion `dc2026246a2e46deacb64b8c294a2b56`（document_url） | 参考 |
