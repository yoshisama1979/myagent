<!-- kaizen:retired -->
# カイゼン台帳（旧の器）— 2026-09-20 に畳みました

**この器はもう使いません。ここに追記しないでください**（足すと月別を見ている道具から見えなくなり、`python3 bin/kaizen.py lint` が止めます）。

## 今の在処（3層）

| 層 | 在処 | 読み方 |
|----|------|--------|
| 状態＝索引 | `data/hp-improve/kaizen-queue.md` | 1件1行・未採否の全件。**判断はここを読む**（生成物・手で書かない） |
| 経緯＝原文 | `data/hp-improve/kaizen/YYYY-MM.md` | 月別・無改変。1件の全文＝`python3 bin/kaizen.py show K-NNN` |
| 倉庫 | `data/hp-improve/skill-kaizen-archive.md` | 退避＝`python3 bin/kaizen.py move <在処>:<行>:<照合>` |

## 足すとき

```
python3 bin/kaizen.py add --title '<1行要約>' --lane <モード> <<'EOF'
（本文）
EOF
```

## 経緯

2026-09-16 に分割（社長ご承認「では分割で。回答の質だけ担保できていれば」）。畳む条件は triage の関門2つ＝
①移行直後に質を実測し一致率100%（実測 9/9・索引だけで決まったのは 7/9）②数字が出てから旧を畳む。
2026-09-20 に検算し直し、旧の 224件すべてが月別3本＋倉庫のハッシュ集合に含まれることを確認したうえで畳みました
（この器の原文は git の履歴にも残っています）。

<!-- kaizen:retired:end -->
