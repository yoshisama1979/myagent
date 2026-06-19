# HP分析ループ サイト設定：はなさか自社サイト（ycom）

> `/hp-loop ycom` が読むサイト固有設定。共通の進め方・原則は [../config.md](../config.md)、動作ルールは `.claude/rules/hp-loop.md`。

| 項目 | 値 | 状態 |
|------|----|----|
| site-key | `ycom` | ✅ |
| ループ識別子（mailbox `to:` / Slackスレッド所有者） | `hp-loop-ycom` | ✅ |
| 対象サイト名 | 株式会社はなさか 自社サイト（YCOM） | ✅ 確定 |
| 対象URL | https://y-com.info/ | ✅ 確定 |
| ゴール | SEO流入＋問い合わせ（見積）増 | ✅ 確定 |
| 種別/前提 | 独自PHPテンプレート（WordPress は一部のみ）。hp-audit の `wp-content` 検出はヒューリスティック | ✅ |
| GSC dataset | `searchconsole_ycom`（`bin/gsc-fetch.py --dataset searchconsole_ycom`） | ✅ 取得可 |
| GA4 dataset | `analytics_265729912`（稼働・`bin/ga4-fetch.py`）。CVイベント正規化は R-023 実装中 | ✅ 取得可 |
| 実装担当エージェント | `web-hanasaka`（拠点PC） | ✅ |
| 掲示板 | `site/hp-analysis/ycom/index.html` | ✅ |
| 社長指示ファイル | `data/hp-loop/from-president.md`（ycom は既存パスを継続） | ✅ |
| サイクル生データ（任意） | `data/hp-loop/cycles/`（必要なら `cycles/ycom/`） | 🟡 |
