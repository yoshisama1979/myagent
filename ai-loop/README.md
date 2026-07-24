# AI Loop — Reviewer × Developer 協働基盤

myagent プロジェクトの改善サイクルを、**Reviewer AI（読み取り専用）**と **Developer AI（実装担当）** の分業で回すための運用基盤。

## ねらい

- 業務時間外（夜・土日）に Reviewer が改善案を提案
- 平日業務中に Developer が選ばれた提案を実装
- 人間（社長）は判断のみに集中

## 構成ファイル

| ファイル | 役割 | 編集者 |
|---------|------|--------|
| `README.md`（本ファイル） | 運用説明 | 人間 |
| `scope.md` | Reviewer のレビュー範囲 | 人間 |
| `exclusions.md` | 提案対象外リスト（却下・保留・確定済み） | 人間 |
| `conversation.md` | AI同士の会話ログ | Reviewer 追記 / Human 編集 / Dev 追記 |

## 動作フロー

```
[Reviewer セッション]
   ↓ /reviewer-cycle 実行
   ↓ scope.md / exclusions.md / conversation.md / プロジェクト本体 を読む
   ↓ conversation.md に提案を追記
   ↓ 終了

[人間]
   ↓ conversation.md を読む（エディタで）
   ↓ 各提案を ✅採用 / ❌却下 / ⏸️保留 に振り分け
   ↓ 採用したものは Dev に実装依頼

[Developer セッション（通常の Claude Code）]
   ↓ 「P-001 実装して」と指示
   ↓ 実装 → コミット
   ↓ conversation.md に実装報告を追記

[次サイクル]
   ↓ 完了した提案は conversation.md から削除
   ↓ 却下したものは exclusions.md に1行追記
   ↓ Reviewer 次サイクルへ
```

## 起動方法

### Reviewer セッション

1. **別の Claude Code セッションを開く**（tmux 推奨）
2. プロジェクトルートに移動：`cd /home/vpsuser/projects/myagent`
3. スラッシュコマンドで起動：`/reviewer-cycle`

または、スラッシュコマンドが効かない場合：
```
rules/modes/reviewer.md を読んで、Reviewer モードで動作して。
conversation.md に新サイクルの提案を追記してください。
```

### Developer セッション（通常運用）

通常の Claude Code セッションを使う。Reviewer の提案を実装依頼するときは：
```
ai-loop/conversation.md の Cycle NNN の P-001 を実装して。
```

## conversation.md の運用ルール

### 残すもの
- ⏳ Pending（Human判断待ち）の提案
- ⏸️ 保留中の提案
- 直近1-2サイクルの完了履歴（参考のため）

### 消すもの
- ✅ 採用→実装完了したサイクル全体
- ❌ 却下されたサイクル全体（理由は exclusions.md に蒸留）

### 蒸留方法
却下された提案は exclusions.md に1行追記：
```markdown
- ダークモード対応（2026-06-01 却下：優先度低、ニーズなし）
```

## ファイル肥大化を防ぐコツ

- conversation.md は **短く保つ**：完了次第削除
- exclusions.md は **長期メモリ**：1行サマリで蓄積
- scope.md は **設定**：頻繁に変えない
- 「過去ログを残したい」場合は git 履歴で十分（diff で復元可能）

## Reviewer の制約（厳守）

- プロジェクト内ファイルは **読み取りのみ**
- 書き込みは `ai-loop/conversation.md` だけ
- git commit / push 禁止
- 詳細は `rules/modes/reviewer.md` 参照

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| Reviewer が conversation.md 以外を書こうとする | 即停止 → `rules/modes/reviewer.md` の制約を再確認させる |
| 同じ提案が何度も出る | exclusions.md に該当論点を追記 |
| 提案の質が低い | scope.md の重点テーマを絞る、Reviewer プロンプトを改善 |
| conversation.md が肥大化 | 完了サイクルを物理削除、必要なら git 履歴で参照 |

## 関連

- `rules/modes/reviewer.md` — Reviewer モードの詳細ルール
- `.claude/commands/reviewer-cycle.md` — 起動コマンド
