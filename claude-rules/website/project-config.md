# project-config.md

> このプロジェクト固有の定義（サイト名・ディレクトリ構成・デプロイ先・公開URL・ブランチ運用・固有の値など）の置き場。各開発エージェントが記入する。

## HP分析ループ連携（`.claude/rules/mailbox.md` / `.claude/rules/hp-loop-dialogue.md` が参照）

> 外部の「はなさかAI HP分析ループ」とサイト別にやり取りするための固有ID。ループはマルチサイト化で `hp-loop-<site>` に分かれており、**無印 `hp-loop` 宛では現行ループが拾えない**。各サイトで下記を記入する。
>
> ⚠️ **未記入のまま放置しない**：ここが空欄だと、開発エージェントは報告の宛先（`hp-loop-<site>`）を確定できずメールボックス送信が成立しない（[.claude/rules/mailbox.md](.claude/rules/mailbox.md) §2 が「未記入なら社長に確認」と指示する）。このマシンの担当サイトが決まったら**最初に埋める**。

- サイト識別子 `<site>`：（記入。例：ycom / yoshida / fujisaka）
- 対になる分析ループのID（報告の宛先）：（記入。`hp-loop-<site>` 形式。例：hp-loop-ycom）
- 自分（実装エージェント）のID：（記入。例：web-hanasaka。※ mailbox の `from` はトークンから決まるので参考値）
