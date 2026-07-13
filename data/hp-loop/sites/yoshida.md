# HP分析ループ サイト設定：よしだ歯科（yoshida）

> `/hp-loop yoshida` が読むサイト固有設定。共通の進め方・原則は [../config.md](../config.md)、動作ルールは `.claude/rules/hp-loop.md`。

| 項目 | 値 | 状態 |
|------|----|----|
| site-key | `yoshida` | ✅ |
| ループ識別子（mailbox `to:` / Slackスレッド所有者） | `hp-loop-yoshida` | ✅ |
| 対象サイト名 | よしだ歯科（クライアント・client_id 60 / project_id 80 / work_id 167 運用管理） | ✅ |
| 対象URL | https://yoshida-smile.info | ✅（hana-tools site_url） |
| ゴール（北極星） | **診療圏の患者からの予約（WEB予約・電話タップ）を増やす**（下記「北極星」参照） | ✅ 確定（2026-07-13 更新・AI起草＝文言修正歓迎） |
| 種別/前提 | **WordPress**。ゴール方針＝「アクセスは十分→質（来院・予約・わかりやすさ）の向上を優先」（2026-04-27 打合せ）。MEO/GBP・広告はサイト外＝運用側 | ✅ |
| GSC dataset | `searchconsole_yoshida`（`bin/gsc-fetch.py --dataset searchconsole_yoshida`） | ✅ 取得可 |
| GA4 dataset | `analytics_287348176`（稼働・2021-09〜・WEB予約/電話タップCV有。`bin/ga4-fetch.py --dataset analytics_287348176`） | ✅ 取得可 |
| 実装担当エージェント | `yoshida-dev`（拠点PC）※mailbox トークン未登録＝社長登録待ち | 🟡 |
| 掲示板 | `site/hp-analysis/yoshida/index.html` | ✅ |
| 社長指示ファイル | `data/hp-loop/yoshida/from-president.md` | ✅ |
| サイクル生データ（任意） | `data/hp-loop/cycles/yoshida/` | 🟡 |
| 案件記録 | `site/clients/yoshida-shika/`（相互リンク） | 参考 |

## 北極星（このループが収束させる成果・2026-07-13 制定）

> ループの原則（hp-loop.md「北極星ファースト」v0.12）：提案はこの北極星を動かせるものだけが席を得る。

- **狙う成果はただ一つ**：**診療圏の患者（来院意図の検索者・既存アクセス）からの予約＝WEB予約・電話タップ（GA4 で CV 計測済み）を増やす**。
- **アクセス総量は追わない**：社長・クライアント方針（2026-04-27 打合せ）＝「アクセスは十分→質（来院・予約・わかりやすさ）の向上を優先」。流入を増やすだけの提案（一般情報記事等）は席を得ない。
- **提案の席次基準**：「測れる窓（GA4＝WEB予約/電話タップCV、GSC＝来院意図クエリのクリック/順位）で予約を動かせるか」。言えない提案は起票しない。
- **剪定の義務**：効果検証で動かないと確定したレバーは足さずに剪定・方向転換。
- **新規が無い日の本業**：効果検証・在庫の剪定・実装済みの再監査（無理に起票しない）。
