#!/bin/bash
# talk-tick — 相談レーン（軽い会話）専用のディスパッチャ。
#
# なぜ agent-tick.sh と分けるのか（2026-08-19 社長決定「会話用途と日1回の重い処理を分ける」）:
#   agent-tick は1本のロックの内側で hp-loop 等を最大25分回す。会話をそこに相乗りさせると、
#   解析が走っている間ずっと相談の返事が来ない（実測で最悪25分待ち）。会話の価値は速さなので、
#   ロックもcronも完全に別レーンにする。こちらは1スレッド最大5分・pending が無ければ即終了。
#
# 1スレッド＝1claudeセッション（--session-id / --resume）:
#   Slack のスレッドと claude のセッションを1対1で結ぶ。2通目以降は続きから話すので、
#   社長が同じ前提を説明し直さなくて済む（＝Claude Code で会話するのと同じ手触り）。
#   セッションの対応表は data/slack/talk-state.json。
#
# 失敗したとき:
#   便は new/ に残す（＝取りこぼさない）。連続失敗はスレッド単位で冷やし、毎分の再試行で
#   費用を垂れ流さない。冷却が続くようなら Slack へ1回だけ鳴らす（黙って止まらない）。
#
# 使い方（cron）:
#   */1 * * * * /home/vpsuser/projects/myagent/bin/talk-tick.sh >> /home/vpsuser/projects/myagent/data/slack/talk.log 2>&1
set -uo pipefail

# --- cron 環境対策（agent-tick.sh と同じ手当て）---
export HOME="${HOME:-/home/vpsuser}"
export PATH="/home/vpsuser/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
  _nvm_bin=$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)
  [ -n "${_nvm_bin:-}" ] && export PATH="$_nvm_bin:$PATH"
fi

PROJ="${MYAGENT_PROJ:-/home/vpsuser/projects/myagent}"
cd "$PROJ" || exit 1
PY="${MYAGENT_PY:-$PROJ/bin/.venv/bin/python3}"
CLAUDE="${CLAUDE:-/home/vpsuser/.local/bin/claude}"
SLACK_DIR="$PROJ/data/slack"
STATE="$SLACK_DIR/talk-state.json"
LOCK="$SLACK_DIR/.talk.lock"
LOG="${TALK_LOG:-$SLACK_DIR/talk.log}"
MAILBOX_NEW="$PROJ/data/mailbox/new"
LOG_MAX_BYTES=524288

# 1スレッドの制限時間。会話の返事に5分以上かかるなら、それは相談でなく調査＝partner の仕事。
TIMEOUT_SEC="${TALK_TIMEOUT:-300}"
# 1tick で扱うスレッド数の上限。まとめて来ても順に捌く（残りは次の分に回る）＝暴発の歯止め。
MAX_THREADS="${TALK_MAX_THREADS:-3}"
# 連続失敗の冷却（秒）。倍々に伸ばす：1回目=2分・2回目=4分・3回目=8分・4回目=16分・5回目以降=30分で頭打ち。
COOLDOWN_BASE="${TALK_COOLDOWN_BASE:-120}"
COOLDOWN_MAX="${TALK_COOLDOWN_MAX:-1800}"
# 何回連続で失敗したら社長に鳴らすか（1回のしくじりでは鳴らさない＝狼少年にしない）
ALERT_AFTER="${TALK_ALERT_AFTER:-2}"

# OOM のときカーネルにこの claude を優先的に殺させる＝社長の tmux を守る（agent-tick と同じ）
if command -v choom >/dev/null 2>&1; then CHOOM=(choom -n 800 --); else CHOOM=(); fi

mkdir -p "$SLACK_DIR" 2>/dev/null
now()     { TZ=Asia/Tokyo date "+%Y-%m-%d %H:%M:%S JST"; }
now_epoch() { date +%s; }
log()     { echo "$(now) $*" >>"$LOG"; }

# --- ログの肥大防止（末尾を残して切り詰め）---
if [ -f "$LOG" ]; then
  sz=$(wc -c <"$LOG" 2>/dev/null || echo 0)
  if [ "${sz:-0}" -gt "$LOG_MAX_BYTES" ]; then
    tail -c 262144 "$LOG" >"$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    log "[log] talk.log が ${sz}B を超えたため末尾256KBに切り詰め"
  fi
fi

# --- 多重起動防止（前回がまだ喋っていれば静かに見送る。便は new/ に残るので取りこぼさない）---
exec 9>"$LOCK"
if ! flock -n 9; then
  exit 0
fi

# --- 受信箱の走査（この1箇所だけが「自分宛の便とは何か」を知っている）---
# ★2つに分けてはいけない：以前は「起動するスレッドを決める処理」と「終わったか確かめる処理」が
#   別々に同じ判定（to == talk・thread_ts を見る）を持っていた。片方だけ直すと両者が食い違い、
#   「起動はするのに終わったと判定されない」＝毎分claudeを起動し続ける形になりうる。
#   mode=threads … "<thread_ts> <件数>" を古い順に／mode=ids … 指定スレッドの便IDを列挙
mb_scan() {
  "$PY" - "$MAILBOX_NEW" "$1" "${2:-}" <<'SCAN'
import json, os, sys
d, mode, want_ts = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    names = sorted(os.listdir(d))
except OSError:
    raise SystemExit
groups = {}
for name in names:
    if not name.endswith(".json"):
        continue
    try:
        with open(os.path.join(d, name), encoding="utf-8") as f:
            m = json.load(f)
    except Exception:
        continue                      # 壊れた便は agent-tick 側が検知して鳴らす（ここでは黙って飛ばす）
    if m.get("to") != "talk":
        continue
    ts = (m.get("slack") or {}).get("thread_ts") or ""
    if not ts:
        continue                      # 返信先が無い便は扱えない（起動もしない）
    if mode == "ids":
        if ts == want_ts:
            print(name[:-5])
    else:
        e = groups.setdefault(ts, {"n": 0, "first": name})
        e["n"] += 1
if mode != "ids":
    for ts, e in sorted(groups.items(), key=lambda kv: kv[1]["first"]):
        print(f"{ts} {e['n']}")
SCAN
}

# 扱うスレッドを決める（pending が無ければ claude を起動しない＝0円で終わる）
threads=$(mb_scan threads)
[ -z "$threads" ] && exit 0

# --- 状態ファイルの読み書き（セッションID・連続失敗・冷却）---
state_get() {   # state_get <thread_ts> <field> [既定値]
  "$PY" - "$STATE" "$1" "$2" "${3:-}" <<'PYEOF'
import json, sys
path, ts, field, default = sys.argv[1:5]
try:
    with open(path, encoding="utf-8") as f:
        s = json.load(f)
except Exception:
    s = {}
print(s.get(ts, {}).get(field, default))
PYEOF
}
state_set() {   # state_set <thread_ts> <field> <値> [field2 値2 ...]
  "$PY" - "$STATE" "$@" <<'PYEOF'
import json, os, sys
path, ts = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        s = json.load(f)
except Exception:
    s = {}
e = s.setdefault(ts, {})
args = sys.argv[3:]
for i in range(0, len(args) - 1, 2):
    e[args[i]] = args[i + 1]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(s, f, ensure_ascii=False, indent=1)
    f.flush(); os.fsync(f.fileno())
os.replace(tmp, path)                  # 途中で落ちても壊れた状態を残さない
PYEOF
}

# state_set の失敗を握り潰さないラッパー。
# ★状態を保存できないまま先へ進んではいけない（2026-08-19 Codexレビュー）：
#   ディスク満杯・権限異常で冷却を書けないと、次の tick は再び fails=0 ・冷却無しと見なし、
#   **毎分同じ便で claude を起動し続ける**（費用が止まらない）。
#   agent-tick が「実行中マーカーを書けなければ起動を見送る」のと同じ考え方。
save_state() {
  if state_set "$@"; then
    return 0
  fi
  log "[fatal] 状態を保存できませんでした（$STATE）。冷却が効かないため今回はここで打ち切ります"
  if [ -x "$PROJ/bin/slack.sh" ] && [ "${TALK_NO_SLACK:-0}" != "1" ]; then
    printf '⚠️ 相談レーンが状態を保存できません（%s）\nディスクや権限を確認してください。\n安全のため今回の処理を止めました（社長の質問は残っています）。\n（%s）\n' \
      "$STATE" "$(now)" | bash "$PROJ/bin/slack.sh" >/dev/null 2>&1 || true
  fi
  return 1
}

# 起動時に居た便が「1つ残らず処理済みへ移ったか」で成功を測る。
# ★そもそも終了コードを信じてはいけない（2026-08-19 実測）：claude は「できませんでした」と
#   報告しながら exit 0 で終わることがある（ガードで出力手段が塞がれていた回がまさにそれ）。
#   rc だけ見ると無進捗を「応答しました」と記録し、社長の質問は残ったままなのに誰も気づかない。
#   rc は「動いたか」であって「仕事をしたか」ではない＝状態の前後差で測る。
# ★その差を件数で測ってもいけない（2026-08-19 Codexレビュー）：取り込み(fetch)は
# このレーンと並行して走るので、実行中に同じスレッドへ新着が1通入ると、正しく返信・done
# していても件数が変わらず「無進捗」と誤判定する→次回セッションを捨てて同じ質問に
# **重複返信**する。逆に、返信せず1通 done しただけでも成功に見えてしまう。
all_gone() {   # all_gone <残っている便ID> <起動時に居た便ID>
  local remain="$1" snapshot="$2" id
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    printf '%s\n' "$remain" | grep -qxF -- "$id" && return 1
  done <<<"$snapshot"
  return 0
}

handled=0
while read -r ts n; do
  [ -z "$ts" ] && continue
  [ "$handled" -ge "$MAX_THREADS" ] && { log "[defer] 上限 $MAX_THREADS 件に達したため残りは次の分へ"; break; }

  # 冷却中なら見送る（便は new/ に残るので、明けたときに拾われる）
  cd_until=$(state_get "$ts" cooldown_until 0)
  [[ "$cd_until" =~ ^[0-9]+$ ]] || cd_until=0
  if [ "$(now_epoch)" -lt "$cd_until" ]; then
    continue
  fi

  sid=$(state_get "$ts" session "")
  if [ -n "$sid" ]; then
    mode=(--resume "$sid"); how="続き"
  else
    sid=$("$PY" -c "import uuid;print(uuid.uuid4())")
    mode=(--session-id "$sid"); how="新規"
  fi

  snapshot=$(mb_scan ids "$ts")
  log "[run] スレッド $ts（$how・便${n}通・session=${sid:0:8}）"
  out=$(MYAGENT_UNATTENDED=1 MYAGENT_AGENT=talk \
    timeout --kill-after=20s "${TIMEOUT_SEC}s" "${CHOOM[@]}" \
    "$CLAUDE" -p "/talk $ts" "${mode[@]}" --permission-mode acceptEdits </dev/null 2>&1)
  rc=$?
  echo "$out" | sed 's/^/» /' >>"$LOG"
  handled=$((handled + 1))

  remain=$(mb_scan ids "$ts")
  if [ "$rc" -eq 0 ] && all_gone "$remain" "$snapshot"; then
    if ! save_state "$ts" session "$sid" fails 0 cooldown_until 0 alerted "" last_ok "$(now)"; then
      break
    fi
    log "[ok] スレッド $ts に応答しました"
    continue
  fi

  # --- 失敗／未完了：便は消さず、そのスレッドだけを冷やす ---
  # ★セッションを捨てるのは rc≠0 のときだけ（2026-08-19）。
  #   「正常終了したが便が残っている」場合に捨てると、次回は白紙から始まり
  #   すでに Slack へ返したことを知らずに**同じ質問へ重複返信**する。
  #   続きからなら自分の発言履歴が見えるので done だけやり直せる。
  if [ "$rc" -eq 0 ]; then
    why="応答は終了しましたが、受信箱の便が処理されていません（返信できていない可能性）"
    keep_sid="$sid"
    log "[no-progress] スレッド $ts は正常終了したのに便が残っています"
  else
    why="実行が失敗しました（rc=$rc）"
    keep_sid=""
  fi
  # 認証切れは原因が特定できるので、そのまま伝える（2026-08-20）。
  # 08-19〜08-20 に OAuth 失効で全ループが14時間止まった際、通知文が原因を言わないと
  # 社長が何をすればよいか分からない＝待っていても直らない種類の停止だから。
  # 行頭固定は agent-tick と同じ理由（自分の応答本文に同じ語が出ても誤検知しない）。
  if printf '%s' "$out" | grep -qiE "^(Failed to authenticate|OAuth session expired|Not logged in|Please run /login|Invalid API key)"; then
    why="claude の認証が切れています（OAuth 失効）。**社長の再ログインが必要です**（VPS で claude を起動して認証）。待っていても直りません"
  fi

  fails=$(state_get "$ts" fails 0); [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
  fails=$((fails + 1))
  # 倍々に伸ばし、上限まで行ったらそこで頭打ち（2分→4→8→…→上限）。
  # ★永久に黙らせない：完全に止めると復旧しても自力で戻らない。上限を 6時間にして
  #   1日数回に押さえる（旧実装の30分上限だと最大 48回/日 燃え続ける）。
  shift_n=$((fails - 1)); [ "$shift_n" -gt 12 ] && shift_n=12
  wait=$((COOLDOWN_BASE << shift_n))
  [ "$wait" -gt "$COOLDOWN_MAX" ] && wait="$COOLDOWN_MAX"
  if ! save_state "$ts" session "$keep_sid" fails "$fails" cooldown_until "$(( $(now_epoch) + wait ))"; then
    break
  fi
  log "[fail] スレッド $ts rc=$rc（連続${fails}回目・${wait}秒冷却／便は残しました）"

  # ★通知は「成功するまで再試行」する（2026-08-19）。
  #   旧実装は fails==2 の1回だけ鳴らし、その Slack 投稿が失敗すると || true で捨てられ
  #   以降二度と鳴らなかった＝黙って止まる。送れたときだけ印を付ける。
  alerted=$(state_get "$ts" alerted "")
  if [ "$fails" -ge "$ALERT_AFTER" ] && [ -z "$alerted" ] \
     && [ -x "$PROJ/bin/slack.sh" ] && [ "${TALK_NO_SLACK:-0}" != "1" ]; then
    if printf '⚠️ 相談チャンネルの返事ができていません（連続%d回）
%s
スレッド: %s
社長の質問は消えずに残っています。復旧後に自動で返します。
（%s）
'         "$fails" "$why" "$ts" "$(now)" | bash "$PROJ/bin/slack.sh" >/dev/null 2>&1; then
      save_state "$ts" alerted "$(now)" || break
    else
      log "[warn] 社長への通知に失敗しました。印を付けず次回再試行します"
    fi
  fi
done <<<"$threads"

exit 0
