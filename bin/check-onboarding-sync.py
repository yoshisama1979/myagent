#!/usr/bin/env python3
"""配布テンプレートの原典を直したとき、その要約ガイドの追随漏れを検出する（読み取り専用）。

`claude-rules/website-onboarding.md` は `claude-rules/website/` 配下の原典を
新人スタッフ向けに 1 枚へ要約したもの（Notion 掲載用）。要約である以上、
原典を直してもガイドは黙って古くなる ＝ 「重複定義しない」原則では解けない
（README.md 設計原則②のスコープは 1 テンプレートの中）。

2026-09-10、起票（TB-010）した当日に 1 回目の版ズレが実際に起きた：
`common/documents/handoff.md` の状態遷移の矛盾を直したとき、同じ誤りが
ガイド §5.1 にも入っており、気づかなければ「誰も動かせなくなるルール」を
Notion に貼るところだった。忘れることだけが本当のリスクなので、宣言でなく機械で拾う。

使い方:
    python3 bin/check-onboarding-sync.py               # ステージ済みの変更を見る
    python3 bin/check-onboarding-sync.py --range A..B  # コミット範囲を見る

書き込み・外部送信はしない。**検査結果としての終了コードは常に 0**
（検知の有無は出力で判断する）＝コミットを機械的に止めない。判断するのは人間。
引数の誤りだけは argparse が 2 で終わる（呼び出し側の間違いなので黙らせない）。

このツールは「何も出力しない」が正常系＝**壊れても気づけない**。
必ず `bash bin/test-check-onboarding-sync.sh` を通してから触ること。
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent

# ガイド → { 原典パス（リポジトリルートからの相対）: そのファイルを要約している節 }
#
# 新しい要約ガイドを作ったら、ここに 1 ブロック足す（例: websystem-onboarding.md）。
# 🚨 原典を新設してガイドに書いたら、その行をここに足す。
#    足し忘れると黙って検出漏れになる（2026-09-10 の Codex レビューで実際に 4 本の漏れが出た）。
#    回帰テストが「ガイド本文が言及する原典が全て登録されているか」を突き合わせるので、
#    足し忘れるとテストが落ちる。
# 🚨 ここは**層の数を前提にしていない**（パスを素で持っているだけ）＝配布プロファイルが
#    複数層になっても道具側の変更は要らない。ただし claude-rules/ を `common/` `site/`
#    `system/` に分けたら（REDESIGN.md ステップ5）、**下のパスを新しい層へ付け替える**。
#    付け替え忘れは「原典が無い」でテストが落ちるので、黙って検出漏れにはならない。
GUIDES = {
    "claude-rules/website-onboarding.md": {
        "claude-rules/common/documents/handoff.md": [
            "§5.1 状態は 6 つだけ", "§5.2 カードの形", "§5.4 書き込むときの約束",
            "§5.7 台帳が長くなったら（退避）",
        ],
        "claude-rules/website/rules/modes/director.md": [
            "§2 全体像・役割", "§4 1 日の流れ", "§5.5 質問は二段構え",
            "§7 正本と番号", "§9 やってはいけないこと（統括）",
        ],
        "claude-rules/website/rules/modes/developer.md": [
            "§4 1 日の流れ", "§5.3 報告 8 項目", "§5.6 直接指示を受けたとき",
            "§9 やってはいけないこと（開発）",
        ],
        "claude-rules/website/rules/modes/content-planning.md": [
            "§6.4 標準工程（フェーズ 0〜8）",
        ],
        "claude-rules/website/documents/client-questions.md": [
            "§6.4 標準工程（フェーズ 0〜8）",
        ],
        "claude-rules/website/rules/modes/build-progress.md": [
            "§6.2 使い始め", "§6.3 記法", "§6.5 促し方", "§6.6 完了の根拠",
            "§6.7 レポートの形", "§6.8 納品単位が複数のとき", "§7 正本と番号",
        ],
        "claude-rules/website/documents/build-checklist.md": [
            "§6.4 標準工程（フェーズ 0〜8）",
        ],
        "claude-rules/website/rules/modes/check.md": [
            "§6.4 標準工程（フェーズ 7 へ進む条件・指摘時の扱い）",
        ],
        "claude-rules/website/rules/modes/start.md": [
            "§3 Step 1 プロジェクトの設定を書く", "§11 導入チェックリスト",
        ],
        "claude-rules/website/documents/company-facts.md": [
            "§3 Step 2 起動時の環境点検", "§7 正本と番号（F-NNN）",
            "§9 やってはいけないこと（開発）", "§11 導入チェックリスト",
        ],
        "claude-rules/common/documents/pending-issues.md": [
            "§5.3 報告 8 項目（範囲外の気づき）", "§7 正本と番号（PI-NNN）",
        ],
        "claude-rules/common/documents/rule-improvements.md": [
            "§7 正本と番号（RI-NNN）",
        ],
        "claude-rules/common/rules/modes/rules-update.md": [
            "§7 正本と番号（ルールの新しい版を取りに来る）",
        ],
        "claude-rules/website/project-config.md": [
            "§3 Step 1 プロジェクトの設定を書く", "§11 導入チェックリスト",
        ],
        "claude-rules/website/CLAUDE.md": [
            "§2 全体像", "§7 正本と番号",
        ],
        # スラッシュコマンドはまとめて §8 に効く（個別に列挙しない＝1本増えるたびに漏れるため）
        "claude-rules/website/.claude/commands/": [
            "§8 コマンド早見表（どの窓で打つか・その根拠）",
        ],
    },
}


def is_rename(status):
    """R（rename）/ C（copy）か。`R100` のようにスコアが付くので先頭 1 文字で見る。

    この判定を外すと「旧パスを照合対象に入れる」「ガイドの改名を検出する」の
    両方が同時に壊れるため、正を 1 箇所に置く。
    """
    return status[:1] in ("R", "C")


def changed_entries(rng=None):
    """変更を [(status, [paths...]), ...] で返す。--range が無ければステージ済み。

    `--name-status -z` を使う理由（2026-09-10 Codex レビュー 🔴）:
      - `--name-only` はリネームを**新名しか返さない**＝原典を改名しても検出できない
      - status が無いと**ガイドの削除**を「追随済み」と誤判定する
      - `-z` + バイト読み + os.fsdecode でないと、`core.quotepath`（既定 true）が
        非ASCIIパスをクォート＋エスケープして返し、パス一致が成立しない
    """
    cmd = ["git", "-C", str(PROJ), "diff", "--name-status", "-z"]
    cmd += [rng] if rng else ["--cached"]
    out = subprocess.run(cmd, capture_output=True)
    if out.returncode != 0:
        msg = out.stderr.decode("utf-8", "replace").strip()
        print(f"⚠️  git が読めませんでした: {msg}", file=sys.stderr)
        return []

    tokens = [os.fsdecode(t) for t in out.stdout.split(b"\0") if t]
    entries, i = [], 0
    while i < len(tokens):
        status = tokens[i]
        n = 2 if is_rename(status) else 1   # R/C は「旧パス・新パス」の 2 つを伴う
        paths = tokens[i + 1:i + 1 + n]
        if len(paths) < n:      # 想定外の切れ方。黙って誤判定するより止める
            print(f"⚠️  git の出力を解釈できませんでした（status={status}）", file=sys.stderr)
            return []
        entries.append((status, paths))
        i += 1 + n
    return entries


def match(path, key):
    """key がディレクトリ指定（末尾 /）ならその配下、そうでなければ完全一致。"""
    return path.startswith(key) if key.endswith("/") else path == key


def guide_state(entries, guide):
    """ガイドがこの変更集合の中でどう扱われたか。'updated' / 'deleted' / 'renamed' / None"""
    for status, paths in entries:
        if is_rename(status):
            old, new = paths
            if new == guide:
                return "updated"        # 別名から移ってきた＝実体は在る
            if old == guide:
                return "renamed"        # ガイドが別名へ移った＝GUIDES の登録が古い
        elif paths[0] == guide:
            return "deleted" if status[:1] == "D" else "updated"
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="配布テンプレの原典を直したとき、要約ガイドの追随漏れを知らせる（読み取り専用）")
    ap.add_argument("--range", dest="rng", metavar="A..B",
                    help="見るコミット範囲（省略時はステージ済みの変更）")
    args = ap.parse_args(argv)

    entries = changed_entries(args.rng)
    if not entries:
        return 0

    # 原典の一致には旧パス・新パスの両方を使う（改名も「触った」とみなす）
    touched = [p for _, paths in entries for p in paths]

    for guide, mapping in GUIDES.items():
        hits = {}
        for path in touched:
            for key, sections in mapping.items():
                if match(path, key):
                    hits.setdefault(key, set()).update(sections)
        if not hits:
            continue

        state = guide_state(entries, guide)
        if state == "updated":
            print(f"✅ {guide} も同じ変更に含まれています（追随済みとみなします）")
            continue
        if state == "deleted":
            print(f"🔔 原典を直しましたが {guide} が**削除**されています")
            print("   意図した削除なら、このツールの GUIDES から該当ブロックを外してください。")
            print()
        elif state == "renamed":
            print(f"🔔 {guide} が**改名**されています（このツールの GUIDES が古いパスを指しています）")
            print("   GUIDES のキーを新しいパスに直してください。")
            print()
        else:
            print(f"🔔 原典を直しましたが {guide} が追随していません")
            print("   このガイドは Notion に貼って配布する要約です。"
                  "原典だけ直すと、貼った先で古いルールを教えることになります。")
            print()

        for key in sorted(hits):
            print(f"   - {key}")
            for section in sorted(hits[key]):
                print(f"       → {guide} の {section}")
        print()
        print("   直す必要が無いと判断した場合は、そのままコミットして構いません"
              "（このチェックはコミットを止めません）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
