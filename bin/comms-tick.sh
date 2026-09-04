#!/bin/bash
# comms-tick — Chatwork・メール蒸留の起動ガード（純シェル・claude非依存・ゼロコスト判定）
#
# cron（2hおき 6-22時・pollの10分後）から呼ばれ、前回蒸留 (.last-distill) 以降に
# 新しい raw が無ければ claude を起動せず即終了する。新着があるときだけ
# agent-tick.sh daily comms（flock・25分timeout・失敗Slack警報つき）へ委譲する。
#
# 監視対象は2ソース（2026-07-30 社長承認「メールをChatworkと同じ台帳に混ぜる」）：
#   data/comms/chatwork/raw/  … 必須。無ければ異常として非0終了
#   data/comms/gmail/raw/     … 任意。無くても chatwork の蒸留は止めない（warn のみ）
# どちらか一方でも新着があれば蒸留を起動する。
#
# .last-distill は /comms モードが「成功時のみ」touch する＝失敗時は残らないので
# 次の2時間ティックが自動再試行する（記録ベース判定。日付や回数では発火させない）。
#
# 事後検査（2026-07-28 Codexレビュー反映）：実行中にマーカーが更新されたのに掲示板が
# 再生成されていない＝手順順序違反か途中失敗。マーカーを消して次の2hティックで再蒸留させる
# （成功サイクルは新着ゼロでも掲示板を台帳から再生成する規約＝rules/modes/comms.md）。
#
#   10 6-22/2 * * * /home/vpsuser/projects/myagent/bin/comms-tick.sh >> .../distill.log 2>&1
set -uo pipefail
PROJ="/home/vpsuser/projects/myagent"
RAW="$PROJ/data/comms/chatwork/raw"
RAW_GM="$PROJ/data/comms/gmail/raw"
MARK="$PROJ/data/comms/chatwork/.last-distill"
BOARD="$PROJ/site/comms/index.html"
now() { date '+%Y-%m-%d %H:%M:%S'; }

# 起票の宿題マーカー。**蒸留の成功マーカー（.last-distill）とは別に持つ**。
# 同じマーカーにすると「蒸留は成功したが起票に失敗した」を表現できず、
# 新着が来るまで再試行が走らない＝取りこぼしが残る（2026-09-04 Codexレビュー指摘）。
POST_MARK="$PROJ/data/comms/chatwork/.post-pending"

# 台帳 → hana-tools の起票。LLM は呼ばない（todo-post.py は純 Python + curl）＝トークンは増えない。
# 失敗しても comms-tick は止めない（ループを殺さない）が、**宿題マーカーを残して必ず再試行させる**。
do_post() {
  local out
  if out=$(python3 "$PROJ/bin/todo-post.py" post 2>&1); then
    rm -f "$POST_MARK"
    echo "$(now) [post] $(printf '%s' "$out" | tr -d '\n' | cut -c1-400)"
  else
    : > "$POST_MARK"
    echo "$(now) [warn] 起票に失敗しました（宿題として残し、次のティックで新着ゼロでも再試行します）:" \
         "$(printf '%s' "$out" | tr -d '\n' | cut -c1-300)"
  fi
}

# raw ディレクトリ自体が無い＝poll が一度も動いていない異常。蒸留しても無意味なので非0で申告
if [ ! -d "$RAW" ]; then
  echo "$(now) [warn] raw ディレクトリがありません（poll 未稼働？）: $RAW"
  exit 1
fi
# メール側は欠けていても chatwork の蒸留は止めない（申告だけして続行）
if [ ! -d "$RAW_GM" ]; then
  echo "$(now) [warn] メールの raw ディレクトリがありません（gmail poll 未稼働？）: $RAW_GM"
fi

if [ -f "$MARK" ]; then
  # find の失敗（権限・ディスク異常）を「新着なし」に化けさせない＝失敗時は安全側で蒸留を実行
  fresh=""; probe_failed=""
  for d in "$RAW" "$RAW_GM"; do
    [ -d "$d" ] || continue
    if hit=$(find "$d" -name '*.jsonl' -newer "$MARK" -print -quit 2>&1); then
      [ -n "$hit" ] && fresh="$hit"
    else
      probe_failed="$d: $hit"
    fi
    [ -n "$fresh" ] && break
  done
  if [ -n "$probe_failed" ] && [ -z "$fresh" ]; then
    echo "$(now) [warn] find が失敗（$probe_failed）＝判定不能のため安全側で蒸留を実行します"
  elif [ -z "$fresh" ]; then
    echo "$(now) [skip] 前回蒸留以降の新着なし（Chatwork・メールとも）＝claude 不起動"
    # ★前回の起票が失敗していたら、新着ゼロでも起票だけは再試行する。
    #   ここを通さないと「次の2hティックが拾い直す」が成立しない＝新着が来るまで宿題が残る。
    if [ -f "$POST_MARK" ]; then
      echo "$(now) [post-retry] 前回の起票が未完了＝蒸留はせず起票だけ再試行します"
      do_post
    fi
    exit 0
  fi
fi

# 実行開始の目印（このティック中の更新かどうかを mtime 比較で見る）
STAMP=$(mktemp "${TMPDIR:-/tmp}/comms-tick.XXXXXX") || exit 1

# --- 宛先の把握を「AIの心がけ」でなく機械で担保する（2026-08-07 Codexレビュー🔴5）---
# rules/modes/comms.md v0.7 は「分類の前に comms-who.py を流す（スキップ不可）」と定めたが、
# 文章の指示だけでは、AI が raw を直読みしても成功扱いになってしまう。そこで
#   ① 起動前に宛先レポートを**こちらで生成**して置く（AIはこれを読むだけ＝流し忘れが起きない）
#   ② 起動後に「新しい C-NNN 行に 〔差出人→宛先〕 が付いているか」を数えて検査する
# ①が失敗しても蒸留は止めない（申告して続行＝取りこぼしより冗長を選ぶ）。
WHO="$PROJ/data/comms/chatwork/.who-latest.txt"
LEDGER="$PROJ/data/comms/chatwork/ledger.md"
# レポートには会話本文と個人名が入る＝作る前に 0600 にしてから書く（緩い権限で存在する隙を作らない）
: > "$WHO.tmp" && chmod 600 "$WHO.tmp"
if ! python3 "$PROJ/bin/comms-who.py" > "$WHO.tmp" 2>&1; then
  echo "$(now) [warn] comms-who.py が異常終了＝宛先レポート無しで蒸留します（AIは生ログを直読み）"
fi
mv -f "$WHO.tmp" "$WHO" 2>/dev/null || true

# 宛先記法の無い「Chatwork行」数を実行前に控える（増えていたら規律違反）。
# メール専用行（gm: だけ）は 〔→〕 を持たない規約なので数えない＝メールが増えるたびの誤警報を防ぐ。
no_arrow() {
  awk '/^[ \t]*C-[0-9][0-9][0-9][ \t]*\|/ && /cw:[ \t]*[0-9]/ && $0 !~ /〔/ {n++} END{print n+0}' \
    "$1" 2>/dev/null || echo 0
}
before_no_arrow=$(no_arrow "$LEDGER")

echo "$(now) [run] 新着あり → agent-tick daily comms"
"$PROJ/bin/agent-tick.sh" daily comms
rc=$?

# 事後検査その2：宛先記法を持たない行が**増えていたら**、宛先を見ずに起票した疑い
after_no_arrow=$(no_arrow "$LEDGER")
if [ "$after_no_arrow" -gt "$before_no_arrow" ]; then
  echo "$(now) [warn] 宛先記法〔→〕の無い C-NNN 行が ${before_no_arrow}→${after_no_arrow} に増えました" \
       "＝宛先を見ずに起票した疑い（rules/modes/comms.md 🅰）。次サイクルで直させます"
  rm -f "$MARK"
fi

# 事後検査：マーカーだけ進んで掲示板が未再生成なら不整合＝マーカーを消して次回再試行
if [ -f "$MARK" ] && [ "$MARK" -nt "$STAMP" ]; then
  if [ ! "$BOARD" -nt "$STAMP" ]; then
    rm -f "$MARK"
    echo "$(now) [warn] マーカーだけ更新され掲示板が未再生成＝不整合。マーカーを削除し次の2hティックで再蒸留します"
  fi
fi
rm -f "$STAMP"

# --- 起票（台帳 → hana-tools）------------------------------------------------
# ★2026-09-04 社長ご承認で接続。それまで todo-post.py は**どこからも呼ばれておらず**、
#   8/24 に手作業で1回動かしたきり10日間止まっていた（C-122 が漏れた直接の原因）。
# ★位置＝**事後検査をすべて通ったあと**。宛先記法の欠落や「マーカーだけ進んで掲示板が
#   未再生成」は台帳が不完全な証拠で、そのまま外部へ書くと不完全な内容で起票してしまう
#   （2026-09-04 Codexレビュー指摘）。検査は $MARK を消して次回の再蒸留を促すので、
#   **$MARK が消えている＝不整合**を起票しない条件に使う。
# 起票を見送るときは、**必ず宿題として残す**（見送りっぱなしにしない）。
defer_post() { : > "$POST_MARK"; echo "$(now) [skip] $1（宿題として残します）"; }

if [ "$rc" -ne 0 ]; then
  defer_post "蒸留が失敗（rc=$rc）＝台帳が中途半端な可能性があるため起票しません"
elif [ ! -f "$MARK" ]; then
  defer_post "事後検査で不整合を検出＝台帳が確定していないため起票しません（次回再蒸留後に起票します）"
else
  do_post
fi

exit "$rc"
