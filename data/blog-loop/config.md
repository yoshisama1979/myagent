# ブログ分析ループ — 設定（config）

> `/blog-loop <client>` が毎サイクル最初に読む**共通設定**。クライアント固有値（ブログURL・GSC/GA4 dataset・ゴール・担当・掲示板・社長指示ファイル）は **クライアント別 config `data/blog-loop/clients/<client>.md`** に分離（hp-loop と同じ構成）。
> ここを社長が編集すれば全クライアント共通の振る舞いが、`clients/<client>.md` を編集すればそのクライアントの設定が変わる。

---

## 対象クライアント登録表（マルチクライアント）

`/blog-loop <client>` の `<client>` に client-key を渡す（無指定は後方互換で `ycom`）。各クライアントの詳細は右のconfigを読む。

| client-key | クライアント | ブログURL | GSC dataset | 執筆/実装担当 | 掲示板 | ループ識別子 | config |
|------------|------------|----------|-------------|--------------|--------|-------------|--------|
| `ycom` | はなさか自社(YCOM) | https://y-com.info/contents/ | `searchconsole_ycom` | `web-hanasaka` | `hp-analysis/ycom/blog/` | `blog-loop-ycom` | [clients/ycom.md](clients/ycom.md) |

> 今後クライアントが増えたら、この表に1行＋ `clients/<client>.md` ＋ `data/blog-loop/<client>/from-president.md` ＋ 掲示板3層を追加する。各クライアントは**独立したループ**として回る（mailbox `to: blog-loop-<client>`／Slack日報スレッド所有者 `blog-loop-<client>`／daily起動も別）。

---

## データソース（権限非依存で最適解／不足は社長に要求）

分析の一次情報。**AI が直接取得できないものは「未整備」と明記し、LLM で代替・捏造しない。**

| ソース | 何に使う | 取得手段 | 状態 |
|--------|---------|---------|------|
| Google Search Console | 記事ごとのクエリ・表示回数・CTR・掲載順位。「あと一歩のクエリ」「取りこぼし」「磨くべき既存記事」が事実で分かる | `bin/.venv/bin/python3 bin/gsc-fetch.py --dataset <GSC dataset>`（T-006・BigQuery読み取り専用・ヘッドレス/cron可）。データラグ2〜3日 | ✅ 取得可 |
| Google Analytics (GA4) | 記事の流入・読了・記事→CVの寄与 | `bin/.venv/bin/python3 bin/ga4-fetch.py`（T-007・BigQuery読み取り専用）。dataset はクライアント別（ycom=`analytics_265729912`） | 🟡 クライアント別 |
| ブログ本文（HTML） | 記事一覧・タイトル・更新日・検索意図の充足・内部リンク・鮮度 | `curl`/`bin/hp-audit.sh`（T-001・運用中）で取得 | ✅ 取得可 |
| 競合トピック（検索結果） | 上位記事が書いている論点・構成・自社に無いテーマの発掘 | `bin/hp-serp.sh "<クエリ>"`（T-011・読み取り専用Yahoo検索）／対比は `bin/hp-compete.py`（T-010） | ✅ 取得可（地域性以外は参考。大阪固有は社長依頼） |

> **原則**：効果（順位/CTR/クリック/CV）が要る提案は GSC/GA4 の実データで裏取りする（捏造しない）。GSC はデータラグ 2〜3日＝施策反映直後は“施策前”値しか出ないので、効果実測はラグを見越して次サイクルに予約してよい。

---

## 運用設定

| 項目 | 値 |
|------|----|
| 頻度（目安） | **クライアントごとに日次**。**HP分析(`/hp-loop`)とは別タイミング**で回す（HP分析が深夜02:00-03:00台なので、ブログは時刻を分離＝下記「cron」）。毎日ブログを更新する運用を支える |
| 1サイクルの提案数 | 既存改善 `B` 2〜3件＋新規テーマ `T` 2〜3件目安（過剰提案禁止。Quick win 優先） |
| タイムゾーン | Asia/Tokyo |
| 停止条件 | 社長の停止指示／未回答の質問が溜まったら一旦停止して回答待ち |
| 実行方式 | **VPSローカル cron ＋ ヘッドレス `claude -p`（無人・クライアント別日次）**。ディスパッチャ＝`bin/agent-tick.sh`（`daily blog-loop-<client>`／`daily blog-write-<client>` で強制／blog-loop は `to: blog-loop-<client>` 新着で随時）。[[project_unattended-loop-cron]] |
| cron（2本・別時刻・HP解析02-03時とずらす） | `0 5 * * * …/bin/agent-tick.sh daily blog-loop-ycom`（05:00 診断）／`30 5 * * * …/bin/agent-tick.sh daily blog-write-ycom`（05:30 執筆→**事実が揃った記事だけ**WP下書き投稿）。社長決定 2026-06-23。**crontab2行追加＋settings.local.json の post 許可は社長作業** |
| 自動投稿の方針 | **「事実が揃った記事だけ」自動で WP `status=draft` 投稿**（プレースホルダ `【要・社長確認】` が残るうちは保留）。**公開(publish)は常に人間**。1日最大1本。 |
| 役割分担 | **blog-loop＝診断・提案・構成案。blog-write＝完成原稿ドラフト生成＋（事実が揃えば）WP下書き投稿。公開は人間。** |

## スコープ

- **含む**：対象クライアントのブログ記事（公開HTML）・GSC/GA4データ・検索意図/トピック網羅/鮮度/内部リンク/カニバリ/title-meta・新規ネタ発掘（hp-improve.md のコンテンツ評価観点に準拠）
- **含まない**：記事の本番投稿・公開の無断実行、記事本文の代筆、外部送信、対象外サイト、機密の外部持ち出し、地域キーワード詰め込み等の小手先SEO

---

## 変更履歴
| 日付 | 内容 |
|------|------|
| 2026-06-23 | 初版。最初の対象＝YCOM（はなさか自社・ブログ https://y-com.info/contents/ ）。複数クライアント前提のパラメータ化（`/blog-loop <client>`）。cron化は手動テスト→合意後 |
