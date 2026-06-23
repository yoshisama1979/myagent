# ブログ分析ループ — クライアント設定：YCOM（はなさか自社）

> `/blog-loop ycom` がサイクル先頭で読む、このクライアントの固有値。共通設定は [../config.md](../config.md)。

| 項目 | 値 | 状態 |
|------|----|----|
| クライアント名 | 株式会社はなさか 自社（YCOM） | ✅ 確定 |
| ブログURL（記事インデックス） | https://y-com.info/contents/ | ✅ 確定（2026-06-23 社長指定・hp-audit で HTTP200・WordPress 確認） |
| サイトドメイン | https://y-com.info/ | ✅ |
| CMS | WordPress（ブログ部分） | ✅（hp-audit `cms: WordPress`） |
| ゴール | ブログ経由のSEO流入＋問い合わせ（見積）への寄与。検索意図に応える記事で「買い手意図クエリ」を取りに行く | ✅（[[project_ycom-seo-traffic-quality]] と整合：買い手意図クエリ＝料金等は2ページ目で取りこぼし／/price/ が伸びしろ） |
| ターゲット | 対応エリア＝大阪・京都・兵庫(神戸)＋東京／業種不問／中規模程度まで（hp-loop ycom の確定値を流用） | ✅ |
| GSC dataset | `searchconsole_ycom` | ✅ |
| GA4 dataset | `analytics_265729912`（2021〜稼働・CVイベント発火中） | ✅ |
| 執筆/実装担当エージェント | `web-hanasaka`（y-com.info サイト実装担当・hp-loop ycom と同じ） | ✅（mailbox トークン登録済＝reachable） |
| 掲示板（3層） | `site/hp-analysis/ycom/blog/{index,spec,archive}.html` | ✅（HP分析掲示板 `hp-analysis/ycom/index.html` と相互リンク） |
| 社長指示ファイル | `data/blog-loop/ycom/from-president.md`（社長のみ書く・AIは読むだけ） | ✅ |
| ループ識別子 | `blog-loop-ycom`（Slack日報スレッド所有者／mailbox 宛先） | ✅ |
| 関連 | HP分析ループ `data/hp-loop/sites/ycom.md`（サイト全体の診断）。本モードはその**ブログ記事に特化** | — |

## メモ（このクライアント固有）

- ブログタイトル＝「YCOMのホームページの制作・運営に役立つブログ」。テーマ＝ホームページ制作・SEO・運営に役立つ情報。
- ゴール上、記事から**受け皿ページ（/price/ ・制作実績 /works/ ・/service/ ・問い合わせ）への内部リンク**を効かせるのが重要（hp-loop ycom の R-014c/021/024/027 と連動）。ブログ記事の改善でこの導線を補強する。
- 買い手意図クエリ（料金・費用・依頼方法など）に応える記事が CV に効く（[[project_ycom-seo-traffic-quality]]）。新規テーマ・既存改善ともここを優先。
