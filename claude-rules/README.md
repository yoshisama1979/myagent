# claude-rules — プロジェクト配布用 Claude Code ルールテンプレート

クライアントプロジェクトの開発で使う **Claude Code 用ルールファイル一式のテンプレート**。
プロジェクト種別に応じてどちらかをコピーして使う。

| テンプレート | 対象 | 中身の骨子 |
|---|---|---|
| [`website/`](website/) | **WEBサイト制作**（コーポレートサイト・LP・小規模サイト。静的HTML or PHP + Sass） | Design.md=SSOT、開始ゲート（start）→ 実装（page-build/page-update/design-replication）→ 公開前チェック（check）→ 運用・SEO（seo-operation）、hp-loop 連携（mailbox/hp-loop-dialogue） |
| [`websystem/`](websystem/) | **WEBシステム開発**（業務システム・管理画面。Laravel + Next.js 等） | 3モード体制（dialogue-mode ↔ autopilot ↔ inbox-mode）、TDD（tdd/testcode/frontend-test）、仕様書HTML（spec-format）、コミット規約・領域分割（commit）、見積もり（estimation） |

## 使い方（新規プロジェクトへの導入手順）

1. **フォルダごとコピー**する（`website/` または `websystem/` の中身をプロジェクトルートへ）
2. **`project-config.md` を最初に記入する**（プロジェクト固有の値はすべてここに集約。ルール本文には書かない）
3. website の場合：`Design.sample.md` を参考に、そのプロジェクトの `Design.md` を作る（`start.md` §1 の手順。Design.sample.md 自体は記入例なのでコピー先に持ち込まなくてよい）
4. `documents/pending-issues.md`・`documents/rule-improvements.md` は **空の状態から**運用を始める
5. websystem の場合：`documents/specs/_template.html` を起点に仕様書を作る（`document.md` は新規プロジェクトでは作らない）

## テンプレートの設計原則（編集時に守ること）

1. **固有値はルール本文に書かない** — クライアント名・実パス・ブランド色・スタックのバージョン等は各プロジェクトの `project-config.md`（デザイン値は `Design.md`）に置き、ルール本文は参照する。例として残す場合は「例:」と明示する
2. **重複定義しない** — 同じルールは1ファイルを本家にし、他は参照で繋ぐ（片方を直して他方が古くなる「版ズレ」を防ぐ）
3. **安全ゲートを崩さない** — 外部送信・本番改変・push・破壊的操作は合意ゲートを通す。捏造しない（要確認情報は確定しない）

## テンプレート自体の育て方

- 各プロジェクトでの運用中に気づいたルールの不足・乖離は、そのプロジェクトの `documents/rule-improvements.md` に記録する（記録と反映の分離）
- テンプレート側に反映すべきものは、棚卸し時にこのリポジトリの `claude-rules/` へ還元する
- テンプレート自体の未完課題（ツール化・定型化などの宿題）は [`TEMPLATE-BACKLOG.md`](TEMPLATE-BACKLOG.md) に置く（配布物の `pending-issues.md` には入れない）
