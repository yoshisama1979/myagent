#!/usr/bin/env bash
# 連続タイムアウトのクールダウン（agent-tick.sh）の回帰テスト。
#
# 設計：ロジックを書き写さず、実ソースから該当ブロックを抽出して実行する。
#       本体を直したらテストが自動で追随する（写した瞬間に「テストだけ正しい」状態が生まれる）。
#
# 触ったら必ず流すこと：bash bin/test-cooldown.sh
set -u

PROJ_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 起動位置ガード（コピーを別の場所から流すと PROJ がずれ、無関係な結果で合格/不合格が出る）
if [ ! -f "$PROJ_REAL/bin/agent-tick.sh" ]; then
  echo "❌ bin/agent-tick.sh が見つからない（起動位置がおかしい）: $PROJ_REAL" >&2
  exit 2
fi

PASS=0; NG=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
ng() { NG=$((NG+1)); echo "  ❌ $1"; [ $# -ge 2 ] && echo "      → $2"; }
eq() { # eq 説明 期待 実際
  if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "期待=$2 実際=$3"; fi
}
between() { # between 説明 下限 上限 実際
  if [ "$4" -ge "$2" ] && [ "$4" -le "$3" ]; then ok "$1"; else ng "$1" "期待=$2〜$3 実際=$4"; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/data/overseer"

# --- 実ソースからクールダウンのブロックだけ抜き出す ---
awk '/^# --- 連続タイムアウトのクールダウン/,/^# --- 反応起動の対象を数える/' \
    "$PROJ_REAL/bin/agent-tick.sh" | sed '$d' > "$T/block.sh"

grep -q 'cooldown_set()'    "$T/block.sh" || { echo "❌ 抽出失敗：cooldown_set が無い（マーカーが変わった？）" >&2; exit 2; }
grep -q 'cooldown_remain()' "$T/block.sh" || { echo "❌ 抽出失敗：cooldown_remain が無い" >&2; exit 2; }
grep -q 'cooldown_note()'   "$T/block.sh" || { echo "❌ 抽出失敗：cooldown_note が無い" >&2; exit 2; }

# 抽出したブロックを、本物の data/overseer ではなく一時ディレクトリで動かすための土台
cat >"$T/harness.sh" <<'EOS'
PROJ="__T__"
LOG="__T__/tick.log"
now() { echo "TEST"; }
EOS
sed -i "s#__T__#$T#g" "$T/harness.sh"
grep -q "$T" "$T/harness.sh" || { echo "❌ 置換失敗：本物の data/overseer を触る危険があるため中止" >&2; exit 2; }

# shellcheck disable=SC1090
run() { ( set -u; . "$T/harness.sh"; . "$T/block.sh"; eval "$@" ); }

echo "=== クールダウン ==="

# 1) 初回＝状態ファイルが無いときは待たない
eq "初回は待たない（remain=0）" "0" "$(run 'cooldown_remain hp-loop:ycom')"

# 2) 1回目のタイムアウト → 連続1回目・30分
eq "1回目の連続回数は 1" "1" "$(run 'cooldown_set hp-loop:ycom')"
between "1回目は約30分待つ" 1750 1800 "$(run 'cooldown_remain hp-loop:ycom')"

# 3) 待っている間は待ち続ける（0にならない）
run 'cooldown_remain hp-loop:ycom' | grep -qv '^0$' && ok "待機中は remain>0" || ng "待機中は remain>0"

# 4) 2回目 → 6時間へ延びる（同じ処理を1日中回し続けない）
eq "2回目の連続回数は 2" "2" "$(run 'cooldown_set hp-loop:ycom')"
between "2回目は約6時間待つ" 21550 21600 "$(run 'cooldown_remain hp-loop:ycom')"

# 5) 3回目以降も6時間のまま（際限なく延びない）
eq "3回目の連続回数は 3" "3" "$(run 'cooldown_set hp-loop:ycom')"
between "3回目も約6時間" 21550 21600 "$(run 'cooldown_remain hp-loop:ycom')"

# 6) 成功でリセット
run 'cooldown_clear hp-loop:ycom'
eq "成功したらリセットされる" "0" "$(run 'cooldown_remain hp-loop:ycom')"
eq "リセット後の連続回数は 1 に戻る" "1" "$(run 'cooldown_set hp-loop:ycom')"
run 'cooldown_clear hp-loop:ycom'

# 7) 期限切れ＝解除時刻を過ぎたら動く（永久に止まらない）
printf '1 100\n' >"$T/data/overseer/.cooldown-hp_loop_ycom"
eq "期限切れなら待たない" "0" "$(run 'cooldown_remain hp-loop:ycom')"
run 'cooldown_clear hp-loop:ycom'

# 7b) 解除時刻が異常に未来＝6時間へ丸める（Codex🔴7）。捨てると即再実行・信じると長期停止になるため
printf '2 9999999999\n' >"$T/data/overseer/.cooldown-hp_loop_ycom"
between "壊れた未来の解除時刻は6時間へ丸める" 21550 21600 "$(run 'cooldown_remain hp-loop:ycom')"
between "丸めた値がファイルにも書き戻る" 21550 21600 "$(run 'cooldown_remain hp-loop:ycom')"
run 'cooldown_clear hp-loop:ycom'

# 7c) 連続回数の時効（Codex🟡8）＝前回の冷却明けから24時間以上空いていれば「連続」ではない
printf '3 1000\n' >"$T/data/overseer/.cooldown-hp_loop_ycom"   # 遠い過去に明けた3回目
eq "十分に間が空いていれば1回目に戻る" "1" "$(run 'cooldown_set hp-loop:ycom')"
between "その待ち時間も30分に戻る" 1750 1800 "$(run 'cooldown_remain hp-loop:ycom')"
run 'cooldown_clear hp-loop:ycom'

# 7c-2) cooldown_hold＝連続回数を進めずに冷ます（クレジット切れ用）
run 'cooldown_clear x; cooldown_set x' >/dev/null            # まず連続1回目にする
run 'cooldown_hold x 1800'
between "hold は指定時間だけ冷ます" 1750 1800 "$(run 'cooldown_remain x')"
eq "hold は連続回数を進めない（次の失敗が1回目に戻る）" "1" "$(run 'cooldown_set x')"
run 'cooldown_clear x'

# 7d) 直前に明けたばかりなら連続として扱う（時効が効きすぎない）
printf '1 %s\n' "$(( $(date +%s) - 60 ))" >"$T/data/overseer/.cooldown-hp_loop_ycom"
eq "明けた直後の失敗は連続2回目" "2" "$(run 'cooldown_set hp-loop:ycom')"
run 'cooldown_clear hp-loop:ycom'

# 8) 壊れたファイルは捨てて通常運転に戻す（無人ループを永久停止させない）
printf 'こわれています\n' >"$T/data/overseer/.cooldown-hp_loop_ycom"
eq "壊れた状態ファイルでも待たない" "0" "$(run 'cooldown_remain hp-loop:ycom')"
[ -f "$T/data/overseer/.cooldown-hp_loop_ycom" ] \
  && ng "壊れた状態ファイルは削除される" "残っている＝毎tickで同じ判定を繰り返す" \
  || ok "壊れた状態ファイルは削除される"

# 9) ラベルのサニタイズ（ファイル名にコロンやスラッシュを持ち込まない）
run 'cooldown_set hp-loop:ycom' >/dev/null
[ -f "$T/data/overseer/.cooldown-hp_loop_ycom" ] \
  && ok "ラベルの記号は _ に変換される" \
  || ng "ラベルの記号は _ に変換される" "$(ls -a "$T/data/overseer" | tr '\n' ' ')"

# 10) ラベルごとに独立（ycom を冷ましても yoshida は動く）
eq "別サイトは巻き込まれない" "0" "$(run 'cooldown_remain hp-loop:yoshida')"

# 11) 通知文の待ち時間表記が、実際の分岐と一致している（片方だけ直して食い違わせない）
eq "1回目の表記は30分" "30分" "$(run 'cooldown_note 1')"
eq "2回目の表記は6時間" "6時間" "$(run 'cooldown_note 2')"
eq "3回目の表記も6時間" "6時間" "$(run 'cooldown_note 3')"

# 12) cooldown_set の標準出力は数字だけ（通知文に余計な文字を混ぜない）
run 'cooldown_clear x; cooldown_set x' | grep -qE '^[0-9]+$' \
  && ok "cooldown_set の出力は数字のみ" || ng "cooldown_set の出力は数字のみ"

echo
echo "=== 呼び出し側（dispatch）の配線 ==="
SRC="$PROJ_REAL/bin/agent-tick.sh"

# Codex🔴1：当初は daily を冷却の対象外にしていたが、「反応tickがタイムアウト→ロック待ちの daily が
# 即起動」で今日の事故がそのまま再現する。daily も冷却を尊重し、順延の印を残すこと。
grep -q '\[ "\$force" -eq 0 \] && cd_left=\$(cooldown_remain "\$label")' "$SRC" \
  && ng "daily もクールダウンを尊重する" "force=1 が冷却を迂回している＝事故が再現する" \
  || ok "daily もクールダウンを尊重する"

grep -q 'daily_due_file' "$SRC" \
  && ok "順延した daily の印を残す仕組みがある" \
  || ng "順延した daily の印を残す仕組みがある" "単純スキップだとその日の解析が落ちる"

sed -n '/直前が異常終了していたら/,/^    fi$/p' "$SRC" | grep -q 'daily順延' \
  && ok "冷却で見送る daily は順延として記録する" \
  || ng "冷却で見送る daily は順延として記録する"

grep -q 'date +%F' "$SRC" \
  && ok "順延の印は日付つき（古い借金を溜め込まない）" \
  || ng "順延の印は日付つき"

# 全異常終了にバックオフ（Codex🔴4）＝rc の分岐より前で1回だけ冷却を進める形になっているか
CD_SET_LINE=$(grep -n 'cd_msg=\$(cooldown_apply "\$label")' "$SRC" | head -1 | cut -d: -f1)
OOM_BRANCH=$(grep -n 'if \[ "\$rc" -eq 137 \]' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$CD_SET_LINE" ] && [ -n "$OOM_BRANCH" ] && [ "$CD_SET_LINE" -lt "$OOM_BRANCH" ]; then
  ok "タイムアウト以外の異常終了にも冷却がかかる"
else
  ng "タイムアウト以外の異常終了にも冷却がかかる" "分岐の内側でしか呼ばれていない（cd=$CD_SET_LINE oom=$OOM_BRANCH）"
fi

# 冷却を進める経路は必ず通知文を伴う（cooldown_apply に集約＝片方だけ書き忘れる経路を作らない）
APPLY_N=$(grep -c 'cooldown_apply "\$label"' "$SRC")
SET_N=$(grep -c 'cooldown_set "\$1"' "$SRC")
if [ "$APPLY_N" -ge 3 ] && [ "$SET_N" -eq 1 ]; then
  ok "冷却の設定と通知文の組み立てが1箇所に集約されている（$APPLY_N 経路）"
else
  ng "冷却の設定と通知文が集約されている" "apply=$APPLY_N set=$SET_N（cooldown_set の直接呼び出しが残っている）"
fi

# 無進捗の検知（Codex🔴5）
grep -q 'trig_before' "$SRC" && ok "起動の引き金になった便を控えている" \
  || ng "起動の引き金になった便を控えている"
grep -q 'label-noprogress' "$SRC" \
  && ok "完走しても未処理なら無進捗として冷やす" \
  || ng "完走しても未処理なら無進捗として冷やす" "exit 0 の無限ループが毎分25分ジョブを起こす"

# クレジット切れの扱い（2026-08-03）＝原因を通知に出し、連続回数には数えない
grep -q 'out of usage credits' "$SRC" \
  && ok "クレジット切れを判定している" \
  || ng "クレジット切れを判定している" "原因が通知に出ず、社長に伝わらない"
sed -n '/クレジット切れの判定/,/^    fi$/p' "$SRC" | grep -q 'cooldown_hold' \
  && ok "クレジット切れは連続回数に数えない（hold を使う）" \
  || ng "クレジット切れは連続回数に数えない" "cooldown_apply だと6時間ロックされ補充後も止まる"
sed -n '/クレジット切れの判定/,/^    fi$/p' "$SRC" | grep -q 'クレジットが尽きています' \
  && ok "通知文に原因（クレジット）が書かれている" \
  || ng "通知文に原因が書かれている"
sed -n '/クレジット切れの判定/,/^    fi$/p' "$SRC" | grep -q 'last-alert-nocredit' \
  && ok "クレジット切れは独立スロットル（他の警報を握り潰さない）" \
  || ng "クレジット切れは独立スロットル"

# ログ書き込み失敗の検知（Codex🟡11）
grep -q 'pipe_rc\[1\]' "$SRC" && ok "ログ書き込みの失敗を拾う" \
  || ng "ログ書き込みの失敗を拾う" "ログが書けない＝冷却も書けない可能性がある"

# クールダウンの return が、実際の起動行より前にあること（後ろだと意味がない）
CD_LINE=$(grep -n 'ACTIONS+=("\$label:\$pending:\$action")' "$SRC" | head -1 | cut -d: -f1)
RUN_LINE=$(grep -n 'timeout --kill-after=30s' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$CD_LINE" ] && [ -n "$RUN_LINE" ] && [ "$CD_LINE" -lt "$RUN_LINE" ]; then
  ok "クールダウン判定は claude 起動より前"
else
  ng "クールダウン判定は claude 起動より前" "cd=$CD_LINE run=$RUN_LINE"
fi

sed -n '/if \[ "\$rc" -ne 0 \]/,/^    else$/p' "$SRC" | grep -q 'cooldown_apply' \
  && ok "タイムアウト／OOM で冷却を設定している" \
  || ng "タイムアウト／OOM で冷却を設定している"
grep -q 'cooldown_clear "\$label"' "$SRC" && ok "完走でリセットしている" \
  || ng "完走でリセットしている"

# 冷却中に pending を消費していないこと＝仕事を捨てない
sed -n "/直前がタイムアウト/,/^    fi$/p" "$SRC" | grep -qE 'rm |mv |done ' \
  && ng "冷却中に mailbox を消費していない" "冷却の分岐で削除/移動をしている" \
  || ok "冷却中に mailbox を消費していない（待つだけ）"

echo
echo "=== 構文チェック ==="
bash -n "$SRC" && ok "agent-tick.sh の構文" || ng "agent-tick.sh の構文"

echo
echo "合計: 合格 $PASS ／ 不合格 $NG"
[ "$NG" -eq 0 ] || exit 1
