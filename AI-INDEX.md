# AI-INDEX — はなさか作業環境の在処マップ

> **自動生成ファイル。手で編集しない。** `python3 bin/build-ai-index.py` で再生成。
> 生成日: 2026-06-07
>
> 用途：AI（ビジネスパートナー）が「どこに何があるか」を即把握するための地図。
> ビジュアル確認用の HTML はそのまま、必要なページ/CSV をここから辿って深掘りする。
> 全体方針・各フォルダの役割は [OVERVIEW.md](OVERVIEW.md) を参照。

## 恒久ファクト（毎回確認不要）

- **会計年度**: 4月1日〜翌3月31日（例: FY2025 = 2025-04〜2026-03）。
- **会社**: 株式会社はなさか。HP制作 / システム開発 / AI活用。社長＋社員体制。
- **財務実績の在処**: `data/financial/<西暦>/pl.csv`・`bs.csv`（Shift-JIS）。保守ストック収益は `site/business/recurring-revenue.html`。

## site/ ページ索引

件数: HTML/PHP 合計 127 ページ

### `site/`

- **`site/index.html`** — 株式会社はなさか — プロジェクト記録
  - 全プロジェクト・全社メモへの入口。各リンクから配下の記録に辿れます。
  - 見出し: 🎯 今日のフォーカス / 🌳 目標ツリー / 本業 / 💼 業務 / 経営トラッカー / ビジネスダッシュボード / 日常メモ / ツール・プレビュー / 🛠 tools/ — ツールハブ / drafts/ …他4件
- **`site/notes.html`** — 日常メモ
  - 社長が思いついた内容を伝えてくれたものを、随時ここに整理して追記していくファイル。
  - 見出し: 2026-05-29 / 開発オートパイロット構想 — 人間判断を最小化しAIに一括自走させる仕組み（社長の大タスク） / システム開発の品質保証方針 — 手動テスト最小化 × AIエージェント活用（調査メモ） / 2026-05-24 / 「HANAツールズ」（仮称）構想：小ツール公開シリーズの立ち上げ検討 / 2026-05-09 / 人事評価制度の方針確定（HANAツールへの組み込み） / マルコマツール（プロジェクト名要確認・API未照合） / 2026-05-08 / 経営方針 — システム制作・運用をメイン事業へ転換 …他6件

### `site/business/`

- **`site/business/_financial-lib.php`** — (タイトルなし)
- **`site/business/annual-forecast.php`** — 年度通年予測
  - 今期（FY2026）の途中までの実績から通年を単純按分予測し、前年（FY2025）と比較。 データソース：MFクラウド「損益計算書 PL」CSV（期間指定でエクスポート）
  - 見出し: 📊 主要KPI（FY2025 vs FY2026予測） / 💸 主要販管費（上位15・通年予測ベース）
- **`site/business/focus.html`** — フォーカスダッシュボード
  - 「やること」と「やったこと」を両輪で見る。情報を集めるのではなく、強制的に絞り込む。
  - 見出し: 🌳 上位目標を見る → goals.html / 今週（2026-W21：05/18-05/24） / 🔥 今週やる（最大3つ） / ✅ 今週やった / 今月（2026-05） / 📊 今月の数字（3指標まで） / 🏆 今月の成果ハイライト / 🤔 今月決める論点（3つに絞る） / 📁 プロジェクト概況 / 📚 過去の振り返り …他1件
- **`site/business/goals.html`** — 目標ツリー
  - 経営最上位目標から日々の活動までを 樹形図で結ぶ。各ノードに数値目標を持たせる。
  - 見出し: 🎯 経営最上位目標 / G0. システム制作・運用をメイン事業へ転換、ストック収益基盤を確立する / G0.1 FY2026 売上目標（3段階：保守 / 標準 / ストレッチ） / G0.2 FY2026 ストック収益比率 20%以上（最重点論点） / 💬 G1. HANAチャット販売拡大 / G1. HANAチャットを多くの企業に届け、月額収益化する / 🛠️ G2. システム受注件数増加 / G2. 月額運用契約を含むシステム受注を継続的に積み上げる / ⚙️ G3. HANAツール業務効率化 / G3. 社内管理ツールHANAを進化させ、業務効率と意思決定スピードを上げる …他1件
- **`site/business/index.php`** — ビジネスダッシュボード
  - 経営方針・KPI・月次レビューの集約入口。「方針 → 行動 → 振り返り → 課題更新」の循環を回す。
  - 見出し: 📈 経営サマリー（FY2026予測 vs FY2025実績） / 🎯 focus.html — フォーカスダッシュボード / 🌳 goals.html — 目標ツリー / 経営方針 / 経営KPIダッシュボード / 月次・年次レビュー / 💰 月次ストック収益 / 📋 案件 状態別 & 月次見積額 / 📈 年度通年予測（FY2025 vs FY2026） / 📒 仕訳チェック（経理サポート） …他5件
- **`site/business/journal-check.php`** — 仕訳チェック
  - MFクラウド「会計帳簿 → 仕訳帳」CSV を **年度単位（期首〜現時点）** でアップロードし、 形式チェック・集計・重複検知を行う。
  - 見出し: 💳 投入済みカード明細 / 📁 投入済みファイル / 📊 分析結果：FY / ⚠ ★要確認の仕訳とカード明細マッチング（件 / マッチ 件） / 🚨 形式チェック（件） / 📅 月別合計 / 📥 借方科目 TOP 15 / 📤 貸方科目 TOP 15 / 📋 税区分内訳 / 🔁 重複疑い（同日・同借方・同貸方・同金額）
- **`site/business/kpi.html`** — 経営ダッシュボード（理想形）
  - 経営判断に必要なデータの理想形を「先に設計」し、それに向けて段階的に整備していく。
  - 見出し: Tier 別の優先度（2026-05-16 追加） / マネーフォワードから取りたい CSV（決算書ベース） / ダッシュボードの全体構造（7カテゴリ） / 1. 収益の見える化 / 2. コストの見える化 / 3. 利益・キャッシュフロー / 4. 顧客指標 / 5. パイプライン / 6. 稼働・キャパシティ / 7. HANAチャット固有 …他6件
- **`site/business/monthly-status.php`** — 月次データ アップロード状況
  - 2025年度（前年）/ 2026年度（今期）の月次データ整備状況
  - 見出し: 📅 今月（）のアップロード状況
- **`site/business/monthly-upload.php`** — 月次データ アップロード
  - CSV形式で月次データをアップロードします。前年同月比較に使用。 → アップロード状況を確認
  - 見出し: 📌 アップロード仕様 / mb-2">
- **`site/business/projects-overview.html`** — 移動しました — projects-overview.php
  - リアルタイム取得版に切り替えました。 自動で移動します。移動しない場合は下のリンクから。
- **`site/business/projects-overview.php`** — 案件 状態別割合＆月次見積額
  - データ取得エラー: ' . htmlspecialchars((string)$err) . ''; exit; } $total = (int)$data['total_count']; $state_data = $…
  - 見出し: ① 案件の状態別割合 / ② 月次見積額の推移 / 月の案件 / ⚠️ データ品質チェック / 🔴 重大：請求・入金漏れに直結 件 / 🟡 中：データ整合性 件
- **`site/business/recurring-revenue.html`** — 月次ストック収益
  - 月額契約による継続的収益の見える化。G0.2「FY2026 ストック収益比率 20%以上」 達成度のモニタリング基盤。
  - 見出し: FY2026 目標との関係 / ⚠️ データ品質の要確認ポイント / クライアント別 月額契約一覧 / 除外・要確認の項目 / 更新運用と次のアクション / 更新運用 / 次のアクション / 関連
- **`site/business/strategy.html`** — 経営方針・重点課題
  - 株式会社はなさかの現在の経営方針・重点課題・KPI を集約する **生きるドキュメント**。
  - 見出し: 経営方針（2026-05-08 確定） / 事業の位置付け / 営業の流れ（目標） / KPI（追跡指標） / 現状の試算（2026-05-09 時点） / 重点課題（現在のフォーカス） / A. 価格・サービス設計 / B. 営業・対象設計 / C. 開発・運用基盤 / D. 体制・キャパシティ …他9件

### `site/business/internal-meetings/`

- **`site/business/internal-meetings/2026-05-25.html`** — 社内定例会議 — 2026-05-25
  - FY2026 第2ヶ月目の月曜定例。年度はじめの決算振り返り、5/11発生インシデントの振り返り、新規4プロジェクトを含む進捗会議を実施。
  - 見出し: 議題一覧（合計 80分想定） / 1. オープニング・今週の最重要事項（5分） / 目的 / 論点 / 議事メモ / 2. ⚠️ 箕面PTAサイト改ざんインシデント振り返り（15分） / 目的 / 事前共有資料 / 事象サマリ / 論点・質問 …他21件
- **`site/business/internal-meetings/_template.html`** — 社内会議 — YYYY-MM-DD
  - テンプレートの記入後、ファイル名を YYYY-MM-DD.html にリネームすること。
  - 見出し: 議題一覧 / 1. 議題名（N分） / 目的 / 事前共有資料 / 論点・質問 / 議事メモ / 決定事項 / アクションアイテム / 次回
- **`site/business/internal-meetings/index.html`** — 社内会議
  - 社内定例会議の議題・議事録の記録置き場。
  - 見出し: 議事録一覧 / 運用ルール / 関連

### `site/business/reviews/`

- **`site/business/reviews/2026-05.html`** — 月次レビュー — 2026-05
  - 本レビューは AI（パートナー）によるドラフト
  - 見出し: 1. 当月のハイライト / 2. KPI 実績 / FY2025 年度業績サマリ（2025-04-01 〜 2026-03-31） / 販管費の内訳（売上比 上位） / 大口クライアント（年間回収額 上位） / 月次 KPI（現状未設定 → 月次推移表 取得後に整備） / 3. 進行案件のスナップショット / 4. 観察事項（パートナーから） / 機会 / リスク …他4件
- **`site/business/reviews/fy2025-annual.html`** — FY2025 年度決算振り返り
  - 2025-04-01 〜 2026-03-31 の業績総括と FY2026 への接続。
  - 見出し: 1. 結果ハイライト（5分） / 数字サマリ / 3行で表すFY2025 / 2. 想定通り / 想定外（10分） / ✅ 想定通りだったこと（≒継続したいこと） / 📈 上振れた要因（再現したい） / 📉 下振れた要因（避けたい） / 📊 主要数字の前期比（参考） / 3. FY2026への接続（10分） / 確定済の経営方針との接続 …他9件
- **`site/business/reviews/index.html`** — 月次レビュー一覧
  - 毎月初に前月の振り返りを行い、方針への反映を更新する。年次は決算後に別途実施。
  - 見出し: 年次（決算振り返り） / 月次 / 運用ルール

### `site/business/skill-sheet/`

- **`site/business/skill-sheet/advanced-skills.html`** — ビジネス基礎力スキル（情報・文章・管理・セキュリティ）
  - PC操作・開発スキルの土台となる実務スキルの定義。情報収集・文章作成・ファイル管理・セキュリティなど、タイピングやショートカット以上に業務成果を左右する“効く”領域を扱う。
  - 見出し: 1. 情報収集・検索力（9項目） / 2. ドキュメント作成・伝達力（9項目） / 3. ファイル・情報管理（8項目） / 4. セキュリティリテラシー（8項目） / 項目数 集計 / レビュー観点（社長判断用） / 関連
- **`site/business/skill-sheet/design-skills.html`** — デザインスキル
  - デザイン基礎・Illustrator・Photoshop・Figma・UI/UX・ブランディングを含むデザイン領域のスキル。
  - 見出し: 1. デザイン基礎（8項目） / 2. Illustrator（8項目） / 3. Photoshop（8項目） / 4. Figma / UIツール（5項目） / 5. UI / UX デザイン（5項目） / 6. ブランディング・印刷物（5項目） / 項目数 集計 / 関連
- **`site/business/skill-sheet/dev-skills.html`** — 開発スキル（全体・習慣編）
  - HTML/CSS のコーディングから業務システムのプログラミングまでを含む、開発全般に共通する習慣・姿勢・プロセスのスキル定義。
  - 見出し: 1. 要件理解・コミュニケーション（5項目） / 2. 設計（6項目） / 3. コーディング習慣（7項目） / 4. テスト・品質管理（5項目） / 5. バージョン管理（Git）（7項目） / 6. デバッグ・問題解決（6項目） / 7. ドキュメンテーション（5項目） / 8. AI活用（開発における）（8項目） / 9. 学習・継続的改善（5項目） / 項目数 集計 …他3件
- **`site/business/skill-sheet/dev-system.html`** — システム開発スキル
  - PHP/Laravel、DB、API、サーバー・インフラ、セキュリティなどシステム開発領域のスキル。
  - 見出し: 1. PHP / Laravel（7項目） / 2. データベース（SQL / 設計）（7項目） / 3. API 設計・実装（6項目） / 4. サーバー・インフラ（6項目） / 5. セキュリティ（5項目） / 6. システムテスト・運用（4項目） / 項目数 集計 / 関連
- **`site/business/skill-sheet/dev-web.html`** — Web制作スキル
  - HTML/CSS/JavaScript からレスポンシブ・SEO・WordPress まで、Web制作領域のスキル。
  - 見出し: 1. HTML / マークアップ（6項目） / 2. CSS / スタイリング（8項目） / 3. JavaScript / インタラクション（6項目） / 4. レスポンシブ・モバイル対応（5項目） / 5. アクセシビリティ（4項目） / 6. SEO・パフォーマンス（5項目） / 7. CMS（WordPress）（5項目） / 8. クロスブラウザ・実機確認（3項目） / 項目数 集計 / 関連
- **`site/business/skill-sheet/index.html`** — スキルシート
  - 社員教育・人事評価のためのスキル定義集。
  - 見出し: スキルカテゴリ / 全社員共通 / PC操作スキル / ビジネス基礎力スキル 暫定 / 開発領域 / 開発スキル（全体・習慣編） / Web制作スキル / システム開発スキル / デザイン領域 / デザインスキル …他2件
- **`site/business/skill-sheet/pc-skills.html`** — PC操作スキル
  - 社員教育・人事評価で使用する PC 操作に関するスキル定義。
  - 見出し: 1. タイピング・文字入力（15項目） / 2. Windows全般のショートカット（26項目） / 3. 共通の編集ショートカット（12項目） / 4. エクスプローラー・ファイル操作（15項目） / 5. ブラウザ（18項目） / 6. 業務効率化・自動化（12項目） / 7. AI活用（業務における）（16項目） / オプション（利用する人のみ評価） / O-1. Word（10項目、オプション） / O-2. Excel（27項目、オプション） …他5件

### `site/clients/`

- **`site/clients/index.html`** — クライアント一覧
  - 取引先クライアントとそのプロジェクト記録。
  - 見出し: カバーオールオーナーズクラブ / 株式会社アースレイズ / 株式会社はなさか（自社） / ヒキタ工業株式会社 / 株式会社井上家具センター / 大阪府立箕面高等学校 / 奈良県フォレスターアカデミー / 大阪トヨペット / 株式会社プライムステージ / Vリーグ …他2件

### `site/clients/_template/`

- **`site/clients/_template/client-info.html`** — クライアント情報
  - クライアント単位の基本情報・契約状況・備考を記録する。
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/_template/index.html`** — [クライアント名]
  - クライアント情報・所属プロジェクトの記録への入口。
  - 見出し: クライアント情報 / プロジェクト / [プロジェクト名]

### `site/clients/_template/projects/_template/`

- **`site/clients/_template/projects/_template/backlog.html`** — 残存課題
  - 要対応・要調査・要確認の項目を種別ごとに整理する。
  - 見出し: 不具合 / 実装タスク / 要確認・要調査 / クライアント回答待ち
- **`site/clients/_template/projects/_template/decisions.html`** — 決定事項・確定仕様
  - 確定した仕様・決定事項・既存実装の前提を背景確認用に記録する。
  - 見出し: 仕様 / [項目名]（YYYY-MM-DD 決定） / アーキテクチャ・運用
- **`site/clients/_template/projects/_template/index.html`** — [プロジェクト名]
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題 / 決定事項・確定仕様 / メモ / 打ち合わせメモ
- **`site/clients/_template/projects/_template/memo.html`** — メモ（雑記帳）
  - 社長から内容のみ渡された無指示時の雑記帳。棚卸し時に backlog.html / decisions.html へ転記し、空にする。
  - 見出し: YYYY-MM-DD
- **`site/clients/_template/projects/_template/project-info.html`** — プロジェクト情報
  - プロジェクト単位の基本情報・要件・技術スタック・サーバー情報を記録する。
  - 見出し: 概要 / 要件 / 技術スタック / サーバー情報 / 納品物 / 関連ドキュメント / 対応履歴

### `site/clients/_template/projects/_template/meeting-notes/`

- **`site/clients/_template/projects/_template/meeting-notes/_template.html`** — 打ち合わせメモ — YYYY-MM-DD
  - 打ち合わせの生記録。後で decisions.html / backlog.html に展開する。
  - 見出し: 出席者 / 議題・決定事項 / 議題1 / 要確認・宿題 / 次のアクション
- **`site/clients/_template/projects/_template/meeting-notes/index.html`** — 打ち合わせメモ一覧

### `site/clients/coverall-owners-club/`

- **`site/clients/coverall-owners-club/client-info.html`** — クライアント情報 — カバーオールオーナーズクラブオブジャパン
  - カバーオールオーナーズクラブオブジャパン
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/coverall-owners-club/index.html`** — カバーオールオーナーズクラブ
  - クライアント情報・所属プロジェクトの記録への入口。
  - 見出し: クライアント情報 / プロジェクト / コーポレートサイト制作

### `site/clients/coverall-owners-club/projects/corporate-site/`

- **`site/clients/coverall-owners-club/projects/corporate-site/backlog.html`** — 残存課題 — コーポレートサイト
  - 仕様は decisions.html 参照。
  - 見出し: 実装タスク / 交通対策費申請ページ / 物件・道具売買ページ / トップページ / 要確認・要調査 / トップページ / クライアント回答待ち / 要件として記録（実装方針・適用範囲は要確認） / ID・パスワード運用要件（2026-05-08 クライアント要望）
- **`site/clients/coverall-owners-club/projects/corporate-site/decisions.html`** — 決定事項・確定仕様 — コーポレートサイト
  - 実装タスクは backlog.html 参照。
  - 見出し: 仕様 / 交通対策費申請ページ（2026-04-09 決定） / 物件・道具売買ページ（2026-04-09 決定） / 対象サイト
- **`site/clients/coverall-owners-club/projects/corporate-site/index.html`** — コーポレートサイト制作 — カバーオール
  - プロジェクト記録への入口（カバーオールオーナーズクラブ）。
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題 / 決定事項・確定仕様 / 打ち合わせメモ
- **`site/clients/coverall-owners-club/projects/corporate-site/project-info.html`** — プロジェクト情報 — コーポレートサイト制作
  - コーポレートサイト制作（カバーオールオーナーズクラブオブジャパン）
  - 見出し: 概要 / 要件 / 技術スタック / 納品物 / 関連ドキュメント / 対応履歴

### `site/clients/coverall-owners-club/projects/corporate-site/meeting-notes/`

- **`site/clients/coverall-owners-club/projects/corporate-site/meeting-notes/2026-04-09.html`** — 打ち合わせメモ — 2026-04-09
  - カバーオール コーポレートサイト クライアント打ち合わせ
  - 見出し: 対象サイト / 修正・対応事項 / 1. 交通対策費申請ページ / 2. お祝いの欄 / 3. サイト全体：お問い合わせ / 4. 物件・道具売買ページ / クライアントからの回答待ち一覧
- **`site/clients/coverall-owners-club/projects/corporate-site/meeting-notes/index.html`** — 打ち合わせメモ一覧 — コーポレートサイト制作

### `site/clients/earth-rays/`

- **`site/clients/earth-rays/client-info.html`** — クライアント情報 — 株式会社アースレイズ
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/earth-rays/index.html`** — 株式会社アースレイズ
  - クライアント情報・所属プロジェクトの記録への入口（発注元：株式会社HRAs）。
  - 見出し: クライアント情報 / プロジェクト / 地盤調査管理システム

### `site/clients/earth-rays/projects/survey-system/`

- **`site/clients/earth-rays/projects/survey-system/backlog.html`** — 残存課題 — 地盤調査管理システム
  - 仕様は decisions.html 参照。
  - 見出し: 不具合 / 編集画面：調査会社が「ログイン中アカウント」で表示される / 実装タスク / 削除処理を一覧画面に集約 / 要調査 / 「削除が編集画面に反映されていない？」
- **`site/clients/earth-rays/projects/survey-system/decisions.html`** — 決定事項・確定仕様 — 地盤調査管理システム
  - 実装タスクは backlog.html 参照。
  - 見出し: 仕様 / 調査会社 / 削除処理（2026-05-09 決定）
- **`site/clients/earth-rays/projects/survey-system/index.html`** — 地盤調査管理システム — アースレイズ
  - プロジェクト記録への入口（株式会社アースレイズ、hana-tools project_id: 32）。
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題 / 決定事項・確定仕様
- **`site/clients/earth-rays/projects/survey-system/project-info.html`** — プロジェクト情報 — 地盤調査管理システム
  - 地盤調査管理システム（株式会社アースレイズ）
  - 見出し: 概要 / 要件 / 技術スタック / サーバー情報 / 関連ドキュメント

### `site/clients/hanasaka/`

- **`site/clients/hanasaka/client-info.html`** — クライアント情報
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/hanasaka/index.html`** — 株式会社はなさか（自社）
  - 自社プロジェクト記録への入口。
  - 見出し: クライアント情報 / プロジェクト / HANAツール / HANAチャット

### `site/clients/hanasaka/projects/hana-chat/`

- **`site/clients/hanasaka/projects/hana-chat/backlog.html`** — 残存課題 — HANAチャット
  - 事業方針は decisions.html 参照。
  - 見出し: 代理店リクルート / 代理店候補マトリクス（2026-05-09 ドラフト） / 打診のための準備物（提案） / セルフサーブ化（開発中） / 既存導入クライアントの管理 / 新規開拓 / AI学習（RAG）強化 / 学習データ登録 — 自由入力 → 自動整理 → 登録 / 会話分析 → 学習内容の改善提案 / UI・ヘルプ …他2件
- **`site/clients/hanasaka/projects/hana-chat/decisions.html`** — 決定事項・確定仕様 — HANAチャット
  - 実装タスク・営業タスクは backlog.html 参照。
  - 見出し: 事業方針（2026-05-09 確認） / 位置付け / サービス内容 / 価格構造 / 販売モデル / 代理店モデル（メイン） / セルフサーブ化（準備中） / 新規開拓 / 紹介サイト（2026-05-09 決定）
- **`site/clients/hanasaka/projects/hana-chat/index.html`** — HANAチャット — はなさか
  - プロジェクト記録への入口（AI活用、hana-tools project_id: 24）。
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題 / 決定事項・確定仕様 / メモ（雑記帳）
- **`site/clients/hanasaka/projects/hana-chat/memo.html`** — メモ — HANAチャット
  - 社長から内容のみ渡された無指示時の雑記帳。棚卸し時に backlog.html / decisions.html へ転記し、空にする。
  - 見出し: 2026-05-28：システム内チャットの機能追加アイデア / ⚠️ 用語の区別（混同注意） / 追加したい機能
- **`site/clients/hanasaka/projects/hana-chat/project-info.html`** — プロジェクト情報 — HANAチャット
  - HANAチャット（株式会社はなさか）
  - 見出し: 概要 / 要件・サービス概要 / 技術スタック / サーバー情報 / 関連案件（works）

### `site/clients/hanasaka/projects/hana-tool/`

- **`site/clients/hanasaka/projects/hana-tool/backlog.html`** — 残存課題 — HANAツール
  - 機能追加・修正事項・バグ・UX改善の残タスクをカテゴリごとに整理。
  - 見出し: タイマー・実績分析 / プロジェクト・案件管理 / ダッシュボード / 紹介者・クライアント管理 / ToDo・Todoist 連携 / 日報 / AI・検索機能 / 評価・スキル / スキルチェックシート機能（人事評価） / 旧スタブ（上記で具体化） …他13件
- **`site/clients/hanasaka/projects/hana-tool/decisions.html`** — 決定事項・確定仕様 — HANAツール
  - 実装タスクは backlog.html 参照。
  - 見出し: 評価・スキル機能（2026-05-09 決定） / 方針 / 評価方式 / 設計思想 / 5段階評価の定義（2026-05-24 確定） / 重要度別 段階的運用ルール（2026-05-24 確定） / 運用フロー（2026-05-17 追加） / 関連 / 目標管理機能（2026-05-24 設計方針） / 背景 …他11件
- **`site/clients/hanasaka/projects/hana-tool/index.html`** — HANAツール — はなさか
  - プロジェクト記録への入口（株式会社はなさか 自社業務システム、hana-tools project_id: 27）。
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題 / 決定事項・確定仕様
- **`site/clients/hanasaka/projects/hana-tool/project-info.html`** — プロジェクト情報 — HANAツール
  - HANAツール（株式会社はなさか）
  - 見出し: 概要 / 要件 / 技術スタック / サーバー情報 / 関連ドキュメント / 対応履歴

### `site/clients/hanasaka/projects/hana-tool/specs/`

- **`site/clients/hanasaka/projects/hana-tool/specs/api-roadmap.html`** — hana-tools API 拡張ロードマップ（議論用） — HANAツール
  - Claude（パートナーAI）が秘書として動くために必要なAPI機能の提案集。優先度別に整理。
  - 見出し: 経緯 / 現状利用可能なAPI（2026-05-25時点） / P1Priority 1：即効性が高い・今すぐ困る / P1-1. ToDo更新 API / P1-2. ToDo完了化 API / P1-3. users 一覧 API / P2Priority 2：重要だが今すぐは凌げる / P2-1. work（案件）一覧 API / P2-2. ToDo の日付範囲フィルタ / P2-3. ToDoキーワード検索 …他5件
- **`site/clients/hanasaka/projects/hana-tool/specs/goal-management-mvp.html`** — 目標管理機能 MVP 実装指示書 — HANAツール
  - HANAツール内に目標ツリーと達成記録を扱う機能を新設するための、Phase 1 MVP 範囲の技術仕様。
  - 見出し: 1. 目的とスコープ / 解決したい課題 / Phase 1 MVP の範囲 / 想定する技術スタック / 2. データモデル / 2.1 goals（目標本体） / 2.2 goal_metrics（指標） / 2.3 goal_measurements（指標の時系列値） / 2.4 goal_achievement_logs（達成記録） / 2.5 goal_status_history（ステータス変遷ログ） …他20件

### `site/clients/hikita-kogyo/`

- **`site/clients/hikita-kogyo/client-info.html`** — クライアント情報 — ヒキタ工業株式会社
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/hikita-kogyo/index.html`** — ヒキタ工業株式会社
  - クライアント情報・所属プロジェクトの記録への入口（発注元：株式会社ソリデンテ）。
  - 見出し: クライアント情報 / プロジェクト / サイト改修・CV計測基盤整備

### `site/clients/hikita-kogyo/projects/site-improvement/`

- **`site/clients/hikita-kogyo/projects/site-improvement/backlog.html`** — 残存課題 — サイト改修・CV計測基盤整備
  - 施策の全体方針は decisions.html 参照。
  - 見出し: 要確認事項（クライアントへ） / 実装タスク / フェーズ1：ベース整備 / フェーズ2：サイト改修 / フェーズ3：コンバージョン計測 / 次のアクション
- **`site/clients/hikita-kogyo/projects/site-improvement/decisions.html`** — 決定事項・確定仕様 — サイト改修・CV計測基盤整備
  - 実装タスクは backlog.html 参照。
  - 見出し: 案件方針（2026-05-09 打ち合わせで決定） / 位置づけ / スコープ / 現状認識（2026-05-09 時点） / 施策の全体構成（2026-05-09 合意）
- **`site/clients/hikita-kogyo/projects/site-improvement/index.html`** — サイト改修・CV計測基盤整備 — ヒキタ工業
  - プロジェクト記録への入口（ヒキタ工業株式会社）。
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題 / 決定事項・確定仕様 / 打ち合わせメモ
- **`site/clients/hikita-kogyo/projects/site-improvement/project-info.html`** — プロジェクト情報 — サイト改修・CV計測基盤整備
  - サイト改修・CV計測基盤整備（ヒキタ工業株式会社）
  - 見出し: 概要 / 要件 / 技術スタック / サーバー情報 / 関連ドキュメント / 対応履歴

### `site/clients/hikita-kogyo/projects/site-improvement/meeting-notes/`

- **`site/clients/hikita-kogyo/projects/site-improvement/meeting-notes/2026-05-09.html`** — 打ち合わせメモ — 2026-05-09（ヒキタ工業）
  - ヒキタ工業 サイト改修・CV計測基盤整備
  - 見出し: 案件位置づけ / 施策一覧 / フェーズ1：ベース整備 / フェーズ2：サイト改修 / フェーズ3：コンバージョン計測 / フェーズ4：広告（出稿時） / 要確認事項 / 次のアクション
- **`site/clients/hikita-kogyo/projects/site-improvement/meeting-notes/index.html`** — 打ち合わせメモ一覧 — サイト改修・CV計測基盤整備

### `site/clients/inoue-kagu-center/`

- **`site/clients/inoue-kagu-center/client-info.html`** — クライアント情報 — 株式会社井上家具センター
  - クライアント単位の基本情報・契約状況・備考を記録する。
  - 見出し: 基本情報 / 契約状況 / 対応経緯 / 備考
- **`site/clients/inoue-kagu-center/index.html`** — 株式会社井上家具センター
  - 家具ブランド「Story&Factory」のコーポレートサイト運用クライアント。
  - 見出し: クライアント情報 / プロジェクト / Story&Factory（storyandfactory.com）

### `site/clients/inoue-kagu-center/projects/story-and-factory/`

- **`site/clients/inoue-kagu-center/projects/story-and-factory/backlog.html`** — 残存課題 — Story&Factory
  - 要対応・要調査・要確認の項目を種別ごとに整理する。
- **`site/clients/inoue-kagu-center/projects/story-and-factory/decisions.html`** — 決定事項・確定仕様 — Story&Factory
  - 実装タスクは backlog.html 参照。
  - 見出し: 商品ページ プルダウン初期表示の制御仕様（2024-10-04 シソーラス由来） / 制御ファイル / chg_arr の指定ルール / 記載例（シソーラス共有） / 運用上の確定事項
- **`site/clients/inoue-kagu-center/projects/story-and-factory/index.html`** — Story&Factory
  - 家具ブランドのコーポレート＋商品ページサイト記録への入口。
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題 / 決定事項・確定仕様
- **`site/clients/inoue-kagu-center/projects/story-and-factory/project-info.html`** — プロジェクト情報 — Story&Factory
  - 家具ブランド「Story&Factory」のコーポレート＋商品ページサイト。
  - 見出し: 概要 / 要件 / 技術スタック / サーバー情報 / 関連ドキュメント / 対応履歴

### `site/clients/minoh-high-school/`

- **`site/clients/minoh-high-school/client-info.html`** — クライアント情報 — 大阪府立箕面高等学校
  - クライアント単位の基本情報・契約状況・備考を記録する。
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/minoh-high-school/index.html`** — 大阪府立箕面高等学校
  - クライアント情報・所属プロジェクトの記録への入口。
  - 見出し: クライアント情報 / プロジェクト / PTAサイト（minokopta.com）

### `site/clients/minoh-high-school/projects/pta-site/`

- **`site/clients/minoh-high-school/projects/pta-site/index.html`** — PTAサイト（minokopta.com）
  - HP制作・運用プロジェクト記録への入口。2026-05-11 改ざんインシデント対応後、監視継続中。
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題・監視タスク / 改ざんインシデント対応報告書
- **`site/clients/minoh-high-school/projects/pta-site/project-info.html`** — プロジェクト情報 — PTAサイト（minokopta.com）
  - プロジェクト単位の基本情報・要件・サーバー情報を記録する。
  - 見出し: 概要 / 要件 / 技術スタック / サーバー情報 / 同居サイト（同一サーバアカウント） / 関連ドキュメント / 対応履歴
- **`site/clients/minoh-high-school/projects/pta-site/residual-tasks.html`** — 改ざんインシデント後 残存課題・監視タスク — PTAサイト
  - 事後の監視・追加対処事項を追跡するためのチェックリスト。
  - 見出し: 監視継続事項（おおむね月次で確認） / サイト改ざんの再発監視 / webshell 隔離ファイル / 証拠保全データ / 優先度: 高（数日以内） / Google Search Console 対応 / konjaku-photo.com の継続要否判断 / 優先度: 中（1〜2週間以内） / konjaku-photo.com の脆弱性追究 / php_error.log の出力停止 …他3件

### `site/clients/minoh-high-school/projects/pta-site/incidents/`

- **`site/clients/minoh-high-school/projects/pta-site/incidents/2026-05-11-webshell-defacement.html`** — Webサイト改ざんインシデント対応報告書 — 2026-05-11
  - 残存課題は residual-tasks.html 参照。
  - 見出し: 1. エグゼクティブサマリ / 2. 何が起こったか / 2.1 改ざんの内容 / 2.2 攻撃の目的 / 3. 原因 / 3.1 侵入経路 / 3.2 設置されていた webshell（全5件） / 3.3 攻撃のタイムライン / 3.4 webshell 設置を許した根本原因 / 4. 対応内容 …他17件

### `site/clients/nara-forester-academy/`

- **`site/clients/nara-forester-academy/client-info.html`** — クライアント情報 — 奈良県フォレスターアカデミー
  - 奈良県フォレスターアカデミー（NFA）
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/nara-forester-academy/index.html`** — 奈良県フォレスターアカデミー
  - クライアント情報・所属プロジェクトの記録への入口（発注元：福岡ひとみ）。
  - 見出し: クライアント情報 / プロジェクト / コーポレートサイト 2026年度HP更新

### `site/clients/nara-forester-academy/projects/corporate/`

- **`site/clients/nara-forester-academy/projects/corporate/backlog.html`** — 残存課題 — コーポレートサイト 2026年度HP更新
  - 仕様・方針は decisions.html 参照。
  - 見出し: 受領待ち / 着手前タスク（並行可） / 確認事項
- **`site/clients/nara-forester-academy/projects/corporate/decisions.html`** — 決定事項・確定仕様 — コーポレートサイト 2026年度HP更新
  - 実装タスクは backlog.html 参照。
  - 見出し: 案件情報 / 作業範囲 / 進行方針
- **`site/clients/nara-forester-academy/projects/corporate/index.html`** — コーポレートサイト 2026年度HP更新 — NFA
  - プロジェクト記録への入口（奈良県フォレスターアカデミー、hana-tools project_id: 47）。
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題 / 決定事項・確定仕様
- **`site/clients/nara-forester-academy/projects/corporate/project-info.html`** — プロジェクト情報 — コーポレートサイト 2026年度HP更新
  - コーポレートサイト 2026年度HP更新作業（奈良県フォレスターアカデミー）
  - 見出し: 概要 / 要件 / 技術スタック / サーバー情報 / 関連ドキュメント

### `site/clients/osaka-toyopet/`

- **`site/clients/osaka-toyopet/client-info.html`** — クライアント情報 — 大阪トヨペット
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/osaka-toyopet/index.html`** — 大阪トヨペット
  - クライアント情報・所属プロジェクトの記録への入口（発注者：株式会社サンヒル）。
  - 見出し: クライアント情報 / プロジェクト / おもいでフォト

### `site/clients/osaka-toyopet/projects/omoide-photo/`

- **`site/clients/osaka-toyopet/projects/omoide-photo/index.html`** — おもいでフォト — 大阪トヨペット
  - プロジェクト記録への入口（大阪トヨペット、hana-tools project_id: 51）。
  - 見出し: プロジェクト情報
- **`site/clients/osaka-toyopet/projects/omoide-photo/project-info.html`** — プロジェクト情報 — おもいでフォト
  - おもいでフォト（大阪トヨペット）
  - 見出し: 概要 / 要件 / 技術スタック / サーバー情報 / 関連案件（works）

### `site/clients/prime-stage/`

- **`site/clients/prime-stage/client-info.html`** — クライアント情報 — 株式会社プライムステージ
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/prime-stage/index.html`** — 株式会社プライムステージ
  - クライアント情報・所属プロジェクトの記録への入口（hana-tools client_id: 12）。
  - 見出し: クライアント情報 / プロジェクト / ミサワリフォーム近畿 ショールーム見学会フォーム

### `site/clients/prime-stage/projects/misawa-showroom-form/`

- **`site/clients/prime-stage/projects/misawa-showroom-form/index.html`** — ミサワリフォーム近畿 ショールーム見学会フォーム — プライムステージ
  - プロジェクト記録への入口（株式会社プライムステージ、hana-tools project_id: 15 / work_id: 168）。
  - 見出し: プロジェクト情報
- **`site/clients/prime-stage/projects/misawa-showroom-form/project-info.html`** — プロジェクト情報 — ミサワリフォーム近畿 ショールーム見学会応募フォーム
  - ミサワリフォーム近畿 ショールーム見学会用 応募フォーム（プライムステージ）
  - 見出し: 概要 / 要件 / ページ構成 / 技術スタック / サーバー情報 / 納品物 / 対応履歴

### `site/clients/v-league/`

- **`site/clients/v-league/client-info.html`** — クライアント情報 — Vリーグ
  - クライアント単位の基本情報・契約状況・備考を記録する。
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/v-league/index.html`** — Vリーグ
  - クライアント情報・所属プロジェクトの記録への入口（発注元：株式会社VUELO）。
  - 見出し: クライアント情報 / プロジェクト / Vリーグチケット検索サイト

### `site/clients/v-league/projects/ticket-search/`

- **`site/clients/v-league/projects/ticket-search/index.html`** — Vリーグチケット検索サイト
  - システム開発プロジェクト記録への入口（進行中）。
  - 見出し: プロジェクト情報 / 記録ファイル / 問い合わせ記録
- **`site/clients/v-league/projects/ticket-search/project-info.html`** — プロジェクト情報 — Vリーグチケット検索サイト
  - プロジェクト単位の基本情報・要件・サーバー情報を記録する。
  - 見出し: 概要 / 要件 / 技術スタック / サーバー情報 / 納品物 / 関連ドキュメント / 対応履歴

### `site/clients/v-league/projects/ticket-search/qa-notes/`

- **`site/clients/v-league/projects/ticket-search/qa-notes/2026-05-11-csv-import.html`** — CSVインポート対応について — 2026-05-11
  - チケットVのCMSにおいて、チケット情報をCSVでインポートできるかという相談。
  - 見出し: 相談内容（先方より） / 背景 / イメージ・確認事項 / 回答（弊社より） / 1. サンプルCSVの出所 / 2. FC種別の表記揺れ対応 / 3. 対象シーズン / 4. CSVインポート時の公開ステータス / 5. 販売区分「その他」のラベル / 6. 既存チケットとの重複判定 …他2件
- **`site/clients/v-league/projects/ticket-search/qa-notes/index.html`** — クライアント問い合わせ記録一覧 — Vリーグチケット検索

### `site/clients/yoshida-shika/`

- **`site/clients/yoshida-shika/client-info.html`** — クライアント情報 — よしだ歯科
  - クライアント単位の基本情報・契約状況・備考を記録する。
  - 見出し: 基本情報 / 契約状況 / 備考
- **`site/clients/yoshida-shika/index.html`** — よしだ歯科
  - 歯科クリニックの HP 制作・運用クライアント。
  - 見出し: クライアント情報 / プロジェクト / コーポレートサイト（HP制作・運用）

### `site/clients/yoshida-shika/projects/corporate-site/`

- **`site/clients/yoshida-shika/projects/corporate-site/backlog.html`** — 残存課題 — よしだ歯科 コーポレートサイト
  - 2026-04-27 打合せで挙がった項目を、種別ごとに整理。
  - 見出し: ホームページ運用方針 — SEO・MEO / 主要ターゲットキーワード / SEO — 外部リンク獲得施策 / MEO — ローカル検索対策 / 広告運用 / Yahoo広告 成果分析・予算最適化 / 提案案件 / HANAチャット導入提案（AIチャット） / サイト実装タスク / 症例集ページの実装（WP） …他4件
- **`site/clients/yoshida-shika/projects/corporate-site/decisions.html`** — 決定事項・確定仕様 — よしだ歯科 コーポレートサイト
  - 実装タスクは backlog.html 参照。
- **`site/clients/yoshida-shika/projects/corporate-site/index.html`** — よしだ歯科 コーポレートサイト
  - HP制作・運用プロジェクト記録への入口。
  - 見出し: プロジェクト情報 / 記録ファイル / 残存課題 / 決定事項・確定仕様 / 打ち合わせメモ
- **`site/clients/yoshida-shika/projects/corporate-site/project-info.html`** — プロジェクト情報 — よしだ歯科 コーポレートサイト
  - プロジェクト単位の基本情報・要件・サーバー情報を記録する。
  - 見出し: 概要 / 技術スタック / サーバー情報 / 運用中の関連サービス / 関連ドキュメント / 対応履歴

### `site/clients/yoshida-shika/projects/corporate-site/meeting-notes/`

- **`site/clients/yoshida-shika/projects/corporate-site/meeting-notes/2026-04-27.html`** — 打ち合わせメモ — 2026-04-27（よしだ歯科）
  - クライアント打合せで挙がった11項目を、状態別に整理。実施タスクは backlog.html に展開済み。
  - 見出し: 基本情報 / アジェンダで挙がった項目（生記録） / 状態別の分類 / A. はなさかで実施／提案する案件（→ backlog.html） / B. クライアントが他社サービスで導入予定（共有のみ・はなさか直接関与なし） / C. 内容詳細が未確認（要ヒアリング） / 要確認・宿題 / 次のアクション
- **`site/clients/yoshida-shika/projects/corporate-site/meeting-notes/index.html`** — 打ち合わせメモ一覧 — よしだ歯科

### `site/company/`

- **`site/company/index.html`** — 社内規程
  - 就業規則をはじめとする、社内の労務・人事関連規程の集約入口。
  - 見出し: 規程一覧 / 就業規則 / 社内運用ガイド
- **`site/company/operation-guide.html`** — 社内運用ガイド
  - 就業規則には載せきれない、具体的なツール名や操作手順・社内オペレーションをまとめる。規程としての労働条件は 就業規則 側を参照。
  - 見出し: 勤怠・有給休暇（クラウド勤怠システム） / 有給休暇の自動付与 / 有給休暇の取得・残日数 / 利用ツール一覧
- **`site/company/work-rules.html`** — 就業規則（ドラフト）
  - 株式会社はなさか の就業規則。標準的な章立てのフォーマットに、現時点で確定・検討中の内容を記載する。未策定の項目は枠のみ用意している。
  - 見出し: 目次 / 第1章 総則 / 目的 / 適用範囲 / 規則の遵守 / 第2章 採用・異動等 / 採用手続・提出書類 / 試用期間 / 労働条件の明示 / 異動（配置転換等） …他45件

### `site/drafts/`

- **`site/drafts/index.html`** — drafts - はなさかプレビューサーバ
  - クライアント案件のLP案、提案書モック、検証用HTMLなど、作業中の草案を置く場所です。
  - 見出し: 📥 チェックリスト草案（CSV） / Googleビジネスプロフィール / ホームページ制作チェックシート（既存「チェックシート」シートへの追加分） / ヒアリングシート 追加項目 / クライアント共有が必要になったら

### `site/external-activities/`

- **`site/external-activities/index.html`** — 外部活動
  - クライアント業務以外の、社長の対外的なコミットメント（団体活動・委員会担当 等）の記録。
  - 見出し: 商工会議所 担当例会

### `site/external-activities/chamber-of-commerce/`

- **`site/external-activities/chamber-of-commerce/index.html`** — 商工会議所 担当例会
  - 社長が担当する商工会議所の担当例会に関する記録。
  - 見出し: 担当パート / 第2総会（2026-10-16 想定）

### `site/external-activities/chamber-of-commerce/daini-soukai-2026-10/`

- **`site/external-activities/chamber-of-commerce/daini-soukai-2026-10/index.html`** — 第2総会（2026-10-16 想定）
  - 社長が担当する商工会議所 担当例会・第2総会の準備記録。
  - 見出し: プロジェクト情報 / 記録ファイル / 打ち合わせメモ
- **`site/external-activities/chamber-of-commerce/daini-soukai-2026-10/project-info.html`** — 商工会議所 担当例会 — 第2総会
  - 社長が担当する第2総会（2026-10-16 開催想定）の準備記録。
  - 見出し: 概要 / タイムテーブル（当日） / 担当範囲（4つの作業領域） / 会場候補 / ケータリング / 役割分担 / ToDo（社長アクション） / 確認待ち項目（後日整理） / 議事録

### `site/external-activities/chamber-of-commerce/daini-soukai-2026-10/meeting-notes/`

- **`site/external-activities/chamber-of-commerce/daini-soukai-2026-10/meeting-notes/2026-05-14-kickoff.html`** — 第2総会 キックオフ打合せ — 2026-05-14
  - 商工会議所 担当例会 / 第2総会 準備のキックオフ。後で project-info.html に反映する。
  - 見出し: アジェンダ（社長担当パート） / 決定事項 / 共有事項 / 会場 / ケータリング / 当日タイムテーブル / 予算 / 次のアクション / 補足（社内整理メモ）
- **`site/external-activities/chamber-of-commerce/daini-soukai-2026-10/meeting-notes/index.html`** — 打ち合わせメモ一覧 — 第2総会

### `site/operations/`

- **`site/operations/index.html`** — 業務
  - 本業の進め方・手順・チェックシート・テンプレートを集約。 「経営の数字」は ビジネスダッシュボード へ。
  - 見出し: 🌐 ホームページ制作 / 📋 制作フロー（10段階） / 📥 チェックリスト草案 / 🛠 システム開発 / ⚠️ 開発フロー（未整備） / 🤖 AIサービス / ⚠️ 提供メニュー（未整備） / 📊 外部スプレッドシート / 関連
- **`site/operations/web-development.html`** — ホームページ制作フロー
  - 案件の進行を10段階に分け、各フェーズで「何をやるか」「どの資料を使うか」を集約。
  - 見出し: 📋 10段階フロー / ① ヒアリング / ② 要件定義 / ③ 見積もり・提案 / ④ 契約・着手金 / ⑤ 情報設計（サイトマップ・WF） / ⑥ デザイン / ⑦ 実装・コーディング / ⑧ テスト・修正 / ⑨ 公開・納品 …他4件

### `site/tools/`

- **`site/tools/index.php`** — ツールハブ
  - PHPで動く社内ツール群。site/tools/<slug>/index.php を追加すれば自動でここに並びます。
  - 見出し: ツールの追加方法

### `site/tools/hello/`

- **`site/tools/hello/index.php`** — Hello — PHP動作確認
  - PHP-FPM + Nginx の動作確認用ページ。

## data/ 主要ファイル

- `data/clients-cache.json`
- `data/financial/` — 財務データ保管ルール
  - `2024/`, `2025/`, `2026/`, `card-statements/`, `journal/`, `journal-rules.json`, `square/`
- `data/monthly/`
  - `cost/`, `revenue/`
- `data/secrets/` — 🔒 機密（中身は非掲載）
- `data/skill-sheets/` — スキルシート データ（ソース・オブ・トゥルース）
  - `advanced-skills.json`, `design-skills.json`, `dev-skills.json`, `dev-system.json`, `dev-web.json`, `pc-skills.json`
- `data/ycom/` — YCOM（個人事業）データ保管

