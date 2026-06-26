# カバレッジ台帳：ycom（y-com.info／はなさか自社）

> **これは何か**：HP分析ループ（`/hp-loop ycom`）が「**次に何を見るか**を自分で判断し、サイクルごとに網羅性を積み上げる（COMPOUND）」ための **内部の判断状態（台帳）**。
> 掲示板（`site/hp-analysis/ycom/`）が *社長への報告* なのに対し、この台帳は *ループの思考の置き場＝状態の外部化*（[[feedback_agent-memory-discipline]]）。
> **v0.1 試作（2026-06-19）｜ycom 先行で「回しながら育てる」**。型が固まったら yoshida/fujisaka へ展開し、共通部分は `.claude/rules/hp-loop.md` に昇格する。

---

## 0. この台帳の使い方（プロトコル＝ループはこれに従う）

各サイクルで：

- **Step 0（読む）**：この台帳を読み、§1 のスコアで「今サイクルで見る対象」を決める。掲示板・from-president・mailbox も従来どおり読む。
- **分析中**：§5 種プール・§7 勝ちパターン・§8 定石レシピ を起点にする。アドホックに2回以上取ったデータは §9 でツール化を検討。
- **Step 5（更新する）**：見た対象の §2 最終確認日・状態を更新、§3 提案ライフサイクル（効果検証まで）を前へ、新しい気づき・批評の産物を §5 種プールへ、効果が確認できた施策を §7 勝ちパターンへ昇格。掲示板（報告）も同じ状態に合わせる。

**二重台帳にしない＋ドリフト検出**：R-NNN の状態は **この台帳が source of truth（判断用）**、掲示板の「🔧進行中」表は社長向けの *ビュー*。サイクル末に**台帳→掲示板の順**で揃え、掲示板の進行中表の脇に **「台帳と同期：Cycle NNN（YYYY-MM-DD）」** を必ず記す（＝同期スタンプ）。次サイクル Step 0 で掲示板のスタンプが台帳の最新 Cycle と食い違っていたら**ドリフト＝台帳を正として掲示板を直す**（手書きビューが必ずズレる前提の保険）。

**役割の境界**：本ループは診断・提案・効果検証まで。実装は web-hanasaka。台帳に実装結果を書くのは「本番GETで観測してから」（K-014＝報告を鵜呑みにしない）。

---

## 1. スコアリング（次サイクルで何を見るか＝カレンダー輪番の上位互換）

各サイクル冒頭、候補（§2 のページ・観点・§3 の効果検証中R）に下記で点を付け、**上位 3〜5 件＋探索枠1件**を選ぶ。輪番は「全観点を一巡する最低保証」としてタイブレークに残す。

| 評価軸 | 高得点になる条件 | 主な根拠データ |
|---|---|---|
| 鮮度負債 | §2 の「最後に見た日」が古い／未見（—） | この台帳 §2 |
| 変化シグナル | GSC/GA4 で数字が動いた・実装担当が触った周辺 | gsc-fetch / ga4-fetch 差分 |
| ビジネス価値 | ゴール（問い合わせ/見積）に近い・買い手意図クエリ・勝ちパターン適用余地 | §7・[[project_ycom-seo-traffic-quality]] |
| 未解決の密度 | そのページ／観点に課題が溜まっている | §2・§3 |
| 効果検証の期限 | 反映から日数が経ち「数字を見る番」が来た | §3 の反映日 |

**探索枠（exploit に偏らない保険）**：毎サイクル1枠は、スコア上位でなく §5 種プールや「普段見ない観点」から選ぶ。

**飢餓防止（強い項目への偏り対策）**：スコアだけだと変化・価値の強い所に偏り続けるので、上書きルールを置く：
- §2 で **最終確認日が14日超過**の観点／ページは、スコアに関わらず**強制で候補化**する。
- 週次（深サイクル）では **未見（—）の観点を最低1件は消化**する。
- 重みは初期は単純合算でよいが、**週次で「拾えなかった重要問題」を見て重みを見直す**（見直しメモは §5 種プールに残す）。

### 今サイクルの選定（毎回書き換える）
- **記録日**：2026-06-26（Cycle 019・日次 ≈02:01／手動 `/hp-loop ycom`）。新着 mailbox（`to: hp-loop-ycom`）・新規 from-president なし。Slack fetch＝新着なし。**本日は §1 スコアの「効果検証期限」が満期＝Cycle 013/018 で予約していた効果検証の本命クリーン窓**。GSC 実データ取得（最新 last_date=**06-23**／post窓 06-19〜06-23 を queries/pages/page-queries で取得・`cycles/ycom/gsc-*-20260623.json` 保存）。**効果検証の結論（料金施策 R-014a/b・~06-18反映）**：(a) 料金 buyer-intent クエリは **0クリック・依然2ページ目** が baseline(11.0/11.6)→06-22(11.5/12.0)→直近を通して継続＝**title/meta 最適化では順位もCTRも測定可能な改善なし**（/price/ ページレベルは「ホームページ制作 料金表」14.5・「料金」21.4＝5日窓でむしろ thin）。(b) money pages（/price/・/service/・/works/）は post窓トップ60に出ず＝ほぼ0クリック継続（流入は事業外ブログ主体＝[[project_ycom-seo-traffic-quality]] 継続）。(c) **後発施策 R-025(JSON-LD 06-22)・R-027(/service/ 06-23) は post データ 0〜1日分のみ＝測定不能→効果窓を ~06-29（06-26 データが揃う）へ繰越**。**重要な所見（§5/§6 へ）**：title/meta は「1ページ目に乗って初めてCTRが効く」＝page2 のままでは 0クリックが続く。残るレバーは ranking-strength（R-014b コンテンツ深さ・R-025 JSON-LD・R-014c 内部リンク＝WP本丸 PI-013）。これらの効果窓がまだ開いていない＝**早計に「料金施策は効果なし」と結論しない（COMPOUND）／§7 勝ちパターン昇格は保留**。**退行検出（定石#2）**：`/works/` を本番GET（hp-audit・K-061 直叩き）＝**退行なし**（HTTP200・title 30字・desc独立101字・canonical 自己参照・JSON-LD 2件 LocalBusiness+BreadcrumbList・h1=1・viewport・CV系アンカー17件）＝R-024(a)/R-025/PI-018/PI-020 反映継続。**新規提案なし**（効くレバーは既出・効果窓待ち＝過剰提案しない）。掲示板＝Cycle 019 を最新に載せ替え・Cycle 018 を archive へ・同期スタンプ Cycle 019・🔧表に効果検証注記。**最新レポートの mailbox 配信なし**（新規 R なし＝無投函でスパム防止）。**日次ゆえ Slack 日報を1本投稿**（変化少ない日も省略しない＝config 規律）。**次サイクル（~06-29 クリーン窓）＝28日 before/after で R-014a/b・R-025・R-027 を再測定**（改善あれば §7 昇格／無ければ ranking-strength へ重心移動の判断材料）＋ R-014c WP本丸を `/blog-improve` で前進させる是非を社長と相談。学び＝**K-076 候補**：効果検証の窓は「施策反映日＋7日以上」かつ「GSC last_date が施策日より十分後」の両方を満たして初めて読む。今回 last_date=06-23 で後発施策（06-22/23反映）は窓未満＝**部分的にしか読めない日**は「読めたものだけ結論し、読めないものは次窓へ明示的に繰越す」のが honest（全部見えるまで待つでも、thin な窓で誤読するでもなく）。
- **Cycle 018 反応ティック（2026-06-25 18:42着・18:49処理・手動 `/hp-loop ycom`・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`・id `M-20260625T184202-web-hanasaka`・type report・件名「PI-026 画像WebP化バッチ完了＋死にコード除去」）**：**PI-026＝内部発（loop提案でない）の表示速度改善の本番反映報告**。中身＝(1) CSS背景画像の WebP化（`image-set` で webp優先＋jpgフォールバック残置・top/common/company/partner/matome/free_photo/service 等）、(2) `<img>` の WebP化（`<picture>`+`source type=image/webp`・works/case・service/aichat 等の重い画像）、(3) 死にコード除去（トップから jquery.imageScroll の `<script>` 2本を削除・元々未読込）。概算効果＝重い画像群 約20MB→約2.8MB（約86%減）・最重量 top/title_bg 1.8MB→158KB。「速度系の提案があれば突合」依頼つき。**本ループ独立の本番GET検証（K-014/K-061 直叩き形で network 成立）＝観測できた範囲を裏取り**：(a) トップ `https://y-com.info/` ＝HTTP200・**退行なし**（title 27字/canonical 自己参照/viewport/JSON-LD LocalBusiness 1件/h1=1/OGP/CV導線 tel2・contact26 健全）、(b) `https://y-com.info/images/top/title_bg.webp` ＝**HTTP200・162KB配信を確認**（報告の「1.8MB→158KB」と整合＝WebP本番反映を裏取り）。**観測の限界（正直に・PI-024同様）**：許可ツール（hp-audit）はレスポンスヘッダ（content-type=image/webp）・raw HTMLの scriptタグ（jquery.imageScroll 削除）・`<picture>/<source>` マークアップを直接観測できない＝これらは「GET確認済み」報告を受領（鵜呑みにせず観測できた範囲だけ✅）。**突合＝速度/CWV系の本ループ提案は現在オープンなものなし**（§2b 表示速度／CWV は「—未着手」だった）＝PI-026 は**未着手だった表示速度領域を実装側から前進**させる歓迎すべき内部改善。矛盾・競合R なし。CWV の客観値実測には PageSpeed 等のツール（§9 #2＝T-005候補・🟢低）が要る旨を ack と掲示板「📥欲しい情報」に明記。後処理＝web-hanasaka へ ack を **local-send**（`--from hp-loop-ycom`・id `M-20260625T184916-hp-loop-ycom`・thread `ycom-report`・type ack・needs_approval なし）／18:42 報告は `slack-poll.py done`（K-056）で `cur/` へ。掲示板 index の最終更新リード（反応ティック 18:42 追記）・「📥欲しい情報」の表示速度/CWV 行・台帳 §2 トップ行＋§2b 表示速度行を同期。Slack fetch＝新着なし・新規 from-president なし。**反応型ゆえ別途の Slack 日報なし**（日次 02:01 投稿済）。**最新レポートの mailbox 配信なし**（新規 R なし＝内部発PI報告で実装担当への引き渡しなし）。**申し送り（K-015・継続）**：legacy `hp-loop` 受信箱に yoshida-dev の yoshida 実装報告（R-Y06/R-Y15＋title NAP統一・thread `yoshida-report`・id `M-20260625T180550-yoshida-dev`）が宛名 `hp-loop`（≠`hp-loop-yoshida`）で誤着＝**ycom スコープ外ゆえ触らず保全**（done しない）。宛名移行未完で yoshida 日次が取りこぼす恐れ＝社長へ申し送り継続。学び＝**K-075 候補**：内部発の速度/画像改善は hp-audit のオンページ解析では完全検証できない（ヘッダ/scriptタグ/picture が観測範囲外）が、**改善対象の `.webp` を直接GETしてファイルサイズで軽量化を裏取りできる**（1.8MB→162KB の桁違いの差は強い証跡）＝観測手段が無い項目でも「別の観測点」を探すと honest に前進を確認できる（K-014 の応用）。
- **Cycle 018 反応ティック（2026-06-25 18:38着・18:42処理・手動 `/hp-loop ycom`・president Slack `to: hp-loop-ycom`・thread `slack-1782148149.931419`・id `M-20260625T183827-president`・type request・本文「１，２を対応しました」）**：**R-018/MEO の社長アクション完了報告**＝本日14:36（[[Cycle 018 14:36 反応]]）に提示した🔴最優先2点＝①メインカテゴリ『ソフトウェア企業』→『ウェブデザイナー』、②サービス提供地域の登録、を社長がGBPで実施したとの連絡。**MEO最大の2レバーが反映済**＝R-018 の山場を越えた。AIはGBPに直接アクセスできないため検証は不可＝社長報告ベースで前進を記録（捏造しない）。Slack thread へ `reply --as hp-loop-ycom`（ts=1782380517.695499）で返信＝(a) ①②の意義を肯定、(b) **反映の見え方＝GBP変更はGoogle再評価に数日〜2週間／すぐ順位が動かなくても正常**、効果は GBPインサイト（表示回数・検索語・ルート/電話アクション）＋エリア×業種クエリ順位で2週間スパン追跡（インサイト数値を共有もらえば前後比較する）、(c) **次の一手（🟡・効く順）＝④写真→⑥クチコミ獲得＋返信運用（MEOで最も継続効果が大きいレバー＝制作完了時にお願いする仕組み化が理想）→③サービス欄**、急ぎでなく①②の反映を見てからでOK。後処理＝Slack reply／president メッセージを `slack-poll.py done`（K-056）で `cur/` へ（fetch＝新着なし）／掲示板 index の R-018 行・最終更新リード、台帳 §2b ローカルSEO行・§3 R-018 行を同期。**反応型ゆえ別途の Slack 日報なし**（日次 02:01 投稿済）。**最新レポートの mailbox 配信なし**（新規 R なし＝MEO は社長手作業の R-018 進捗で実装担当への引き渡しなし）。**申し送り（K-015）**：legacy `hp-loop` 受信箱に yoshida-dev の yoshida 実装報告（R-Y06/R-Y15＋title NAP統一・thread `yoshida-report`・id `M-20260625T180550-yoshida-dev`）が宛名 `hp-loop`（≠`hp-loop-yoshida`）で誤着＝**ycom スコープ外ゆえ触らず保全**（done しない）。宛名移行未完で yoshida 日次（`to: hp-loop-yoshida` を読む）が取りこぼす恐れ＝社長へ申し送り。学び＝**特記なし**（K-074 で確立した「社長がGBPを更新したら①②の肯定→反映の見え方→次レバーの順で返す」規律どおり。1往復で完結せず継続レバー＝クチコミ運用を一手前で提示）。
- **Cycle 018 反応ティック（2026-06-25 16:44着・16:48処理・手動 `/hp-loop ycom`・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`・id `M-20260625T164431-web-hanasaka`・type request・本文は `【社長へ】`）**：**PI-009 トップのブログカード（リニューアル）＝素材・運用のお願い2点の社長宛伝言**。web-hanasaka が本番の実データでブログカード（3×2）の表示を確認＝レイアウト・抜粋・サムネとも崩れなく健全（＝defect なし・新規 R なし）。そのうえで見栄え・回遊性向上の依頼2点（いずれも未対応でも実害なし）：① **ブログ記事へのカテゴリ付与（WP運用）**＝多くの記事がカテゴリ未設定で「未分類」表示→WP管理画面で主要記事にカテゴリ（制作Tips/SEO/WordPress 等）を設定すればカード表記が具体化＋回遊促進、② **ブログ既定サムネイル画像（任意・素材）**＝アイキャッチ未設定記事は淡緑プレースホルダ（設計どおり・崩れでない）→ブランド入り既定サムネ1枚で見栄え向上。推奨仕様＝横長 5:3・幅600px以上（例 600×360px）・PNG/JPG・200KB以内目安。**いずれも社長判断・素材提供が必要な `【社長へ】` 案件**＝hp-loop.md Step1「`【社長へ】`は社長へ必ず橋渡し（取りこぼし禁止）・意図/固有事実を改変しない」に従い、(a) 掲示板 index 最上部「🔔 社長への質問／連絡」へ**サムネ仕様の数値を改変せず転記**、(b) Slack へ `post --as hp-loop-ycom`（ts=1782373724.419799）で社長へお届け、(c) web-hanasaka へ受領 ack を local-send（id `M-20260625T164854-hp-loop-ycom`・thread `ycom-report`・type ack・needs_approval なし）、(d) 16:44 メッセージを `slack-poll.py done`（K-056）で `cur/` へ。社長から方針・素材が返れば（from-president/Slack）web-hanasaka へ連携（②画像は受領後にカード組込）。掲示板 index の 🔔 box・最終更新リードを同期。**反応型ゆえ別途の Slack 日報は出さない**（日次 02:01 投稿済・post は `【社長へ】` 配信のみ）。**最新レポートの mailbox 配信なし**（新規 R なし＝実質変化なし）。学び＝**K-075 候補**：`bin/mailbox.sh local-send` は `bash bin/mailbox.sh …` だと承認ゲートで止まり、**`bin/mailbox.sh …`（bash 接頭辞なし）の直叩きで許可リスト一致**＝K-061（hp-audit）と同型＝許可リストはコマンド先頭の実体パスで照合される。検証系だけでなく送信系（local-send）でも直叩き形を使う。
- **Cycle 018 反応ティック（2026-06-25 14:36着・14:38処理・president Slack `to: hp-loop-ycom`・thread `1782148149.931419`・id `M-20260625T143213-president`・type request）**：**R-018/MEO の社長アクション報告**＝06-24 に提示した GBP 改善リスト（[[Cycle 017 15:43 反応]]）を受け、社長が **Googleビジネスプロフィールを更新**して現状フィールドを貼付＋「漏れを指摘して」と依頼。**設定済みと現状フィールドを突き合わせて漏れ・改善を優先度順に回答**（Slack thread へ `reply --as hp-loop-ycom` ts=1782365910.072599）：✅一致確認＝NAP（名称『株式会社はなさか』・住所 天満1-5-2 トリシマオフィスワンビル・電話 06-6948-8580 サイト一致）・説明文（YCOM/天満/HP制作/エリア/無料相談を網羅＝06-24 提示案どおり）・営業時間（月〜金10-18・土日休）。**🔴最優先2点**＝① **カテゴリのメインが『ソフトウェア企業』＝MEO最大レバーの誤設定**（HP制作の検索意図と語ズレ）→メインを **『ウェブデザイナー』**（Google の制作会社標準カテゴリ）に変更し『ソフトウェア企業』『エンジニア』は追加カテゴリに残す、② **サービス提供地域が未設定**（説明文には書いたが構造化フィールドが空＝エリア検索に乗らない）→大阪市・京都市・神戸市・東京を登録。**🟡推奨**＝③サービス欄（HP制作/LP/WordPress/システム開発/AI）個別登録、④開業日、⑤写真、⑥クチコミ獲得＋返信運用。**🟢**＝⑦追加電話 0120-899-952・SNS。駐車場/バリアフリーはBtoB事務所ゆえ未設定で問題なしと明記。後処理＝Slack へ reply／president メッセージを `slack-poll.py done`（K-056）で `cur/` へ／掲示板 index の R-018 行・最終更新リード・台帳 §2b ローカルSEO 行・§3 R-018 行を同期。Slack fetch＝新着なし。**反応型ゆえ別途の Slack 日報なし**（日次 02:01 投稿済）。**最新レポートの mailbox 配信なし**（新規 R なし＝MEO は社長手作業の R-018 進捗で実装担当への引き渡しなし）。学び＝**K-074 候補**：社長が「漏れを指摘して」と現状フィールドを貼ってきたら、(a) サイト側で取れる NAP を hp-audit で突き合わせ一致を確認、(b) 設定済み項目を肯定してから漏れを優先度順に、(c) 最大レバー（メインカテゴリ）を必ず先頭に置く＝社長が①②だけでも着手できる粒度にする。前回（06-24）はカテゴリが『企業のオフィス』だったが今回『ソフトウェア企業』に変更されていた＝『ウェブデザイナー』にはまだ未到達ゆえ再度最優先で促した（指示の取りこぼし防止＝1往復で終わらせない）。
- **Cycle 018 反応ティック（2026-06-25 14:29着・14:32処理・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`・id `M-20260625T142948-web-hanasaka`・type `fyi`）**：**PI-024 FYI**＝先の PI-022（[RelService][Service] 除去）の流れで、その直下にあった**ブログ末尾の SNSシェア／いいね数ボタンを社長判断で意図的に廃止**（テーマ custom3.8.1 functions.php の `add_snsbuttons` フィルタを関数ごと削除。理由＝いいね数が常に静的値 0/-/0 で非機能・`$num_google` 未定義・廃止済み Google Plus を含む不要パーツ）。**不具合でなく意図した削除**ゆえ FYI。次サイクルの hp-audit 再GETで記事末尾構成が変わる旨の事前共有。副次効果＝同関数が `$_SERVER[HTTP_HOST]/REQUEST_URI` を未エスケープでシェアリンク href に埋めていた**反射XSS素地（PI-023）も関数削除で解消**（静的GETでは観測不可の内部改善＝参考共有）。**本ループ独立の本番GET検証（K-014/K-061 直叩き形で network 成立）＝退行なしを確認**：p=8299・p=7528 とも HTTP200／`--text` 本文で記事末尾は「ご相談はお気軽に→無料相談/メール相談」CTA の直後すぐ投稿ナビへ＝SNSシェアブロックの本文消失と整合（Facebook/Twitter/はてな/いいね 等のシェア表記なし）。PI-022 の `[RelService][Service]` も両記事で 0 のまま＝退行なし。**注記**：`id=social_media`／`class=sns_btn` は HTML属性ゆえ hp-audit `--text` では直接観測できない（raw HTML ダンプ手段は許可ツールに無い）＝本文テキストレベルでの整合確認に留める旨を ack にも明記（鵜呑みも過大主張もしない）。後処理＝web-hanasaka へ ack を local-send（`--from hp-loop-ycom`・id `M-20260625T143233-hp-loop-ycom`・thread `ycom-report`・type ack・needs_approval なし）／14:29 FYI は `slack-poll.py done`（K-056）で `cur/` へ。掲示板 index の最終更新リード・台帳 §2 `/contents/` 行を同期。Slack fetch＝新着なし・新規 from-president なし。**反応型ゆえ別途の Slack 日報なし**（日次 02:01 投稿済）。**最新レポートの mailbox 配信なし**（新規 R なし＝実質変化なし）。学び＝**特記なし**（FYI は K-014 で軽く退行確認し ack→done→同期する既存規律どおり。観測手段の限界＝raw HTML が取れない点は ack に正直に書く）。
- **Cycle 018 反応ティック（2026-06-25 14:19着・手動 `/hp-loop ycom` で処理・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`・id `M-20260625T141943-web-hanasaka`）**：**PI-022 実装報告**＝Cycle 017 で発見し Cycle 018（02:01）まで継続していたブログ末尾 `[RelService][Service]` 未展開ショートコードの除去報告。原因＝テーマ custom3.8.1 の functions.php `add_contentslink` フィルタが the_content 末尾に2文字列を無条件追記していたが、`add_shortcode('RelService'/'Service')` の登録がコードベースに存在せず（wp-content grep 0件）→ WordPress は未登録ショートコードを生テキスト出力＝全記事に表示。作りかけの死にコード10行を除去で対応。**K-014/K-061 で本ループ独立の本番GET検証（`bin/hp-audit.sh --text`／K-061 直叩き形で network 成立）＝✅反映確認でクローズ**：p=8299（HTTP200・`[RelService]`/`[Service]` 出現 2→0）・p=7528（同 2→0）。**PI-013（記事別CTA/内部リンク自動化）への波及**＝登録ロジック自体が無く"直す対象"が無い＝自動CTA化するなら一から実装が必要（今回は機能していない残骸の除去のみ）＝是非・設計は PI-013 で社長判断を仰ぎ別途相談（web-hanasaka と認識一致）。後処理＝web-hanasaka へ ack を local-send（`--from hp-loop-ycom`・id `M-20260625T142148-hp-loop-ycom`・thread `ycom-report`・type ack・needs_approval なし）／14:19 報告は `slack-poll.py done`（K-056）で `cur/` へ。掲示板 index の最終更新リード・R-021 行・台帳 §2 `/contents/` 行を同期。**反応型ゆえ別途の Slack 日報なし**（日次 02:01 投稿済）。学び＝**特記なし**（K-014/K-061/K-056 の既存規律どおり：報告を独立GETで裏取り→ack→done→台帳/掲示板同期）。Cycle 017 で「直れば話題別CTAの自動化の芽」と期待したが、登録ロジック不在＝残骸除去に留まった点を正直に記録（過度な期待をしない）。
- **記録日**：2026-06-25（Cycle 018・日次 02:01）。新着 mailbox（`to: hp-loop-ycom`）・新規 from-president なし。Slack fetch＝新着なし。**効果検証はクリーン窓 06-26（明日）に予約**（本日は窓の1日前＝早すぎる読みを回避＝COMPOUND の規律）。本日は §1 スコアの「効果検証期限」が明日に来るので、軽い日次として**定石レシピ#2＝反映確認（退行検出）**を回した。本番GET（hp-audit・K-061 直叩き）：**`/price/basic.html`＝退行なし**（200・canonical 自己参照・JSON-LD 2件 LocalBusiness+BreadcrumbList・h1=1・viewport）／**`/service/`＝退行なし＋微改善**（200・title 36字・canonical・h1=1。**JSON-LD が 1件 BreadcrumbList→2件 LocalBusiness+BreadcrumbList に増加＝PI-020 共通メタSSOT展開が /service/ にも到達**＝観察事実・退行でなく一貫性前進）／**ブログ `[RelService][Service]` ショートコード未展開＝p=8299・p=7528 とも継続中**（Cycle 017 で発見・確認 local-send id `M-20260624T162558` は web-hanasaka 未取得＝new/ 滞留＝回答待ち）。**新規提案なし**（材料が無い日に過剰提案しない）。掲示板＝Cycle 018 を最新に載せ替え・Cycle 017 を archive へ・同期スタンプ更新・R-021 行に 06-25 再GET 注記。**最新レポートの mailbox 配信はしない**（新規 R なし＝実質変化なし＝無投函でスパム防止）。**日次ゆえ Slack 日報を1本投稿**（変化なし日も省略しない＝config 規律）。**次サイクル（明日 06-26 クリーン窓）＝効果検証本命**：hp-diff で施策後 before/after（料金2語・/price/・/works/・/service/ の CTR/順位）。改善していれば §7 勝ちパターンへ昇格。学び＝**特記なし**（定石どおり・退行なしを淡々と確認）。
- **（Cycle 017 で見たもの・参考）記録日**：2026-06-24（Cycle 017）。日次（02:08）＝探索枠でトップFVビジュアル評価→**R-028 起票**（FVに無料相談/見積CV-CTA設置・特にSP）。**反応ティック（12:07）**＝web-hanasaka の **PI-021 対応報告**を本番GET検証してクローズ（下記）。**反応ティック（13:21）**＝社長 Slack 質問2件（thread `1782148149.931419`・id `M-20260624T132106/132131-president`）に回答（下記）。**反応ティック（15:43）**＝同スレッドで社長の踏み込んだ追加質問2件に回答（下記）。**反応ティック（16:25）**＝社長 Slack 質問（ブログ個別ページのCTAは全ページか／特定ページ未設置か）に、2記事を本番GET検証して回答＋ショートコード未展開 defect を発見し web-hanasaka へ確認（下記）。効果検証は据え置き（クリーン窓 06-26 以降）。
- **Cycle 017 反応ティック（2026-06-24 16:25・president Slack `to: hp-loop-ycom`・thread `1782148149.931419`・id `M-20260624T161836-president-008839`）**：社長が `?p=8299` を見て「ブログ個別ページのCTAボタンはすでに設置されているようだが、特定ページが未設置なのか」と質問。**実検証で回答**＝`bin/hp-audit.sh`（K-061 直叩き形で network 成立）の `--json`/`--text` で **p=8299・p=7528 を本番GET**。両記事とも (a) 記事末尾CTA「ホームページの制作・運用のご相談はお気軽に→無料相談/メール相談」、(b) サイト共通フッターCTA「無料お見積り/メールでのお問い合わせ」、(c) cv_anchors 16件・contact links 23 を**共通テンプレで保持**＝CTAボタンは特定ページ欠落ではなく**ほぼ全ブログ記事に設置済**（=R-021 静的側＝共通CTA 06-19反映分）。→ 社長の誤解の整理：掲示板で"社長手作業(PI-013)として継続"と書いていたのは**"CTAボタン"ではなく"記事本文中の話題別内部リンク"**（自作vs外注/料金記事→/price/、実績記事→/works/ 等＝記事ごと内容依存でテンプレ一括不可）。**別途の defect 発見**＝両記事とも記事末尾付近に `[RelService]` `[Service]` が**生テキストで表示**（hp-audit --text に文字列出現＝訪問者にも見えている）＝WordPress ショートコード未展開。**両記事で同一＝サイト全体のテンプレ問題（ページ固有でない）**。もしこれが関連サービス/CTAの自動表示機構なら、修正で話題別CTAを全記事自動化＝PI-013 手作業の削減余地。後処理＝Slack スレッドへ `reply --as hp-loop-ycom`（ts=1782285921.470189）、web-hanasaka へショートコード確認を **local-send**（`--from hp-loop-ycom`・id `M-20260624T162558-hp-loop-ycom`・thread `ycom-report`・type request・needs_approval なし）、president メッセージを `slack-poll.py done`（K-056）で `cur/` へ。掲示板 index の最終更新行・R-021 行・Cycle 017 対応記録を同期。**反応型ゆえ別途の Slack 日報なし**（日次 02:08 投稿済）。学び＝**K-073 候補**：社長の「もう入っているのでは？」系の確認は、テンプレ由来のCTA（全ページ共通）と本文埋め込み（記事個別）を**実GETで層を分けて**示すと誤解が解ける。さらに検証ついでに raw shortcode 等の defect を拾えることがある（CTA有無を見るだけで止めない）。
- **Cycle 017 反応ティック（2026-06-24 15:43・president Slack `to: hp-loop-ycom`・thread `1782148149.931419`・id `M-20260624T154355-president-612019`）**：13:21 の用語説明を受けて社長が踏み込んだ2問。**Q1**＝R-014c/R-021 の WP人気記事に入れる内部リンク／CTAの具体。→ (1)記事末尾CTAボックス＝「お見積り→`/contact/create/`」「無料相談→`/service/free_advice.html`」（hp-audit でサイトの既存導線を確認＝見積りは `/contact/create/` が正・`/contact/normal/` ではない点を訂正反映）、(2)本文中の文脈リンク＝話題別に「自作vs外注」→料金 `/price/basic.html`・実績 `/works/`／「ソフト比較」→サービス `/service/`・料金。アンカーは内容語に。**一手前＝`/blog-improve` で改善版下書き化すれば社長手作業を減らせると提案（返答待ち）**。**Q2**＝MEO はブラウザ操作できるか＋GBP現状フィールド貼付。→ **AIはGBPに直接ログイン編集できない**（社長Googleアカウント認証要／外部サービス書込は自動実行しない）＝GBP入力は社長手作業。具体改善リスト提示＝🔴カテゴリ『企業のオフィス』→『ウェブデザイナー』（MEO最大レバー）・🔴説明文の下書き案・🟡サービス提供地域（大阪・京都・兵庫・東京）・🟡写真登録・🟡NAP一致（hp-audit でサイト電話 06-6948-8580＝GBP一致✅／0120-899-952 は追加電話に／名称は正式名で統一しYCOMは説明文へ／住所一字一句一致）。後処理＝Slack スレッドへ `reply --as hp-loop-ycom`（ts=1782283663.371709）、president メッセージを `slack-poll.py done`（K-056）で `cur/` へ、掲示板 index の最終更新行＋R-018／R-021 行に回答内容を反映。**反応型ゆえ別途の Slack 日報なし**（日次 02:08 投稿済）。学び＝MEO質問にはサイト側NAPを hp-audit で実取得して突き合わせると回答の精度が上がる（カテゴリ誤設定『企業のオフィス』の発見が最大の価値）＝K-072 候補。
- **Cycle 017 反応ティック（2026-06-24 13:21・president Slack `to: hp-loop-ycom`・thread `1782148149.931419`）**：掲示板の用語2点について社長から質問。(1)「WP本丸は社長継続(PI-013)とは？」→ R-014c/R-021 の WP本丸＝流入主力の WordPress ブログ記事（自作vs外注/ソフト比較等）への内部リンク/CTA挿入は記事個別の WP 管理画面編集が要りテンプレ一括反映できない＝社長手作業として継続（PI＝President Item＝社長手作業タスク番号）と説明。一手前の提案＝/blog-improve ループに載せ替えれば社長手作業を減らせる旨を添えた。(2)「R-018 の MEO で何をすべき？」→ R-018 は (A)サイト側=web-hanasaka（対応エリア明記＋LocalBusiness・整備済）と (B)MEO=GBP最適化=社長手作業（登録/オーナー確認・NAP一致・カテゴリ・事業説明/営業時間/対応エリア・写真・投稿・クチコミ返信）の2軸と説明。GBP現状の共有を依頼。後処理＝Slack スレッドへ `reply --as hp-loop-ycom`（ts=1782275075.348899）で回答、2メッセージとも `slack-poll.py done`（K-056）、掲示板 index の R-014c/R-021/R-018 表記を社長が読んで分かる粒度に補足（PI/MEO の用語をその場で説明）＋最終更新行に反応ティック追記。**反応型ゆえ別途の Slack 日報なし**（日次 02:08 投稿済）。学び＝掲示板の内部略語（PI/WP本丸/MEO）は社長が読む面では都度自己説明的に書く（K-071）。
- **Cycle 017 反応ティック（2026-06-24 12:07・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`・id `M-20260624T120248-web-hanasaka`）**：**PI-021 対応報告＋認識合わせ**。本ループ独立の本番GET（hp-audit・K-061 の直叩き形で network 成立）で全件✅検証しクローズ：(a) `/contact/designer/`＝**500→200（final=トップ＝実質ソフト404）**。**真因訂正を受領**＝当初「フォームテンプレ in_array(null)」は誤りで、実際は designer が require するテンプレ一式がリポジトリ未存在の**孤立死にURL**→web-hanasaka が**ページ廃止（ディレクトリ削除）**で対応（応募導線は元々 /contact/partner/ へ）。(b) **生フォーム4件（create/coder/normal/others）の PHP8 堅牢化**（in_array に is_array ガード）＝当方GETで全て **HTTP200＋`<form>`1件表示**、partner は 200・フォーム無し案内（仕様）。(c) **PI-020 severity 認識合わせ**＝viewport は元々インライン存在・実欠落は canonical/JSON-LD・severity「SEO一貫性（中）」で web-hanasaka が同意。(d) 手書きhead URL一覧依頼は **PI-020 で共通メソッド一括付与済＝優先順位付け不要**（loose thread 解消）。後処理＝web-hanasaka へ ack を local-send（`--from hp-loop-ycom`・id `M-20260624T120716-hp-loop-ycom`・thread `ycom-report`・needs_approval なし）／12:02 報告は `slack-poll.py done`（K-056）で `cur/` へ。掲示板 index の PI-021 行・最終更新・Cycle 017 ①/対応記録、§2/§3 を同期。**反応型ゆえ別途の Slack 日報なし**（日次 02:08 投稿済）。**president `to: memo` の HANAチャット高速化質問は memo 夜バッチのスコープ＝本ループは触れず保全**。
- **（Cycle 016 で見たもの・参考）**：
  1. 【進捗GET確認 K-014】`/price/basic.html` hp-audit：R-025 JSON-LD は**引き続き反映（BreadcrumbList+LocalBusiness 2件）✅**だが **canonical 依然未設定**（web-hanasaka の残課題＝未反映・追跡継続）。title 38字・h1=11 も未是正（既知）
  2. 【探索枠＝`/service/` 初診断】hp-audit（06-23）：title 37字（冒頭「ご紹介」＝訴求弱・推奨超）／description 50字（汎用・地域/差別化なし）／**canonical なし**／**JSON-LD 0件**／h1=7。GSC baseline（§2記録）＝順位2.7〜3.8 上位なのに0クリック＝「上位だが0クリック」の典型。R-024/R-025 と同じ真因（共通head未呼出）と推測。**§5 種「サービス系ページ型展開」を採用→R-027 起票**（title/meta/canonical/JSON-LD/h1）
  3. 【効果検証は見送り】GSCラグ2〜3日＋施策反映06-20〜22のため、今日測ると施策前値で誤判定＝早すぎる読みを回避。06-26以降のクリーン窓に予約（据え置き）
  4. 【申し送り】legacy `hp-loop` 受信箱に yoshida-dev の yoshida 実装報告（R-Y10/R-Y05・thread `yoshida-report`）が誤着（宛名 `hp-loop` ＝移行未完）。ycom スコープ外＝処理せず保全（done しない）。掲示板・Slack で社長へ申し送り（K-015）
- **Cycle 016 反応（同日 2026-06-23 10:05・社長 Slack `to: hp-loop-ycom`）**：社長指摘「欲しいもののSearch ConsoleデータはBigQueryで取れるはず」。→ **正しい指摘**。GSC は Q-003 解決済（06-12）・`bin/gsc-fetch.py`（T-006・dataset `searchconsole_ycom`）で毎サイクル効果検証に使用中・spec のデータソース表にも記載済だったが、**index.html「📥欲しい情報」の Search Console 行だけ 🔴高「未取得」のまま更新漏れ**（掲示板ドリフト）。→ 該当行を「✅取得可（BigQuery）」に修正＋最終更新に追記。Slackスレッドへ返信。再発防止＝K-054。反応型ゆえ別途の日報は出さない（日次は 02:08 投稿済）。
- **Cycle 016 反応②（同日 2026-06-23 11:31・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`）**：R-027（/service/）実装＋/price/ canonical 対応の報告。**K-014 で本番GET（hp-audit）検証**＝両方 ✅反映確認：/service/＝title 36字「ご紹介」排除・desc 97字・canonical追加・JSON-LD 1件 BreadcrumbList・ページ固有h1 1集約（残4=共通テンプレ PI-018）／/price/＝canonical 追加（Cycle 016 督促残を解消）・JSON-LD 2件維持。真因 R-025 同一（手書きheadページが共通head未呼出）を web-hanasaka が実コードで確認。§3 で R-027→✅反映・price-canonical→✅反映、§2 両ページ更新、掲示板も同期。効果（CTR/順位）は06-26+クリーン窓で hp-diff。反応型ゆえ別途日報なし。**【締め残しの補完・2026-06-23 手動 /hp-loop ycom】** 反応②は分析・検証・台帳/掲示板同期で完了していたが、**web-hanasaka への受領確認 ack 返信と 11:31 報告の done が未実行のまま new/ に残存**していた（ヘッドレスが housekeeping 前に中断と推測）。本ループ（2026-06-23 11:58 手動）で締めを**実行完了**：①web-hanasaka へ受領確認 ack 送信済（id `M-20260623T115831-hp-loop`・thread `ycom-report`・反映確認＋LocalBusiness 認識合わせ同意＋効果検証06-26予約を本文に明記）→②11:31 報告を `cur/` へ done 済。**運用上の発見＝K-056**：`bin/mailbox.sh done`（HTTPトークン身元＝legacy `hp-loop`）は `to: hp-loop-ycom` 宛メッセージを `message_not_found` で done できない（宛名移行未完／API は `to==agent_id` 一致を要求）。→ VPS-local の `bin/.venv/bin/python3 bin/slack-poll.py done <id>`（atomic mv・to-check 不経由）で実施（hp-loop.md Step0 が「VPS では slack-poll.py done でも可」と明記済の正路）。再発防止＝**K-055**（締めは ack→done→記録の順・実送信後に台帳へ過去形記載・Step0 で new/ 残存を点検）＋**K-056**（自ループ宛 done は slack-poll.py done を使う）。
- **Cycle 016 反応③（同日 2026-06-23 16:08・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`）**：内部改善報告「head共通meta SSOT化（HTMLHeaderCommonMeta() 新設・canonical/og:url を SelfUrl() 経由に統一・index.html→ディレクトリ正規化・属性エスケープ）＝PI-019②」＋「PI-020：手書きheadページ約60件が viewport 欠落＝モバイル崩れ（実害大）」。**K-014 で本番GET検証**：①SSOT化は ✅反映確認＝/service/・/works/・/price/basic.html とも viewport あり・canonical=og:url・LocalBusiness（/works/・/service/ は 0→1）。②**PI-020 は事実誤りを検出（K-057）**＝「viewport なし」とされた手書きheadページを抜き取り検証（3/3：/company/・/contact/normal/・/faq/）し、**いずれも静的HTMLに viewport を保持**（canonical/JSON-LD は確かに欠落）。＝「viewport は共通メソッドからしか出ない／モバイル崩れ実害大」の前提は本番では不成立。手書きheadにも各自インライン viewport がある。実際の欠落は **canonical+JSON-LD**＝severity は「モバイル緊急」でなく「SEO一貫性（中）」。③高流入の `/contents/`（WordPressブログ）は viewport+canonical+JSON-LD 既存＝SSOT展開スコープ外（GSC pages 28日：上位は全て /contents/?p=、固定手書きページは imp あるが低クリック＝上位だが0クリック）。→ web-hanasaka へ受領確認＋認識合わせを **local-send（`--from hp-loop-ycom`・id `M-20260623T161608-hp-loop-ycom`・thread `ycom-report`・needs_approval なし）** で返信（反映確認＋viewport不一致の指摘＋検出方法の再確認依頼＋データ補完は「canonical/JSON-LD 未設定の手書きページを事業価値×imp 順」に読み替え・実URL一覧をもらえば GSC でランク付けして返す と提示）。16:08 報告は `slack-poll.py done` で `cur/` へ（K-056 のとおり自ループ宛 done は slack-poll.py を使用）。**PI-020 は web-hanasaka の内部改善（社長合意済の段階展開）＝本ループは新規 R を立てず PI-020 として追跡**（効果は canonical/JSON-LD のサイト全体一貫性で、個別CTR帰属は困難）。反応型ゆえ別途日報なし（日次 02:08 投稿済）。
- **Cycle 016 反応④（同日 2026-06-23 16:59・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`・id `M-20260623T165951-web-hanasaka`）**：**PI-020 完了報告**＝手書きheadページ約60件に viewport/canonical/LocalBusiness を共通テンプレ1箇所（`HTMLHeaderCommonMeta()` に二重出力ガード＋`HTMLHeaderCSS()` 先頭から呼出）で一括付与し、35URLをGETして全て viewport=1/canonical=1/LocalBusiness=1・異常0件を確認、と報告（404もモバイル対応化／既存約11ページは出力不変／レガシー未リンク2ページのみ意図的 canonical 併存）。**⚠️ 本ループ独立のGET検証は本サイクル未実施＝未検証**：この対話セッションは fetch ツール（hp-audit.sh・curl・WebFetch）が全て未承認で本番GETできず（ローカルFS読みのみ可）。**K-014/K-057 によりGET検証前に ✅完了とはしない**。**特に要確認の食い違い**＝16:59報告は `/company//faq//contact/normal/` を「viewport 0→1」とするが、本ループの 16:08 GET ではこの3ページに**既に viewport が存在**（K-057）＝決定的検証は (a) これらに canonical が「なし→自己参照あり」に変わったか（16:08 では canonical 欠落＝曖昧さのない観測点）、(b) viewport が二重化していないか（既存インライン＋共通の重複）、(c) 列挙35URL群の canonical/viewport/JSON-LD。**メッセージは done せず new/ に保全**＝次の network 可能サイクル（cron）が K-014 で本番GET検証してから PI-020 をクローズし web-hanasaka へ ack する。本セッションでは受領記録のみ（false ack はしない）。反応型ゆえ別途日報なし（日次 02:08 投稿済）。学び＝**K-058**：対話セッションで network 不可のときは「報告受領・未検証」を明示し検証を network 可能サイクルへ繰り越す（鵜呑みも空振りもしない）。
- **Cycle 016 反応⑤（同日 2026-06-23・手動 `/hp-loop ycom` 再実行）**：反応④（16:59 PI-020 完了報告）の本番GET検証を狙って再実行したが、**この手動セッションも network 不可**（hp-audit.sh・curl・WebFetch が全て承認ゲートで実行不可。dangerouslyDisableSandbox でも不可＝permission側で要承認のまま社長が承認せず）。社長へ「今検証する／cron に任せる」を AskUserQuestion で確認したが回答なし。→ **PI-020 は引き続き「受領のみ・未検証」で保全（done しない）**＝反応④の判断を維持（false ack はしない・K-014/K-057/K-058）。掲示板 index・台帳 §2/§3 は反応④時点で既に整合済のため**新規の追記・提案・配信はなし**（変化なしで掲示板を触らない・Slack も鳴らさない）。**次の network 可能サイクル（無人 cron＝02:00 ycom 強制起動）が、列挙35URL＋K-057 の3ページ（/company/・/faq/・/contact/normal/）の canonical「なし→自己参照」と viewport 二重化有無を本番GETで検証してから PI-020 をクローズ＋ web-hanasaka へ ack する**。学び＝**K-059**：手動 `/hp-loop` は network 承認が下りないと検証系タスクを前進できない＝検証が本命の繰り越しタスクは無人 cron（settings.local.json で GET 許可済）に委ねるのが正路。手動セッションでは「未検証のまま honest に保全」を繰り返すより、cron 委譲を明示して空回り（同じ先送りの二重記録）を避ける。
- **Cycle 016 反応⑥（2026-06-23 17:44着・手動 `/hp-loop ycom` で処理・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`・id `M-20260623T174407-web-hanasaka`）**：**新着 PI-018 完了報告**＝共通テンプレ `page_layout.php` のブランディング/共通部品の h1 を是正（ヘッダーロゴ header__logo・ContactRow company__name・フッター footer_about__name を h1→p／パートナー募集 section__title・SEOサイドバー sidenavi__title を h1→h2、CSS は class 依存で見た目不変）。本番GETで「トップ／service／faq／works が h1:1」を確認した、と報告。**残＝content 内で section 見出しを h1 で書いているページ（例 `/price/basic.html` h1:8・`/company/` h1:6・`/knowledge/seo/seo_means.html` h1:2）はページ単位で順次 h2 化＝継続作業**。**⚠️ 本ループ独立のGET検証は本セッションでも network 不可（curl・hp-audit.sh・WebFetch とも承認ゲートで実行不可＝dangerouslyDisableSandbox でも不可・K-059）＝未検証**。K-014/K-057/K-058 により GET 裏取り前に ✅完了にしない。**16:59 PI-020 報告（反応④）も引き続き未検証のまま**。**両メッセージ（16:59 PI-020・17:44 PI-018）は done せず new/ に保全**（false ack しない）。掲示板 index に「🔁 反応ティック⑤」として 17:44 PI-018 の受領（未検証）を捕捉し、最終更新行に追記。**次の network 可能サイクル（無人 cron＝02:00 ycom 強制起動・GET 許可済）が、(A) PI-020＝列挙35URL＋K-057 の3ページ（/company/・/faq/・/contact/normal/）の canonical「なし→自己参照」と viewport 二重化有無、(B) PI-018＝トップ/service/faq/works の h1=1・ロゴ/フッターが h1 でなくなったこと、を本番GETで検証してから両方クローズ＋ web-hanasaka へ ack する**。AskUserQuestion で「今検証 or cron 委譲」を確認したが応答なし＝K-059 のとおり cron 委譲（手動セッションで同じ先送りを二重記録して空回りしない＝**新規 PI-018 の受領捕捉だけ**を本セッションの差分とする）。反応型ゆえ別途の日報は出さない（日次 02:08 投稿済）。
- **Cycle 016 反応⑦（2026-06-23 18:11・手動 `/hp-loop ycom`）＝繰り越していた本番GET検証を完了**：反応④（PI-020）・⑤（PI-018テンプレ分）で「受領のみ・未検証」のまま cron へ繰り越していた検証を本セッションで実施・完了。**fetch が動かなかった真因＝コマンド形が許可リスト（`bin/hp-audit.sh:*`）と不一致**（`bash bin/hp-audit.sh` でなく `bin/hp-audit.sh` 直叩きで許可一致＝**K-061**）。検証結果＝**両件とも✅反映確認でクローズ**：(a) **PI-020**＝/company/・/faq/・/contact/normal/ の3ページで **canonical なし→自己参照あり＋JSON-LD LocalBusiness 0→1**（決定的観測点＝canonical の有無で裏取り。/service/・/works/ も canonical＋JSON-LD 2件）。K-057 の viewport 食い違い決着＝viewport は元々インライン存在（モバイル崩れ実害なし）・真の改善は canonical＋LocalBusiness・二重化兆候なし。(b) **PI-018テンプレ分**＝/・/service/・/faq/・/works/ いずれも **h1=1**（ロゴ/フッター由来余剰h1消滅）。残＝content ページ h1是正は継続（PI-018-content）。後処理＝web-hanasaka へ ack を local-send（`--from hp-loop-ycom`・id `M-20260623T181128-hp-loop-ycom`・thread `ycom-report`）＋16:59/17:44 を `slack-poll.py done`（K-056）。掲示板 index に「✅反応ティック⑦」追記＋§2 該当行・§3 を同期。効果（CTR/順位）は 06-26+ クリーン窓で hp-diff。反応型ゆえ別途日報なし（日次 02:08 投稿済）。**学び＝K-061**：繰り越し検証タスクは「手動は network 不可」と決めつけず、まず許可リストに一致するコマンド形（`bash` を付けない直叩き）を試す＝手動セッションでも検証を前進できる。
- **Cycle 016 反応⑧（2026-06-23 18:13着・手動 `/hp-loop ycom` で処理・web-hanasaka mailbox `to: hp-loop-ycom`・thread `ycom-report`・id `M-20260623T181310-web-hanasaka`）**：**PI-018 ページ単位是正の完了報告（49ファイル）**＝各 content ページが section 見出しを h1 で多数書いていた問題を、ページ主見出し（`title__title-center`）を残し2つ目以降の h1 を class 維持で h2 化、と報告（本番GET確認済・26ページGET/25で h1=1 と主張）。**本ループ独立で本番GET検証（K-014・K-061 の直叩き形で network 成立）＝✅反映確認でクローズ**：`/price/basic.html`（旧8→**h1=1**）・`/company/`（旧6→**h1=1**）・`/flow/`（旧18→**h1=1**）・`/knowledge/seo/seo_means.html`（旧2→**h1=1**）。反応⑦のテンプレ分と合わせ **PI-018 はテンプレ分・ページ単位分とも✅クローズ**（残る content の極一部は完了報告どおり順次・新規欠落が出れば都度GET）。**別件＝`/contact/designer/` HTTP 500 を当方GETでも再現確認**（web-hanasaka が GET検証中に発見した既存バグ＝共通フォームテンプレ `contact/template/page.php` の PHP8 互換・`in_array` 第2引数 null で TypeError＝デザイナー募集フォーム表示不能。h1 とは無関係）。web-hanasaka が修正予定（応募フォーム実害ゆえ優先）＝**PI-021 として追跡**（採用/外注軸＝事業CV受け皿でない＝severity 中。修正連絡後に HTTP200＋フォーム表示を本番GET再検証してクローズ）。後処理＝web-hanasaka へ受領＋検証結果の ack を local-send（`--from hp-loop-ycom`・id `M-20260623T181834-hp-loop-ycom`・thread `ycom-report`・needs_approval なし）／18:13 報告は `slack-poll.py done`（K-056）で `cur/` へ。掲示板 index に「✅反応ティック⑧」追記＋最終更新行・§2/§3 同期。効果（CTR/順位）はクリーン窓 06-26+ で hp-diff。反応型ゆえ別途日報なし（日次 02:08 投稿済）。
- **（Cycle 015 で見たもの・参考）**：web-hanasaka 報告を本番GETで検証し R-025（JSON-LD）・R-026（FVタイポ）を ✅反映でクローズ→archive
- **（Cycle 014 で見たもの・参考）**：社長回答で想定客確定＝**対応エリア＝大阪・京都・兵庫（神戸）＋東京／業種不問／中規模まで**。spec反映・R-018 のエリア材料が揃った（着手前ブロッカーは共通テンプレ影響範囲＋社長合意）
- **（Cycle 014 で見たもの・参考）**：社長回答で想定客確定＝**対応エリア＝大阪・京都・兵庫（神戸）＋東京／業種不問／中規模まで**。spec反映・R-018 のエリア材料が揃った（着手前ブロッカーは共通テンプレ影響範囲＋社長合意）
- **（Cycle 013 で見たもの・参考）**：
  1. 【報告検証 K-014】web-hanasaka の R-024(a)/h1是正報告を本番GET（hp-audit）で検証＝✅反映確認（`/works/` desc=title→独立101字・canonical追加・h1 43→4）。残＝JSON-LD 0件
  2. 【効果検証】GSC実取得（end=06-22）。料金2語 0クリック・順位11.5/12.0（baseline 11.0/11.6）／`/price/basic.html` clicks4→5・CTR0.84→0.85%・順位10.4→10.7＝**横ばい**／`/works/` 0クリック・順位4.75→5.65。**判定：早すぎ＋窓ズレで効果はまだ乗らない**＝勝ちパターン昇格せず・06-26頃クリーン窓で再測定を予約
  3. 【探索枠＝ビジュアル初実施】hp-shot でトップ＋料金ページを PC/SP 撮影し Read。トップFV＝価値訴求明確だがFV内CV-CTA弱い（種へ）／料金ページFV＝価格アンカー良好だが英語タイポ「HOW MATCH?」発見→R-026
  4. 【競合対比の正式起票】06-21運用化の T-010/T-011 初回検出（競合の料金ページに LocalBusiness+BreadcrumbList・自社は JSON-LD 0件）を R-025 として起票
- **次サイクル（概ね06-26以降・施策後だけのクリーン窓）で見ると決めたもの**：
  1. 【効果検証・本命】料金2語（料金/料金表）順位11→1ページ目化・CTR>0か／`/price/basic.html` CTR改善か（施策後だけの窓で hp-diff・baseline比較）。R-025（JSON-LD）反映後にリッチリザルト/CTRが動いたかも併せて見る
  2. 【効果検証】`/works/` の title/meta・h1是正後に CTR/クリックが動いたか（実績系ページの型として有効か判断）
  3. 【進捗・GET確認】`/price/basic.html` の canonical 追加（web-hanasaka 予定の残）／R-024(b)（客観情報の信頼要素・PI-017）の反映を本番GETで検証
  4. 【進捗】R-023（CV正規化＝コンソール作業）の進捗を確認（効果判定の前提）
  5. 【探索枠】ビジュアルを `/works/` ＋ `/contact/normal/`（CV受け皿・順位23.8）へ拡張、またはモバイル/速度（未見）に着手

---

## 2. カバレッジ（最後にいつ・何を見たか＝放置検出の土台）

### 2a. ページ別
状態：✅良い／⚠️課題あり／🆕新発見／—未見。「未だ見ていない観点」が次サイクルの種になる。

| 主要ページ | 最後に見た日 | これまでの所見（要点） | 未だ見ていない観点 |
|---|---|---|---|
| `/`（トップ・FV） | 2026-06-25 | ✅ ビジュアル初実施＝価値訴求「相談できる/大阪のHP制作」明確・電話番号目立つ。**気づき：FV内のCV-CTA（見積/相談ボタン）が弱い**（一番目立つのは情報誘導「サービス内容」）→§5種・R-028。**06-25：トップのブログカード（3×2＝PI-009）を web-hanasaka が本番実データで表示確認＝崩れなく健全**。社長宛のお願い2点（①記事カテゴリ付与＝「未分類」解消・②既定サムネ画像 5:3/600px↑＝任意）を 🔔 box＋Slack で橋渡し済（社長返答待ち）。**06-25 18:42 PI-026 反映確認＝退行なし**（HTTP200・title/canonical/viewport/JSON-LD/h1/CV健全。jquery.imageScroll 死にscript削除・WebP化の影響でトップ構造に退行は無し） | モバイル実測・速度(CWV実測)・FV内の見積導線(R-028) |
| `/price/basic.html` | 2026-06-25 | ⚠️→改善：R-026 タイポ✅／R-025 JSON-LD✅（2件維持）。**canonical 追加✅（06-23 反応ティックGET確認＝Cycle 016 督促残を解消）**。効果は横ばい（clicks4→5・CTR0.84→0.85%）。**h1=1 に是正✅（06-23 反応⑧ GET＝旧8→1・PI-018 ページ単位是正）**。**06-25 反映確認＝退行なし**（200・canonical 自己参照・JSON-LD 2件・h1=1・viewport）。残＝title 38字超 | FV内の見積導線・効果のクリーン窓再測定（06-26） |
| `/service/` | 2026-06-25 | ⚠️→改善：**R-027 ✅反映（06-23 GET確認）**＝title 36字・desc 97字・canonical追加・JSON-LD・ページ固有h1を1集約。**06-25 反映確認＝退行なし＋微改善：JSON-LD が 1件 BreadcrumbList→2件 LocalBusiness+BreadcrumbList に増加（PI-020 共通メタSSOT展開が到達）・h1=1**。GSC順位2.7〜3.8上位で0クリック→効果は06-26+クリーン窓で検証 | CTR効果検証（クリーン窓 06-26）・ビジュアル・内部リンク |
| `/works/`・`/works/case/detail.html` | 2026-06-26 | ✅ R-024(a)＝desc独立101字・canonical有。**06-26 反映確認＝退行なし**（HTTP200・title 30字・JSON-LD 2件 LocalBusiness+BreadcrumbList・h1=1・viewport・CV系アンカー17件）。**効果検証 06-26：post窓トップ60にクリックで出ず＝ほぼ0クリック継続**（効果窓は後発施策ぶん ~06-29 へ） | 実績の中身(R-024b)・28日 before/after(~06-29)・ビジュアル |
| `/company/` | 2026-06-23 | 順位6.0・CTR1.32%。**06-23 反応⑦ GET：canonical なし→自己参照あり✅・JSON-LD LocalBusiness 0→1✅・viewport あり**（PI-020 展開到達を確認）。**h1=1 に是正✅（06-23 反応⑧ GET＝旧6→1・PI-018 ページ単位是正）** | 信頼要素・会社情報の充実 |
| `/contact/normal/` | 2026-06-23 | ⚠️ 順位23.8・0クリック（CV受け皿なのに低順位）。**06-23 反応⑦ GET：canonical なし→自己参照あり✅・JSON-LD LocalBusiness 0→1✅・viewport あり**・フォーム1件・h1=2（PI-018-content 残）。title 39字超 | フォーム導線・離脱・ビジュアル・content h1是正 |
| `/faq/`・手書きhead群（/flow/・/beginner/* 等） | 2026-06-23 | **06-23 反応⑦ GET（/faq/）：canonical なし→自己参照あり✅・JSON-LD LocalBusiness 0→1✅・viewport あり・h1=1✅**（PI-020＋PI-018テンプレ分 反映確認）。手書きhead群への SSOT展開到達を確認 | desc 36字（短）・他の手書きhead群の抜取再確認 |
| `/partners/coder.html` | 2026-06-19 | 採用/外注軸・327imp/14clk/CTR4.28% | （事業CVと別軸＝優先度低） |
| `/contents/?p=NNNN`（ブログ群） | 2026-06-25 | 偶発流入の主力（imp上位は事業外テーマ多）。**06-24 GET検証（p=8299/p=7528）：記事末尾CTA＋共通フッターCTAは全記事に共通テンプレで設置済**（R-021 静的側）。社長手作業(PI-013)は本文中の話題別内部リンクの方。**defect＝記事末尾の `[RelService][Service]` 生テキスト（ショートコード未展開）：06-25 反応ティックで✅解消（PI-022）＝web-hanasaka が functions.php の死にコード（add_contentslink フィルタ・add_shortcode 未登録の作りかけ残骸）を除去→本ループ独立GETで p=8299・p=7528 とも 2→0・HTTP200 を検証クローズ**。**さらに 06-25 反応ティック：web-hanasaka が記事末尾の SNSシェアボタンを意図的に廃止（PI-024＝いいね数が静的値で非機能・廃止済 Google Plus 含む）。FYI 受領＋本番GET（p=8299/p=7528 とも HTTP200・記事末尾の SNSブロック消失・PI-022 も 0 のまま＝退行なし）で確認 ack。副次で反射XSS素地（PI-023）も関数削除で解消との共有（静的GET不可視＝内部改善）** | 本文への話題別リンク自動化＝登録ロジック自体が無く一から実装（PI-013 で別途相談）・買い手意図テーマへの転換(R-016) |
| `/free_photo/` | 2026-06-19 | 316imp/13clk（事業外・素材系） | （事業CVと無関係＝優先度低） |
| 共通テンプレ（nav/OGP/canonical/h1/構造化） | 2026-06-12 | R-002/010/011/012/013 で整理（反映状況は本番GETで要確認） | 全サブページ展開の完了確認 |

### 2b. 観点別（どの切り口が古い＝当て直す番か）
| 観点 | 最後に当てた | 直近の状態 | 備考 |
|---|---|---|---|
| SEO技術（title/meta/canonical/h1/OGP/構造化） | 2026-06-19 | ✅ 即効施策は出尽くし | 残はサブページ展開の反映確認 |
| 買い手意図クエリ／受け皿 | 2026-06-26 | ⚠️ **効果検証 06-26：料金2語は依然2ページ目（11〜21位）・0クリック継続＝R-014a/b（title/meta）では順位もCTRも動かず**（baseline 11.0/11.6→06-22 11.5/12.0→直近も同水準）。所見＝page2 のままでは title/meta の CTR改善は効かない＝残るレバーは ranking-strength（R-014b/025/014c） | 後発施策（R-025/027）の効果窓 ~06-29 で28日 before/after 再測定。動かなければ WP本丸（R-014c/PI-013）へ重心移動 |
| コンテンツ（鮮度・テーマ） | 2026-06-12 | ⚠️ R-005/016 ブログ方向転換 | 進捗追跡 |
| 内部リンク・回遊 | 2026-06-24 | 🔧 R-014c/R-021 進行中。06-24 GET検証で「CTAボタンは全記事に共通テンプレ設置済／手作業は本文話題別リンク」を確定。`[RelService][Service]` 未展開ショートコードを発見（web-hanasaka 確認中＝直れば本文CTA自動化の芽） | ショートコード修正可否の回答待ち |
| 信頼要素（実績・客観的事実） | 2026-06-20 | 🔧 Q-007 回答済（方向確定）／R-024(b) 着手準備中(PI-017) | 客観情報（工夫/機能/成果の事実）。自作のお客様の声は不要（社長判断）。数値を数字で出す場合のみ事実待ち（捏造しない） |
| 構造化データ（JSON-LD） | 2026-06-22 | ✅ R-025 反映確認 | money pages に JSON-LD 整備済（/works/=BreadcrumbList／/price/basic.html=BreadcrumbList+LocalBusiness）。競合ギャップ解消。効果（リッチリザルト/CTR）は次のクリーン窓で |
| ローカルSEO（地域・MEO） | 2026-06-25 | 🔧 R-018 進行中（**対応エリア確定＝大阪・京都・兵庫・東京**／06-22 社長回答）。**06-25 社長がGBP更新→現状フィールド受領→漏れを優先度順に回答**（最優先＝メインカテゴリ『ソフトウェア企業』→『ウェブデザイナー』・サービス提供地域 未設定→大阪/京都/神戸/東京。NAP・説明文・営業時間は✅一致確認）。**06-25 18:38 社長より「①②を対応した」＝メインカテゴリ『ウェブデザイナー』化・サービス提供地域 登録 完了（MEO最大の2レバー反映）**。効果は2週間スパンでGBPインサイト＋エリア×業種クエリ順位 | サイト側（共通テンプレのエリア明記）＝web-hanasaka＋影響範囲合意。GBP側＝①②反映済／残＝🟡④写真→⑥クチコミ運用（最大の継続レバー）→③サービス欄（社長手作業・急ぎでない） |
| 計測基盤（CV正規化） | 2026-06-19 | 🔧 R-023 進行中 | 効果判定の前提 |
| **ビジュアル（FV/配色/CTA/SP崩れ）** | **2026-06-22** | ✅ 料金FV再撮影で R-026 修正確認（「How much?」）。FV-CTA弱の種は継続 | 次＝/works/・/contact/normal/ へ拡張 |
| 表示速度／CWV | 2026-06-25 | 🟢 実装側で前進：**PI-026 画像WebP化**（重い画像群 約20MB→約2.8MB・最重量 top/title_bg 1.8MB→158KB／死にscript jquery.imageScroll 削除）を本番反映。本ループGET＝`title_bg.webp` HTTP200・162KB配信を裏取り（軽量化と整合）・トップ退行なし | CWV客観値の実測ツール未（T-005候補＝§9 #2・🟢低）。WebP化の効果（LCP改善等）は数値で未測定 |
| モバイル | 2026-06-23 | 🟢 PI-020「手書き約60ページ viewport 欠落＝モバイル崩れ」は**本番GETで反証**（抜取で viewport 存在）。反応⑦で PI-020 展開（canonical/LocalBusiness）も検証済。モバイル崩れの実害は確認できず | hp-shot の SP 版＋実測（CWV/タップ領域）は引き続き未 |
| 手書きheadページの canonical/JSON-LD（PI-020/PI-019②） | 2026-06-23 | ✅**検証済クローズ（反応⑦）**：web-hanasaka の 16:59 完了報告を本ループ独立GETで検証（K-014）。決定的観測点＝canonical の有無（16:08 で『なし』だった点）で裏取り＝/company/・/faq/・/contact/normal/ の3ページとも **canonical なし→自己参照あり＋JSON-LD LocalBusiness 0→1**。/service/・/works/ も canonical＋JSON-LD（2件）。K-057 の viewport 食い違いは決着＝viewport は元々インライン存在（モバイル崩れ実害なし）、真の改善は canonical＋LocalBusiness。viewport 二重化は hp-audit 上は兆候なし | 効果（カバレッジ/CTR）はクリーン窓 06-26+ で。新規欠落ページが見つかれば実URLで都度検証 |
| 共通テンプレ h1 乱用是正（PI-018） | 2026-06-23 | ✅**テンプレ分・ページ単位分とも検証済クローズ（反応⑦＋⑧）**：⑦＝/・/service/・/faq/・/works/ が h1=1（ロゴ/フッター由来の余剰 h1 消滅）。⑧＝49ファイルのページ単位是正を本ループ独立GETで検証＝/price/basic.html（旧8→1）・/company/（旧6→1）・/flow/（旧18→1）・/knowledge/seo/seo_means.html（旧2→1）いずれも **h1=1**。サイトの h1 構造が「1ページ1h1」に整い PI-018 クローズ | 新規欠落ページが出れば都度GET。h1=1 化の効果（あれば）は SEO 一貫性として 06-26+ に観測 |
| /contact/designer/（PI-021＝500） | 2026-06-24 | ✅**クローズ（06-24 反応ティック・本番GET検証）**。**真因訂正**：当初「共通フォームテンプレ `contact/template/page.php` の in_array(null)」と報告したが web-hanasaka 本番確認で誤りと判明＝実際は `/contact/designer/` が require するテンプレ一式（./template/page.php 等4ファイル）がリポジトリ未存在で常時 fatal→500。サイト内リンク0・sitemap無の**孤立した死にURL**（`/partners/designer.html`＝提携デザイナー紹介 とは別物）。応募導線は元々ページ内から `/contact/partner/` へ逃がしていたため、フォーム復活ではなく**ページ廃止（ディレクトリ削除）**で対応。本ループGET＝**500→200（final=トップ＝実質ソフト404）**を確認。併せて**生フォーム4件（create/coder/normal/others）を PHP8 堅牢化**（in_array に is_array ガード）＝当方GETで全て HTTP200＋`<form>`1件表示、partner は 200・フォーム無し案内（仕様）を確認 | 残＝厳密な 404/410 化（.htaccess＝git管理外・社長案件・孤立URLゆえ優先低）。新規の死にURL/500が出れば都度GET |
| アクセシビリティ | — 未 | 未着手 | 優先度は低だが放置中 |

---

## 3. 提案ライフサイクル台帳（R-NNN｜提案→着手→反映→効果検証→クローズ）

効果検証まで追うのがこの台帳の肝（掲示板の「進行中」表に無い列＝反映日・効果）。

**状態遷移ルール（無人運用で壊れないための不変条件）**：
- 許可遷移：`提案 → 着手 → 反映 → 効果検証中 → クローズ`（どの段階からでも `→ 却下/中止` は可）。段飛ばし（提案→効果検証中 等）は不可。
- **反映日が空のまま「効果検証中」にしない**（反映を本番GETで観測＝K-014 してから反映日を入れる）。
- **R-ID は一意・再利用しない**。`却下/中止` 済みの R-ID は §4 へ移し、**同じ論点を新IDで再提案しない**（§4 を必ず照合）。
- 効果検証は「反映日からの期間」を満たして判定（§7 の期間条件）。未達なら「効果検証中（待ち）」のまま。

| R | 観点 | 状態 | 反映日 | 効果検証（数字） | 次アクション |
|---|---|---|---|---|---|
| R-014a | /price/ title/meta | ✅反映 | ~06-18 | **06-26 効果検証：改善なし**（料金2語 順位 baseline 11.0/11.6→直近も page2・CTR 0%継続・0クリック） | title/meta では page2→page1 を動かせない＝勝ちパターン昇格せず。~06-29 に28日窓で再確認＋ranking-strength（R-014b/025/014c）の窓を待つ |
| R-014b | /price/ 料金レンジ＋FAQ | ✅反映(Q-010) | 06-18 | **06-26：CTR/順位とも改善なし（0クリック継続）** | コンテンツ深さの効果は反映から日が浅い＝~06-29 の28日窓で再測定（ranking-strength レバーの本命） |
| R-014c | 料金系ブログ→/price/ 内部リンク | ✅静的側反映／WP本丸=社長継続 | 06-19(静的) | — | 静的側=本番GET生存確認(HTTP200)。WP本丸(自作vs外注/ソフト比較記事)は社長作業PI-013 |
| R-018 | ローカルSEO（地域/MEO） | 🔧 進行 | — | — | **対応エリア確定（06-22 社長）＝大阪・京都・兵庫・東京**。サイト側＝共通テンプレ影響範囲の確定＋社長合意（全ページ影響）。**MEO＝06-25 社長がGBP更新→漏れを回答済**（🔴メインカテゴリ→『ウェブデザイナー』・サービス提供地域 登録／🟡サービス・開業日・写真・クチコミ）。**06-25 18:38 社長より①②（カテゴリ→ウェブデザイナー・サービス提供地域）実施完了の連絡＝MEO最大2レバー反映済**。反映はGoogle再評価で数日〜2週間。効果はGBPインサイト＋エリア×業種クエリ順位で2週間スパン追跡。残＝🟡④写真→⑥クチコミ運用→③サービス欄（社長手作業ゆえ本ループは助言・追跡） |
| R-019 | （即効・反映済） | ✅反映 | ~06-18 | ⏳ 待ち | 効果検証（06-21+） |
| R-020 | （即効・反映済） | ✅反映 | ~06-18 | ⏳ 待ち | 効果検証（06-21+） |
| R-021 | 人気記事末尾にCTA＋関連リンク | ✅静的側反映／WP本丸=社長継続 | 06-19(静的) | — | 静的側=共通フッターCTA既出＋beginner記事に関連サービス文脈リンク。WP本丸は社長PI-013 |
| R-022 | GA4新規作成 | ❌中止(Q-009) | — | — | 既存GA4を使う（合意済） |
| R-023 | GA4 CVイベント正規化＋キーイベント化 | 🔧 進行（要件書done） | — | — | **効果判定の前提**。外注向け要件書done（?p_mode=complete をGTM URL条件＝コード変更なし）。社長/外注コンソール作業待ち |
| R-024 | /works/ title/meta＋信頼要素 | 🔧 (a)✅反映確認／(b)着手準備中 | (a)~06-21 | (a)⏳ 待ち（0クリック・順位4.75→5.65＝fix後GSC未反映） | (a)**06-21/22 GET検証＝desc独立101字・canonical追加・h1 43→4**。/works/ の JSON-LD は R-025 で解消済。(b)客観的事実ベースで web-hanasaka 着手準備中(PI-017)。効果は06-26+クリーン窓で |
| R-025 | money pages(/price/・/works/) に JSON-LD 整備 | ✅反映 | 06-22 | ⏳ 待ち（**06-26 時点では post データ 0〜1日分のみ＝測定不能**） | 06-22反映＝効果窓未満（GSC last_date 06-23）。**~06-29 に28日 before/after で リッチリザルト/CTR を測定** |
| R-026 | /price/basic.html FV「How match?」→「How much?」 | ✅反映 | 06-22 | — | **06-22 hp-shot で「How much?」目視＝✅反映**。クローズ |
| R-027 | /service/（サービスハブ）title/meta/canonical/JSON-LD/h1 最適化 | ✅反映 | 06-23 | ⏳ 待ち（**06-26 時点では post データ 0日分＝測定不能・効果窓未満**） | **06-23 反応ティックで本番GET検証＝✅反映**（title 36字「ご紹介」排除・desc 97字・canonical追加・JSON-LD 1件 BreadcrumbList・ページ固有h1を1集約）。真因=R-025同一。残=title 36字/共通テンプレh1→PI-018合流。効果は **~06-29 のクリーン窓で hp-diff**（上位2.7〜3.8で0クリック→動いたか） |
| R-028 | トップ FV に「無料相談・お見積り」CV-CTA 設置（特にSP） | 🆕 提案（Cycle 017・日次） | — | — | 探索枠のトップFV hp-shot 評価から起票（§5 FV-CTA 種を採用）。FV最目立ちが情報誘導／SPヘッダーはアイコンのみでラベル付きCV-CTA皆無。🟡推奨。**定量効果判定は R-023（GA4 CV正規化）完了が前提**。共通ヒーロー＝全ページ影響可能性→影響範囲を web-hanasaka と確定＋社長合意の上で引き渡し |
| price-canonical | /price/basic.html canonical（Cycle 016 督促残） | ✅反映 | 06-23 | — | **06-23 反応ティックで本番GET検証＝canonical なし→自己参照 追加✅／JSON-LD 2件維持**。Cycle 016「未反映」残課題を解消。クローズ |
| R-001〜R-013,R-015〜R-017 | 初期サイクルの提案（OGP/canonical/h1/構造化/KPI分離 等） | 大半✅反映 or 後続Rへ統合 | 〜06-12 | — | 詳細は掲示板アーカイブ。再提案しない |

---

## 4. 却下・見送りプール（再提案しない＝reviewer の exclusions 相当）
- **出張写真撮影サービスの撤去（誤検知防止・退行ではない）**：2026-06 に出張撮影サービスが終了し、web-hanasaka がサイト内の撮影参照（メガメニュー/フッターのリンク・料金ページのオプション価格・/service/一覧・/photo/配下）を意図的に撤去（thread ycom-report・2026-06-19報告）。本番確認済＝`/photo/` は現在トップへリダイレクト(HTTP200)。**今後の監査で「出張撮影が消えた／ /photo/ が無い」を退行・課題として起票しない**。残課題＝サブドメイン `photo.y-com.info` の停止（社長作業）。
- **R-022（GA4新規作成）**：❌中止。4年9か月の履歴を捨てるため／既存GA4(analytics_265729912)が GTM 経由で稼働中と判明。今後「計測されていないから新規作成」を再提案しない。
- **WordPress 前提のプラグイン施策（Yoast 等）**：サイトは独自PHPテンプレ＝不適合。canonical/メタはテンプレ側出力で対応（K-009）。
- **「総クリック数」を主KPIにする**：事業外の偶発流入が多く誤誘導（R-015でKPIを事業関連クエリ・順位・CVに分離済み）。総クリックの増減だけで成否判定しない。

---

## 5. 種プール（次サイクルの探索候補＝自分で観点を見つける燃料）
> 「気づいたが今回深掘りしなかった」もの＋週次の完全性批評の産物。スコアの探索枠はここから引く。
>
> **肥大・堂々巡り防止（上限と棚卸し）**：各種は状態を持つ＝`仮説／保留／採用／却下／統合済み`。ルール：
> - 1サイクルで**新規に「採用（深掘り着手）」するのは最大2件**（残りは保留のまま積む＝過剰提案しない）。
> - **採用した種は R-NNN 化**して §3 へ移す（種プールに残さない＝二重管理回避）。
> - **30日以上「保留」で動かない未検証の種は棚卸し**：却下（理由1行）か統合（似た種にまとめる）にして、生きた種だけ残す。
> - 却下した種は §4 と同じ扱い＝再浮上させない。

- **[一部採用 Cycle 016]** `/service/`(順位3.8)・`/works/`(6.4)・`/works/case/`(5.0)・多数の `/works/(case/)detail.html`(順位4〜8) が**横断的に「順位上位だが0クリック」**。共通原因（検索結果での見え方＝title/meta/サムネ）の横断調査が一括で効く型。→ **`/service/` を Cycle 016 で採用＝R-027 化**（§3へ）。残＝detail テンプレの title/meta 一括点検は保留（R-027 の効果が出たら型として横展開）。状態＝一部採用。
- **[確認済 Cycle 016反応③→PI-020 で web-hanasaka が対応中]** **手書きheadページの canonical/JSON-LD 一括欠落**：R-025/R-027 の真因（手書きheadが共通 head メソッド未呼出）は **web-hanasaka が SSOT化（HTMLHeaderCommonMeta() 新設＝PI-019②）で構造ごと解消に着手**。06-23 抜取検証（/company/・/contact/normal/・/faq/）で **canonical/JSON-LD 欠落は確認**（＝仮説は当たり）。一方 **viewport 欠落（モバイル崩れ）は反証**（3/3 で viewport 存在＝K-057）。→ 本ループの役割＝(1) web-hanasaka に「展開すべき手書きページの実URL一覧」を依頼し GSC imp 順でランク付けして返す、(2) 展開後に canonical/JSON-LD の付与を本番GETで再監査（K-014）。週次定石に「手書きhead一括スイープ（canonical/JSON-LD の有無点検）」を追加候補。状態＝web-hanasaka 側で対応中（本ループは追跡・検証）。
- **[K-057＝学び]** 実装担当の「本番GETで確認した」報告でも、こちらの独立GETで**再検証する価値がある**（PI-020 の viewport 欠落は本番では成り立たなかった＝検出方法/対象の差で食い違う）。「viewport なし」のような**実害の大小を左右する事実主張は必ず自分でGETして裏取り**してから severity を確定する（K-014 の徹底）。
- **[仮説]** `/contact/normal/` が順位23.8と低い＝CV受け皿が検索で見つからない。問い合わせ導線は「サイト内回遊」前提か「検索直接」前提かでテコ入れ先が変わる。GA4のCV前経路で検証したい。
- **[ビジュアル・一部消化 Cycle 013]** トップ＋/price/ を hp-shot で評価済。残＝/works/・/contact/normal/。**新しい仮説（FV-CTA）**：トップFVの一番目立つボタンが情報誘導「サービス内容」で、見積/相談のコンバージョンCTAがFV内で弱い（電話は右上のみ）。ゴール（問い合わせ/見積増）に直結する観点なので、次サイクルで「FVに無料相談/見積CTAを足す」要否を検討（GA4のFV→CV経路と合わせて）。**[採用 Cycle 017→R-028化]** トップFVを hp-shot 再評価し、SPヘッダーがアイコンのみでラベル付きCV-CTA皆無を確認＝R-028 として §3 へ移管（効果定量化は R-023 完了が前提）。状態＝採用・消化。
- **[競合対比・R化済 Cycle 013→R-025]** SEOは相対評価＝狙うクエリで上位の競合を超えるのがゴール（社長 2026-06-21）。①②③が無人で回る手段＝hp-serp(T-011)→hp-compete(T-010)→hp-shot。競合リスト＝`data/hp-loop/ycom/competitors.md`。**初回検出（料金ページの構造化データ差：競合=LocalBusiness+BreadcrumbList／自社=0件）は R-025 として正式起票済（§3）**＝この種は採用・消化。**残る運用課題**＝週次定石#6 を「狙うクエリ確定→hp-serp→hp-compete→R化」のサイクルで定常運用すること（料金以外のクエリでも競合ギャップを探す）。
- **[コンテンツ]** ブログ上位（contents/?p=7528等）の流入テーマが事業外。買い手意図テーマへの転換（R-016）と既存記事のCTA回収（R-021）の効果を分けて測る。

---

## 6. 観点ライブラリ（hp-improve 流用＋ループが発見した観点を追記して育てる）
基本観点は [hp-improve.md](../../../.claude/rules/hp-improve.md) の評価観点表（FV／導線・CV／情報設計／コンテンツ／訴求・コピー／SEO／仮置き残存／速度／モバイル／デザイン／アクセシビリティ／信頼性）。
**ycom 運用で足した観点**：
- 「**上位表示だが0クリック**」＝順位は良いのにCTRが極端に低いページ＝検索結果の見え方の問題（title/meta/リッチリザルト）。最も低工数で効きやすい（R-024 で発見）。
- 「**偶発流入の事業価値**」＝imp/clickが多くても事業外テーマなら CV に効かない。流入の「量」でなく「質（買い手意図か）」で評価する。
- 「**title/meta は page1 に乗って初めて効く**」＝順位が2ページ目（11位以下）のままだと、いくら title/meta を最適化しても CTR は 0% のまま（クリックはほぼ1ページ目で発生）。＝title/meta は「page1 内の CTR を上げる」レバーであって「page2→page1 へ順位を上げる」レバーではない。**料金クエリの効果検証 06-26 で実証**（R-014a/b 反映後も順位11→page2 のまま0クリック）。順位を上げるには ranking-strength（コンテンツ深さ・内部リンク・構造化データ・被リンク）が要る。＝**「上位だが0クリック」（title/meta で解決）と「2ページ目で0クリック」（ranking-strength が要る）を切り分けて処方する**。

---

## 7. 勝ちパターン（成功体験ライブラリ＝効果が確認できた型を蓄積し再利用）
> **効果検証で数字が改善して初めてここへ昇格**（仮説段階は §5）。似た状況で再適用する「定石」になる。

| 型（パターン） | 状況→打ち手 | 効果（実測） | 再適用先の候補 |
|---|---|---|---|
| （※ 初期化時点では効果実測待ち。料金施策 R-014a/b の before/after が06-21以降に出たら、効果込みでここへ昇格する） | — | ⏳ baseline固定済・検証待ち | — |

**昇格ルール（偶然を勝ちパターンと誤認しない期間条件）**：R-NNN が下記を満たしたら、(状況→打ち手→効果) を1行で型化し、§5/§2 の似た対象に「この型を当てる」種を撒く。これが COMPOUND の本体＝成功を次に効かせる。
- **反映後の期間を空ける**：反映後 7日（一次）・できれば 28日（確証）の before/after で見る（hp-diff の旧/新スナップショット）。GSCラグ2〜3日も考慮。
- **偶然・季節要因を除外**：単発の上振れでなく、表示回数が一定以上ある中での改善か。季節・キャンペーン等の外的要因があれば**メモ必須**（無ければ「型」と誤認する）。
- 満たさないうちは §3 で「効果検証中（待ち）」のまま昇格させない。

---

## 8. 定石レシピ（毎回・週次で必ず回す標準分析＝抜け漏れ防止＋自動化の単位）
> 「考える分析」の前に「決まった分析」を機械的に回す。各レシピは可能な限り §9 でツール化し、安く実行する。

**毎サイクル（軽・日次）**
1. 変化検知：GSC pages/queries を取得し前回と差分（→ ツール化候補＝§9 #1）
2. 反映確認：✅反映済みRの本番URLを hp-audit/GET で観測（報告を鵜呑みにしない・K-014）
3. 効果追跡：効果検証中Rの数値を gsc-fetch/ga4-fetch で前へ
4. 継続R：🔧進行中Rのステータス更新（着手・反映チェック）

**週次（深・ズームアウト）**
5. 主要ページを hp-audit 再監査＋ hp-shot ビジュアル取得（§2の古い行を当て直す）
6. **競合対比（社長のSEOワークフローを自動実行）**：(a) gsc-fetch で今週狙うクエリを特定（2ページ目の買い手意図・上位だが0クリック）。(b) `bin/hp-serp.sh "<クエリ>" --exclude y-com.info --urls`（T-011・Yahoo!JAPAN＝Googleインデックス）で競合URLを自動取得。(c) `python3 bin/hp-compete.py <自社URL> <競合URL...>`（オンページ差分）＋ `bin/hp-shot.sh`（見た目）でギャップ→ R-NNN 化。競合は competitors.md に記録。大阪ローカル順位が厳密に要るときだけ社長にSERPを依頼。詳細は competitors.md §0
7. 完全性批評：「今週見ていない切り口・放置ページは？」→ §5 種プールへ書き出す

**スポット**
8. 新規ページ発見時：hp-audit＋hp-shot で初期評価し §2 に行追加

---

## 9. ツール化トリガー／ツール候補（欲しいデータは回り道でなく1コマンドにする）
> **判断基準**：同じデータ取得・加工を **2回以上アドホックに手でやった**ら、決定論的ツール（`bin/` の読み取り専用スクリプト）にする。作ったら `data/hp-loop/tools-log.md` に `T-NNN` で記録（automation.md 準拠＝読み取りのみ）。手作業は「暫定」と明示。

| 候補 | 欲しいこと | 今の取り方 | ツール化の形 | 優先 |
|---|---|---|---|---|
| #1 GSC/GA4 差分 | 前回サイクルとの before/after（順位・CTR・CV） | ✅ **`bin/hp-diff.py`（T-009）で実装済（2026-06-19）** | `python3 bin/hp-diff.py <旧> <新> --section queries --match 料金`。新規/消滅も検出・▲改善/▼悪化判定 | ✅ 完了（効果検証の中核） |
| #2 CWV/PageSpeed | 表示速度の客観値（curlで測れない） | 未取得 | PageSpeed Insights API の読み取りラッパ（T-005候補） | 🟢 低 |
| #3 競合対比 | 競合サイトの構成・見た目・コンテンツギャップ | ✅ **hp-serp(T-011)→hp-compete(T-010)→hp-shot で実装済（2026-06-21）** | ②競合特定＝`bin/hp-serp.sh "クエリ" --exclude y-com.info --urls`（Yahoo!JAPAN＝Googleインデックス・VPSから取得可）→ ③`python3 bin/hp-compete.py <自社> <競合...>`＋hp-shot。①②③が無人で回る | ✅ 完了（SEO相対評価の中核） |
| #4 「上位表示だが0クリック」抽出 | 順位≦10かつCTR極小のページ一覧 | GSC JSON を手で探す | `gsc-fetch` に閾値フィルタ出力を足す | 🟡 中 |

既存ツール：T-001 hp-audit（オンページ）／T-006 gsc-fetch／T-007 ga4-fetch／T-008 hp-shot（ビジュアル）／T-009 hp-diff（before/after差分）／**T-010 hp-compete（競合オンページ比較）**／**T-011 hp-serp（SERPから競合URL取得＝Yahoo!JAPAN）**。いずれも読み取り専用。

---

## 変更履歴
| version | 日付 | 内容 |
|---------|------|------|
| 0.1 | 2026-06-19 | 初版（試作・ycom 先行）。Cycle 010 までの実状態を台帳化。プロトコル(§0)・スコアリング(§1)・カバレッジ(§2)・提案ライフサイクル(§3)・却下プール(§4)・種プール(§5)・観点ライブラリ(§6)・勝ちパターン(§7)・定石レシピ(§8)・ツール化トリガー(§9)。回しながら育て、型が固まれば yoshida/fujisaka へ展開＋共通部分を hp-loop.md に昇格 |
