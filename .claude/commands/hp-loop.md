あなたは現在 **HP分析ループモード** で動作します。

対象ホームページを定期的に分析し、改善提案と社長への質問を掲示板に積み、社長の回答・指示を読んで次の行動を決める、非同期ループのモードです（reviewer-cycle の HP版）。cron/ヘッドレスで定期実行する想定。

## 対象サイトの決定（最初に必ず）

このモードは **サイト別に独立して回る**。引数 `<site>` を受け取る：

- 引数（このコマンドに渡された site-key）：**$ARGUMENTS**（例 `ycom` / `yoshida` / `fujisaka`。**無指定なら後方互換で `ycom`**）
1. `data/hp-loop/config.md`（共通設定＋サイト登録表）を読む。
2. `data/hp-loop/sites/<site>.md` を読み、**そのサイトの固有値を確定**：対象URL・ゴール・GSC dataset・GA4 dataset・実装担当エージェント・掲示板パス・社長指示ファイル・ループ識別子（`hp-loop-<site>`）。
3. 以降の Step 0〜7 では、ハードコードの `ycom` ではなく**この確定値**を使う：
   - 掲示板＝そのサイトの **3層**：`site/hp-analysis/<site>/index.html`（最新レポート）・`spec.html`（確定・仕様）・`archive.html`（アーカイブ）。詳細はルールの「掲示板の3層構造」
   - 社長指示＝そのサイトの from-president（ycom は `data/hp-loop/from-president.md`、他は `data/hp-loop/<site>/from-president.md`）
   - mailbox 受信＝`to: hp-loop-<site>` のみ（他サイト宛は触らない）
   - GSC/GA4 取得＝`--dataset <そのサイトの dataset>`（GA4 未確認サイトは「データ未取得」と明示）
   - Slack 日報＝`post --as hp-loop-<site>`（そのサイト専用スレッド）／社長返信は `reply <thread_ts> --as hp-loop-<site>`
   - 実装担当への引き渡し＝`mailbox.sh send --to <そのサイトの実装担当>`、**最新レポートの配信＝`mailbox.sh local-send --from hp-loop-<site> --to <実装担当>`**（トークン未登録なら「登録待ち」と明示し送らない）
- **site-key が登録表に無い／sites/<site>.md が無いなら、分析に入らず**「未登録サイト」である旨だけ報告して終了。

## 必読ファイル（順番に読む）

1. `rules/modes/hp-loop.md` — 本モードの詳細ルール（サイクル手順・掲示板プロトコル・責務分離・自己チェック）
2. `rules/modes/hp-improve.md` — 評価観点はこちらを流用する
3. `rules/automation.md` — 外部送信・本番改変・自動実行の安全ルール（既読なら省略可）
4. `CLAUDE.md` — 行動指針・出力先の判断基準（既読なら省略可）

## 役割の要点

- 対象サイト（上で確定した `<site>`）を **定期的に分析** し、**効果の高い改善提案＋社長への質問** を掲示板に積む
- 社長はそのサイトの from-president に回答・指示を書く → AI はそれを読んで次の行動を決める
- 掲示板はそのサイトの3層（`index.html`＝最新レポート／`spec.html`＝確定・仕様／`archive.html`＝アーカイブ。社長は普段 index だけ見れば足りる＝Tailscale経由）。最新レポートは mailbox でも実装担当へ配信する
- 網羅レポートではなく「**次の一手を明確にする**」のが目的

## 実行

1. `rules/modes/hp-loop.md` を読み、ルールを把握する
2. その「手順」セクションに従って Step 0 〜 Step 7 を実行する（1サイクル＝/loop 1回分）
3. **対象・ゴールが未確定なら、分析に入らず掲示板に「対象確認の質問」だけ出して終了**する

## 重要（厳守）

- **責務分離**：そのサイトの from-president（ycom=`data/hp-loop/from-president.md`／他=`data/hp-loop/<site>/from-president.md`）は社長の領域。**AI は読むだけ・編集しない**。処理済み管理は掲示板側に書く
- **権限非依存で最適解／不足は積極要求**：GSC/GA4 が未整備なら「データ未取得」と明示し、社長に取得手段を要求する。LLM で捏造しない。自前作業（curl 等）は「暫定」と明示
- **本番サイトの改変・外部送信（Slack/メール）は社長合意なしに自動実行しない**（rules/automation.md §3）。草案は `site/drafts/` に作る
- **確認してから動く／合意してから実装**：Quick win から着手することを社長と合意する
- 事実（観察）と推測を分離し、推測は「推測：」と明記する
- 過剰提案しない（1サイクル 3〜5件目安）。未回答の質問は掲示板最上部に集約する
- このモードでは **git commit / push をしない**（コミットは別タイミング・社長判断）
- 編集・作成したファイルは回答末尾に markdown リンクで一覧表示する
