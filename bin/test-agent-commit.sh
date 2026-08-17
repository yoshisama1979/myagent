#!/usr/bin/env bash
# bin/agent-commit.sh（無人エージェントがサイクル末に自分の成果物をコミットする）の回帰テスト。
#
# 契機＝2026-08-17 社長判断（O-040 の続き）。testing.md §2 の3条件すべてに当たる＝
# ①無人ループ（agent-tick）から毎サイクル呼ばれる ②git の履歴という状態を書く
# ③判定を持つ（対象パス・変更の有無・競合時の再試行）。
#
# **このツールの失敗も二方向とも高くつく**：
#   ・広すぎる → 他エージェントの書きかけを巻き込む（混入事故3回の再演）
#   ・狭すぎる／黙って何もしない → 成果物が git 外に溜まり続ける（＝解決しようとした問題の再発）
# よって「自分の分だけ拾う」と「拾えないときは黙らずログに出す」を対で固定する。
#
# ⚠️ 本番リポジトリではコミットしない：使い捨ての git リポジトリを一時ディレクトリに作り、
#    そこへ agent-commit.sh と precommit-guard.py を複製して流す。
# 触ったら必ず流すこと：bash bin/test-agent-commit.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/agent-commit.sh" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

P=0; N=0
say_ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
say_ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      → %s\n' "$2"; fi; }
has(){ case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(printf '%s' "$2" | tr '\n' '|' | cut -c1-240)"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(printf '%s' "$2" | tr '\n' '|' | cut -c1-240)"; else say_ok "$3"; fi; }
want_eq(){     if [ "$1" = "$2" ]; then say_ok "$3"; else say_ng "$3" "実際=[$1] 期待=[$2]"; fi; }

R="$T/repo"
mkdir -p "$R/bin" "$R/.githooks" "$R/site/overseer" "$R/data/hp-loop/ycom" "$R/site/hp-analysis/ycom" "$R/rules"
cp "$PROJ/bin/agent-commit.sh" "$PROJ/bin/precommit-guard.py" "$R/bin/"
cp "$PROJ/.githooks/pre-commit" "$R/.githooks/"
chmod +x "$R/bin/agent-commit.sh" "$R/.githooks/pre-commit"
printf 'data/secrets/\nsite/drafts/\n' > "$R/.gitignore"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
g(){ git -C "$R" "$@"; }
g init -q -b main
g config core.hooksPath .githooks
echo "初期" > "$R/site/overseer/index.html"
g add -A; g commit -q -m "初期"

run(){ OUT="$(cd "$R" && bash bin/agent-commit.sh "$@" 2>&1)"; RC=$?; }
count(){ g log --oneline | wc -l; }

echo "=== 変更が無いときは何もしない（空コミットを作らない）==="
before=$(count); run overseer
want_eq "$RC" "0" "正常終了する"
want_in "変更なし" "$OUT" "変更なしと報告する（黙らない）"
want_eq "$(count)" "$before" "コミットを増やさない"

echo
echo "=== 自分の成果物をコミットする ==="
echo "<div>Cycle 063 の記録</div>" > "$R/site/overseer/index.html"
before=$(count); run overseer
want_eq "$RC" "0" "成功する"
want_eq "$(count)" "$((before+1))" "1つコミットが増える"
msg="$(g log -1 --format=%s)"
want_in "[auto]" "$msg" "★人の作業と区別できる接頭辞を付ける（git log を絞り込める）"
want_in "overseer" "$msg" "誰の記録か分かる"
want_in "1件" "$msg" "件数を書く"
run overseer
want_in "変更なし" "$OUT" "2回目は何もしない（冪等）"

echo
echo "=== 新規ファイルも拾う（追記だけでなく作成も）==="
echo "cov" > "$R/data/hp-loop/ycom/coverage.md"
run hp-loop-ycom
want_eq "$RC" "0" "新規ファイルでもコミットできる"
want_in "coverage.md" "$(g show --stat --format= HEAD)" "新規ファイルが入っている"

echo
echo "=== ★他エージェントの領域を巻き込まない ==="
echo "hp-loop の書きかけ" > "$R/data/hp-loop/ycom/wip.md"
echo "<div>統括の更新</div>" > "$R/site/overseer/index.html"
before=$(count); run overseer
want_eq "$(count)" "$((before+1))" "統括のコミットは作られる"
changed="$(g show --stat --format= HEAD)"
want_in "site/overseer" "$changed" "自分の掲示板は入る"
want_not_in "data/hp-loop" "$changed" "★hp-loop の書きかけは入らない"
if [ -f "$R/data/hp-loop/ycom/wip.md" ]; then say_ok "巻き込まなかったファイルはディスクに残る"; else say_ng "巻き込まなかったファイルが消えた"; fi
run hp-loop-ycom
want_in "wip.md" "$(g show --stat --format= HEAD)" "後から本人が回れば自分でコミットできる"

echo
echo "=== 許可パス未登録のエージェントは何もしない ==="
echo "x" > "$R/site/somewhere.html"
before=$(count); run partner
want_eq "$RC" "0" "エラーにしない（無人ループを落とさない）"
want_in "対象外" "$OUT" "対象外であることをログに出す（★黙って全部を掴まない）"
want_eq "$(count)" "$before" "コミットしない"
rm -f "$R/site/somewhere.html"

echo
echo "=== 引数・環境の異常 ==="
OUT="$(cd "$R" && bash bin/agent-commit.sh 2>&1)"; RC=$?
want_eq "$RC" "2" "エージェント名なしはエラー"
mv "$R/bin/precommit-guard.py" "$R/bin/precommit-guard.py.off"
run overseer
want_eq "$RC" "0" "★許可パスの表が無い版へ戻っても無人ループを落とさない"
want_in "何もしません" "$OUT" "理由を出す"
mv "$R/bin/precommit-guard.py.off" "$R/bin/precommit-guard.py"

echo
echo "=== --dry-run は書かない ==="
echo "<div>下見</div>" > "$R/site/overseer/index.html"
before=$(count); run overseer --dry-run
want_eq "$(count)" "$before" "コミットしない"
want_in "site/overseer/index.html" "$OUT" "対象を出す"
if ! g diff --quiet; then say_ok "作業ツリーの変更はそのまま残る"; else say_ng "作業ツリーを変えてしまった"; fi

echo
echo "=== ★共有インデックスを汚さない（他セッションのステージを巻き込まない）==="
echo "別セッションの作業" > "$R/rules/other-session.md"
g add -- rules/other-session.md            # 他セッションがステージした状態を再現
run overseer
want_eq "$RC" "0" "自分のコミットは成功する"
want_not_in "rules/other-session.md" "$(g show --stat --format= HEAD)" "★他セッションのステージ済みファイルを巻き込まない"
staged="$(g diff --cached --name-only)"
want_in "rules/other-session.md" "$staged" "★相手のステージはインデックスに残ったまま（剥がさない）"

echo
echo "=== 共有インデックスが古いだけのときは空コミットを作らない ==="
# 1段目のチェック（worktree/index/未追跡）は「差分あり」に見えるが、HEAD から組み直すと
# 実は差分が無い状況＝**共有インデックスが古い**とき。ここで2段目が効かないと空コミットが毎回増える。
g reset -q
g show HEAD:site/overseer/index.html > "$T/head-content"
echo "いったん違う内容" > "$R/site/overseer/index.html"
g add -- site/overseer/index.html                 # インデックスだけ進める
cp "$T/head-content" "$R/site/overseer/index.html" # 作業ツリーは HEAD と同じに戻す
before=$(count); run overseer
want_eq "$(count)" "$before" "★HEAD と同じ内容なら空コミットを作らない（共有インデックスが古いだけ）"
want_in "実質の差分なし" "$OUT" "理由を出す"
g reset -q

echo
echo "=== フックが止めたら無理に通さない ==="
g reset -q
mkdir -p "$R/data/secrets"
echo "架空商事" > "$R/data/secrets/deny-names.txt"
echo "<div>本日 架空商事 と面談</div>" > "$R/site/overseer/index.html"
before=$(count); run overseer
want_eq "$RC" "1" "コミットできなかったことを終了コードで返す"
want_eq "$(count)" "$before" "履歴は増えない"
want_in "コミットせず" "$OUT" "★理由をログに出す（黙って握りつぶさない）"
want_not_in "架空商事" "$OUT" "★ログに該当語を出さない"
echo "<div>本日 面談</div>" > "$R/site/overseer/index.html"
run overseer
want_eq "$RC" "0" "直せば次は通る"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
