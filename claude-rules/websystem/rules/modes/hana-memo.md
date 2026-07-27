# hana-tools プロジェクトメモ 登録・更新ルール（hana-memo）

hana-tools の各プロジェクトに付随する「プロジェクトメモ」へ、残存課題や重要な仕様を
外部 API 経由で登録・更新するときのルール。`/hana-memo` コマンドから読み込まれる。

このファイル単体で作業できるよう自己完結させてある（API 仕様・HTML の書き方を含む）。

## 0. 位置づけ（最初に把握）

- プロジェクトメモは **管理画面から人間も読み書きする共有メモ**。編集のたびにバージョン履歴が自動で積まれる（上書きしても過去版は残る）。
- **記録の正本はあくまで開発プロジェクト側のファイル**（`documents/pending-issues.md` 等）。プロジェクトメモは**その写し**として扱い、内容を変更するときはファイル側を直してから反映する。
- できること：
  - 取得: `GET /api/external/projects/{id}/notes`
  - 追加・更新: `POST /api/external/projects/{id}/notes`
- 認証は全リクエストに `X-API-TOKEN` ヘッダを付ける。

## 1. 固有値と認証（project-config.md を正とする）

| 項目 | 参照先 |
|---|---|
| ベースURL | `project-config.md`「hana-tools プロジェクトメモ連携」欄（例: `https://stg.hana-tools.com`） |
| project_id | 同上（未記入なら §5 の方法で調べ、**ユーザー確認で確定**してから **project-config.md に記録**し、以後は問い合わせない） |
| visibility | 同上（既定: `shared`＝全体共有） |
| API トークン | 環境変数（既定: `HANASAKA_API_TOKEN`）。置き場は同欄に記す |

**トークンの取り扱い（厳守）**：

- **リポジトリに書かない**。環境変数か Git 管理外のファイルに置く。実値を読まない・表示しない・ログやコミットに残さない。
- このトークン 1 本で外部 API の全エンドポイント（Chatwork メッセージ送信・ToDo 作成を含む）が叩けるため、漏えい時の影響範囲が広い。

## 2. 最重要の前提：POST は「全置換」

**POST は追記ではなく、本文をまるごと差し替える。** 既存の内容に書き足したい場合は、
必ず先に GET で現在の本文を取得し、それと統合した完全な HTML を送ること。

```
GET で現在の body を取得 → 手元で統合 → 統合後の全文を POST
```

これを怠ると、**他の人が書いた内容を消してしまう**（バージョン履歴からの復元は可能だが、気づかれない）。

### 競合を防ぐ（推奨）

GET のレスポンスに含まれる `current_version` を、POST の `expected_version` に渡すと楽観ロックが効く。
その間に他者が更新していれば `409` が返るので、GET からやり直す。省略した場合は無条件に最新へ上書きする。

### 送信前のユーザー確認（合意ゲート）

POST は共有の外部システムへの書き込み。実行前に **統合後の本文に対する変更点（何を追加・修正するか）と `edit_summary` をユーザーに提示し、承認を得てから送信する**。ユーザーが内容を確定済みで「登録して」と明示的に依頼した場合はそのまま実行してよい。

### 宛先（project_id）の初回ガード

`project-config.md` に記入された `project_id` を**このプロジェクトで初めて使うとき**は、POST 前の GET で取得した既存本文が**自分のプロジェクトの内容として辻褄が合うか**を確認してから送る（記入ミスの最後の砦）。`shared` が `null`（メモ未作成）で判断材料が無い場合は、`GET /api/external/projects/{id}` でプロジェクト名を照合し、ユーザーに宛先を確認してから送る。ID の特定手順は §5。

## 3. リクエスト仕様

### 取得

```bash
curl -X GET "$BASE_URL/api/external/projects/$PROJECT_ID/notes" \
  -H "X-API-TOKEN: $HANASAKA_API_TOKEN"
```

レスポンス:

```json
{
  "success": true,
  "data": {
    "shared": { "id": 1, "body": "<p>...</p>", "current_version": 3, "...": "..." },
    "mine": null
  }
}
```

- `shared` が `null` の場合はメモが未作成（POST すれば作成される）。
- `mine` はクエリに `user_id` を付けたときだけ、そのユーザーの個人メモが入る。

### 追加・更新

HTML をファイルに書き出してから `jq --rawfile` で JSON に包むと、エスケープ事故が起きにくい。

```bash
jq -n --rawfile body ./note.html \
  '{visibility: "shared", body: $body, edit_summary: "残存課題を更新"}' \
| curl -X POST "$BASE_URL/api/external/projects/$PROJECT_ID/notes" \
    -H "X-API-TOKEN: $HANASAKA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d @-
```

| パラメータ | 必須 | 説明 |
|---|---|---|
| `visibility` | 必須 | `shared`（全体共有）/ `private`（個人） |
| `user_id` | `private` 時必須 | 個人メモの所有ユーザーID |
| `body` | 必須 | メモ本文（HTML）。**サーバ側でサニタイズされる**（§4） |
| `edit_summary` | 任意 | 変更内容の要約（最大255文字、履歴に記録される） |
| `expected_version` | 任意 | 楽観ロック。不一致なら `409` |
| `edited_by_user_id` | 任意 | 履歴に残す編集者ID |

成功時は新規作成なら `201`、更新なら `200`。

## 4. HTML の書き方ルール（重要）

送信した HTML は**そのまま保存されない**。サーバ側で HTMLPurifier を通し、
許可リストにない要素・属性を除去したものが保存される。**エラーにはならず 200 が返る**ため、
気づかないまま要素が消える。以下のルールに従うこと。

### 使えるタグ

```
a  p  br
h1 h2 h3 h4 h5 h6
ul  ol  li
blockquote  code  pre
table  thead  tbody  tr  td  th
strong  em  b  i  u  s
img  span  div
```

### 使える属性

| タグ | 属性 |
|---|---|
| すべて | `class` `id` |
| `a` | + `href` `title` `target` |
| `img` | + `src` `alt` `title` `width` `height` |

`href` / `src` に使えるスキームは `http` `https` `mailto` `tel` と `data:image/(png|jpeg|gif)` のみ。

### 使えないもの（無言で除去される）

- `hr`（区切り線）
- `dl` `dt` `dd`（定義リスト）
- `td` / `th` の `colspan` `rowspan` ← **表の結合セルは崩れる**
- `caption` `tfoot` `colgroup`
- `input`（チェックボックス）
- `style` 属性、`on*` 属性、`script` / `iframe` / `form`
- HTML コメント `<!-- ... -->`

### 装飾について

表示側に Tailwind Typography（`prose`）が効いているため、**素朴なタグを書けば自動的に整形される**。
見出し・リスト・表・コードブロックにクラスを付ける必要はない。

逆に `class="text-red-500"` のようなユーティリティクラスは**効かない**。
Tailwind はビルド時にソースコードを走査して CSS を生成する仕組みで、DB 内の文字列は走査対象外のため。
強調したい場合は `<strong>` `<em>` `<blockquote>` など意味を持つタグを使う。

### 推奨する書き方

```html
<h2>残存課題</h2>

<h3>○○が未対応</h3>
<p><strong>経緯</strong>：2026-07-20 の実装時に……</p>
<p><strong>未対応</strong>：……</p>
<p><strong>今後の判断ポイント</strong>：……</p>
<ul>
  <li>選択肢A：……</li>
  <li>選択肢B：……</li>
</ul>

<h3>△△の設計判断</h3>
<p>……</p>
```

- `hr` や定義リストが使えないため、**セクション区切りは見出しタグ（`h2` / `h3`）で表現する**。
- 「経緯 / 未対応 / 今後の判断ポイント」のような項目名は `<strong>` + `<p>` で書く（`documents/pending-issues.md` の記録フォーマットと揃う）。

### 除去されたかどうかの確認

POST のレスポンスに含まれる `data.body` は、**サニタイズ後に保存された正規形**。
送信した HTML と比較して差異があれば、何かが除去されている。
重要な記録を書いたときは一度確認し、消えていた要素は上記ルールに従って書き直すこと。

なお差異は除去だけでなく正規化（属性順・エンティティ・空白の変換、未閉じタグの補完）でも生じる。
完全一致しないこと自体は異常ではない。

## 5. project_id の調べ方（最後はユーザー確認で確定する）

`project-config.md` に記入済みならそれを使う。未記入のときだけ以下で調べる。

```bash
curl -X GET "$BASE_URL/api/external/projects" \
  -H "X-API-TOKEN: $HANASAKA_API_TOKEN"
```

1. 一覧の各プロジェクトの名称・クライアント名・サイトURL を、`project-config.md` のプロジェクト名／公開URL と突き合わせて候補を絞る。
2. **AI が単独で確定しない。** 候補（`id` と名称・クライアント名・サイトURL）を提示し、**「このプロジェクトで合っていますか」とユーザーに確認して確定する**。候補が1件に絞れた場合も確認する。
3. 確定したら **`project-config.md` の「hana-tools プロジェクトメモ連携」欄に記録**し、以後は問い合わせない。

> **なぜ確認が要るか**：ID を1つ間違えたまま POST すると、**別プロジェクトの共有メモを全置換で丸ごと消す**（§2）。しかもサーバはエラーを返さず成功するため、誰も気づかない。一覧の名称だけでは同名・類似案件を取り違えうるので、確定はユーザーに委ねる。

## 6. 運用上の注意（まとめ）

- **トークンをリポジトリ・ログ・コミットに含めない**（§1）。
- **共有メモは人間も編集する。** 全置換の性質上、GET → 統合 → POST の手順を必ず守る（§2）。
- **宛先（project_id）は AI が単独で確定しない。** 未記入なら候補を提示してユーザー確認で確定し、`project-config.md` に記録する（§5）。誤った ID への POST は他プロジェクトのメモを消す。
- **記録の正本は開発プロジェクト側のファイル**（`documents/pending-issues.md` 等）。プロジェクトメモは写しとして扱い、内容を変更するときはファイル側を直してから反映する（コミット運用のあるプロジェクトは push まで済ませる）。
- 書いた直後に `data.body` を確認し、重要な要素が除去されていないかチェックする（§4）。
