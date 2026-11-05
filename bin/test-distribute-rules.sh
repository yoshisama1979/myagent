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
# 「未コミットだと配らせない」を確かめるために、テンプレへ一時的に未追跡ファイルを置く。
# 途中で落ちても残さないよう、作る前から trap に載せておく。
DIRTY_PROBE="$PROJ/claude-rules/website/.dirty-probe-$$"
trap 'rm -rf "$T"; rm -f "$DIRTY_PROBE"' EXIT

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
if [ -n "$(git -C "$PROJ" status --porcelain -- claude-rules/common/ claude-rules/websystem/ claude-rules/website/)" ]; then
  DIRTY="--allow-dirty"
fi

echo "▼ 共通のものは common/ に1本だけ（コピーを置かない）"
# 以前は website / websystem に同一内容のコピーを置き、「同一であること」をテストで見張って
# いた。common 層が入ってからは**1本しか無い**ので、ズレようがない（＝テストで見張る必要が
# 無くなった）。ここで見るのは「面レイヤーにコピーが戻っていないか」だけ。
for f in bin/rule-report.sh bin/rules-update.sh rules/modes/rules-update.md \
         rules/modes/hana-memo.md rules/modes/mailbox.md .claude/commands/hana-memo.md \
         documents/pending-issues.md documents/rule-improvements.md \
         documents/handoff.md; do
  want_file "$PROJ/claude-rules/common/$f" "common に1本ある: $f"
  if [ -e "$PROJ/claude-rules/website/$f" ] || [ -e "$PROJ/claude-rules/websystem/$f" ]; then
    say_ng "面レイヤーにコピーが戻っていない: $f" "common と二重になると、どちらが正か配布先でしか分からない"
  else
    say_ok "面レイヤーにコピーが戻っていない: $f"
  fi
done
# 実行ビットは配布でも保たれる必要がある（現場は bash bin/… で叩くが、直接実行もされる）
for f in bin/rule-report.sh bin/rules-update.sh; do
  if [ -x "$PROJ/claude-rules/common/$f" ]; then say_ok "実行ビットが立っている: $f"
  else say_ng "実行ビットが立っている: $f"; fi
done

echo "▼ 配る前の安全確認"
OUT="$(dr apply websystem "$T/nowhere" --yes)";     want_in "配布先がありません" "$OUT" "存在しない配布先は拒否"
OUT="$(dr apply websystem "$PROJ/claude-rules/websystem" --yes $DIRTY)"
want_in "テンプレート自身には配れません" "$OUT" "テンプレート自身には配れない"
# ここは**いつも**確かめる。テンプレがたまたま汚れている日だけ動く条件付きテストにすると、
# いちばん効かせたい守り（版の SHA と中身をズラさない）が普段は検証されないまま残る。
: > "$DIRTY_PROBE"
OUT="$(dr apply website "$T")"
rm -f "$DIRTY_PROBE"
want_in "未コミットの変更があります" "$OUT" "未コミットのまま配らせない（版と中身がズレるため）"
want_in ".dirty-probe" "$OUT"                  "止めた理由（どのファイルが未コミットか）を示す"

echo "▼ 初回配布"
mkdir -p "$T/dest"
OUT="$(dr apply websystem "$T/dest" --dest-name "案件X" --yes $DIRTY)"
want_in "配りました" "$OUT" "配れる"
want_file "$T/dest/CLAUDE.md"                        "ルール層が置かれる"
want_file "$T/dest/documents/handoff.md"             "初回は案件の記録の雛形も置かれる"
want_file "$T/dest/bin/rule-report.sh"               "通知スクリプトが同梱される"
want_file "$T/dest/.claude/rules-version"            "版が刻印される"
VER="$(head -1 "$T/dest/.claude/rules-version")"
if printf '%s' "$VER" | grep -qE '^websystem@[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9a-f]+(\+dirty)?$'; then
  say_ok "版の1行目が <プロファイル>@<日付>/<SHA>"
else
  say_ng "版の1行目が <プロファイル>@<日付>/<SHA>" "実際=[$VER]"
fi
# 層が2つ以上なら2行目に内訳が入る（1層なら付けない＝下の「配布プロファイル」節で確かめる）
want_in "layers: common=" "$(cat "$T/dest/.claude/rules-version")" "2層なら版の2行目に層の内訳が入る"

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

echo "▼ 配布プロファイル（層の組み合わせ）"
# 一覧の正は claude-rules/profiles.json ひとつ。読む側が Python 2本と PHP 1本に分かれるので、
# コードに同じ一覧を書き写すと層を足した日に片方だけ古くなる（＝配れるのに取りに来られない）。
PROF="$PROJ/claude-rules/profiles.json"
want_file "$PROF" "配布プロファイルの定義ファイルがある"
want_in "website" "$(cat "$PROF" 2>/dev/null)"   "旧名 website が残っている（現場のトークンがこの名前）"
want_in "websystem" "$(cat "$PROF" 2>/dev/null)" "旧名 websystem が残っている"
HARD="$(grep -rn "('website', 'websystem')\|\"website\", \"websystem\"\|'website', 'websystem'" \
        "$PROJ/bin/distribute-rules.py" "$PROJ/bin/rule-reporter.py" "$PROJ/site/tools/rules/index.php" 2>/dev/null)"
if [ -z "$HARD" ]; then say_ok "一覧をコードに書き写していない（正は profiles.json ひとつ）"
else say_ng "一覧をコードに書き写していない" "$(printf '%s' "$HARD" | tr '\n' ' ' | cut -c1-160)"; fi

OUT="$(dr apply nosuchprofile "$T/dest2" --yes $DIRTY)"
want_in "invalid choice" "$OUT" "知らないプロファイル名は引数の段で弾く"
printf '{"profiles": {"ghost": ["no-such-layer"]}}\n' > "$T/ghost-profiles.json"
OUT="$(RULES_PROFILES="$T/ghost-profiles.json" python3 "$PROJ/bin/distribute-rules.py" apply ghost "$T/dest2" --yes --allow-dirty 2>&1)"
want_in "層がありません" "$OUT" "定義が実在しない層を指していたら止める"

printf '{"profiles": {"x": "not-a-list"}}\n' > "$T/bad-profiles.json"
OUT="$(RULES_PROFILES="$T/bad-profiles.json" python3 "$PROJ/bin/distribute-rules.py" list 2>&1)"
want_in "層名の配列" "$OUT" "壊れた定義では黙って既定に落ちず止まる"
OUT="$(RULES_PROFILES="$T/none.json" python3 "$PROJ/bin/distribute-rules.py" list 2>&1)"
want_in "定義がありません" "$OUT" "定義が無ければ止まる"

# 🚨 ここから下は 2026-10-28 の Codex レビューで見つかった穴の再発防止。
# プロファイル名・層名は**コード内の定数から JSON 由来の値になった**ので、形の検証が要る。
# 検証が無いと、層名に絶対パスを書くだけで claude-rules の外のファイルが配られる（実証済み）。
mkdir -p "$T/outside/secret" && echo "テンプレ外のファイル" > "$T/outside/secret/leak.md"
badprof(){ printf '%s\n' "$1" > "$T/p.json"; RULES_PROFILES="$T/p.json" \
  RULES_DIST_REGISTRY="$T/reg2.md" python3 "$PROJ/bin/distribute-rules.py" "${@:2}" 2>&1; }

mkdir -p "$T/escape"
OUT="$(badprof "{\"profiles\": {\"evil\": [\"$T/outside/secret\"]}}" apply evil "$T/escape" --dest-name x --yes --allow-dirty)"
want_in "層名" "$OUT" "層名が絶対パスなら入口で弾く"
if [ -e "$T/escape/leak.md" ]; then say_ng "テンプレ外のファイルを配っていない" "leak.md が配布された"
else say_ok "テンプレ外のファイルを配っていない"; fi
OUT="$(badprof '{"profiles": {"evil": ["../../etc"]}}' list)"
want_in "層名" "$OUT" "層名に .. があれば弾く"
OUT="$(badprof '{"profiles": {"../evil": ["website"]}}' list)"
want_in "プロファイル名" "$OUT" "プロファイル名に .. があれば弾く"
OUT="$(badprof '{"profiles": {"Evil Name": ["website"]}}' list)"
want_in "プロファイル名" "$OUT" "プロファイル名に大文字・空白があれば弾く"
OUT="$(badprof '{"profiles": {"a": ["x","x"]}}' list)"
want_in "同じ層が2回" "$OUT" "同じ層を2回並べたら弾く"

# 🚨 名前の形の判定は **3箇所**にある（Python・PHP・配布物の bash）。言語が違うので1つに
# 統合できないぶん、**同じ文字集合であること**を機械で見張る。ズレると「配布はできるのに
# 現場の報告が別スレッドへ落ちる」が黙って起きる（_ を許す／許さないで実際にズレていた）。
PY_SET="$(grep -o '\^\[a-z0-9\]\[a-z0-9-\]\*\$' "$PROJ/bin/distribute-rules.py" | head -1)"
PHP_SET="$(grep -o '\^\[a-z0-9\]\[a-z0-9-\]\*' "$PROJ/site/tools/rules/index.php" | head -1)"
SH_SET="$(grep -o '\*\[!a-z0-9-\]\*' "$PROJ/claude-rules/common/bin/rule-report.sh" | head -1)"
want_eq "$PY_SET" '^[a-z0-9][a-z0-9-]*$'  "Python の名前の形が [a-z0-9-]"
want_eq "$PHP_SET" '^[a-z0-9][a-z0-9-]*'  "PHP の名前の形が Python と同じ文字集合"
want_eq "$SH_SET" '*[!a-z0-9-]*'          "現場 bash の名前の形も同じ文字集合"

# 形が違う JSON でトレースバックを出さない（＝必ず「❌ …」で止まる）
for bad in '{"profiles": []}' '{"profiles": ["website"]}' '{"profiles": {}}' '[]' '{}'; do
  OUT="$(badprof "$bad" list)"
  if has "Traceback" "$OUT"; then say_ng "壊れた形でトレースバックを出さない: $bad" "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-120)"
  elif has "❌" "$OUT"; then say_ok "壊れた形でも明示エラーで止まる: $bad"
  else say_ng "壊れた形で止まる: $bad" "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-120)"; fi
done

# 読み取り系が同じ判断をするか。以前は distribute-rules が落ち rule-reporter は通る、と
# **同じ設定ファイルで判断が割れていた**。設定の不備だと分かるメッセージ（profiles.json を
# 名指し）が出ることまで見る＝別の理由のエラーを拾って誤って通らないように。
printf '{"profiles": ["website"]}\n' > "$T/p.json"
OUT="$(RULES_PROFILES="$T/p.json" RULE_REPORTER_TOKENS="$T/tok.json" RULE_REPORTER_LEDGER="$T/led.md" \
       python3 "$PROJ/bin/rule-reporter.py" list 2>&1)"
want_not_in "Traceback" "$OUT" "rule-reporter が壊れた設定でトレースバックを出さない"
want_in "profiles.json" "$OUT" "rule-reporter も設定の不備として止まる（読み取りの判断は1箇所）"

# 層が3つ以上でも衝突を見つける
mkdir -p "$T/src3/l1" "$T/src3/l2" "$T/src3/l3"
echo a > "$T/src3/l1/a.md"; echo b > "$T/src3/l2/b.md"; echo a2 > "$T/src3/l3/a.md"
printf '{"profiles": {"three": ["l1","l2","l3"]}}\n' > "$T/p3.json"
mkdir -p "$T/d3"
OUT="$(RULES_SRC="$T/src3" RULES_PROFILES="$T/p3.json" RULES_DIST_REGISTRY="$T/reg2.md" \
       python3 "$PROJ/bin/distribute-rules.py" apply three "$T/d3" --yes --allow-dirty 2>&1)"
want_in "同じパスが2つの層にあります" "$OUT" "3層以上でも同じパスの衝突を見つける"
want_in "a.md" "$OUT"                                "衝突したパスを示す"

# 🚨 profiles.json は配布物の中身を決めるので、版の対象集合に入っていないといけない
# （層を1つ足したのに版が進まないと、受け取り側の「もう直っているか」の判定が嘘になる）
PR="$(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("dr",sys.argv[1]+"/bin/distribute-rules.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(" ".join(m.layer_rels("website")))' "$PROJ" 2>&1)"
want_in "claude-rules/profiles.json" "$PR" "版の対象集合に profiles.json が入っている（層構成の変更が版に出る）"

echo "▼ 追補（append）＝同じパスを層の順に連結する（REDESIGN ステップ5-3 の器）"
# なぜ要るか：CLAUDE.md・director.md などは「共通の土台＋面ごとの追加」という形なので、
# common に1本置くには**同じパスが複数層にあっても連結する**仕組みが要る。
# 連結しない従来の挙動（原則②＝重複定義しない）は、追補に挙げていないパスでは変えない。
mkdir -p "$T/srcA/base" "$T/srcA/face" "$T/srcA/base/documents" "$T/srcA/face/documents" "$T/dA/documents"
printf '# 土台\n\n共通の行\n' > "$T/srcA/base/CLAUDE.md"
printf '面の行\n'             > "$T/srcA/face/CLAUDE.md"
printf 'base-only\n'          > "$T/srcA/base/only.md"
printf '雛形（共通）\n'        > "$T/srcA/base/documents/handoff.md"
printf '雛形（面）\n'          > "$T/srcA/face/documents/handoff.md"
printf '案件が書いたカード\n'  > "$T/dA/documents/handoff.md"
printf '{"profiles": {"mix": ["base","face"]}, "append": ["CLAUDE.md","only.md","documents/handoff.md"]}\n' > "$T/pA.json"
drA(){ RULES_SRC="$T/srcA" RULES_PROFILES="$T/pA.json" RULES_DIST_REGISTRY="$T/regA.md" \
       python3 "$PROJ/bin/distribute-rules.py" "$@" 2>&1; }
OUT="$(drA apply mix "$T/dA" --yes --allow-dirty)"
want_in "配りました" "$OUT"                      "追補に挙げたパスが2層にあっても配れる（衝突で止まらない）"
CA="$(cat "$T/dA/CLAUDE.md" 2>/dev/null)"
want_in "共通の行" "$CA"                         "追補：共通層の中身が入る"
want_in "面の行" "$CA"                           "追補：面層の中身も入る（片方が消えない）"
want_eq "$(printf '%s\n' "$CA" | awk '/共通の行/{a=NR} /面の行/{b=NR} END{print (a&&b&&a<b)?"共通が先":"順序がおかしい"}')" \
        "共通が先" "追補：連結の順は profiles.json の層の順"
want_in "face 層" "$CA"                          "追補：どの層から来た行かが分かる境界が入る"
want_eq "$(cat "$T/dA/only.md")" "base-only"     "追補に挙げても1層にしか無ければ中身はそのまま（境界を足さない）"
want_eq "$(cat "$T/dA/documents/handoff.md")" "案件が書いたカード" \
        "追補でも案件の記録は上書きしない（KEEP_IF_EXISTS が勝つ）"
# 層ごとの枚数にも数える（追補の分が数え落ちると「層が入っていない」と誤読する）
want_in "base（" "$OUT"                          "追補：層ごとの枚数に数える"
# 🔴1 配布元のシンボリックリンクは読まない（リンク先の中身を配布物に混ぜない）
mkdir -p "$T/srcL/base" "$T/srcL/face" "$T/dL"
printf 'ひそかに読まれては困る中身\n' > "$T/outside.md"
printf '# 土台\n' > "$T/srcL/base/CLAUDE.md"
ln -s "$T/outside.md" "$T/srcL/face/CLAUDE.md"
printf '{"profiles": {"mix": ["base","face"]}, "append": ["CLAUDE.md"]}\n' > "$T/pL.json"
drL(){ RULES_SRC="$T/srcL" RULES_PROFILES="$T/pL.json" RULES_DIST_REGISTRY="$T/regL.md" \
       python3 "$PROJ/bin/distribute-rules.py" "$@" 2>&1; }
OUT="$(drL apply mix "$T/dL" --yes --allow-dirty)"
want_in "シンボリックリンク" "$OUT"                  "配布元がシンボリックリンクなら止める（リンク先を配らない）"
want_not_in "ひそかに読まれては困る中身" "$(cat "$T/dL/CLAUDE.md" 2>/dev/null || true)" "リンク先の中身が配布物に入らない"
# 層の中のファイルを指すリンクでも止める（「外向きでなければ良い」にしない）
rm "$T/srcL/face/CLAUDE.md"; ln -s "$T/srcL/base/CLAUDE.md" "$T/srcL/face/CLAUDE.md"
want_in "シンボリックリンク" "$(drL apply mix "$T/dL" --yes --allow-dirty)" "層の中を指すリンクでも止める"
# ディレクトリのリンクでも止める
rm "$T/srcL/face/CLAUDE.md"; mkdir -p "$T/srcL/face/real"; ln -s "$T/srcL/face/real" "$T/srcL/face/link"
want_in "シンボリックリンク" "$(drL apply mix "$T/dL" --yes --allow-dirty)" "ディレクトリのリンクでも止める"
rm -rf "$T/srcL/face/link" "$T/srcL/face/real"

# 🔴2 追補する層で実行ビットが食い違っていたら、黙ってどちらかに決めずに止める
mkdir -p "$T/srcM/base" "$T/srcM/face" "$T/dM"
printf '#!/bin/sh\necho base\n' > "$T/srcM/base/tool.sh"; chmod 644 "$T/srcM/base/tool.sh"
printf 'echo face\n'           > "$T/srcM/face/tool.sh"; chmod 755 "$T/srcM/face/tool.sh"
printf '{"profiles": {"mix": ["base","face"]}, "append": ["tool.sh"]}\n' > "$T/pM.json"
drM(){ RULES_SRC="$T/srcM" RULES_PROFILES="$T/pM.json" RULES_DIST_REGISTRY="$T/regM.md" \
       python3 "$PROJ/bin/distribute-rules.py" "$@" 2>&1; }
OUT="$(drM apply mix "$T/dM" --yes --allow-dirty)"
want_in "実行ビット" "$OUT"                          "追補する層で実行ビットが食い違えば止める"
if [ -e "$T/dM/tool.sh" ]; then say_ng "食い違いのときは1ファイルも書かない" "tool.sh が書かれている"
else say_ok "食い違いのときは1ファイルも書かない"; fi
chmod 755 "$T/srcM/base/tool.sh"
OUT="$(drM apply mix "$T/dM" --yes --allow-dirty)"
want_in "配りました" "$OUT"                          "揃っていれば配れる"
if [ -x "$T/dM/tool.sh" ]; then say_ok "揃った実行ビットが配布先でも立つ"; else say_ng "揃った実行ビットが配布先でも立つ"; fi

# 🟡3 書く前に全部読んで検証する＝途中で失敗しても部分配布にしない
mkdir -p "$T/srcU/base" "$T/srcU/face" "$T/dU"
printf '# 土台\n' > "$T/srcU/base/CLAUDE.md"
printf 'ok\n'     > "$T/srcU/base/zz-other.md"
printf '\xff\xfe これは UTF-8 ではない\n' > "$T/srcU/face/CLAUDE.md"
printf '{"profiles": {"mix": ["base","face"]}, "append": ["CLAUDE.md"]}\n' > "$T/pU.json"
OUT="$(RULES_SRC="$T/srcU" RULES_PROFILES="$T/pU.json" RULES_DIST_REGISTRY="$T/regU.md" \
       python3 "$PROJ/bin/distribute-rules.py" apply mix "$T/dU" --yes --allow-dirty 2>&1)"
want_in "UTF-8" "$OUT"                               "追補元が UTF-8 で読めなければ止める"
if [ -e "$T/dU/zz-other.md" ]; then say_ng "読めないファイルがあるときは1ファイルも書かない" "先行ファイルが書かれている"
else say_ok "読めないファイルがあるときは1ファイルも書かない"; fi

# 🟡5 連結の改行の仕様（末尾改行は1つに揃える・CRLF は LF に・空の層は境界だけ残さない）
mkdir -p "$T/srcN/base" "$T/srcN/face" "$T/dN"
printf '# 土台（末尾に改行なし）' > "$T/srcN/base/CLAUDE.md"
printf '面の行\r\n\r\n\r\n'       > "$T/srcN/face/CLAUDE.md"
: > "$T/srcN/base/empty.md"
printf '面だけの行\n'             > "$T/srcN/face/empty.md"
printf '{"profiles": {"mix": ["base","face"]}, "append": ["CLAUDE.md","empty.md"]}\n' > "$T/pN.json"
OUT="$(RULES_SRC="$T/srcN" RULES_PROFILES="$T/pN.json" RULES_DIST_REGISTRY="$T/regN.md" \
       python3 "$PROJ/bin/distribute-rules.py" apply mix "$T/dN" --yes --allow-dirty 2>&1)"
want_in "配りました" "$OUT" "改行が揃っていなくても配れる"
want_eq "$(tail -c 1 "$T/dN/CLAUDE.md" | od -An -c | tr -d ' \n')" '\n' "連結の末尾は改行で終わる"
want_not_in '\\n\\n' "$(tail -c 2 "$T/dN/CLAUDE.md" | od -An -c | tr -d ' \n')" "末尾の改行は1つだけ（空行で終わらない）"
want_eq "$(grep -c $'\r' "$T/dN/CLAUDE.md" || true)" "0" "CRLF は LF に揃える"
want_eq "$(head -1 "$T/dN/empty.md")" "面だけの行" "空の層は飛ばす（空行や境界だけを残さない）"

# 🟢8 3層の追補も層の順に連結し、寄与を3層それぞれに数える
mkdir -p "$T/srcT/a" "$T/srcT/b" "$T/srcT/c" "$T/dT"
printf 'A\n' > "$T/srcT/a/x.md"; printf 'B\n' > "$T/srcT/b/x.md"; printf 'C\n' > "$T/srcT/c/x.md"
printf '{"profiles": {"three": ["a","b","c"]}, "append": ["x.md"]}\n' > "$T/pT.json"
OUT="$(RULES_SRC="$T/srcT" RULES_PROFILES="$T/pT.json" RULES_DIST_REGISTRY="$T/regT.md" \
       python3 "$PROJ/bin/distribute-rules.py" apply three "$T/dT" --yes --allow-dirty 2>&1)"
want_eq "$(tr -d '\n' < "$T/dT/x.md" | sed 's/<!--[^>]*-->//g')" "ABC" "3層でも層の順に連結する"
want_in "層の寄与" "$OUT" "層ごとの数は「寄与」と明示する（総ファイル数と読み違えない）"
want_in "a（1）" "$OUT" "3層それぞれに1件ずつ数える"
want_in "c（1）" "$OUT" "3層目も数える"

# 追補に挙げていない同名パスは、今までどおり止める
mkdir -p "$T/srcB/l1" "$T/srcB/l2" "$T/dB"
echo x > "$T/srcB/l1/dup.md"; echo y > "$T/srcB/l2/dup.md"
printf '{"profiles": {"two": ["l1","l2"]}, "append": ["CLAUDE.md"]}\n' > "$T/pB.json"
OUT="$(RULES_SRC="$T/srcB" RULES_PROFILES="$T/pB.json" RULES_DIST_REGISTRY="$T/regB.md" \
       python3 "$PROJ/bin/distribute-rules.py" apply two "$T/dB" --yes --allow-dirty 2>&1)"
want_in "同じパスが2つの層にあります" "$OUT" "追補に挙げていないパスの衝突は今までどおり止める"
# 追補の書き方が壊れていたら、黙って無視せず止める
badapp(){ printf '%s\n' "$1" > "$T/pC.json"; RULES_SRC="$T/srcA" RULES_PROFILES="$T/pC.json" \
          RULES_DIST_REGISTRY="$T/regC.md" python3 "$PROJ/bin/distribute-rules.py" list 2>&1; }
want_in "append"   "$(badapp '{"profiles":{"mix":["base","face"]},"append":"CLAUDE.md"}')" "append が配列でなければ止まる"
want_in "ディレクトリ" "$(badapp '{"profiles":{"mix":["base","face"]},"append":["documents/"]}')" "append にディレクトリは書けない"
want_in "append"   "$(badapp '{"profiles":{"mix":["base","face"]},"append":["../x.md"]}')"   "append に配布先の外へ出るパスは書けない"
want_in "append"   "$(badapp '{"profiles":{"mix":["base","face"]},"append":["a.md","a.md"]}')" "append に同じパスを2回書けない"
# 🟡4 append のパスは正規形だけ受ける（宣言と実際の相対パスがズレると衝突で止まる）
want_in "append" "$(badapp '{"profiles":{"mix":["base","face"]},"append":["./CLAUDE.md"]}')"  "append に ./ 付きは書けない"
want_in "append" "$(badapp '{"profiles":{"mix":["base","face"]},"append":["a//b.md"]}')"      "append に空の区切りは書けない"
want_in "append" "$(badapp '{"profiles":{"mix":["base","face"]},"append":["a\\b.md"]}')"      "append に逆斜線は書けない"


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
# 規定形の1行（rules/testing.md §6-5）。これが無いと bin/test-all.sh が項目数を0と数える。
printf '合計: 合格 %d ／ 不合格 %d\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
