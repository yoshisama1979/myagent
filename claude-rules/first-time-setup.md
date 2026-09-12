# はじめての配布（人間用・初回だけの手順）

案件にルールファイル一式を渡すのは**初回だけ人の手**が要る。2回目からは各案件のエージェントが
自分で最新版を取りに来るので、この紙は「最初の1回」のためのもの。

所要 5 分。**この手順で渡した案件は、以後こちらから配り直さなくてよくなる。**

---

## 全体の流れ

```
①どのテンプレかを決める → ②トークンを発行 → ③パッケージを作る → ④案件へ渡す → ⑤現場で展開
                                                                        ↓
                                         以後：現場のエージェントが自分で取りに来る（人は承認するだけ）
```

---

## ① どちらのテンプレートを配るか決める

| テンプレート | 対象 |
|---|---|
| `website` | コーポレートサイト・LP・WordPress 等のサイト制作（HTML/CSS(Sass)/JS） |
| `websystem` | 業務システム・API・管理画面（仕様書と受け入れ条件で進める開発） |

迷ったら「デザインカンプから作るなら website／仕様書から作るなら websystem」。

## ② その案件のトークンを発行する（VPS の myagent で）

```bash
python3 bin/rule-reporter.py issue "案件名" --id <英小文字の識別子> --template website
```

- 案件名は日本語でよい（台帳の表示名）。`--id` は `yoshida-dental` のような英小文字（日本語名なら必須）
- **表示されるトークンは、このとき1回しか出ない。** 控えてから閉じる
- 既定の期限は 365 日。短くするなら `--days 90`

このトークン1本で、その案件は **①ルールの問題を送る ②最新版を取りに来る** の両方ができる。

## ③ 配布物を作る

```bash
# 別マシンの案件へ渡す（tar.gz ができる）
python3 bin/distribute-rules.py pack website "案件名"

# 同じマシンの中なら直接配れる（既定は下見・--yes で書き込み）
python3 bin/distribute-rules.py apply website /path/to/project --yes
```

⚠️ `claude-rules/` に未コミットの変更があると止まる（版と中身がズレるため）。先にコミットする。

## ④ 案件へ渡すもの（2つ）

1. ③で作った `tar.gz`
2. `.env` に書く3行 ── **トークンはチャットに貼らない**（パスワード共有と同じ扱いで渡す）

```
RULE_REPORT_URL=http://100.123.104.87/tools/mailbox/
RULE_UPDATE_URL=http://100.123.104.87/tools/rules/
RULE_REPORT_TOKEN=rr_xxxxxxxxxxxxxxxxxxxxxxxx
```

> IP はこの VPS の Tailscale アドレス。**社内網（Tailscale）の中からしか届かない**ので、
> 案件側の PC が Tailscale に入っていることが前提。

## ⑤ 現場でやること（このまま渡してよい手順）

```bash
# プロジェクトのルートで
tar xzf website_2026-09-12_xxxxxxxx.tar.gz
cp -rn website/. .          # 既存ファイルは上書きしない
rm -rf website

# .env に上の3行を追記（.env は git に入れない）

# 疎通確認（何も書き換えません）
bash bin/rules-update.sh    # 「最新です」と出れば配線OK
```

エージェントには **「`rules/modes/rules-update.md` を読んで」** と伝えれば、以後の更新は
本人が手順どおりに動く（確認 → 人に相談 → 承認後に適用）。

---

## 2回目以降（配り直しは要らない）

こちら側でルールを直したら、**配ってよいと決めたときに公開する**だけ。

```bash
python3 bin/rules-publish.py publish website    # これをするまで現場には流れない
python3 bin/rules-publish.py status             # いま何版を配信しているか
```

公開すると、各案件のエージェントが区切りのタイミングで気づき、**その案件の担当者に確認してから**
自分で更新する。こちらから案件ごとに配り直す必要はない。

---

## 見る・止める

| したいこと | コマンド |
|---|---|
| 誰にいつ出したか・最後にいつ使われたか・どこから（IP）・どの版を持っているか | `python3 bin/rule-reporter.py list` |
| 発行の台帳（git 追跡・トークン値は載らない） | `data/rule-reporters.md` |
| どの案件にどの版を配ったか | `python3 bin/distribute-rules.py list` |
| **1案件を止める**（通知も更新も同時に止まる） | `python3 bin/rule-reporter.py revoke RR-NNN --reason "理由"` |
| **全案件への配信を止める**（既に配ったものは戻らない） | `python3 bin/rules-publish.py unpublish website` |

🚨 **見覚えのない接続元（`100.x.x.x` の拠点）から使われていたら revoke する。** 失効は行を消さずに
理由を残すので、後から「そんな番号あったか」にならない。

---

## よくある詰まり

| 症状 | 原因と対処 |
|---|---|
| 現場で「`RULE_UPDATE_URL` がありません」 | `.env` の3行が入っていない（④） |
| 現場で「まだ配信されていません」 | こちらで `rules-publish.py publish` をしていない |
| 現場で「サーバに接続できません」 | 案件の PC が Tailscale に入っていない |
| 現場で「失効／期限切れ」 | 期限切れか revoke 済み。②で再発行して `.env` を差し替える |
| `pack` が止まる | `claude-rules/` に未コミットの変更がある（③） |
