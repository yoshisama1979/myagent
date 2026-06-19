# HP分析ループ サイト設定：よしだ歯科（yoshida）

> `/hp-loop yoshida` が読むサイト固有設定。共通の進め方・原則は [../config.md](../config.md)、動作ルールは `.claude/rules/hp-loop.md`。

| 項目 | 値 | 状態 |
|------|----|----|
| site-key | `yoshida` | ✅ |
| ループ識別子（mailbox `to:` / Slackスレッド所有者） | `hp-loop-yoshida` | ✅ |
| 対象サイト名 | よしだ歯科（クライアント・client_id 60 / project_id 80 / work_id 167 運用管理） | ✅ |
| 対象URL | https://yoshida-smile.info | ✅（hana-tools site_url） |
| ゴール | アクセス＋コンバージョン（予約・問い合わせ）増 | ✅ |
| 種別/前提 | **WordPress**。ゴール方針＝「アクセスは十分→質（来院・予約・わかりやすさ）の向上を優先」（2026-04-27 打合せ）。MEO/GBP・広告はサイト外＝運用側 | ✅ |
| GSC dataset | `searchconsole_yoshida`（`bin/gsc-fetch.py --dataset searchconsole_yoshida`） | ✅ 取得可 |
| GA4 dataset | `analytics_287348176`（稼働・2021-09〜・WEB予約/電話タップCV有。`bin/ga4-fetch.py --dataset analytics_287348176`） | ✅ 取得可 |
| 実装担当エージェント | `yoshida-dev`（拠点PC）※mailbox トークン未登録＝社長登録待ち | 🟡 |
| 掲示板 | `site/hp-analysis/yoshida/index.html` | ✅ |
| 社長指示ファイル | `data/hp-loop/yoshida/from-president.md` | ✅ |
| サイクル生データ（任意） | `data/hp-loop/cycles/yoshida/` | 🟡 |
| 案件記録 | `site/clients/yoshida-shika/`（相互リンク） | 参考 |
