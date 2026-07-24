#!/bin/bash
# agent-tick — 無人運用の単一ディスパッチャ（システム cron が回す）。
# 堅牢な番人（多重起動防止 flock / fetch / heartbeat / 失敗通知）として、
# Slack 新着を1回だけ取り込んだあと、mailbox の宛先ごとに必要なエージェントだけを
# ヘッドレス起動する。fetch は last-seen を進めるため「1プロセスが所有」する＝多重 fetch 競合を防ぐ。
#
#   1) slack-poll.py fetch … 社長Slackの新着を mailbox へ取り込む（純シェル・確実・低コスト）
#   2) 宛先ごとに振り分け：
#        to: hanasaka-main あり        → claude -p /chat        （社長との会話・スレッド返信）
#        to: memo あり（反応tick）     → claude -p /memo-triage （#memo の新着メモを軽く点検・曖昧点だけ確認→memo-stock へ退避）
#        daily memo（夜バッチ）        → claude -p /memo-intake （memo-stock の当日メモを notes.html へまとめて整理）
#        to: overseer あり / daily指定 → claude -p /overseer    （統括）
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
#   0 1   * * * /home/vpsuser/projects/myagent/bin/agent-tick.sh daily overseer        # 1日1回：overseer 精密診断
#   0 7   * * * /home/vpsuser/projects/myagent/bin/agent-tick.sh daily partner         # 毎朝7:00：経営パートナーの朝礼ブリーフィング（手動テスト＋合意後に有効化）
#   0 2   * * * /home/vpsuser/projects/myagent/bin/agent-tick.sh daily hp-loop-ycom    # HP解析（サイト別。入力凍結ループ=rally/konjaku は週次・月曜＝2026-07-08 社長決定）
#   0 5   * * * /home/vpsuser/projects/myagent/bin/agent-tick.sh daily blog-loop-ycom  # ブログ診断（B/T提案）
#   30 5  * * 1 /home/vpsuser/projects/myagent/bin/agent-tick.sh daily blog-write-ycom   # ブログ新規記事→WP下書き（週次・月曜＝在庫凍結中の右サイズ化 2026-07-08）
#   0 6   * * 1 /home/vpsuser/projects/myagent/bin/agent-tick.sh daily blog-improve-ycom # ブログ既存記事の改善版（週次・月曜＝同上）
#   0 23  * * * /home/vpsuser/projects/myagent/bin/agent-tick.sh daily memo              # 日常メモ：#memo の当日分を notes.html へまとめて整理（夜バッチ）
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
LAST_ALERT="$PROJ/data/overseer/.last-alert"        # Slack通知のスロットル用（既定ch）
PARTNER_ALERT="$PROJ/data/overseer/.last-alert-partner"  # #partner 向け警報のスロットル用（既定chとは独立）
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

# --- 多重起動防止 ---
# normal（反応ティック）は前回が走っていれば静かにスキップ（取りこぼしても次の */N で拾える）。
# daily（強制起動）は取りこぼすと「毎日忘れず解析」の規律が崩れるので、ロックを最大15分待つ。
# （同時刻の */N ティックと衝突しても skip させない＝mode=daily が 0回になっていたバグ対策。2026-06-19）
exec 9>"$LOCK"
if [ "$MODE" = "daily" ]; then
  # 待ち時間は「反応tickの最悪保持時間（複数エージェント×各~930s）」を上回る余裕を取る。
  if ! flock -w 3600 9; then
    echo "$(now) [skip] daily: 60分待ってもロックを取得できずスキップ" >>"$LOG"
    exit 0
  fi
else
  if ! flock -n 9; then
    echo "$(now) [skip] 前回の tick がまだ実行中。今回はスキップ" >>"$LOG"
    exit 0
  fi
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

# --- 朝礼(partner)の失敗を #partner にも通知（社長合意 2026-07-24・#2「今日いちばん効く」） ---
# 従来 alert() は既定ch（ウェブ解析）だけに出るため、社長は #partner で朝礼が「無い」ことで
# しか気づけなかった。伴走の中核なので、失敗を社長が普段見る #partner へ届ける（既定chの警報は
# 従来どおり残す＝systemic な失敗ストリームを消さない）。スロットルは既定chと独立（互いに握り潰さない）。
partner_alert() {
  local msg="$1"
  echo "$(now) [ALERT:partner] $msg" >>"$LOG"
  if [ -f "$PARTNER_ALERT" ]; then
    local last age
    last=$(cat "$PARTNER_ALERT" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    age=$(( $(date +%s) - last ))
    [ "$age" -lt 3600 ] && return 0
  fi
  printf '⚠️ 朝礼ブリーフィングが正常に完了しませんでした\n%s\n（%s）\n※自動警報です（次の実行で自動再試行します）。\n生存確認: http://100.123.104.87/overseer/last-tick.txt' \
    "$msg" "$(now)" | "$PY" "$PROJ/bin/slack-poll.py" post --as partner --channel partner >>"$LOG" 2>&1 \
    && date +%s >"$PARTNER_ALERT"
}

# --- 1) 新着取り込み（純シェル・LLM不要・このスクリプトが fetch の唯一の所有者） ---
# 出力は「» 」接頭辞つきで記録（Slack本文由来の改行が偽の制御マーカー行になるのを防ぐ＝claude出力と同じ理由）
"$PY" bin/slack-poll.py fetch 2>&1 | sed 's/^/» /' >>"$LOG"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
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
  # daily（強制）モードでは強制対象だけ動かす。他エージェントの pending 処理は反応tickに任せ、
  # daily の保持時間を最短にして取りこぼし／横入りを防ぐ（Codex指摘：daily中に全dispatchが走る問題）。
  if [ "$MODE" = "daily" ] && [ "$FORCE_AGENT" != "$to" ]; then
    ACTIONS+=("$label:-:skip(daily)")
    return 0
  fi
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
    # 制限時間は全エージェント25分（社長合意 2026-07-24・15分→25分に統一）。
    # 契機＝07-24 朝礼が15分タイムアウトで黙って落ちた件。台帳/掲示板を読む重いセッションは
    # どのエージェントでも起こり得るため、朝礼だけの延長でなく一律に。暴走時も --kill-after で
    # 25分で確実に止まる。反応tickは前回実行中スキップのため、重い実行中の新着処理は最大25分待ち。
    local tmo=1500
    echo "$(now) [run] claude -p $slash 起動（label=$label pending=$pending force=$force timeout=${tmo}s）" >>"$LOG"
    # --kill-after：SIGTERM を無視されても30秒後に SIGKILL（子プロセス残留を始末＝Codex🔴4）
    # MYAGENT_UNATTENDED=1：無人実行の目印。PreToolUse フック（guard-unattended-edits.py）が
    # この時だけ社長ゲート対象ファイル（SYSTEM.md・CLAUDE.md・ルール/コマンド/設定）への
    # Edit/Write を拒否する＝acceptEdits でも勝手に書けない（2026-06-26 地図自動編集の再発防止）。
    # 出力は「» 」接頭辞つきで記録：制御マーカー（[run]/[tick]等の行頭タイムスタンプ行）を
    # このスクリプトだけが書ける形にし、claude出力による状態偽装を防ぐ（Codex🔴 2026-07-17）
    MYAGENT_UNATTENDED=1 timeout --kill-after=30s "${tmo}s" "$CLAUDE" -p "$slash" --permission-mode acceptEdits 2>&1 | sed 's/^/» /' >>"$LOG"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        fail "$label-timeout"; action="$action(TIMEOUT)"
        alert "ヘッドレス $label が$((tmo/60))分でタイムアウトしました（pending=$pending force=$force）。"
        [ "$to" = "partner" ] && partner_alert "朝礼が制限時間（$((tmo/60))分）内に終わりませんでした。台帳・掲示板が重くなっている可能性があります。"
      else
        fail "$label-fail($rc)"; action="$action(ERR$rc)"
        alert "ヘッドレス $label が異常終了しました（exit=$rc pending=$pending force=$force）。"
        [ "$to" = "partner" ] && partner_alert "朝礼が異常終了しました（終了コード $rc）。生存確認リンクとログをご確認ください。"
      fi
    fi
  fi
  ACTIONS+=("$label:$pending:$action")
}

# --- 2) 各エージェントを振り分け（会話→メモ→統括の順。pending か daily 強制のときだけ起動） ---
dispatch "chat"     "/chat"     "hanasaka-main"
# メモ窓口は2層（社長決定 2026-06-24）。どちらも mailbox to: memo を見るが役割が違う：
#  ・日中（反応tick=normal）：/memo-triage が新着メモを軽く点検し、曖昧点だけ #memo の当該メモの
#    スレッドへ確認→点検済みは memo-stock/ へ退避（new/ が空に戻り再起動・再質問しない）。notes は書かない。
#    → 「届いたその場で・社長が在席の日中に」確認して、ストックされる情報の質を上げる。小さな単位＝低トークン。
#  ・夜（daily memo）：/memo-intake が memo-stock/ の当日分をまとめて notes.html へ清書＋#memo に要約1本。
# normal 限定にして daily 実行中（overseer 等）に triage が誤起動しないようにする。
[ "$MODE" = "normal" ] && dispatch "memo-triage" "/memo-triage" "memo"
[ "$MODE" = "daily" ]  && dispatch "memo"        "/memo-intake" "memo"
dispatch "overseer" "/overseer" "overseer"
# 経営パートナー（右腕）：社長が #partner に渡した情報（mailbox to: partner）を反応tickで取り込み
# その用件にスレッド返信する。毎朝の「朝礼ブリーフィング」は daily partner（07:00）で投稿する。
dispatch "partner"  "/partner"  "partner"
# HP分析ループはサイト別に独立（mailbox to: hp-loop-<site> 新着 or daily hp-loop-<site> 強制で起動）
dispatch "hp-loop:ycom"     "/hp-loop ycom"     "hp-loop-ycom"
dispatch "hp-loop:yoshida"  "/hp-loop yoshida"  "hp-loop-yoshida"
dispatch "hp-loop:fujisaka" "/hp-loop fujisaka" "hp-loop-fujisaka"
dispatch "hp-loop:yokohawaii" "/hp-loop yokohawaii" "hp-loop-yokohawaii"
dispatch "hp-loop:rally"    "/hp-loop rally"    "hp-loop-rally"
dispatch "hp-loop:konjaku"  "/hp-loop konjaku"  "hp-loop-konjaku"
# ブログ：診断(blog-loop)→執筆/下書き投稿(blog-write)。HP解析とは別時刻の daily で回す（05:00/05:30）。
# blog-loop-ycom は web-hanasaka の事実回答等で反応tick起動もする。blog-write-ycom は daily強制専用キー（mailbox受信なし）。
dispatch "blog-loop:ycom"    "/blog-loop ycom"    "blog-loop-ycom"
dispatch "blog-write:ycom"   "/blog-write ycom"   "blog-write-ycom"
# 既存記事の改善（B）：元記事は触らず改善版を下書き複製で作る。新規(blog-write)とは別ループ・別時刻。
dispatch "blog-improve:ycom" "/blog-improve ycom" "blog-improve-ycom"

# --- 3) ハートビート（毎回・Web可視・書き込み失敗も検知＝Codex🔴2） ---
HB_LINE="agent-tick alive: $(now) | mode=$MODE force=${FORCE_AGENT:-none} | ${ACTIONS[*]:-none} | status=$(status_str)"
mkdir -p "$(dirname "$HEARTBEAT_WEB")" 2>/dev/null
if ! { printf '%s\n' "$HB_LINE" >"$HEARTBEAT_WEB.tmp" && mv -f "$HEARTBEAT_WEB.tmp" "$HEARTBEAT_WEB"; }; then
  fail "heartbeat-write"
  alert "ハートビートの書き込みに失敗しました（$HEARTBEAT_WEB）。ディスク/権限を確認してください。"
fi

# --- ログ（heartbeat 失敗も反映した最終 status を記録） ---
echo "$(now) [tick] mode=$MODE force=${FORCE_AGENT:-none} | ${ACTIONS[*]:-none} | status=$(status_str)" >>"$LOG"
