# スキルシート データ（ソース・オブ・トゥルース）

スキルシートHTMLは **このフォルダの JSON が正**。HTMLは生成物なので直接編集しない。

## 編集フロー

1. `data/skill-sheets/<id>.json` を編集（スキルの追加・修正・削除）
2. 再生成：

   ```bash
   python3 bin/build-skills.py <id>      # 例: python3 bin/build-skills.py pc-skills
   python3 bin/build-skills.py           # 引数なしで全シート再生成
   ```

3. `site/business/skill-sheet/<id>.html` が上書きされる → ブラウザ確認

## 生成器が自動でやること（手作業しなくてよい）

- **並べ替え**：各グループ内のスキルを重要度 A→B→C 順にソート（同ランク内は記載順を保持）
- **項目数**：各グループ見出しの「（N項目）」を自動計算
- **集計表**：A/B/C・小計・オプション数・総数を自動算出
- **トークン置換**：`reviewPoints` / `totalsNote` 中の `{A} {B} {C} {SUBTOTAL} {OPTION} {TOTAL}` を算出値に差し替え（件数を本文に書いても陳腐化しない）

なので JSON にスキルを足すときは **好きな位置に rank 付きで1行追加するだけ**。順序も件数も気にしなくてよい。

## JSON の構造（pc-skills.json 参照）

- `groups[].skills[]` … 評価対象スキル `{ "rank": "A"|"B"|"C", "text": "..." }`
- `optionGroups[].skills[]` … オプション（O）。文字列の配列
- `text` は **HTML可**（`<strong>` 等。信頼済み内部データとしてそのまま出力＝エスケープしない）

## 状態（2026-06-07）

- ✅ 全5シート（`pc-skills` / `dev-skills` / `dev-system` / `dev-web` / `design-skills`）JSON化＋生成器で運用中
- ✅ `index.html` の各カードの項目数 … `build-skills.py` 実行時に全JSONから自動同期（カード説明文の末尾「（…項目）」のみ差し替え）

### 移行時に判明・修正した既存バグ（集計表の手計算ミス）

| シート | 旧集計（誤） | 実体＝新集計 |
|--------|------------|------------|
| dev-skills | A19 / B19 / C9 = 47 | **A21 / B22 / C11 = 54** |
| dev-system | A13 / B14 / C8 = 35 | **A13 / B15 / C7 = 35** |
| dev-web | A15 / B15 / C12 = 42 | **A17 / B16 / C9 = 42** |
| design-skills | A11 / B14 / C14 = 39 | **A11 / B15 / C13 = 39** |

いずれも各グループ見出しの項目数は正しく、集計表の A/B/C 内訳だけがズレていた（dev-skills は合計も誤り）。
スキル行データは1件も変えていない（並べ替えと集計の自動化のみ）。今後は集計が自動算出されるため再発しない。
