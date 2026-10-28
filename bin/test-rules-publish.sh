#!/usr/bin/env bash
# bin/rules-publish.py の回帰テスト。
#
# testing.md §2 の「テスト必須」に当たる＝①状態を書く（配信ディレクトリを差し替える）
# ②判定を持つ（どの層を束ねるか・公開中かどうか・未公開の変更があるか）。
#
# ここで守りたい不変条件：
#   - **公開が中途半端な瞬間を配らない**（.publishing が残ったまま終わらない）
#   - **配信物に版と「守るファイルの一覧」が同梱される**（現場がそれを読んで記録を守る）
#   - **プロファイルの層をすべて束ねる**（層が増えた日に片方だけ配る事故を起こさない）
#
# ⚠️ 本番の配信ディレクトリ（data/cache/rules-release）には触れない：RULES_RELEASE_DIR を
#    /tmp に差し替える。テンプレート自体は読むだけ。
# 触ったら必ず流すこと：bash bin/test-rules-publish.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/rules-publish.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

export RULES_RELEASE_DIR="$T/release"
rp(){ python3 "$PROJ/bin/rules-publish.py" "$@" 2>&1; }

P=0; N=0
say_ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
say_ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      → %s\n' "$2"; fi; }
has(){ case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; else say_ok "$3"; fi; }
want_eq(){     if [ "$1" = "$2" ]; then say_ok "$3"; else say_ng "$3" "実際=[$1] 期待=[$2]"; fi; }
want_file(){   if [ -f "$1" ]; then say_ok "$2"; else say_ng "$2" "$1 が無い"; fi; }
jq_get(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2" 2>/dev/null; }

DIRTY=""
if [ -n "$(git -C "$PROJ" status --porcelain -- claude-rules/)" ]; then DIRTY="--allow-dirty"; fi

echo "▼ 未公開のとき"
OUT="$(rp status)"
want_in "未公開" "$OUT" "公開していなければ status が未公開と言う"
OUT="$(rp unpublish website)"
want_in "もともと配信していません" "$OUT" "公開していないものを止めても落ちない"
OUT="$(rp publish nosuchprofile)"
want_in "invalid choice" "$OUT" "知らないプロファイルは引数の段で弾く"

echo "▼ 公開（いまの website＝common + website の2層）"
OUT="$(rp publish website $DIRTY)"
want_in "配信する版を更新しました" "$OUT" "公開できる"
D="$T/release/website"
want_file "$D/package.tar.gz" "配布物が置かれる"
want_file "$D/meta.json"      "版の情報が置かれる"
want_file "$D/changelog.tsv"  "変更点が同梱される"
if [ -e "$D/.publishing" ]; then say_ng "公開の目印を残さない（残ると受け口が配信を止める）"; else say_ok "公開の目印を残さない（残ると受け口が配信を止める）"; fi
for f in .package.tar.gz.tmp .meta.json.tmp .changelog.tsv.tmp; do
  if [ -e "$D/$f" ]; then say_ng "一時ファイル $f を残さない"; else say_ok "一時ファイル $f を残さない"; fi
done
TAR="$(tar tzf "$D/package.tar.gz" 2>/dev/null)"
want_in "website/.claude/rules-version" "$TAR" "配布物に版が入る"
want_in "website/.claude/rules-keep"    "$TAR" "配布物に「守るファイルの一覧」が入る"
want_in "website/bin/rules-update.sh"   "$TAR" "配布物に更新スクリプトが入る"
KEEP="$(tar xzf "$D/package.tar.gz" -O website/.claude/rules-keep 2>/dev/null)"
want_in "documents/" "$KEEP"       "守る一覧に documents/ が入る（案件の記録）"
want_in "project-config.md" "$KEEP" "守る一覧に project-config.md が入る"
want_eq "$(jq_get "$D/meta.json" profile)" "website" "meta にプロファイル名が入る"
want_eq "$(jq_get "$D/meta.json" layers)" "['common', 'website']" "meta に束ねた層が入る"
want_in "website@" "$(jq_get "$D/meta.json" version)" "meta の版がプロファイル名で始まる"
SHA256="$(jq_get "$D/meta.json" sha256)"
want_eq "$(sha256sum "$D/package.tar.gz" | cut -d' ' -f1)" "$SHA256" "meta の sha256 が配布物と一致する（壊れた取得を現場が検出できる）"
# 層が2つ以上なら2行目に内訳が入る（1層なら付けない＝下の mix/solo で確かめる）
want_in "layers: common=" "$(tar xzf "$D/package.tar.gz" -O website/.claude/rules-version 2>/dev/null)" \
  "刻印の2行目に層の内訳が入る"

echo "▼ status"
OUT="$(rp status)"
want_in "website" "$OUT"   "公開中のプロファイルが出る"
want_in "公開 " "$OUT"     "公開日時が出る"
: > "$D/.publishing"
OUT="$(rp status)"
want_in "公開が途中で終わっています" "$OUT" "公開が中断していたら status が警告する"
rm -f "$D/.publishing"

echo "▼ SHA を引けない版は公開させない"
# 公開は稼働案件が取りに来る口。層が git に入っていない版（SHA が `nogit`）を公開すると、
# 受け取り側が changelog から「自分の版より後の変更」を辿れなくなる＝更新の判断ができない。
# `--allow-dirty` は `+dirty`（SHA はある）までの逃げ道で、SHA が無い版の公開は許さない。
#
# ⚠️ 複数層を束ねた公開そのものは、上の website（common + website の2層）で確認済み。
#    ここは「git に無い層を公開させない」ことだけを見る。
mkdir -p "$T/src/lcommon/rules" "$T/src/lsite"
echo "common の CLAUDE" > "$T/src/lcommon/CLAUDE.md"
echo "common のルール"  > "$T/src/lcommon/rules/common-rule.md"
echo "site のルール"    > "$T/src/lsite/site-only.md"
printf '{"profiles": {"mix": ["lcommon","lsite"]}}\n' > "$T/mix-profiles.json"
L(){ RULES_SRC="$T/src" RULES_PROFILES="$T/mix-profiles.json" python3 "$PROJ/bin/rules-publish.py" "$@" 2>&1; }
OUT="$(L publish mix)"
want_in "コミットが見つかりません" "$OUT" "版の SHA が引けない層は既定で公開させない"
OUT="$(L publish mix --allow-dirty)"
want_in "SHA を引けないので公開できません" "$OUT" "--allow-dirty でも SHA の無い版は公開させない"
want_in "changelog" "$OUT"                            "止めた理由（受け取り側が変更点を辿れない）を示す"
if [ -d "$T/release/mix" ] && [ -f "$T/release/mix/meta.json" ]; then
  say_ng "公開を止めたら配信物を作らない" "meta.json ができている"
else
  say_ok "公開を止めたら配信物を作らない"
fi

echo "▼ 配信を止める"
OUT="$(rp unpublish website)"
want_in "配信を止めました" "$OUT" "止められる"
if [ -d "$D" ]; then say_ng "止めたら配信ディレクトリが消える"; else say_ok "止めたら配信ディレクトリが消える"; fi
want_in "トークン" "$OUT" "取り消したいのがトークンなら別の道具だと案内する"

echo
echo "────────────────────────────────"
printf '成功 %d / 失敗 %d\n' "$P" "$N"
# 規定形の1行（rules/testing.md §6-5）。これが無いと bin/test-all.sh が項目数を0と数える。
printf '合計: 合格 %d ／ 不合格 %d\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
