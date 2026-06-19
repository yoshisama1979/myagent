# HP分析ループ — 設定（config）

> `/hp-loop <site>` が毎サイクル最初に読む**共通設定**。サイト固有値（URL・GSC/GA4 dataset・ゴール・実装担当・掲示板・社長指示ファイル）は **サイト別 config `data/hp-loop/sites/<site>.md`** に分離（2026-06-19 複数サイト化）。
> ここを社長が編集すれば全サイト共通の振る舞いが、`sites/<site>.md` を編集すればそのサイトの設定が変わる。

---

## 対象サイト登録表（マルチサイト）

`/hp-loop <site>` の `<site>` に site-key を渡す（無指定は後方互換で `ycom`）。各サイトの詳細は右のconfigを読む。

| site-key | サイト | URL | GSC dataset | 実装担当 | 掲示板 | ループ識別子 | config |
|----------|--------|-----|-------------|---------|--------|-------------|--------|
| `ycom` | はなさか自社(YCOM) | https://y-com.info/ | `searchconsole_ycom` | `web-hanasaka` | `hp-analysis/ycom/` | `hp-loop-ycom` | [sites/ycom.md](sites/ycom.md) |
| `yoshida` | よしだ歯科 | https://yoshida-smile.info | `searchconsole_yoshida` | `yoshida-dev` | `hp-analysis/yoshida/` | `hp-loop-yoshida` | [sites/yoshida.md](sites/yoshida.md) |
| `fujisaka` | 藤阪ガス | https://fujisakagas.com/ | `searchconsole_fujisaka` | `fujisaka-dev` | `hp-analysis/fujisaka/` | `hp-loop-fujisaka` | [sites/fujisaka.md](sites/fujisaka.md) |

> 各サイトは**独立したループ**として回る（mailbox `to: hp-loop-<site>`／Slack日報スレッド所有者 `hp-loop-<site>`／daily起動も別）。1回の実行を1サイトに限定し、ヘッドレス900秒タイムアウトを避ける。

---

## データソース（権限非依存で最適解／不足は社長に要求）

分析の一次情報。**AI が直接取得できないものは「未整備」と明記し、LLM で代替・捏造しない。**

| ソース | 何に使う | 現状の取得手段 | 状態 |
|--------|---------|--------------|------|
| Google Search Console | 検索クエリ・表示回数・CTR・掲載順位・インデックス | `bin/.venv/bin/python3 bin/gsc-fetch.py`（BigQuery読み取り専用・**ヘッドレス/cron でも実行可**＝settings.local.json許可済・認証は.env自前ロード）。**`--dataset <サイトのGSC dataset>` 必須**（`sites/<site>.md` 参照：ycom/yoshida/fujisaka） | ✅ 取得可 |
| Google Analytics (GA4) | 流入・流入経路・滞在・離脱・CV | `bin/.venv/bin/python3 bin/ga4-fetch.py`（BigQuery読み取り専用・ヘッドレス可）。**GA4 dataset はサイト別**（ycom=`analytics_265729912` 稼働／yoshida・fujisaka は要確認＝無ければ「データ未取得」と明示し社長へ要求） | 🟡 サイト別 |
| サイトアクセス（HTML/レスポンス） | ファーストビュー・導線・on-page信号・速度・モバイル | `curl`/`bin/hp-audit.sh`（運用中）で取得可 | ✅ 取得可 |

> **原則**：GSC/GA4 は BigQuery 経由で**ヘッドレス（cron）でも取得可**＝「承認待ち/未整備で回せない」は誤り。効果計測が要る提案では実データを引く（捏造しない）。ただし **GSC はデータラグ 2〜3日**・施策反映直後は“施策前”値しか出ないので、効果の実測はラグを見越して次サイクルに予約してよい。サイトのソース取得（curl 等）は hp-audit を一次にする。

---

## 運用設定

| 項目 | 値 |
|------|----|
| 頻度（目安） | **サイトごとに日次**（毎日深夜に各サイトの解析を強制：ycom 02:00 / yoshida 02:30 / fujisaka 03:00）＋ `to: hp-loop-<site>` の新着（実装担当の報告／社長Slack返信）があれば随時。HP本体もGSC/GA4も1時間では変わらないため日次が妥当 |
| 1サイクルの提案数 | 3〜5件目安（過剰提案禁止。Quick win 優先） |
| タイムゾーン | Asia/Tokyo |
| 停止条件 | 社長の停止指示／未回答の質問が溜まったら一旦停止して回答待ち |
| 実行方式 | **VPSローカル cron ＋ ヘッドレス `claude -p "/hp-loop <site>"`（無人・サイト別日次）**。ディスパッチャ＝`bin/agent-tick.sh`（`daily hp-loop-<site>` で強制／`to: hp-loop-<site>` 新着で随時）。日報は Slack のサイト別スレッドへ `post --as hp-loop-<site>`（**日次実行では毎日必ず1本＝概要＋掲示板URL**。変化が無い日も省略しない＝社長の「毎日忘れず」の規律可視化）。[[project_unattended-loop-cron]] |
| 役割分担 | **本ループ＝診断・提案まで。実装（drafts作成含む）はしない。** 提案は社長が対象サイト担当の別エージェントに引き渡して実装（web-maintenance と同じ分担） |

## スコープ

- **含む**：対象サイトの公開HTML・on-page信号・GSC/GA4データ・導線/CV・SEO・速度・モバイル・信頼性（hp-improve.md の評価観点に準拠）
- **含まない**：本番サイトの無断改変、外部送信、対象外サイト、機密の外部持ち出し

---

> **頻度についての注記（AIからの一手前の指摘）**：HP本体もGSC/GA4データも1時間で変わらないため、1時間ごとの分析は同じ提案の繰り返しになりやすい。実務的には**日次〜週次**が妥当。1時間ごとは /loop の動作テスト用と理解。本番運用の頻度は要再確認（Cycle 001 を手動テストとし、定期化は合意後）。

## 変更履歴
| 日付 | 内容 |
|------|------|
| 2026-06-11 | 初版（型）。対象・データソースは仮置き、確定待ち |
| 2026-06-11 | 対象=y-com.info / ゴール=SEO流入+問い合わせ増 / 頻度=1時間（要再考）を確定。Q-003(GSC/GA4)は保留 |
