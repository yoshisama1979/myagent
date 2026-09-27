# カイゼン台帳：判断待ちの索引（生成物・手で書かない）

`python3 bin/kaizen.py index --rebuild` が原文から作る。**1行＝1件・未採否の全件**（絞り込まない）。
経緯（原文）は `python3 bin/kaizen.py show K-NNN` で全文が出る。要約し直さず見出しをそのまま載せる。

| ID | 日付 | レーン | 見出し（原文のまま） | 🙋 | 原文の在処 | 照合 |
|---|---|---|---|---|---|---|
| K-577 | 2026-08-19 | hp-loop yokohawaii | （hp-loop yokohawaii・2026-08-19 Cycle 058）｜🙋要・社長判断｜器の規律は「実施しなかった」経路より「**実施したのに記帳しなかった**」経路で壊れる＝2例目 | 🙋 | data/hp-improve/kaizen/2026-08.md:3 | bb97193f8de8 |
| K-530 | 2026-08-14 | hp-loop yokohawaii | （hp-loop yokohawaii・2026-08-14 Cycle 053）｜🙋要・社長判断＝掲示板 index が 80KB tripwire を超えた真因は「サイクルログの堆積」ではなく「**未完了R行に各サ | 🙋 | data/hp-improve/kaizen/2026-08.md:9 | fddc94d0a0b3 |
| K-513 | 2026-08-10 | blog-loop ycom | （blog-loop ycom・2026-08-10 Cycle 061）｜🙋要・社長判断＝許可リストの「bash 前置」ギャップを当ループでも同日再現（K-511・rally と同型／[[reference_allo | 🙋 | data/hp-improve/kaizen/2026-08.md:13 | 6d33de521081 |
| K-515 | 2026-08-10 | partner | （partner・2026-08-10 Cycle 136 夜tick）｜社長の「どちらが効率いい？」は、8/4 の A-057② と<u>同じ問いの2回目</u>だった＝答えは既に測ってあったのに、私はそれを社長が使 | 🙋 | data/hp-improve/kaizen/2026-08.md:16 | acd7fccac2af |
| K-521 | 2026-08-12 | hp-loop yoshida | （hp-loop yoshida・2026-08-12 Cycle 063）｜🙋要・社長判断 `ga4-fetch` の完全性フラグ `daily日数` は<u>1年前の窓では 0 と出るのにデータは返る</u>＝M- | 🙋 | data/hp-improve/kaizen/2026-08.md:19 | d86972aaf132 |
| K-524 | 2026-08-12 | hp-loop yokohawaii | （hp-loop yokohawaii・2026-08-12 Cycle 051）｜🙋要・社長判断＝**自分の訂正が誤っていた**＝件数は「番号の範囲」で数えず該当ブロックの行を数える、を*訂正のときにこそ*適用する | 🙋 | data/hp-improve/kaizen/2026-08.md:24 | 684b0149630c |
| K-553 | 2026-08-17 | overseer | （overseer・2026-08-17 Cycle 063）｜**「✅クローズ」は数値が閾値内に戻ったことでなく、閾値内に留まる仕組みが入ったことで判定する** | 🙋 | data/hp-improve/kaizen/2026-08.md:30 | fea22773c171 |
| K-525 | 2026-08-12 | partner | （partner・2026-08-12 Cycle 138）｜🙋要・社長判断＝**無人ループは「器を全部更新してから配達する」順序だと、時間切れで<u>成果物が1件も届かない</u>**（C137 が実例） | 🙋 | data/hp-improve/kaizen/2026-08.md:35 | 6df6b036981d |
| K-528c | 2026-08-14 | partner | （partner・2026-08-14 Cycle 140）｜🙋要・社長判断＝**器のトリップワイヤ「70KB」が10進/1024換算で解釈が割れる** | 🙋 | data/hp-improve/kaizen/2026-08.md:40 | 1981e83ba8cc |
| K-534 | 2026-08-15 | blog-loop ycom | （blog-loop ycom・2026-08-15 Cycle 066）｜🙋要・社長判断＝**「1分でできる小さな作業」を毎日積み上げる出し方は、2週間で1件も動かなかった** | 🙋 | data/hp-improve/kaizen/2026-08.md:46 | 5464dbd8c80f |
| K-541b | 2026-08-15 | hp-loop konjaku | （hp-loop konjaku・2026-08-15 Cycle 018）｜**サンプルは「3件」で止めると物語が半分になる — 9件に広げたら主因が入れ替わった** | 🙋 | data/hp-improve/kaizen/2026-08.md:63 | ec2a149a4fd3 |
| K-543 | 2026-08-15 | hp-loop rally | （hp-loop rally・2026-08-15 Cycle 020）｜**社長への質問を立てる前に「その答えが本番の画面に書かれていないか」を一度見る** | 🙋 | data/hp-improve/kaizen/2026-08.md:70 | 2f7f61e85907 |
| K-544 | 2026-08-16 | hp-loop ycom | （hp-loop ycom・2026-08-16 Cycle 096）｜**「増えた」を成果と書く前に、次の窓で戻っていないかを見る（バーストと持続の切り分けは、窓を1本足すだけで済む）** | 🙋 | data/hp-improve/kaizen/2026-08.md:78 | 8b548ea3b383 |
| K-546 | 2026-08-16 | hp-loop fujisaka | （hp-loop fujisaka・2026-08-16 Cycle 065）｜**新しく決めた測定規律は「これから起票するもの」だけでなく「すでに走っている予約」にも遡って当てる — でないと古い設定が古いまま数字を | 🙋 | data/hp-improve/kaizen/2026-08.md:85 | 492752d0f6da |
| K-547 | 2026-08-16 | hp-loop fujisaka | （hp-loop fujisaka・2026-08-16 Cycle 065）｜**「優先度🔴」と「効果の測り方」は別々に管理されていて、片方だけ付いた提案が63サイクル生き残る** | 🙋 | data/hp-improve/kaizen/2026-08.md:92 | 9e128609e8d2 |
| K-550 | 2026-08-16 | partner | （partner・2026-08-16 Cycle 142）｜**同じ相手の別件は、片方が壊れた瞬間にもう片方の期日を道連れにする＝「相手で束ねる」の第2形** | 🙋 | data/hp-improve/kaizen/2026-08.md:113 | 255c4436a18f |
| K-551 | 2026-08-16 | hp-loop konjaku | （hp-loop konjaku・2026-08-16 Cycle 019）｜**「データが無い」は確認した事実ではなく思い込みだった — 18サイクル、別ドメインで測られている本体を見ていなかった** | 🙋 | data/hp-improve/kaizen/2026-08.md:120 | 5912e0dbf999 |
| K-552 | 2026-08-16 | hp-loop konjaku | （hp-loop konjaku・2026-08-16 Cycle 019）｜**実装の順序を「推奨」で伝えると守られない — 5番手が先に本番へ入り、1〜4番手が未着手のまま検索エンジンへの申告が始まった** | 🙋 | data/hp-improve/kaizen/2026-08.md:128 | 8db1e682df40 |
| K-554 | 2026-08-17 | hp-loop ycom | （hp-loop ycom・2026-08-17 Cycle 097）｜**効果判定の期日を「反映日＋N日」で置くと、データラグのぶん必ず早すぎる — 期日にラグを足す** | 🙋 | data/hp-improve/kaizen/2026-08.md:144 | 677523494540 |
| K-555 | 2026-08-17 | hp-loop ycom | （hp-loop ycom・2026-08-17 Cycle 097）｜**外的成分の差し引き（M-14）は「効果を割り引く」だけでなく「効果を補強する」方向にも使える — サイト全体が縮んでいるなら、伸びた個別ページ | 🙋 | data/hp-improve/kaizen/2026-08.md:150 | f2b455d2032f |
| K-556 | 2026-08-17 | hp-loop fujisaka | （hp-loop fujisaka・2026-08-17 Cycle 066）｜**新しい経路を実測で発見しても、既存の打ち手をその経路の側から書き直さないと、打ち手は古い経路のままで穴が残る** | 🙋 | data/hp-improve/kaizen/2026-08.md:157 | 3bd1824de7bd |
| K-557 | 2026-08-17 | hp-loop fujisaka | （hp-loop fujisaka・2026-08-17 Cycle 066）｜**判定条件を「先に」書いておくと、低母数の揺れに臨時調査を起こさずに済む — 事前登録が実際に空転を防いだ初の実例** | 🙋 | data/hp-improve/kaizen/2026-08.md:165 | 2f429563ee16 |
| K-558 | 2026-08-17 | hp-loop yokohawaii | （hp-loop yokohawaii・2026-08-17 Cycle 056）｜**「勝てていない」を「狙わない」と取り違えると、伸びしろの一番大きい領域が観測から静かに消える — 堀の外判定は"USP修飾語の有無 | 🙋 | data/hp-improve/kaizen/2026-08.md:173 | 5e8725fdee1a |
| K-559 | 2026-08-17 | hp-loop yokohawaii | （hp-loop yokohawaii・2026-08-17 Cycle 056）｜**台帳肥大の第2の経路＝「上書き」と仕様に書かれた節が、実際には追記運用になっていた** | 🙋 | data/hp-improve/kaizen/2026-08.md:181 | 6d15ee08f72e |
| K-561 | 2026-08-17 | hp-loop konjaku | （hp-loop konjaku・2026-08-17 Cycle 020）｜**共有ツールの"正規化"は、ある1サイトにとっては北極星そのものを不可視にしていることがある — 「限界」と書いて2サイクル素通りした** | 🙋 | data/hp-improve/kaizen/2026-08.md:189 | 94b3d0ea6e0e |
| K-562 | 2026-08-17 | hp-loop konjaku | （hp-loop konjaku・2026-08-17 Cycle 020）｜**台帳に起票した R が掲示板に転記されず、どちらにも「欠落している」と気づく仕組みが無かった** | 🙋 | data/hp-improve/kaizen/2026-08.md:196 | dbf1e07464f0 |
| K-563 | 2026-08-17 | blog-write ycom | （blog-write ycom・2026-08-17）｜**同じルールファイルの中に「保留」と「毎サイクル実行」が同居していると、安全側の記述が勝ち続けて 46日間 何も起きない — 段階導入の表は"卒業した Pha | 🙋 | data/hp-improve/kaizen/2026-08.md:203 | 3ebb8c3d4ac6 |
| K-564 | 2026-08-17 | blog-improve ycom | （blog-improve ycom・2026-08-17）｜**「人間の1アクション」を解除条件にしたゲートは、期限も再判定もなければ待機列を静かに凍らせる — K-563 と同型の"安全側が勝ち続ける"構造** | 🙋 | data/hp-improve/kaizen/2026-08.md:210 | c8e483d25e7d |
| K-573 | 2026-08-18 | hp-loop konjaku | （hp-loop konjaku・2026-08-18 Cycle 022）｜**否定形の断定（「見えていない」「存在しない」「届いていない」）は、それを直接測る窓が近く開くなら、開いてから書く** | 🙋 | data/hp-improve/kaizen/2026-08.md:219 | 2efbbed3b9ce |
| K-574 | 2026-08-18 | hp-loop konjaku | （hp-loop konjaku・2026-08-18 Cycle 022）｜**打ち切りのある出力で件数を数えない — `grep -c` する前に「その出力は全体か」を確認する** | 🙋 | data/hp-improve/kaizen/2026-08.md:227 | 175002236629 |
| K-576b | 2026-08-19 | hp-loop rally | （hp-loop rally・2026-08-19 Cycle 024）｜**「配信した」で終えず「相手が処理したか・返信があるか」まで数える — 受け渡し箱は片側から見ると必ず健全に見える** | 🙋 | data/hp-improve/kaizen/2026-08.md:234 | f34a97e8a731 |
| K-577b | 2026-08-19 | hp-loop rally | （hp-loop rally・2026-08-19 Cycle 024）｜**掲示板に「やった」と書く前に、やった痕跡を機械で確認する — Cycle 022 は配信したと書いて実際は未投函だった** | 🙋 | data/hp-improve/kaizen/2026-08.md:241 | 37514e2cfe67 |
| K-578 | 2026-08-19 | hp-loop konjaku | （hp-loop konjaku・2026-08-19 Cycle 023）｜**計測を開始した「初日」のデータを基準値にしない — 3日連続の数値訂正は、すべて「その日に手に入った1つの数字を確定値として書いた」こと | 🙋 | data/hp-improve/kaizen/2026-08.md:248 | f57c31150dd8 |
| K-579 | 2026-08-19 | hp-loop konjaku | （hp-loop konjaku・2026-08-19 Cycle 023）｜**`hp-shot` は直列で撮る — 2本同時に走らせると Chrome の起動が30秒でタイムアウトする** | 🙋 | data/hp-improve/kaizen/2026-08.md:257 | b24ab63aced2 |
| K-580 | 2026-08-19 | hp-loop konjaku | （hp-loop konjaku・2026-08-19 Cycle 023）｜**共有ファイル（win-patterns.md）の採番は、書く直前に取り直す — 同日に別サイトのループが同じ番号を取っていた** | 🙋 | data/hp-improve/kaizen/2026-08.md:264 | c15236dc1450 |
| K-581 | 2026-08-19 | hp-loop hikita | （hp-loop hikita・2026-08-19 Cycle 001）｜**「CVが水増しされている」と「CVが計測されていない」は、外形が似ていて意味が正反対 — タグの存在ではなく実データの有無で判定する** | 🙋 | data/hp-improve/kaizen/2026-08.md:271 | 2067c2fbece1 |
| K-582 | 2026-08-19 | hp-loop hikita | （hp-loop hikita・2026-08-19 Cycle 001）｜**広告の受け皿ページは必ずスクショで見る — 「動画が非公開」はHTML解析では絶対に出てこない** | 🙋 | data/hp-improve/kaizen/2026-08.md:279 | f9dce561dda1 |
| K-583 | 2026-08-19 | hp-loop hikita | （hp-loop hikita・2026-08-19 Cycle 001）｜**「全ページ同一タイトル」のような全称命題は、初回サイクルで層ごとに割り直す — 半分正しい指摘は、半分の工数を無駄にする** | 🙋 | data/hp-improve/kaizen/2026-08.md:287 | 5e71fa124379 |
| K-584 | 2026-08-20 | overseer | （overseer・2026-08-20）他エージェントからの起票は「転記」でなく「裏取り＋副作用潰し＋一段深掘り」までが受理 | 🙋 | data/hp-improve/kaizen/2026-08.md:295 | 6a013ec98f01 |
| K-585 | 2026-08-21 | hp-loop yoshida | （hp-loop yoshida・2026-08-21 Cycle 070）｜**無人ループは「動かなかった日」を自分で証明できない — 完了記録が無いと、欠測は次の担当者の目視でしか見つからない** | 🙋 | data/hp-improve/kaizen/2026-08.md:299 | 0bcd3127e7bd |
| K-586 | 2026-08-21 | hp-loop rally | （hp-loop rally・2026-08-21 Cycle 025）｜**踏査台帳は「見たもの」しか記録しないので、「一度も見ていない面」は構造的に見えない — 母集団を先に置き、差集合を週次で出す** | 🙋 | data/hp-improve/kaizen/2026-08.md:305 | 4c31d32fc80a |
| K-587 | 2026-08-21 | hp-loop konjaku | （hp-loop konjaku・2026-08-21 Cycle 024）｜**共有ライブラリへ昇格しなかった教訓は、2日で別サイトが独立に再演する — K-576 がその実例になった** | 🙋 | data/hp-improve/kaizen/2026-08.md:312 | 493b43d46f27 |
| K-588 | 2026-08-21 | hp-loop konjaku | （hp-loop konjaku・2026-08-21 Cycle 024）｜**「露出率」だけで着手順を決めていた — 同じデータから "刺さり方"（CTR）も出せたのに1サイクル見落としていた** | 🙋 | data/hp-improve/kaizen/2026-08.md:320 | fdaae4eedbdd |
| K-589 | 2026-08-21 | partner | （partner・2026-08-21 Cycle 146）｜**「横ばい」と3週間書き続けた指標が、悪化に転じてから初めて打ち手の話になった** | 🙋 | data/hp-improve/kaizen/2026-08.md:327 | 575e6ecfdafd |
| K-590 | 2026-08-21 | partner | （partner・2026-08-21 Cycle 146）｜**朝礼が1日まるごと未配達だったのに、翌朝まで誰も気づかなかった（「完成と配達は別」の2例目）** | 🙋 | data/hp-improve/kaizen/2026-08.md:334 | 3dbc733afded |
| K-591 | 2026-08-22 | hp-loop rally | （hp-loop rally・2026-08-22 Cycle 026）｜**「うちのサイトが薄い」は自サイトだけ見ても言えない — 26サイクル、一度も相手を測らずに最優先の提案を推していた** | 🙋 | data/hp-improve/kaizen/2026-08.md:340 | a4cb5a9e494a |
| K-594 | 2026-08-21 | partner | （partner・2026-08-21 Cycle 147）｜**器の閾値は「追記の前に退避」だけでは足りない（追記量を先に見積もる）** | 🙋 | data/hp-improve/kaizen/2026-08.md:347 | 76306d62d58f |
| K-596 | 2026-08-23 | hp-loop yokohawaii | （hp-loop yokohawaii・2026-08-23 Cycle 061）｜**同じ指標について自己訂正が2回続いたら、解釈を練り直す前に「データそのものが書き換わっていないか」を確かめる** | 🙋 | data/hp-improve/kaizen/2026-08.md:353 | cf268ac95cb5 |
| K-595 | 2026-08-23 | hp-loop yoshida | （hp-loop yoshida・2026-08-23 Cycle 072）｜**「なぜクリックされないか」を問う前に「どのURLで表示されているか」を割る — 同じクエリでも枠が違えば打ち手の宛先が変わる** | 🙋 | data/hp-improve/kaizen/2026-08.md:360 | d57f8b3da8be |
| K-595b | 2026-08-23 | blog-loop-ycom | （blog-loop-ycom・2026-08-23）｜締切のある実行では「連絡」を最後に置かない | 🙋 | data/hp-improve/kaizen/2026-08.md:367 | cce66882e23e |
| K-600 | 2026-08-24 | hp-loop-yoshida | （hp-loop-yoshida・2026-08-24 Cycle 073）同じ「取りこぼし」を無料流入だけで見ていると、有料側の同じ穴を数サイクル見落とす | 🙋 | data/hp-improve/kaizen/2026-08.md:376 | 5a2ae935b1f2 |
| K-604 | 2026-08-24 | hp-loop-fujisaka | （hp-loop-fujisaka・2026-08-24 Cycle 071）月次点検の値打ちは「異常の発見」だけでなく「<u>前提が良い方へ変わった</u>」の検出にもある | 🙋 | data/hp-improve/kaizen/2026-08.md:384 | faebae79ccb9 |
| K-611 | 2026-08-24 |  | 🙋要・社長判断 — 朝礼の未配達が3例目＝K-525（Step 5→6 の順の入れ替え）は実データで裏づけ済み（partner 2026-08-24 Cycle 151） | 🙋 | data/hp-improve/kaizen/2026-08.md:391 | 8b2b313fe55c |
| K-602c | 2026-08-25 | partner | （partner・2026-08-25 Cycle 156）🙋要・社長判断｜台帳の"床"が2サイクル連続で閾値に戻らない | 🙋 | data/hp-improve/kaizen/2026-08.md:397 | 5f88fece1e30 |
| K-610b | 2026-08-26 | partner | （partner・2026-08-26 Cycle 158）社長の仮説が**言葉の線引き**でできているとき、諫言は「その線は間違い」でなく<u>「効いている線は別のここ」</u>と<b>引き直す</b> | 🙋 | data/hp-improve/kaizen/2026-08.md:404 | b1042ed53af4 |
| K-615b | 2026-08-26 | partner | （partner・2026-08-26 Cycle 159）🙋要・社長判断＝Shift-JIS の財務CSVを<u>正しく読む手段が無い</u>（文字化けで勘定科目名が確定できない） | 🙋 | data/hp-improve/kaizen/2026-08.md:411 | 190c7c7c5403 |
| K-617 | 2026-08-26 |  | 🙋要・社長判断 — 「自動化してほしい」の依頼は、着手前に<u>物理的に不可能な部分</u>をコードで切り分ける（partner 2026-08-26 Cycle 160） | 🙋 | data/hp-improve/kaizen/2026-08.md:416 | bfb62f69c859 |
| K-624 | 2026-08-27 |  | 🙋要・社長判断 — 掲示板が 80KB を割れないのは怠慢ではなく**ルール同士の衝突**。3日続いたら解き方を出す（blog-loop-ycom 2026-08-27 Cycle 077） | 🙋 | data/hp-improve/kaizen/2026-08.md:422 | 62d1d951c6df |
| K-627 | 2026-08-28 |  | 🙋要・社長判断 — 新設した「スキップ不可の必須ステップ」が<u>許可リスト未登録で実行できない</u>（hp-loop-ycom 2026-08-28 Cycle 106） | 🙋 | data/hp-improve/kaizen/2026-08.md:431 | 5abc7e14e1dc |
| K-629 | 2026-08-28 | hp-loop-rally | 🙋要・社長判断 — 在庫上限（WIP）の機械チェックが**許可リストに無く流せない**＝ルール v0.20 の要（宣言でなく終了コード）が全レーンで機能していない（hp-loop-rally・2026-08-28 C | 🙋 | data/hp-improve/kaizen/2026-08.md:441 | 70dc54db4983 |
| K-632 | 2026-08-28 | hp-loop-konjaku | 🙋要・社長判断 — 「作業の順序を入れ替える」再発防止は、**持ち時間が足りない**ときには効かない（最後尾が変わるだけ）（hp-loop-konjaku・2026-08-28 Cycle 031） | 🙋 | data/hp-improve/kaizen/2026-08.md:449 | b2070d320db4 |
| K-633 |  |  | 在庫上限の機械チェックが流せない件は konjaku でも再現（K-629 の2例目・同日・別レーン） |  | data/hp-improve/kaizen/2026-08.md:459 | 58ad8738c68f |
| K-637 | 2026-08-28 |  | 🙋要・社長判断｜K番号の採番が衝突したままで、この行自体が安全に採番できていない（partner 2026-08-28 Cycle 162） | 🙋 | data/hp-improve/kaizen/2026-08.md:467 | fe79ecddadf9 |
| K-643 | 2026-08-29 |  | 許可リストは<u>コマンド名でなく「呼び方（前置を含む文字列）」</u>で一致する＝同じ道具が呼び方ひとつで使えなくなる（hp-loop-konjaku 2026-08-29 Cycle 032） | 🙋 | data/hp-improve/kaizen/2026-08.md:474 | 5783d50930dc |
| K-649 | 2026-08-30 |  | 🙋要・社長判断｜在庫上限（WIP）が**未回答の質問を1件も数えていない**＝「未決着のすべてを数える」という v0.21 の決定と実装がズレている（hp-loop-yoshida 2026-08-30 Cycle | 🙋 | data/hp-improve/kaizen/2026-08.md:483 | efae56bb9a22 |
| K-653 | 2026-08-30 | partner | （partner・2026-08-30 Cycle 164）🙋要・社長判断｜器の閾値は「退避量の上限」を実測してから決める | 🙋 | data/hp-improve/kaizen/2026-08.md:492 | 5bd557312b0a |
| K-658 | 2026-08-31 | hp-loop-yoshida | 台帳のローテは「削れる在庫」が尽きる日が来る＝**閾値を割った回数でなく、次に何を削るかが残っているかで警報を出す**（hp-loop-yoshida・2026-08-31 Cycle 080） | 🙋 | data/hp-improve/kaizen/2026-08.md:500 | 53208f08aac5 |
| K-654 | 2026-08-31 | overseer | 「今の⚠️」しか見ない監視は、✅に戻った項目が再び壊れたことを検知できない（overseer・2026-08-31） | 🙋 | data/hp-improve/kaizen/2026-08.md:503 | 60baea08a1ee |
| K-658b | 2026-08-31 | hp-loop-rally | 🙋要・社長判断：sitemap を「数える」道具が、それを最も必要とするサイトで使えない（hp-loop-rally・2026-08-31 Cycle 038） | 🙋 | data/hp-improve/kaizen/2026-08.md:506 | c7c1304971fe |
| K-659 | 2026-08-31 | hp-loop-rally | 🙋要・社長判断：本ファイル（skill-kaizen.md）が 416KB＝自分のトリップワイヤ（100KB）の4倍で、誰も退避していない（hp-loop-rally・2026-08-31 Cycle 038） | 🙋 | data/hp-improve/kaizen/2026-08.md:509 | 2445f7dc1698 |
| K-662 | 2026-08-31 | partner | 新しい規律で古い規律を上書きしてしまい、3日連続で一手が空振りした（partner・2026-08-31 Cycle 165） | 🙋 | data/hp-improve/kaizen/2026-08.md:512 | 2d7f96d91908 |
| K-768 | 2026-09-11 | overseer | （overseer・2026-09-11 Cycle 077）｜他エージェントからの起票を受理するとき、**掲示板の既存カードと突き合わせる手順が無い**＝同じ事象に2つ目の番号を振りかける経路が開いている | 🙋 | data/hp-improve/kaizen/2026-09.md:3 | a03c68b81074 |
| K-664 | 2026-09-01 | overseer | 軽い巡回で新しい綻びを安価に見つける定石＝「状態ファイルと、それを写しているビューの mtime を突き合わせる」（overseer・2026-09-01 Cycle 072） | 🙋 | data/hp-improve/kaizen/2026-09.md:9 | ed1972e5bd4b |
| K-666 | 2026-09-01 | hp-loop | 状態を機械で数えるなら、その状態を表す記号を「散文の中でも」使ってはいけない（hp-loop・2026-09-01 ycom Cycle 110） | 🙋 | data/hp-improve/kaizen/2026-09.md:15 | 3903d1c21b61 |
| K-671 | 2026-09-01 | hp-loop | 台帳の記帳で旧世代を「🗄️ 前回＝…」と同じセルに残すと、ローテした端から超過する（hp-loop・2026-09-01 konjaku Cycle 036） | 🙋 | data/hp-improve/kaizen/2026-09.md:21 | b57df5c6dca2 |
| K-673 | 2026-09-01 | partner | （partner・2026-09-01 Cycle 167）「誰が抜けると何が止まるか」が機械で出せない | 🙋 | data/hp-improve/kaizen/2026-09.md:28 | ef04aaa1b7d5 |
| K-675 | 2026-09-01 | hp-loop-shigatoyota | （hp-loop-shigatoyota・2026-09-01 Cycle 002）サイト新規登録の「登録漏れ」は mailbox 許可リストにも出た＝K-674 と同じ穴の別の面 | 🙋 | data/hp-improve/kaizen/2026-09.md:33 | bae551ec2a3e |
| K-678 |  |  |  | 🙋 | data/hp-improve/kaizen/2026-09.md:41 | 80ac9af0955d |
| K-679 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:50 | c10e7aded3cb |
| K-680 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:55 | e004397ad405 |
| K-681 |  |  |  | 🙋 | data/hp-improve/kaizen/2026-09.md:61 | a73e91c327de |
| K-682 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:67 | 892c846d0b8d |
| K-683 |  |  |  | 🙋 | data/hp-improve/kaizen/2026-09.md:73 | c5e0459cb277 |
| K-684 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:80 | 422f47468ff7 |
| K-685 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:88 | cc23deddf1bf |
| K-686 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:95 | ee3cdcd1d548 |
| K-687 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:106 | f86c1c49c0f1 |
| K-688 | 2026-09-02 | 2026-09-02 | （2026-09-02・blog-loop-ycom / Cycle 083）社長への質問は、出したあとで「自分で解けないか」を定期的に洗い直す | 🙋 | data/hp-improve/kaizen/2026-09.md:119 | 49b6af6afa58 |
| K-689 | 2026-09-03 | 2026-09-03 | （2026-09-03・blog-loop-ycom / Cycle 084）順位の変化を語るときは、同一窓の前後半だけで済ませない — 比較窓が短いと「窓の中にある出来事」に原因を引き寄せてしまう | 🙋 | data/hp-improve/kaizen/2026-09.md:133 | 292d8bcde309 |
| K-689b | 2026-09-02 | 2026-09-02 | （2026-09-02・hp-loop-shigatoyota / Cycle 003）外形監査は「タグの存在」しか見ていない — 実装側の内部確認と突き合わせて初めて事実になる | 🙋 | data/hp-improve/kaizen/2026-09.md:147 | 983d0b29720a |
| K-690 | 2026-09-02 | 2026-09-02 | （2026-09-02・hp-loop-shigatoyota / Cycle 003）🔴 受信箱APIの「0件」を生存確認に使わない — 実際に報告2通を取り逃しかけた | 🙋 | data/hp-improve/kaizen/2026-09.md:163 | 0ab194e13d6e |
| K-692 | 2026-09-02 | partner | （partner・2026-09-02 Cycle 170）hana-tools の期日は UTC で返る＝そのまま読むと1日早くずれる | 🙋 | data/hp-improve/kaizen/2026-09.md:175 | 25fd9e4290bb |
| K-693 | 2026-09-03 | hp-loop ycom Cycle 112 | （hp-loop ycom Cycle 112・2026-09-03）🙋要・社長判断 — 読み取り専用ツールを作れても、許可リストに載らないと動かせない＝「作る権限」と「動かす権限」の非対称 | 🙋 | data/hp-improve/kaizen/2026-09.md:182 | 83b36086bac7 |
| K-695 | 2026-09-03 |  | （hp-loop fujisaka Cycle 080・2026-09-03）社長が「これは騒がなくてよい」と線を引いたら、その日のうちに鳴らす仕組みごと止める | 🙋 | data/hp-improve/kaizen/2026-09.md:199 | 46573f668264 |
| K-696 | 2026-09-03 |  | （hp-loop konjaku Cycle 037・2026-09-03）機序の断定は「観測が変化を捉えられる期間」を超えてから — 3日の不変で「止まっている」と言い切って翌々日に撤回した | 🙋 | data/hp-improve/kaizen/2026-09.md:206 | a849da05cb22 |
| K-697 | 2026-09-03 |  | （hp-loop konjaku Cycle 037・2026-09-03）層で割ると「守るべきもの」と「壊れている場所」が同じ1か所に重なることがある — 移行の危険度は総量でなく層別で測る | 🙋 | data/hp-improve/kaizen/2026-09.md:213 | 59e9ceb73471 |
| K-698 | 2026-09-03 |  | （hp-loop konjaku Cycle 037・2026-09-03）🙋要・社長判断 — 掲示板が 80KB を割れなくなった。堆積ではなく「アクティブな提案20件 × 詳細」という実体で、器の設計を変えないと解けな | 🙋 | data/hp-improve/kaizen/2026-09.md:220 | 9c92ea142aa1 |
| K-699 | 2026-09-03 |  | （hp-loop shigatoyota Cycle 004・2026-09-03）— `ga4-fetch.py cv` の既定イベント名リストが他サイト用のハードコードで、「CVゼロ」と誤報する罠 | 🙋 | data/hp-improve/kaizen/2026-09.md:227 | 318e4183b070 |
| K-700 | 2026-09-03 |  | （hp-loop shigatoyota Cycle 004・2026-09-03）🙋要・社長判断 — 受信箱APIの不具合が「機能の不便」から「最重要の意思決定を取り逃す」段階に進んだ | 🙋 | data/hp-improve/kaizen/2026-09.md:234 | 7a26ea0da36d |
| K-701 | 2026-09-03 | partner Cycle 171 | （partner Cycle 171・2026-09-03）— 「これが残された唯一の場です」と朝礼に書いても、その場では何も起きない。書くべきなのは判定ではなく、貼る1行 | 🙋 | data/hp-improve/kaizen/2026-09.md:241 | e56aeae6f7be |
| K-702 | 2026-09-03 | partner Cycle 171 | （partner Cycle 171・2026-09-03）— 器のローテが「作業として正しく」回っているのに、閾値から遠ざかっている。3サイクル連続で退避量より起票量が多い | 🙋 | data/hp-improve/kaizen/2026-09.md:248 | 21eb816b4819 |
| K-717 | 2026-09-05 |  | （hp-loop yoshida Cycle 082・2026-09-05）🙋要・社長判断 — 台帳のローテが「まるごと退避できるブロック」の在庫に依存しており、次で尽きる | 🙋 | data/hp-improve/kaizen/2026-09.md:257 | 8116e463d7cb |
| K-720 | 2026-09-05 | hp-loop rally Cycle 041 | （hp-loop rally Cycle 041・2026-09-05）— `hp-serp` はホスト単位で重複除外するため `site:` 検索に使えない＝M-15（インデックス有無の切り分け）が全サイトで実行不能 | 🙋 | data/hp-improve/kaizen/2026-09.md:265 | b266c95849d7 |
| K-721 | 2026-09-05 | blog-loop ycom Cycle 086 | （blog-loop ycom Cycle 086・2026-09-05）— 「本文に案内が無い」と書く前に、テンプレ由来と本文由来のリンクを機械で分ける（同型の取り違えが2度目） | 🙋 | data/hp-improve/kaizen/2026-09.md:275 | 92cd921b19d6 |
| K-679b |  |  |  |  | data/hp-improve/kaizen/2026-09.md:287 | 0f7c63aedfc4 |
| K-680b |  |  |  |  | data/hp-improve/kaizen/2026-09.md:293 | 30d63d8130ad |
| K-681b |  |  |  |  | data/hp-improve/kaizen/2026-09.md:298 | 51757dcbb421 |
| K-682b |  |  |  |  | data/hp-improve/kaizen/2026-09.md:303 | b044724431d3 |
| K-683b |  |  |  |  | data/hp-improve/kaizen/2026-09.md:308 | d87740e51003 |
| K-684b |  |  |  |  | data/hp-improve/kaizen/2026-09.md:313 | e396102a2e72 |
| K-685b |  |  |  | 🙋 | data/hp-improve/kaizen/2026-09.md:318 | 23fe9e6648e5 |
| K-726 | 2026-09-06 |  | （hp-loop yoshida Cycle 083・2026-09-06）— 🙋要・社長判断 ｜ 社長の「区分を移せ」というご指示と、在庫を数える機械（🔔 を数える）が正面衝突する | 🙋 | data/hp-improve/kaizen/2026-09.md:325 | 991354868335 |
| K-729 | 2026-09-06 |  | （hp-loop konjaku Cycle 038・2026-09-06）— 解析ペースが3日になったら、「週次＝7日以上で実施」の定石は必ず9日になる | 🙋 | data/hp-improve/kaizen/2026-09.md:337 | 795973e3fa04 |
| K-partner-736 |  |  |  | 🙋 | data/hp-improve/kaizen/2026-09.md:360 | a8398baa2038 |
| K-partner-737 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:367 | 5df80ab40d07 |
| K-partner-738 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:372 | 8aada6481f4f |
| K-partner-739 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:377 | 06c727897e20 |
| K-736 | 2026-09-06 | hp-loop rally Cycle 045 | （hp-loop rally Cycle 045・2026-09-06）相手の道具の失敗を「相手のミス」で閉じない — 自分で同じ道具を使って再現を試す | 🙋 | data/hp-improve/kaizen/2026-09.md:382 | 1ddf3e70ae9e |
| K-738 | 2026-09-06 | hp-loop rally Cycle 046 | （hp-loop rally Cycle 046・2026-09-06）サーバ描画のページは「本文テキスト」だけ見ても検証にならない — 埋め込みデータ層がある | 🙋 | data/hp-improve/kaizen/2026-09.md:406 | eac7589df4f6 |
| K-741 | 2026-09-06 | hp-loop rally Cycle 047 | （hp-loop rally Cycle 047・2026-09-06）サイトが落ちていたら「取れなかった」で終えず、①自分側 ②DNS ③ポート の3点で切り分けてから報告する | 🙋 | data/hp-improve/kaizen/2026-09.md:420 | e3245dda4279 |
| K-742 | 2026-09-07 | overseer | （overseer・2026-09-07 Cycle 075）🙋要・社長判断 — 「読むと決めた」だけでは届かない。起こされる経路が無い器は、週1の cron 分しか目を覚まさない | 🙋 | data/hp-improve/kaizen/2026-09.md:442 | 387f57cf4c67 |
| K-752 | 2026-09-07 | blog-write ycom | （blog-write ycom・2026-09-07）「レビュー用の印」は、置き場所を1つ間違えると本番の文章になる — 見えるか見えないかを目で判定しない | 🙋 | data/hp-improve/kaizen/2026-09.md:449 | 605c8981d25c |
| K-753 | 2026-09-07 | blog-improve ycom | （blog-improve ycom・2026-09-07）「本文に入っているから流用できる」は、描画後の画面だけを見て言ってはいけない — 出どころ（post content か、仕組み側か）まで確かめる | 🙋 | data/hp-improve/kaizen/2026-09.md:462 | 03957af7aa45 |
| K-754 | 2026-09-07 |  | （hp-loop shigatoyota Cycle 008・2026-09-07）「起票からN日」は当事者の努力を消す — 同じ在庫でも「誰にいつ渡したか」で読み方が180度変わる | 🙋 | data/hp-improve/kaizen/2026-09.md:470 | 469f69a23695 |
| K-755 | 2026-09-07 |  | （hp-loop shigatoyota Cycle 008・2026-09-07）「同一ページ内の対照」は、施策を打つ前に原因を切り分けられる最も安い実験 | 🙋 | data/hp-improve/kaizen/2026-09.md:478 | 87a5a84b3c35 |
| K-partner-740 | 2026-09-07 |  | （2026-09-07 partner Cycle 175）「明日は空いている」を一手を倒す根拠にしない | 🙋 | data/hp-improve/kaizen/2026-09.md:486 | 065e7fc5223a |
| K-partner-741 | 2026-09-07 |  | （2026-09-07 partner Cycle 175）ローテの純減がゼロになった＝器の規律は「増やさない」ことしかできていない | 🙋 | data/hp-improve/kaizen/2026-09.md:494 | ee6a7a31eab4 |
| K-756 |  |  |  | 🙋 | data/hp-improve/kaizen/2026-09.md:502 | 3346999ff81d |
| K-757 |  |  |  | 🙋 | data/hp-improve/kaizen/2026-09.md:511 | 4be93f617b82 |
| K-758 |  |  |  | 🙋 | data/hp-improve/kaizen/2026-09.md:520 | 6dd877cee0f1 |
| K-759 | 2026-09-08 | hp-loop rally Cycle 048 | （hp-loop rally Cycle 048・2026-09-08）待ち望んだ数字ほど、出た瞬間に「それは何を数えているか」を別の観測と突き合わせる — ゼロが1になった喜びは検算の動機を弱める | 🙋 | data/hp-improve/kaizen/2026-09.md:531 | d23a344f5353 |
| K-760 | 2026-09-08 | hp-loop rally Cycle 048 | （hp-loop rally Cycle 048・2026-09-08）手動セッションで補助スクリプトが実行できなくても、`sed`/`head`/`tail`/`cat`/`cp` の組み合わせでローテは完遂できる | 🙋 | data/hp-improve/kaizen/2026-09.md:558 | 762167eb23a7 |
| K-761 | 2026-09-08 | 2026-09-08 | （2026-09-08・blog-loop-ycom Cycle 089）実需の判定を「記事側の語」だけで行っていた ― 受け皿ページ側を見れば8週間 早く分かった | 🙋 | data/hp-improve/kaizen/2026-09.md:587 | ffa5e440a36b |
| K-762 | 2026-09-08 | 2026-09-08 | （2026-09-08・blog-loop-ycom Cycle 089）許可リストに無いツールの代わりを「対照実験」で作る | 🙋 | data/hp-improve/kaizen/2026-09.md:601 | b7c5dbc22dfc |
| K-763 | 2026-09-08 | 2026-09-08 | （2026-09-08・hp-loop-shigatoyota Cycle 009）許可が下りない道具は「承認のゆらぎ」と決めつける前に、呼び出しの形を変えて試す | 🙋 | data/hp-improve/kaizen/2026-09.md:613 | 17d5cc1efe3d |
| K-761b | 2026-09-08 | hp-loop rally Cycle 049 | （hp-loop rally Cycle 049・2026-09-08）「索引されているか」は<u>出てきたURLの有無</u>ではなく<u>母集団からの無作為抽出</u>で測る — 上位に何本か出ることは、母集団が入っ |  | data/hp-improve/kaizen/2026-09.md:627 | 6c54617b812f |
| K-762b | 2026-09-08 | hp-loop rally Cycle 049 | （hp-loop rally Cycle 049・2026-09-08）レポート冒頭の時刻表記は `date` で確かめてから書く — 同じ日に複数回走るモードでは、前回の記憶で「夕」と書いてしまう |  | data/hp-improve/kaizen/2026-09.md:635 | c49792251b10 |
| K-764 | 2026-09-09 | hp-loop ycom Cycle 118 | （hp-loop ycom Cycle 118・2026-09-09）「断定できない」と11サイクル書き続けた原因は、対照群に施策対象そのものを混ぜていたこと ― 保留は"慎重さ"の顔をして居座る | 🙋 | data/hp-improve/kaizen/2026-09.md:644 | 9fb18fc8795e |
| K-765 | 2026-09-09 | hp-loop ycom Cycle 118 | （hp-loop ycom Cycle 118・2026-09-09）内部の台帳が正しくても、掲示板の要約行が古ければ社長には誤報として届く ― 正本と要約の二層構造では、要約側に消し込み漏れが溜まる | 🙋 | data/hp-improve/kaizen/2026-09.md:653 | 1e2ac114b3eb |
| K-766 | 2026-09-09 |  | （hp-loop yoshida Cycle 086・2026-09-09）「ツールが動かない」と5回報告し社長へ設定変更まで依頼したが、真因は自分の呼び出し形の誤りで、正しい形は自分の台帳に最初から書いてあった | 🙋 | data/hp-improve/kaizen/2026-09.md:662 | 0392be19a2f2 |
| K-767 | 2026-09-09 |  | （hp-loop fujisaka Cycle 082・2026-09-09）解析ペースが3日になったため「週次」定石が実質隔週へ伸びていた／前倒しで回したら、その1回が当サイクル最大の成果を出した | 🙋 | data/hp-improve/kaizen/2026-09.md:672 | 5118e39c7c35 |
| K-768b | 2026-09-09 |  | （hp-loop konjaku Cycle 039・2026-09-09）平均掲載順位の悪化は「層構成の変化＝希釈」を先に疑ってから「順位が下がった」と言う |  | data/hp-improve/kaizen/2026-09.md:683 | 2d5dea7c27ff |
| K-769 | 2026-09-09 |  | （hp-loop konjaku Cycle 039・2026-09-09）「見立て」が3サイクル以上揺れたら、それは新事実ではなく観測間隔が現象の周期に足りていないサイン |  | data/hp-improve/kaizen/2026-09.md:691 | ec9b88db660b |
| K-770 | 2026-09-09 |  | （hp-loop konjaku Cycle 039・2026-09-09）「全部そろってから」型のブロッカーは、影響量で層別に数え直すと部分的に解けることがある | 🙋 | data/hp-improve/kaizen/2026-09.md:699 | 719a468c8c97 |
| K-771 | 2026-09-09 |  | （hp-loop konjaku Cycle 039・2026-09-09）台帳ローテは「ブロック単位」でなく「前サイクルの記帳量以上」で退避量を決める |  | data/hp-improve/kaizen/2026-09.md:708 | 11c08b9df357 |
| K-772 | 2026-09-09 |  | （hp-loop konjaku Cycle 039・2026-09-09）🙋 カイゼン台帳本体が 695KB＝トリップワイヤ 100KB の約7倍で、退避が長期間止まっている | 🙋 | data/hp-improve/kaizen/2026-09.md:716 | 36c0e0f53938 |
| K-773 | 2026-09-09 |  | （hp-loop shigatoyota Cycle 010・2026-09-09）サンプリング＋短窓のデータで「N回連続ゼロ」を根拠に原因を断定しない |  | data/hp-improve/kaizen/2026-09.md:724 | 51cbe8c1ccf6 |
| K-774 | 2026-09-09 |  | （hp-loop shigatoyota Cycle 010・2026-09-09）効果測定の窓を共有する提案は、起票時に「片方ずつ反映」と書く |  | data/hp-improve/kaizen/2026-09.md:733 | f875eb187f6c |
| K-775 | 2026-09-09 |  | （hp-loop shigatoyota Cycle 010・2026-09-09）「次回は◯◯で見られる」という申し送りは、実現可能性を確かめてから書く |  | data/hp-improve/kaizen/2026-09.md:740 | 1a80e28b57d7 |
| K-764b | 2026-09-09 | blog-loop-ycom | （blog-loop-ycom / Cycle 090・2026-09-09）散らばりの検査だけでは、ペースが一定の機械を通してしまう |  | data/hp-improve/kaizen/2026-09.md:747 | dbac610f7762 |
| K-765b | 2026-09-09 | partner | （partner / Cycle 177・2026-09-09）掲示板と Slack が別工程で、片方だけ落ちても誰も気づかない |  | data/hp-improve/kaizen/2026-09.md:754 | 9a0a2bcd4b1c |
| K-766b | 2026-09-09 | partner | （partner / Cycle 177・2026-09-09）🙋要・社長判断 — 見えない経路がある以上、「未着手かどうか」に賭けない一手を選ぶ | 🙋 | data/hp-improve/kaizen/2026-09.md:760 | 70dd15f19043 |
| K-767b | 2026-09-09 |  | （hp-prospect ×2件同時再現・2026-09-09）— hp-shot.sh の出力先制限が /hp-prospect の手順と不整合 |  | data/hp-improve/kaizen/2026-09.md:766 | 5ddaacee8d4e |
| K-776 | 2026-09-10 | hp-loop ycom Cycle 119 | （hp-loop ycom Cycle 119・2026-09-10）「掲示板の誤記を直した」で終えると、正本（台帳）の同じ誤記が残る |  | data/hp-improve/kaizen/2026-09.md:770 | 8e9ce9959a86 |
| K-777 | 2026-09-10 | hp-loop ycom Cycle 119 | （hp-loop ycom Cycle 119・2026-09-10）「次サイクルでスタブを置いて補完」は再発防止ではない（K-697 の再発） |  | data/hp-improve/kaizen/2026-09.md:776 | e6f9623b14ae |
| K-779 | 2026-09-10 |  | （hp-loop yoshida Cycle 087・2026-09-10）未点検ページの実査は「新規Rを探す作業」ではなく「既存Rの誤りを潰す作業」でもある |  | data/hp-improve/kaizen/2026-09.md:792 | 79f25a81027e |
| K-780 | 2026-09-10 |  | （hp-loop yokohawaii Cycle 073・2026-09-10）独立2手段の「一致」は、両方が同じ性質の道具なら確証にならない |  | data/hp-improve/kaizen/2026-09.md:799 | c198e74c24c6 |
| K-781 | 2026-09-10 |  | （hp-loop yokohawaii Cycle 073・2026-09-10）台帳・掲示板の圧縮で実際にバイトが減るのは「削除」だけで、「言い換え」はほぼ長さ中立 |  | data/hp-improve/kaizen/2026-09.md:808 | 35875573fd80 |
| K-782 | 2026-09-10 | blog-loop ycom Cycle 091 | （blog-loop ycom Cycle 091・2026-09-10）🙋要・社長判断　掲示板（spec）に確定を書いても、**毎サイクル冒頭で読む正本（ルール本体）が古いまま**なら、誤った前提から毎朝 出発する | 🙋 | data/hp-improve/kaizen/2026-09.md:819 | 96a3f0119e7e |
| K-783 | 2026-09-10 | blog-loop ycom Cycle 091 | （blog-loop ycom Cycle 091・2026-09-10）「自分は間違えていた」と書く前に、**自分の確定台帳を先に読む**——自己批判も、裏を取らないと誤報になる |  | data/hp-improve/kaizen/2026-09.md:826 | f0f96a0b0f76 |
| K-784 | 2026-09-10 | blog-loop ycom Cycle 091 | （blog-loop ycom Cycle 091・2026-09-10）「通らない」と書いたコマンドは、**引数の形を1回だけ変えて再試行する**（bash 前置ギャップの第2形） |  | data/hp-improve/kaizen/2026-09.md:833 | 5573a3a2196a |
| K-partner-700 | 2026-09-10 |  | （2026-09-10 partner Cycle 178）「答えは手元にあるのに渡していない」を一手の探索対象に加える |  | data/hp-improve/kaizen/2026-09.md:849 | 9a84a684f4bd |
| K-partner-701 | 2026-09-10 |  | （2026-09-10 partner Cycle 178）外注・協力会社の「◯時まで対応可能」を5枚目の突合対象にする |  | data/hp-improve/kaizen/2026-09.md:854 | 522538bc60da |
| K-partner-702 | 2026-09-10 |  | （2026-09-10 partner Cycle 178）数え方が確立していない指標は、前回と同じ名前で出さない | 🙋 | data/hp-improve/kaizen/2026-09.md:858 | 1516850b0ef1 |
| K-786 | 2026-09-11 | hp-loop ycom Cycle 120 | （hp-loop ycom Cycle 120・2026-09-11）**「自社ページに検索語が無い」と書く前に、自社ページを取り直す**＝SERP の fold に自社が居ないと、競合の title だけを見て自社を断定 | 🙋 | data/hp-improve/kaizen/2026-09.md:863 | d71853407cc8 |
| K-788 | 2026-09-11 |  | （hp-loop shigatoyota Cycle 012・2026-09-11）**「404 だったものが 200 になった」を「設置された」と読まない＝中身を見るまで完了にしない。curl が使えなくても Chrom | 🙋 | data/hp-improve/kaizen/2026-09.md:878 | aee3ac4de493 |
| K-790 | 2026-09-12 | hp-loop ycom Cycle 121 | （hp-loop ycom Cycle 121・2026-09-12）**「承認外」と2サイクル記録した週次レシピ2本は、`bash` を前置していただけだった＝「できない」と書く前に別の呼び出し形を1回試す** | 🙋 | data/hp-improve/kaizen/2026-09.md:895 | ce8a21eef519 |
| K-791 | 2026-09-12 |  | （hp-loop yoshida Cycle 089・2026-09-12）**「当ループでは解けない」は〈同一条件下での話〉であって永久命題ではない＝依存しているツールが更新されたら、1回だけ再試行する** | 🙋 | data/hp-improve/kaizen/2026-09.md:906 | c1e8a0292c32 |
| K-792 | 2026-09-12 |  | （hp-loop yoshida Cycle 089・2026-09-12）**Step 5 は index を先に書き、archive への移設を後にする＝時間切れで落ちてよいのは倉庫側であって、社長が見る面ではない** | 🙋 | data/hp-improve/kaizen/2026-09.md:915 | c07d53221271 |
| K-793 | 2026-09-12 |  | （hp-loop yoshida Cycle 089・2026-09-12）**「archive へ移設した」と書いたら、同じサイクル内で grep して本文が消えているか機械確認する＝宣言と実装の食い違いは12サイクル生 | 🙋 | data/hp-improve/kaizen/2026-09.md:924 | 028c2798b7ba |
| K-794 | 2026-09-12 |  | （hp-loop fujisaka Cycle 083・2026-09-12）**ページ集計の「改善」は、北極星クエリ単体の「後退」を隠す＝M-01 の"良い方向の誤読"版。効果検証の直前に `query-pages` を | 🙋 | data/hp-improve/kaizen/2026-09.md:933 | 82767a316626 |
| K-795 | 2026-09-12 |  | （hp-loop fujisaka Cycle 083・2026-09-12）**掲示板 80KB 超過は「堆積」ではなく「在庫件数 × 根拠」の構造＝K-698 の社長ご判断がないと解けない段階に入った（2サイクル連続で |  | data/hp-improve/kaizen/2026-09.md:941 | dffd8f775277 |
| K-796 | 2026-09-13 | hp-loop rally Cycle 050 | （hp-loop rally Cycle 050・2026-09-13）**`ga4-fetch.py` の `landing`/`sources` は ycom 既定のCVイベント名（問い合わせ・見積り 等）で `cv_ |  | data/hp-improve/kaizen/2026-09.md:948 | e1d50ad2edd3 |
| K-797 | 2026-09-13 | hp-loop rally Cycle 050 | （hp-loop rally Cycle 050・2026-09-13）**掲示板・台帳の「一括載せ替えスクリプト」は無人セッションで実行承認が下りない＝ローテ手順を1本のスクリプトに頼る設計にしない** | 🙋 | data/hp-improve/kaizen/2026-09.md:955 | 12885a4e3cf6 |
| K-769b | 2026-09-12 | hp-loop konjaku | （hp-loop konjaku・2026-09-12 Cycle 040）「固有」と「一意」を取り違えると、根拠の"説明"だけが間違ったまま2サイクル持ち回られる |  | data/hp-improve/kaizen/2026-09.md:961 | 67ca5651b8af |
| K-770b | 2026-09-12 | hp-loop konjaku | （hp-loop konjaku・2026-09-12 Cycle 040）解析ペース3日では「前回比」が必ず窓の重なりを生む＝2サイクル前と比べれば非重複にできる |  | data/hp-improve/kaizen/2026-09.md:968 | 76592c903750 |
| K-771b | 2026-09-12 | hp-loop konjaku | （hp-loop konjaku・2026-09-12 Cycle 040）🙋要・社長判断：台帳ローテの目標量は「平均」でなく「最大」で見積もる／それでも4サイクル連続で後手になっている | 🙋 | data/hp-improve/kaizen/2026-09.md:974 | 2d51b52959fa |
| K-772b | 2026-09-12 | hp-loop konjaku | （hp-loop konjaku・2026-09-12 Cycle 040）「うまくいっている層は守れている」は検証していない思い込みになりやすい |  | data/hp-improve/kaizen/2026-09.md:980 | 690ecb99344a |
| K-796b | 2026-09-12 | 2026-09-12 | （2026-09-12・blog-loop-ycom Cycle 092）新しいデータを探す前に、すでに許可されている `bin/` を棚卸しする |  | data/hp-improve/kaizen/2026-09.md:986 | 84591ae9cb0d |
| K-797b | 2026-09-12 | 2026-09-12 | （2026-09-12・hp-loop-shigatoyota Cycle 013）「先方に聞かないと分からない」と書いた前提は、まず実物を見て潰す |  | data/hp-improve/kaizen/2026-09.md:995 | 5b6457f096f4 |
| K-798 | 2026-09-12 | 2026-09-12 | （2026-09-12・hp-loop-shigatoyota Cycle 013）低頻度イベントの「N回連続ゼロ」は、分母と期待値を置いてから数える |  | data/hp-improve/kaizen/2026-09.md:1003 | b7922d9f471f |
| K-799 | 2026-09-12 | 2026-09-12 | （2026-09-12・hp-loop-shigatoyota Cycle 013）🙋要・社長判断｜台帳のローテは「本文圧縮」まで行っても上限に届かない＝分割以外に手が無い | 🙋 | data/hp-improve/kaizen/2026-09.md:1012 | 60a4f49a5849 |
| K-800 | 2026-09-12 | overseer | （overseer・2026-09-12・Cycle 078）配管は「件数」でなく「中身」を1件開ける |  | data/hp-improve/kaizen/2026-09.md:1019 | a2433288a9f1 |
| K-801 | 2026-09-13 | hp-loop ycom Cycle 122 | （hp-loop ycom Cycle 122・2026-09-13）「移送」と称して同じ分量の要約を書き戻すと、台帳は縮まない＝量ではなくスキーマの問題 | 🙋 | data/hp-improve/kaizen/2026-09.md:1029 | 783ce1c66213 |
| K-802 | 2026-09-13 | hp-loop ycom Cycle 122 | （hp-loop ycom Cycle 122・2026-09-13）効果窓を「0 → 発生」で置くと、着手前に baseline 側で成立して壊れる |  | data/hp-improve/kaizen/2026-09.md:1053 | 99ed0fdc7b6d |
| K-803 | 2026-09-13 |  | （hp-loop yokohawaii Cycle 074・2026-09-13）閾値超えが「編集で痩せない」段階に入ったら、全文を無改変コピーに逃がしてから現状だけで書き直す | 🙋 | data/hp-improve/kaizen/2026-09.md:1072 | f58b64cb4bc4 |
| K-804 | 2026-09-13 | blog-loop ycom Cycle 093 | （blog-loop ycom Cycle 093・2026-09-13）K-803 の2例目＋「提案を積む前に、同型の稼働中施策の結果を先に見る」 | 🙋 | data/hp-improve/kaizen/2026-09.md:1084 | 2a1a8ceea1f9 |
| K-805 | 2026-09-13 |  | （hp-loop shigatoyota Cycle 014・2026-09-13）「0クリック」は人間の検索とは限らない／共有ツールを直したら、各レーンの手順書に残る回避策も書き換える |  | data/hp-improve/kaizen/2026-09.md:1095 | cfe7519a355d |
| K-806 | 2026-09-13 | partner Cycle 181 | （partner Cycle 181・2026-09-13）先方が置いた日付は「⚠️滞り」欄に置くと7日間 誰も拾わない | 🙋 | data/hp-improve/kaizen/2026-09.md:1105 | dc6d0ac452aa |
| K-807 | 2026-09-14 | overseer | （overseer・2026-09-14 Cycle 079）計測の警報を転記する前に、「その計測が区切りに使っている書式」を台帳の実物と照合する |  | data/hp-improve/kaizen/2026-09.md:1111 | 3c3a20cc956a |
| K-808 | 2026-09-14 |  | （hp-loop yoshida Cycle 090・2026-09-14）自分で置いた「3例目で提案」の発火と、北極星テスト（測れる窓）がぶつかったら、提案を「検出＝解析側の作業／修正＝既存の束」に分解する |  | data/hp-improve/kaizen/2026-09.md:1115 | ba8d4a2bcd40 |
| K-809 | 2026-09-14 | hp-loop rally Cycle 051 | （hp-loop rally Cycle 051・2026-09-14）相手から「定義」を受け取ったら、その定義で最初に数えた数字を、もう1つの軸で割って矛盾が無いか確かめてから使う | 🙋 | data/hp-improve/kaizen/2026-09.md:1120 | 1e87dedaa87c |
| K-810 | 2026-09-14 | blog-loop ycom Cycle 094 | （blog-loop ycom Cycle 094・2026-09-14）「カニバリ注意」は相手の本文の見出しを実物で並べてから書く／受け皿の順位の段差は週まで割って他ループの作業日と突き合わせる |  | data/hp-improve/kaizen/2026-09.md:1126 | 0972750bc3a2 |
| K-811 | 2026-09-14 | blog-write ycom | （blog-write ycom・2026-09-14）「そのまま貼れます」の文案も、貼る前に対象記事の本文と1語ずつ突き合わせる |  | data/hp-improve/kaizen/2026-09.md:1132 | cb36e4430c7e |
| K-812 | 2026-09-14 | partner Cycle 182 | （partner Cycle 182・2026-09-14）無人の partner では `todo-brief.py outside`・`calendar-fetch.py show`・絶対パスの `hana-api.s | 🙋 | data/hp-improve/kaizen/2026-09.md:1137 | 97f72a2d8077 |
| K-813 | 2026-09-14 | overseer Cycle 080 | （overseer Cycle 080・2026-09-14）「修正しました」の報告を受けたら、コードで確認するだけで閉じない＝修正で「失敗になった呼び出し元」が次に動くまで、本当に直ったかは分からない |  | data/hp-improve/kaizen/2026-09.md:1142 | e8d8bf743d33 |
| K-814 | 2026-09-15 | overseer Cycle 081 | （overseer Cycle 081・2026-09-15）修正を受理するときは「実害が出た経路」と「修正が入った経路」を1件ずつ突き合わせる＝同じ欠陥の兄弟（同じファイルの別コマンド・配布版コピー）を grep で洗う |  | data/hp-improve/kaizen/2026-09.md:1146 | 046e569b0029 |
| K-815 | 2026-09-15 |  | （hp-loop fujisaka Cycle 084・2026-09-15）28日窓の CV 実数が帯を割ったら、評価の前に「窓から抜けた日・入った日」の実数を割る＝特異日（お盆明け・連休明け）の出入りで単窓差が説明でき |  | data/hp-improve/kaizen/2026-09.md:1150 | 21addc7bb9a9 |
| K-816 | 2026-09-15 |  | （hp-loop fujisaka Cycle 084・2026-09-15）固定窓クロスチェック（#10）の結果でも「構成比（増分の何%がこのページ）」は1窓で強く書かない＝窓の選び方で突出の大きさが大きく変わる |  | data/hp-improve/kaizen/2026-09.md:1154 | 8a15baa00f64 |
| K-817 | 2026-09-15 |  | （hp-loop konjaku Cycle 041・2026-09-15）ドメイン移行中の層別分析は「旧に同じページがあるか」でもう1段割る＝同じタイトル・同じ層でも、重複の有無で成績が2倍以上違うことがある |  | data/hp-improve/kaizen/2026-09.md:1158 | 7cf8b30e7a58 |
| K-818 | 2026-09-15 | blog-loop ycom Cycle 095 | （blog-loop ycom Cycle 095・2026-09-15）文言修理（B）を起こす記事は、本文を全文読んで「記事が教えていること」を記事自身が守っているか1回照合する＝自己言及チェック |  | data/hp-improve/kaizen/2026-09.md:1162 | 2e041a1b3e3b |
| K-819 | 2026-09-15 |  | （hp-loop shigatoyota Cycle 015・2026-09-15）「解決」報告を当方の間接証拠（データが取れる）で閉じない＋アイコン付きの番号は種別を確かめてから数える |  | data/hp-improve/kaizen/2026-09.md:1166 | a72ff1901bc0 |
| K-partner-742 |  |  |  |  | data/hp-improve/kaizen/2026-09.md:1171 | b8b6a3f93e4f |
| K-partner-743 |  |  |  | 🙋 | data/hp-improve/kaizen/2026-09.md:1174 | a935a0e95539 |
| K-820 |  | hp-loop:ycom | ga4-fetch の既定CVリストは採用応募を含む＝流入元比較で採用CVを営業CVと誤読した（Cycle 122「ChatGPT 経由 CV率23倍」は8件中7件が採用・提携応募）（hp-loop:ycom・202 |  | data/hp-improve/kaizen/2026-09.md:1177 | b119b9348771 |
| K-821 |  | hp-loop:ycom | 🙋要・社長判断 「開発側の作業待ち」と書く前に、実装担当が受信箱を取りに来ているかを見る（web-hanasaka は 09-04 以降13通未取得＝10サイクル気づかず）（hp-loop:ycom・2026-09- | 🙋 | data/hp-improve/kaizen/2026-09.md:1183 | e527dea6c7a8 |
| K-822 | 2026-09-16 | hp-loop:yoshida | 件数の少ない広告検索語（指名語）を28日窓の zero-conv で「CV0」と5回書いた＝90日窓では最良CPA帯だった（hp-loop:yoshida・2026-09-16） |  | data/hp-improve/kaizen/2026-09.md:1190 | c0671f29b5df |
| K-823 | 2026-09-16 | hp-loop:yokohawaii | 判定条件を avg_position の閾値で書くと、表示回数の急増や同一クエリ内の別URL併走で意味が揺れる（hp-loop:yokohawaii・2026-09-16） |  | data/hp-improve/kaizen/2026-09.md:1195 | 80e97b6470de |
| K-824 | 2026-09-16 | blog-loop | ブログ全記事の本文を語で探す読み取り道具が無い＝事実誤りの横点検が「見つかった分」止まり（blog-loop・2026-09-16） |  | data/hp-improve/kaizen/2026-09.md:1199 | 72fc7c84f2db |
| K-825 | 2026-09-16 | hp-loop:shigatoyota | 受領確認は「登録されたR番号」と「送ったR番号」を全件突き合わせる（hp-loop:shigatoyota・2026-09-16） |  | data/hp-improve/kaizen/2026-09.md:1205 | 8d5c23ac262b |
| K-826 | 2026-09-16 | hp-loop:shigatoyota | 週次の競合対比が「競合URLが台帳に無い＋ヘッドレスで検索不可」で止まる（hp-loop:shigatoyota・2026-09-16） |  | data/hp-improve/kaizen/2026-09.md:1209 | 9ff2af9b4a94 |
| K-827 | 2026-09-16 | partner | 予定×用件の突合に、対面予定のクライアントの解析掲示板（本番反映の停滞・未回答Q）を含める（partner・2026-09-16） | 🙋 | data/hp-improve/kaizen/2026-09.md:1213 | ada46c1b49be |
| K-828 | 2026-09-17 | hp-loop:yoshida | 共通テンプレ部分の誤字は --text 点検で読み飛ばされる（駐車場25完備を7ページ点検後に初検出）（hp-loop:yoshida・2026-09-17） |  | data/hp-improve/kaizen/2026-09.md:1217 | bae0633ec7f9 |
| K-829 | 2026-09-17 | hp-loop:fujisaka | 実装担当の「反映経路」（静的FTP／WP管理画面など）を台帳で持ち、Rごとに経路を付ける（hp-loop:fujisaka・2026-09-17） |  | data/hp-improve/kaizen/2026-09.md:1222 | 847e3997ca3e |
| K-830 | 2026-09-17 | hp-loop:rally | 3日ペースでは週次定石が「7日以上」判定で最大2日遅れる（rally #14 が 9/15 期日→9/17 実施）（hp-loop:rally・2026-09-17） |  | data/hp-improve/kaizen/2026-09.md:1227 | 325121fbe1c6 |
| K-831 | 2026-09-17 | blog-loop | 公開前の完成原稿も、自社の既存記事・サービスページと照合してから次の候補に置く（blog-loop・2026-09-17） |  | data/hp-improve/kaizen/2026-09.md:1232 | ec36c8005d9a |
| K-832 | 2026-09-17 | partner | 無人の partner で hana-api.sh todos が承認要になり ToDo 件数・期日が取れなかった（partner・2026-09-17） | 🙋 | data/hp-improve/kaizen/2026-09.md:1237 | 7cc1cd4aa89d |
| K-833 | 2026-09-18 | hp-loop:fujisaka | hp-audit --text の12,000字上限で「本文が読めない」ことを「未対応の証拠」と取り違えない（hp-loop:fujisaka・2026-09-18） |  | data/hp-improve/kaizen/2026-09.md:1240 | 6ae32b02d363 |
| K-835 | 2026-09-18 | partner | 対策の一覧を書いたら、その下に「真因に効くのはどれか」を1行書く（無ければ「無い」と書く）（partner・2026-09-18） | 🙋 | data/hp-improve/kaizen/2026-09.md:1267 | db64308fc87b |
| K-836 | 2026-09-19 | hp-loop:ycom | GSC pages JSON の集計は jq で行う（一時 .py の実行は承認外）（hp-loop:ycom・2026-09-19） |  | data/hp-improve/kaizen/2026-09.md:1279 | 1e06dba3ab3a |
| K-837 | 2026-09-19 | hp-loop:yoshida | 広告の日次監視は summary(7日合計) だけでは急減を2日遅れで見逃す＝daily の直近2日を必ず見る（hp-loop:yoshida・2026-09-19） |  | data/hp-improve/kaizen/2026-09.md:1284 | f52862beee25 |
| K-838 | 2026-09-19 | blog-loop | blog-loop Step 0 で「前回の回が途中で止まったか」を機械で見る（archive の最新 id と index の最新 id の突き合わせ）（blog-loop・2026-09-19） |  | data/hp-improve/kaizen/2026-09.md:1289 | 5af12ce41830 |
| K-839 | 2026-09-19 | hp-loop:shigatoyota | 「記録に無い」と断定する前に検索語を変えて2回引く（競合URLは spec にあったのに C016 で grep 0件と誤断）（hp-loop:shigatoyota・2026-09-19） |  | data/hp-improve/kaizen/2026-09.md:1295 | 7d47405cc2c0 |
| K-840 | 2026-09-19 | partner | 🙋要・社長判断 partner 無人実行で hana-api todos 読み取りが3サイクル連続で承認要＝件数・期日が出せない（partner・2026-09-19） | 🙋 | data/hp-improve/kaizen/2026-09.md:1300 | c1b5bdf69caa |
| K-841 | 2026-09-20 | hp-loop:yoshida | CV経路の切り分けは reservation 単独で sources を割る（tel 混合は読み違える）（hp-loop:yoshida・2026-09-20） |  | data/hp-improve/kaizen/2026-09.md:1303 | 4b9e3a601fc4 |
| K-842 | 2026-09-20 | hp-loop:rally | GA4 の params で page_location を見ると計測URLに載った秘密（認証トークン等）を検出できる＝北極星イベントの初計測時は発火URLも必ず見る（hp-loop:rally・2026-09-20 |  | data/hp-improve/kaizen/2026-09.md:1307 | ea4d7c61d161 |
| K-843 | 2026-09-20 | blog-loop | blog-loop: 完成原稿の【要・社長確認】は公開ページ側が後から答えていることがある＝照合時に料金・FAQページの文言で1問ずつ引く（blog-loop・2026-09-20） |  | data/hp-improve/kaizen/2026-09.md:1313 | ed70fbb5b714 |
| K-844 | 2026-09-20 | partner | 台帳の 70KB トリップワイヤと「未完了は本体に残す」規律が両立していない（13サイクル連続超過）（partner・2026-09-20） | 🙋 | data/hp-improve/kaizen/2026-09.md:1318 | 3551e2fa478c |
| K-845 | 2026-09-20 | hp-loop:rally | 「存在しない」の証明に ls｜tail を使って誤り、訂正メールを出した（順序を明示したコマンドで取り直す）（hp-loop:rally・2026-09-20） |  | data/hp-improve/kaizen/2026-09.md:1336 | 09d360246890 |
| K-846 | 2026-09-20 | hp-loop:rally | 「0件だと思う」と言ってきた相手にこそ実測を返す（先方の前提ごと検査する）（hp-loop:rally・2026-09-20） |  | data/hp-improve/kaizen/2026-09.md:1359 | 5780f00bbc7d |
| K-847 | 2026-09-21 | overseer | 報告の「静か＝故障」を、道具が成功時に何を書く設計かで裏取りしてから受ける（overseer・2026-09-21） | 🙋 | data/hp-improve/kaizen/2026-09.md:1383 | 922d4cf51492 |
| K-848 | 2026-09-21 | hp-loop:fujisaka | リンクの到達性はタグ実査にもスクショにも映らない＝週次ビジュアルと --links 全数走査をセットにする（hp-loop:fujisaka・2026-09-21） |  | data/hp-improve/kaizen/2026-09.md:1394 | 95f553449807 |
| K-849 | 2026-09-21 | hp-loop:konjaku | 幅（自然変動）を n=5 で確定させない＝短い窓の幅を合否基準にする前に「窓長を変えて測り直す」（hp-loop:konjaku・2026-09-21） |  | data/hp-improve/kaizen/2026-09.md:1417 | e04ef9bb4530 |
| K-850 | 2026-09-21 | hp-loop:konjaku | 🙋要・社長判断 gsc-layer.py / sitemap-count.py の許可リスト未登録が18サイクル連続＝本日は4通りの層別集計を全部手作業でやった（hp-loop:konjaku・2026-09-21） | 🙋 | data/hp-improve/kaizen/2026-09.md:1447 | 40361f23a193 |
| K-851 | 2026-09-21 | blog-loop | 完成原稿の公開前照合は、自社サイトの営業ページと共通フッタまで広げる（社長への確認が減る）（blog-loop・2026-09-21） |  | data/hp-improve/kaizen/2026-09.md:1464 | cbe23c5bc5e1 |
| K-852 | 2026-09-21 | blog-write | 完成原稿は正本とプレビューで本文を二重持ち＝改訂のたびに同じ編集を2回している（blog-write・2026-09-21） |  | data/hp-improve/kaizen/2026-09.md:1471 | 4399a1da03aa |
| K-853 | 2026-09-21 | blog-improve | K-660の点検コマンドが grep -o で行を切るため誤検知する（切らずに読む）（blog-improve・2026-09-21） |  | data/hp-improve/kaizen/2026-09.md:1483 | e1b26107a56c |
| K-854 | 2026-09-21 | partner | 同じ督促を2日続けるなら「相手がいつ読むか」を根拠にする＝連休は督促の理由を作り直せる（partner・2026-09-21） |  | data/hp-improve/kaizen/2026-09.md:1502 | 870c9354cfdd |
| K-855 | 2026-09-21 | partner | 🙋要・社長判断 社長が「器の問題にするな」と仰った論点を18日間 朝礼に出し続けていた＝ご指示の撤回条件を行に持つ（partner・2026-09-21） | 🙋 | data/hp-improve/kaizen/2026-09.md:1515 | 1ff9027905bb |
| K-856 | 2026-09-21 | hp-loop:rally | hp-serp の site: は1ページ目（最大10件）しか返さない＝そこから出した本数は下限値。層の本数は1本ずつ site:＋GSC 表示ありで数える（hp-loop:rally・2026-09-21） |  | data/hp-improve/kaizen/2026-09.md:1528 | 3ae6a6c22e5d |
| K-857 |  |  | ツール由来の「異常なし」は、そのページにタグが入っていることを確かめてから言う（/service/web/ は Clarity 未設置なのに Cycle 118 が operate/ を「Clarity で故障なし」 |  | data/hp-improve/kaizen/2026-09.md:1534 | 125a1cf43dab |
| K-858 | 2026-09-22 | blog-loop | 公開前照合の相手に「WP内の未公開の改善版下書き」を足す（8363×T-008/T-011 の重なりを見落としていた）（blog-loop・2026-09-22） |  | data/hp-improve/kaizen/2026-09.md:1541 | 5e984afd77df |
| K-859 | 2026-09-22 | new | hp-loop: 「返事なし」の前に自分の送信が読まれたか（new/ 残存）と、別セッションが出したクライアントレポートを確かめる（hp-loop:shigatoyota・2026-09-22） |  | data/hp-improve/kaizen/2026-09.md:1545 | 4d4e8070b12b |
| K-860 | 2026-09-22 | partner | partner Step 0 に board 決定台帳（decisions.md）の差分確認が無い＝決定が翌朝に効かない（partner・2026-09-22） | 🙋 | data/hp-improve/kaizen/2026-09.md:1551 | 66865b441d6f |
| K-861 | 2026-09-22 | sed -i | archive 先頭への節の挿入に安全な道具が無い（sed -i・複数 -e は許可外）（hp-loop:konjaku・2026-09-22） | 🙋 | data/hp-improve/kaizen/2026-09.md:1559 | f5315627950b |
| K-862 | 2026-09-23 | hp-loop:rally | mailbox の --body-file 誤用が送信側（rally-dev）で再発＝受信側でも本文が「--」で始まる通を検知したい（hp-loop:rally・2026-09-23） | 🙋 | data/hp-improve/kaizen/2026-09.md:1565 | 5f744e72ebee |
| K-863 | 2026-09-23 | hp-loop:yoshida | ads-fetch は「コンバージョン」列（プライマリのみ）しか見ない＝セカンダリの電話計測を測れない（hp-loop:yoshida・2026-09-23） |  | data/hp-improve/kaizen/2026-09.md:1571 | af8fe6d8a39d |
| K-864 | 2026-09-23 | hp-loop:rally | 同日2回目の定期起動（反応サイクル直後の cron）は数字を引き直さず、期日が近い週次を前倒しする（hp-loop:rally・2026-09-23） | 🙋 | data/hp-improve/kaizen/2026-09.md:1576 | 071e20f89734 |
| K-865 | 2026-09-23 | blog-loop | blog-loop: 公開前チェックが「リンクを約束する見える文＋リンク本体はコメント内」を素通りする（8365で2件）（blog-loop・2026-09-23） |  | data/hp-improve/kaizen/2026-09.md:1581 | dac780a5829f |
| K-866 | 2026-09-23 | partner | partner が mailbox local-send の送り主として許可されていない（partner.md の制約表と実装が食い違い）（partner・2026-09-23） |  | data/hp-improve/kaizen/2026-09.md:1587 | 012d5d4dffbf |
| K-867 | 2026-09-23 | partner | board 決定の「追補」を読み落として、誤った一手を2日続けた（学び(70) の再発）（partner・2026-09-23） |  | data/hp-improve/kaizen/2026-09.md:1593 | 7bcdd13d718c |
| K-605 |  |  | 「最後のステップ」は重い日に落ちる。落ちても気づけないなら順序を変える（hp-loop rally C028） |  | data/hp-improve/kaizen/undated.md:3 | 76f96b6b980b |
| K-606 |  |  | 新しい道具・新しい測り方は、本番の前に「答えを知っている統制群」で当てる（hp-loop rally C028） |  | data/hp-improve/kaizen/undated.md:12 | c28240dde068 |
| K-607b |  |  | 🙋要・社長判断 — 共有台帳 `skill-kaizen.md` が 263KB＝トリップワイヤ(100KB)の2.6倍（hp-loop rally C028） | 🙋 | data/hp-improve/kaizen/undated.md:20 | ab3949d7bc3b |
