#!/bin/bash
# agent-tick — 無人運用の単一ディスパッチャ（システム cron が回す）。
# 堅牢な番人（多重起動防止 flock / fetch / heartbeat / 失敗通知）として、
# Slack 新着を1回だけ取り込んだあと、mailbox の宛先ごとに必要なエージェントだけを
# ヘッドレス起動する。fetch は last-seen を進めるため「1プロセスが所有」する＝多重 fetch 競合を防ぐ。
#
#   1) slack-poll.py fetch … 社長Slackの新着を mailbox へ取り込む（純シェル・確実・低コスト）
#   2) 宛先ごとに振り分け：
#        to: hanasaka-main あり        → claude -p /chat     （社長との会話・スレッド返信）
#        to: overseer あり / daily指定 → claude -p /overseer （統括）
#      （--permission-mode acceptEdits ＝ 編集は自動承認／Bash は settings.local.json の許可リストのみ）
#   3) ハートビート … 毎回 last-tick を記録（沈黙＝不明、を解消。Web からも確認可）
#   4) 失敗時は社長Slackへ通知（1時間スロットル）＝「私が見てない間に壊れてた」を防ぐ
#
# 設計上の「黙って壊れる」対策（Codexレビュー反映 2026-06-18）：
#   - 失敗は1件で握り潰さず FAILURES に積み、heartbeat/status に全て残す
#   - mailbox の new/ 不在・heartbeat 書き込み失敗を「idle/正常」に化けさせず alert
#   - timeout は --kill-after で子プロセス残留を始末／tick.log はサイズ超過で末尾保持に切り詰め
#
# 使い方（cron）:
#   */10 * * * * /home/vpsuser/projects/myagent/bin/agent-tick.sh                # 10分ごと：受信+対応
#   0 1   * * * /home/vpsuser/projects/myagent/bin/agent-tick.sh daily overseer  # 1日1回：overseer 精密診断を強制
#   0 2   * * * /home/vpsuser/projects/myagent/bin/agent-tick.sh daily hp-loop   # 1日1回：HP解析を強制（Phase2で有効化）
#
# automation.md：外部送信は各モードのルールで社長専用チャンネルに限定。raw mv は使わず slack-poll done。
set -uo pipefail

# --- cron 環境対策：claude が内部で使う node 等のため PATH/HOME を明示 ---
export HOME="/home/vpsuser"
export PATH="/home/vpsuser/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PROJ="/home/vpsuser/projects/myagent"
cd "$PROJ" || exit 1
PY="$PROJ/bin/.venv/bin/python3"
CLAUDE="/home/vpsuser/.local/bin/claude"
LOG="$PROJ/data/overseer/tick.log"
LOG_MAX_BYTES=1048576                                # 1MB を超えたら末尾512KBに切り詰め
HEARTBEAT_WEB="$PROJ/site/overseer/last-tick.txt"   # Web から生存確認できる場所
LOCK="$PROJ/data/overseer/.tick.lock"
LAST_ALERT="$PROJ/data/overseer/.last-alert"        # Slack通知のスロットル用
MAILBOX_NEW="$PROJ/data/mailbox/new"                # 受信箱（1ファイル=1メッセージ・JSON）
mkdir -p "$PROJ/data/overseer"

MODE="${1:-normal}"          # normal | daily
FORCE_AGENT="${2:-}"         # daily のとき強制起動するエージェント（既定 overseer）
[ "$MODE" = "daily" ] && [ -z "$FORCE_AGENT" ] && FORCE_AGENT="overseer"
now() { date '+%Y-%m-%d %H:%M:%S %Z'; }

# --- 失敗の蓄積（単値上書きで先の失敗を消さない＝Codex🔴1） ---
FAILURES=()
fail() { FAILURES+=("$1"); }
status_str() { if [ "${#FAILURES[@]}" -eq 0 ]; then echo "ok"; else echo "${FAILURES[*]}"; fi; }

# --- 多重起動防止（前回がまだ走っていれば静かに退避） ---
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "$(now) [skip] 前回の tick がまだ実行中。今回はスキップ" >>"$LOG"
  exit 0
fi

# --- tick.log の肥大防止（末尾を残して切り詰め＝Codex🟢7） ---
if [ -f "$LOG" ]; then
  sz=$(wc -c <"$LOG" 2>/dev/null || echo 0)
  if [ "${sz:-0}" -gt "$LOG_MAX_BYTES" ]; then
    tail -c 524288 "$LOG" >"$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    echo "$(now) [log] tick.log が ${sz}B を超えたため末尾512KBに切り詰め" >>"$LOG"
  fi
fi

# --- 失敗を社長Slackへ通知（claude非依存・純シェル経由・1時間スロットル） ---
alert() {
  local msg="$1"
  echo "$(now) [ALERT] $msg" >>"$LOG"
  if [ -f "$LAST_ALERT" ]; then
    local last age
    last=$(cat "$LAST_ALERT" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0          # 壊れた値で算術が落ちないように（Codex🟡6）
    age=$(( $(date +%s) - last ))
    [ "$age" -lt 3600 ] && return 0              # 1時間以内に通知済みなら鳴らさない（スパム防止）
  fi
  printf '⚠️ agent-tick 異常\n%s\n（%s）\n生存確認: http://100.123.104.87/overseer/last-tick.txt' \
    "$msg" "$(now)" | "$PY" "$PROJ/bin/slack-poll.py" post >>"$LOG" 2>&1 \
    && date +%s >"$LAST_ALERT"
}

# --- 1) 新着取り込み（純シェル・LLM不要・このスクリプトが fetch の唯一の所有者） ---
if ! "$PY" bin/slack-poll.py fetch >>"$LOG" 2>&1; then
  echo "$(now) [warn] fetch失敗" >>"$LOG"
  fail "fetch-fail"
  alert "Slack新着の取り込み(fetch)に失敗しました。トークン/ネットワークを確認してください。"
fi

# --- 受信箱の健全性（new/ 不在・権限異常を「idle」に化けさせない＝Codex🔴3） ---
MAILBOX_OK=1
if [ ! -d "$MAILBOX_NEW" ]; then
  MAILBOX_OK=0
  fail "mailbox-missing"
  alert "mailbox の new/ がありません（$MAILBOX_NEW）。受信処理をスキップします。"
fi

# --- 振り分け：宛先 mailbox に未読があれば（または daily で強制されていれば）当該モードを起動 ---
# 引数：表示ラベル / スラッシュコマンド / mailbox 宛先(to) → 行った action 文字列を ACTIONS に積む
declare -a ACTIONS=()
dispatch() {
  local label="$1" slash="$2" to="$3"
  local pending force action rc
  # new/ が健全な時だけ数える。find なので glob 非展開や空ディレクトリでも誤検知しない
  if [ "$MAILBOX_OK" -eq 1 ]; then
    pending=$(find "$MAILBOX_NEW" -maxdepth 1 -type f -name '*.json' \
              -exec grep -l "\"to\": *\"$to\"" {} + 2>/dev/null | wc -l | tr -d ' ')
  else
    pending=0
  fi
  force=0; [ "$FORCE_AGENT" = "$to" ] && force=1
  action="idle"
  if [ "$pending" -gt 0 ] || [ "$force" -eq 1 ]; then
    [ "$force" -eq 1 ] && action="daily" || action="handle($pending)"
    echo "$(now) [run] claude -p $slash 起動（label=$label pending=$pending force=$force）" >>"$LOG"
    # --kill-after：SIGTERM を無視されても30秒後に SIGKILL（子プロセス残留を始末＝Codex🔴4）
    timeout --kill-after=30s 900s "$CLAUDE" -p "$slash" --permission-mode acceptEdits >>"$LOG" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        fail "$label-timeout"; action="$action(TIMEOUT)"
        alert "ヘッドレス $label が15分でタイムアウトしました（pending=$pending force=$force）。"
      else
        fail "$label-fail($rc)"; action="$action(ERR$rc)"
        alert "ヘッドレス $label が異常終了しました（exit=$rc pending=$pending force=$force）。"
      fi
    fi
  fi
  ACTIONS+=("$label:$pending:$action")
}

# --- 2) 各エージェントを振り分け（会話→統括の順。pending か daily 強制のときだけ起動） ---
dispatch "chat"     "/chat"     "hanasaka-main"
dispatch "overseer" "/overseer" "overseer"
# Phase2 で有効化： dispatch "hp-loop" "/hp-loop" "hp-loop"   （+ cron に daily hp-loop を追加）

# --- 3) ハートビート（毎回・Web可視・書き込み失敗も検知＝Codex🔴2） ---
HB_LINE="agent-tick alive: $(now) | mode=$MODE force=${FORCE_AGENT:-none} | ${ACTIONS[*]:-none} | status=$(status_str)"
mkdir -p "$(dirname "$HEARTBEAT_WEB")" 2>/dev/null
if ! { printf '%s\n' "$HB_LINE" >"$HEARTBEAT_WEB.tmp" && mv -f "$HEARTBEAT_WEB.tmp" "$HEARTBEAT_WEB"; }; then
  fail "heartbeat-write"
  alert "ハートビートの書き込みに失敗しました（$HEARTBEAT_WEB）。ディスク/権限を確認してください。"
fi

# --- ログ（heartbeat 失敗も反映した最終 status を記録） ---
echo "$(now) [tick] mode=$MODE force=${FORCE_AGENT:-none} | ${ACTIONS[*]:-none} | status=$(status_str)" >>"$LOG"
