# HP分析ループ サイト設定：藤阪ガス（fujisaka）

> `/hp-loop fujisaka` が読むサイト固有設定。共通の進め方・原則は [../config.md](../config.md)、動作ルールは `.claude/rules/hp-loop.md`。

| 項目 | 値 | 状態 |
|------|----|----|
| site-key | `fujisaka` | ✅ |
| ループ識別子（mailbox `to:` / Slackスレッド所有者） | `hp-loop-fujisaka` | ✅ |
| 対象サイト名 | 藤阪ガスセンター（client_id 11 / project_id 14 コーポレートサイト / work_id 16 運用管理） | ✅ |
| 対象URL | https://fujisakagas.com/ | ✅（hana-tools site_url） |
| ゴール（北極星） | **枚方近郊の「ガス機器・水まわりの困りごと」からの電話・フォーム問い合わせを増やす**（下記「北極星」参照） | ✅ 確定（2026-07-13 更新・AI起草＝文言修正歓迎） |
| 種別/前提 | 要確認（CMS/静的・WordPress 等は初回サイクルで hp-audit と本文確認） | 🟡 要確認 |
| GSC dataset | `searchconsole_fujisaka`（`bin/gsc-fetch.py --dataset searchconsole_fujisaka`） | ✅ 取得可 |
| GA4 dataset | `analytics_316110295`（2026-06-16 設定・蓄積中＝初期はデータ少。`bin/ga4-fetch.py --dataset analytics_316110295`） | 🟡 蓄積中 |
| 実装担当エージェント | `fujisaka-dev`（拠点PC）※mailbox トークン未登録＝社長登録待ち | 🟡 |
| 掲示板 | `site/hp-analysis/fujisaka/index.html` | 🟡 新規作成 |
| 社長指示ファイル | `data/hp-loop/fujisaka/from-president.md` | ✅ |
| サイクル生データ（任意） | `data/hp-loop/cycles/fujisaka/` | 🟡 |
| 案件記録 | Notion `dc2026246a2e46deacb64b8c294a2b56`（document_url） | 参考 |

## 北極星（このループが収束させる成果・2026-07-13 制定）

> ループの原則（hp-loop.md「北極星ファースト」v0.12）：提案はこの北極星を動かせるものだけが席を得る。

- **狙う成果はただ一つ**：**枚方市近郊で「ガス機器・給湯器・水まわりの困りごとを今解決したい」人**（交換・修理・緊急対応の意図。例＝「枚方市 給湯器交換」「枚方市 給湯器 水漏れ」）**からの電話・フォーム問い合わせ（GA4 で問い合わせ完了・電話タップ CV 計測済み）**。リフォーム・保証（あんしん10年保証）など高単価案件の入口も同軸。
- **追わないもの**：指名検索の二次表示の最適化（`/faq/` を直しても効果なし＝Cycle 032 で確定・撤回済み）。地域と関係ない一般情報の量的流入。
- **提案の席次基準**：「測れる窓（GSC＝買い手・緊急意図クエリのクリック/順位、GA4＝問い合わせCV）で北極星を動かせるか」。言えない提案は起票しない。
- **剪定の義務**：効果検証で動かないと確定したレバーは足さずに剪定・方向転換（`/faq/` 撤回・R-F17→R-F18 の主対象移管が正しい型）。
- **新規が無い日の本業**：効果検証・在庫の剪定・実装済みの再監査（無理に起票しない）。
