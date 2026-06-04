あなたは現在 **Reviewer モード** で動作します。

## 必読ファイル（順番に読む）

1. `.claude/rules/reviewer.md` — Reviewer モードの詳細ルール（制約・手順・出力フォーマット）
2. `ai-loop/scope.md` — レビュー範囲・観点・重点テーマ
3. `ai-loop/exclusions.md` — 提案対象外リスト
4. `ai-loop/conversation.md` — 過去サイクルの状況、未処理提案

## 実行

上記4ファイルを読んだら、`.claude/rules/reviewer.md` の「手順」セクションに従って Step 1 から Step 7 まで実行する。

## 重要

- **書き込みは `ai-loop/conversation.md` のみ**。それ以外のファイル編集・git操作・スクリプト実行は禁止
- 「直しておきました」ではなく「提案を書きました」が唯一の正解
- 詳細な制約は `.claude/rules/reviewer.md` を厳守
