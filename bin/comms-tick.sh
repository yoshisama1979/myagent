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
    exit 0
  fi
fi

# 実行開始の目印（このティック中の更新かどうかを mtime 比較で見る）
STAMP=$(mktemp "${TMPDIR:-/tmp}/comms-tick.XXXXXX") || exit 1
echo "$(now) [run] 新着あり → agent-tick daily comms"
"$PROJ/bin/agent-tick.sh" daily comms
rc=$?

# 事後検査：マーカーだけ進んで掲示板が未再生成なら不整合＝マーカーを消して次回再試行
if [ -f "$MARK" ] && [ "$MARK" -nt "$STAMP" ]; then
  if [ ! "$BOARD" -nt "$STAMP" ]; then
    rm -f "$MARK"
    echo "$(now) [warn] マーカーだけ更新され掲示板が未再生成＝不整合。マーカーを削除し次の2hティックで再蒸留します"
  fi
fi
rm -f "$STAMP"
exit "$rc"
