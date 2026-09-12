#!/usr/bin/env bash
# bin/distribute-rules.py の回帰テスト。
#
# testing.md §2 の「テスト必須」に当たる＝①状態を書く（配布先のファイルを上書きする・
# レジストリを更新する）②判定を持つ（どのファイルを上書きしてよいか・版の作り方）。
#
# ここで守りたい不変条件はひとつ：**配布で案件の記録を消さない**。
# documents/・project-config.md・Design.sample.md・.claude/rules/private.md は
# 案件が書き足していくファイルなので、再配布で上書きしたら現場の記録が飛ぶ。
# これが壊れると被害が大きく、しかも配った先で静かに起きるので機械で見張る。
#
# ⚠️ 本番のレジストリ（data/rules-distribution.md）には触れない：RULES_DIST_REGISTRY で
#    /tmp に差し替える。テンプレート自体は読むだけ。
# 触ったら必ず流すこと：bash bin/test-distribute-rules.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/distribute-rules.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

export RULES_DIST_REGISTRY="$T/registry.md"
dr(){ python3 "$PROJ/bin/distribute-rules.py" "$@" 2>&1; }

P=0; N=0
say_ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
say_ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      → %s\n' "$2"; fi; }
has(){ case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; else say_ok "$3"; fi; }
want_eq(){     if [ "$1" = "$2" ]; then say_ok "$3"; else say_ng "$3" "実際=[$1] 期待=[$2]"; fi; }
want_file(){   if [ -f "$1" ]; then say_ok "$2"; else say_ng "$2" "$1 が無い"; fi; }

# テンプレートに未コミットの変更があるかで --allow-dirty の要否が変わる。
# テストは「どちらの状態でも通る」ようにしたいので、必要なときだけ付ける。
DIRTY=""
if [ -n "$(git -C "$PROJ" status --porcelain -- claude-rules/websystem/ claude-rules/website/)" ]; then
  DIRTY="--allow-dirty"
fi

echo "▼ 配る前の安全確認"
OUT="$(dr apply websystem "$T/nowhere" --yes)";     want_in "配布先がありません" "$OUT" "存在しない配布先は拒否"
OUT="$(dr apply websystem "$PROJ/claude-rules/websystem" --yes $DIRTY)"
want_in "テンプレート自身には配れません" "$OUT" "テンプレート自身には配れない"
if [ -n "$DIRTY" ]; then
  OUT="$(dr apply websystem "$T")"
  want_in "未コミットの変更があります" "$OUT" "未コミットのまま配らせない（版と中身がズレるため）"
fi

echo "▼ 初回配布"
mkdir -p "$T/dest"
OUT="$(dr apply websystem "$T/dest" --dest-name "案件X" --yes $DIRTY)"
want_in "配りました" "$OUT" "配れる"
want_file "$T/dest/CLAUDE.md"                        "ルール層が置かれる"
want_file "$T/dest/documents/handoff.md"             "初回は案件の記録の雛形も置かれる"
want_file "$T/dest/bin/rule-report.sh"               "通知スクリプトが同梱される"
want_file "$T/dest/.claude/rules-version"            "版が刻印される"
VER="$(cat "$T/dest/.claude/rules-version")"
if printf '%s' "$VER" | grep -qE '^websystem@[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9a-f]+(\+dirty)?$'; then
  say_ok "版の形式が <テンプレ>@<日付>/<SHA>"
else
  say_ng "版の形式が <テンプレ>@<日付>/<SHA>" "実際=[$VER]"
fi

echo "▼ 再配布で案件の記録を消さない（この仕組みの肝）"
echo "案件が書いた値" >> "$T/dest/project-config.md"
echo "H-001 のカード" >> "$T/dest/documents/handoff.md"
echo "RI-001 の気づき" >> "$T/dest/documents/rule-improvements.md"
echo "この環境の癖" >> "$T/dest/.claude/rules/private.md"
echo "// 案件が書き換えたルール" >> "$T/dest/rules/README.md" 2>/dev/null || true
OUT="$(dr apply websystem "$T/dest" --yes $DIRTY)"
want_in "触らない" "$OUT" "再配布では触らないファイルを明示する"
want_in "案件が書いた値"   "$(cat "$T/dest/project-config.md")"              "project-config.md を上書きしない"
want_in "H-001 のカード"   "$(cat "$T/dest/documents/handoff.md")"           "documents/handoff.md を上書きしない"
want_in "RI-001 の気づき"  "$(cat "$T/dest/documents/rule-improvements.md")" "rule-improvements.md を上書きしない"
want_in "この環境の癖"     "$(cat "$T/dest/.claude/rules/private.md")"       "private.md を上書きしない（環境の癖が溜まる）"
want_in "Design"           "$(cat "$T/dest/Design.sample.md" | head -3)"     "Design.sample.md は残る"
# ルール層は上書きされる＝案件が勝手に書き換えたルールは戻る（テンプレが正）
want_not_in "案件が書き換えたルール" "$(cat "$T/dest/CLAUDE.md")" "ルール層はテンプレで上書きされる"

echo "▼ 下見（既定）は書き込まない"
mkdir -p "$T/dest2"
OUT="$(dr apply website "$T/dest2" $DIRTY)"
want_in "下見だけです" "$OUT" "--yes が無ければ下見"
if [ -f "$T/dest2/CLAUDE.md" ]; then say_ng "下見では書き込まない"; else say_ok "下見では書き込まない"; fi

echo "▼ レジストリ"
REG="$(cat "$RULES_DIST_REGISTRY")"
want_in "案件X" "$REG"       "配布先が記録される"
want_in "websystem" "$REG"   "テンプレ名が記録される"
want_not_in "$T/dest" "$REG" "実パスは記録しない（--dest-name で付けた名前）"
want_eq "$(grep -c '^| 案件X ' "$RULES_DIST_REGISTRY")" "1" "同じ配布先は1行のまま更新される（2回配っても増えない）"
OUT="$(dr apply website "$T/dest2" --dest-name "案件Y" --yes $DIRTY)"
want_eq "$(grep -cE '^\| 案件[XY] ' "$RULES_DIST_REGISTRY")" "2" "別の配布先は行が増える"
want_in "website" "$(grep '^| 案件Y ' "$RULES_DIST_REGISTRY")" "配布先ごとにテンプレを持つ"
OUT="$(dr list)";            want_in "案件X" "$OUT" "list で一覧できる"
want_in "git log" "$OUT"     "「もう直っているか」の引き方を案内する"

echo "▼ レビュー指摘の再発防止"
# 版セルのバッククォートが更新のたびに増えないか（読むとき剥がし、書くとき付け直す）
OUT="$(dr apply websystem "$T/dest" --dest-name "案件X" --yes $DIRTY)"
ROW="$(grep '^| 案件X ' "$RULES_DIST_REGISTRY")"
want_not_in '``' "$ROW" "版のバッククォートが増殖しない（更新を繰り返しても1組）"
want_in '`websystem@' "$ROW" "版はバッククォートで囲まれている"
# 壊れた行を捨てない（捨てるとその案件の記録が黙って消える）
printf '| 壊れた行 ここに縦棒が無い\n' >> "$RULES_DIST_REGISTRY"
OUT="$(dr apply website "$T/dest2" --dest-name "案件Y" --yes $DIRTY 2>&1)"
want_in "壊れた行" "$(cat "$RULES_DIST_REGISTRY")" "解釈できない行を消さずに残す"
want_in "解釈できない行" "$OUT"                    "解釈できない行があれば知らせる"
want_in "案件X" "$(cat "$RULES_DIST_REGISTRY")"   "壊れた行があっても他の記録は失わない"
# 配布先名が表を壊せない
OUT="$(dr apply website "$T/dest2" --dest-name "壊す|名前" --yes $DIRTY)"
want_in "| や改行は使えません" "$OUT" "配布先名の | を入口で弾く"
# 配布先の外へ書かせない
mkdir -p "$T/outside" "$T/dest3" && ln -s "$T/outside" "$T/dest3/rules"
OUT="$(dr apply website "$T/dest3" --dest-name "案件S" --yes $DIRTY)"
want_in "シンボリックリンク" "$OUT" "symlink 経由で配布先の外へ書かない"
if [ -n "$(ls -A "$T/outside" 2>/dev/null)" ]; then say_ng "リンク先に書き込んでいない"; else say_ok "リンク先に書き込んでいない"; fi
# myagent 自身には配れない（このリポジトリの CLAUDE.md / rules/ を踏み潰さない）
OUT="$(dr apply website "$PROJ" --dest-name "自分" $DIRTY)"
want_in "myagent 自身" "$OUT" "myagent 自身には配れない"
OUT="$(dr apply website "$(dirname "$PROJ")" --dest-name "親" $DIRTY)"
want_in "myagent 自身" "$OUT" "myagent の親にも配れない"

echo "▼ pack（別マシンの案件向け）"
OUT="$(dr pack website "案件Z" --out "$T/dist" $DIRTY)"
want_in "配布用パッケージ" "$OUT" "tar.gz を作れる"
TGZ="$(ls "$T/dist"/*.tar.gz 2>/dev/null | head -1)"
if [ -n "$TGZ" ]; then say_ok "tar.gz が出力される"; else say_ng "tar.gz が出力される"; fi
want_in "website/.claude/rules-version" "$(tar tzf "$TGZ" 2>/dev/null)" "パッケージに版が入る"
want_in "website/bin/rule-report.sh"    "$(tar tzf "$TGZ" 2>/dev/null)" "パッケージに通知スクリプトが入る"
want_in "website@" "$(tar xzf "$TGZ" -O website/.claude/rules-version 2>/dev/null)" "パッケージの版が刻印済み"
want_in "案件Z" "$(cat "$RULES_DIST_REGISTRY")" "pack もレジストリに記録する"

echo
echo "────────────────────────────────"
printf '成功 %d / 失敗 %d\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
