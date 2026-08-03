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
# --- メモリ枯渇時に「社長の作業机」を巻き添えにしない（2026-07-31 社長承認・OOM対策①）---
# 契機＝07-30 02:19 と 07-31 10:05 の2回、このVPS（RAM 5.8GB）でメモリが尽き、カーネルが
# user@1000.service（社長のログインセッションを束ねる systemd）を殺した＝配下の tmux が全滅した。
# 実測では claude プロセス2本が計5.3GB を占めており、cron 起動の claude 自身は 90MB＝健全だった。
# oom_score_adj は fork で子に継承されるので、ここで 800 を付けておけば暴走した子孫ごと
# 「カーネルが最初に殺す候補」になり、tmux とログインセッション（adj 100〜200）が生き残る。
# 無人ループは殺されても次の周期で拾えるが、tmux が落ちると社長の手が止まるための優先順位。
# choom は timeout の下で exec して claude 本体になる（プロセスは増えず timeout の kill 対象は同じ）。
# choom が無い環境では黙って素通りする＝起動を止めない。
if command -v choom >/dev/null 2>&1; then CHOOM=(choom -n 800 --); else CHOOM=(); fi
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
# あわせて故障イベントを failures.jsonl に1行追記（切り詰めなし＝system-health.py T-018 の
# 正確な7日集計のソース。tick.log は1MB超で末尾512KBに切り詰められ約1.5日分しか残らないため。
# ローテ（60日）は system-health.py が毎日実施。タグは英数字のみ＝JSON安全）
FAILLOG="$PROJ/data/overseer/failures.jsonl"
FAILURES=()
fail() {
  FAILURES+=("$1")
  printf '{"ts":"%s","fail":"%s"}\n' "$(date -Iseconds)" "$1" >>"$FAILLOG" 2>/dev/null || true
}
status_str() { if [ "${#FAILURES[@]}" -eq 0 ]; then echo "ok"; else echo "${FAILURES[*]}"; fi; }

# --- 失敗を社長Slackへ通知（claude非依存・純シェル経由・1時間スロットル） ---
# 第2引数でスロットル用ファイルを差し替えられる（既定＝$LAST_ALERT）。重要度の違う警報が
# 互いを握り潰さないようにするため＝partner_alert が独立スロットルなのと同じ理由（2026-07-31 追加）。
# 定義位置がメインロックより前なのは、下の OOM 検知がロック外で鳴らす必要があるため（同上）。
alert() {
  local msg="$1"
  local throttle="${2:-$LAST_ALERT}"
  echo "$(now) [ALERT] $msg" >>"$LOG"
  if [ -f "$throttle" ]; then
    local last age
    last=$(cat "$throttle" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0          # 壊れた値で算術が落ちないように（Codex🟡6）
    age=$(( $(date +%s) - last ))
    [ "$age" -lt 3600 ] && return 0              # 1時間以内に通知済みなら鳴らさない（スパム防止）
  fi
  printf '⚠️ agent-tick 異常\n%s\n（%s）\n生存確認: http://100.123.104.87/overseer/last-tick.txt' \
    "$msg" "$(now)" | "$PY" "$PROJ/bin/slack-poll.py" post >>"$LOG" 2>&1 \
    && date +%s >"$throttle"
}

# --- proc 読み取りヘルパー（OOM検知と137判別で共用）---
# 同じ awk を3箇所に散らすと、片方だけ直して静かに食い違う（例：vmstat の項目名が変わったとき）。
oom_kill_count() { awk '/^oom_kill /{print $2; exit}' /proc/vmstat 2>/dev/null || true; }
mem_avail_mb()   { awk '/^MemAvailable/{printf "%dMB", $2/1024}' /proc/meminfo 2>/dev/null; }

# --- OOM kill の検知（2026-07-31 社長承認・Codexレビュー反映でメインロックの外へ）---
# 契機＝07-30/07-31 の2回、メモリ枯渇でカーネルが社長のログインセッションを殺し tmux が全滅したが、
# 誰も気づかず社長が手元で異変に気づくまで分からなかった。/proc/vmstat の oom_kill は起動時0からの
# 単調増加カウンタで sudo 不要＝journal を読む権限が要らない（system-health.py は日次＝翌朝01:15まで
# 気づけないため、通知はここに置く）。
#
# ★メインロックより前に置く理由（Codex🔴）：実際の OOM 2回はどちらも「ヘッドレス claude 実行中」＝
#   メインロックが握られている時間帯に起きた。ロックの内側に置くと、いちばん鳴ってほしい場面で
#   毎回 25分（daily は最大60分）遅れる＝「即時通知」という設計目的を満たさない。
#   代わりに OOM 専用の短いロックで read→通知→write を直列化する（取れなければ他の tick が
#   今まさに同じ判定をしている＝取りこぼしゼロで黙って抜ける）。
# ★通知に失敗したらカウンタを進めない（Codex🔴）：進めてしまうと次回は差分ゼロになり、その OOM は
#   二度と通知されない。Slack 投稿が失敗した回は据え置いて次の tick で再試行する。
# ★カウンタが減ったら再起動＝差分を取らず値だけ更新（負の差分で鳴らさない）。
OOM_COUNT="$PROJ/data/overseer/.oom-count"
oom_now=$(oom_kill_count)
if [[ "${oom_now:-}" =~ ^[0-9]+$ ]]; then
  exec 8>"$PROJ/data/overseer/.oom.lock"
  if flock -n 8; then
    oom_prev=$(cat "$OOM_COUNT" 2>/dev/null || echo "")
    oom_save=1
    if [ -f "$OOM_COUNT" ] && ! [[ "$oom_prev" =~ ^[0-9]+$ ]]; then
      fail "oom-count-broken"                    # 破損を無言で「初回」に化けさせない（Codex🟡）
      oom_prev=""
    fi
    [[ "$oom_prev" =~ ^[0-9]+$ ]] || oom_prev=""
    if [ -n "$oom_prev" ] && [ "$oom_now" -gt "$oom_prev" ]; then
      fail "oom-kill($((oom_now - oom_prev)))"
      # スロットルは独立（fetch失敗等の日常的な警報に最重要の OOM を握り潰させない）
      alert "メモリ枯渇でカーネルがプロセスを $((oom_now - oom_prev)) 件強制終了しました（OOM kill）。tmux やヘッドレス実行が落ちている可能性があります。空きメモリ: $(mem_avail_mb)" \
        "$PROJ/data/overseer/.last-alert-oom" || oom_save=0
    fi
    if [ "$oom_save" -eq 1 ]; then
      # 原子的に更新（直接上書きだと途中終了で空ファイル化し、次回「初回」に化ける＝Codex🟡）
      if ! { printf '%s\n' "$oom_now" >"$OOM_COUNT.tmp" && mv -f "$OOM_COUNT.tmp" "$OOM_COUNT"; }; then
        fail "oom-count-write"                   # 保存できない＝以後ずっと検知できないので黙らない
        rm -f "$OOM_COUNT.tmp" 2>/dev/null || true
      fi
    else
      echo "$(now) [warn] OOM を検知しましたが通知に失敗＝カウンタを据え置き、次の tick で再通知します" >>"$LOG"
    fi
  fi
  exec 8>&-
fi

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

# --- 連続タイムアウトのクールダウン（2026-07-31 社長承認）---
# 契機＝07-31 12:19〜13:10。hp-loop:ycom が25分でタイムアウトし、その13秒後に同じ処理を再実行して
# また25分でタイムアウト＝51分間サーバが高負荷になり、その最中に OOM が2回起きた（空きメモリ262MB）。
# 25分かけて終わらなかった処理を同じ条件ですぐ回しても結果は同じ＝待ってから再挑戦する。
#   1回目 → 30分待つ／2回目以降（連続）→ 6時間待つ（同じ処理を1日中回し続けない）。完走でリセット。
# 状態＝data/overseer/.cooldown-<label>（「連続回数 解除時刻(epoch)」の1行）。壊れていたら捨てて通常運転に戻す
# ＝クールダウンの誤動作で無人ループが永久に止まる方が、多少重いより悪い。
#
# ★daily（定時の強制起動）も冷却を尊重する（Codex🔴1）：当初は「1日1回だから増幅しない」として迂回させたが、
#   「01:36に反応tickが起動→02:01タイムアウト→ロック待ちの02:00 daily が即起動」で今日の事故がそのまま
#   再現する。ただし単純にスキップすると日次解析を失うので、見送った daily は .daily-due-<label> に印を残し、
#   冷却明けの normal tick が一度だけ肩代わりする（下の dispatch 参照）。
# ★タイムアウト以外の異常終了にも冷却をかける（Codex🔴4）：「24分走って exit 1」を繰り返せば負荷は同じ。
COOLDOWN_1ST=1800     # 30分（★提案既定値）
COOLDOWN_NTH=21600    # 6時間（★提案既定値）
COOLDOWN_RESET=86400  # 前回の冷却明けからこれ以上経っていれば「連続」とみなさず1回目に戻す（★提案既定値）
# 待ち時間の決定はここ1箇所。cooldown_set（実際の待ち）と cooldown_note（通知文）が同じ分岐を
# 各自に持つと、片方だけ直したとき「30分待つのに6時間と通知する」ような食い違いが静かに生まれる。
cooldown_wait_for() { [ "${1:-1}" -ge 2 ] && echo "$COOLDOWN_NTH" || echo "$COOLDOWN_1ST"; }
cooldown_file()   { printf '%s/data/overseer/.cooldown-%s'   "$PROJ" "${1//[^a-zA-Z0-9]/_}"; }
daily_due_file()  { printf '%s/data/overseer/.daily-due-%s'  "$PROJ" "${1//[^a-zA-Z0-9]/_}"; }
# 実行中の印（Codex🔴6）：クールダウンは「終了後」にしか書けないため、監督している側（この
# スクリプトの bash 自体・timeout・パイプライン）が OOM で殺されたり VPS が落ちたりすると、
# 何も記録されないまま次の tick が即再実行できてしまう。起動の【前】に印を置き、メインロックを
# 取れたのに印が残っていたら「前回は最後まで走れなかった」と判断する（ロックがある以上、
# 他の tick が実行中という可能性はない）。印を書けないときは起動しない＝fail-closed。
inflight_file()   { printf '%s/data/overseer/.inflight-%s'   "$PROJ" "${1//[^a-zA-Z0-9]/_}"; }

# 残り秒を返す（0＝待ち不要）。壊れたファイルは削除して0＝止めっぱなしにしない
cooldown_remain() {
  local f count until now_s max
  f=$(cooldown_file "$1")
  [ -f "$f" ] || { echo 0; return 0; }
  read -r count until <"$f" 2>/dev/null || true
  if ! [[ "${until:-}" =~ ^[0-9]+$ ]]; then
    rm -f "$f" 2>/dev/null || true
    echo 0; return 0
  fi
  now_s=$(date +%s)
  # 解除時刻が上限を超えて未来＝値の破損かシステム時刻の巻き戻り。捨てると即再実行、信じると長期停止に
  # なるため、6時間へ丸めて記録し直す（Codex🔴7）。どちらの事故にも倒れない側に寄せる。
  max=$((COOLDOWN_NTH + 600))
  if [ $((until - now_s)) -gt "$max" ]; then
    [[ "${count:-}" =~ ^[0-9]+$ ]] || count=2
    until=$((now_s + COOLDOWN_NTH))
    { printf '%s %s\n' "$count" "$until" >"$f.tmp" && mv -f "$f.tmp" "$f"; } 2>/dev/null \
      || rm -f "$f.tmp" 2>/dev/null || true
    echo "$(now) [warn] $1 のクールダウン解除時刻が異常（上限超え）＝6時間に丸めました" >>"$LOG"
  fi
  if [ "$now_s" -ge "$until" ]; then echo 0; else echo $((until - now_s)); fi
}

# 異常終了（タイムアウト・OOM・その他）のときに呼ぶ＝連続回数を1つ進めて次回まで待たせる。
# 標準出力に連続回数（通知文で使う）。$LOG への出力は標準出力を汚さないよう必ずリダイレクトする。
cooldown_set() {
  local f count prev_until until wait_s now_s
  f=$(cooldown_file "$1")
  count=""; prev_until=""
  [ -f "$f" ] && read -r count prev_until <"$f" 2>/dev/null || true
  [[ "${count:-}" =~ ^[0-9]+$ ]] || count=0
  now_s=$(date +%s)
  # 前回の冷却明けから十分に間が空いていれば「連続」ではない＝1回目に戻す（Codex🟡8）。
  # これが無いと、1か月前の1回目を引きずって次の1回目が6時間停止になる。
  if [[ "${prev_until:-}" =~ ^[0-9]+$ ]] && [ $((now_s - prev_until)) -gt "$COOLDOWN_RESET" ]; then
    count=0
  fi
  count=$((count + 1))
  wait_s=$(cooldown_wait_for "$count")
  until=$((now_s + wait_s))
  if ! { printf '%s %s\n' "$count" "$until" >"$f.tmp" && mv -f "$f.tmp" "$f"; }; then
    rm -f "$f.tmp" 2>/dev/null || true
    echo "$(now) [warn] クールダウンの記録に失敗＝$1 は次の tick で即再実行されます" >>"$LOG"
  fi
  echo "$count"
}

# 削除失敗を黙殺しない（Codex🟡10）＝残ると次の失敗が不当に「連続2回目」になる
# 原因がこちらに無い（待っても直らないが、毎分叩いても無駄）ときに、連続回数を進めずに冷ます。
# クレジット切れがこれ＝失敗回数として数えて6時間ロックすると、補充後も長く止まったままになる。
cooldown_hold() {
  local f until; f=$(cooldown_file "$1")
  until=$(( $(date +%s) + ${2:-$COOLDOWN_1ST} ))
  { printf '0 %s\n' "$until" >"$f.tmp" && mv -f "$f.tmp" "$f"; } || rm -f "$f.tmp" 2>/dev/null || true
}

cooldown_clear() {
  local f; f=$(cooldown_file "$1")
  [ -e "$f" ] || return 0
  rm -f "$f" 2>/dev/null && return 0
  echo "$(now) [warn] $1 のクールダウン解除に失敗＝次の失敗が連続扱いになります（$f）" >>"$LOG"
  return 1
}

# 通知文で使う待ち時間の表記（待ち時間そのものは cooldown_wait_for が正＝定義を二重に持たない）
cooldown_note() {
  local w; w=$(cooldown_wait_for "${1:-1}")
  [ "$w" -ge 3600 ] && printf '%d時間' "$((w / 3600))" || printf '%d分' "$((w / 60))"
}

# 冷却を1つ進め、通知文に添える一文を返す。失敗の種類ごとに同じ組み立てを書き写すと、
# ある経路だけ「冷やしたのに通知に書き忘れる／通知したのに冷やしていない」がすり抜ける。
# ★状態を進める副作用がある＝1回の失敗につき1回だけ呼ぶこと（表示用の関数ではない）。
cooldown_apply() {
  local n; n=$(cooldown_set "$1")
  printf '連続%d回目＝%s冷ましてから再挑戦します' "$n" "$(cooldown_note "$n")"
}

# --- 反応起動の対象を数える（2026-07-31 社長承認）---
# 従来は「自分宛の未読が1通でもあれば起動」＝中身を見ずに鳴る呼び鈴だった。実際 07-31 は開発
# エージェントからの受領確認（type=ack「了解しました」）2通で25分のフル解析が2本走り、サーバが
# 50分間高負荷になって OOM が2回起きた。全期間の実績でも、解析ループ宛の便の約2/3は
# report/ack/fyi＝「本番はもう直っている」「受け取りました」の事後連絡で、待っている人がいない。
#
# 判断軸は「社長が待っているか」の一点にする（社長の指示 2026-07-31）：
#   ・社長からの便 → 反応tickで即起動（従来どおりフルに動く。仕事は削らない）
#   ・それ以外     → 起動しない。定時（daily）の解析でまとめて処理する
# 起動しなかった便は消さず new/ に残るので、次の daily がそのまま拾う＝取りこぼさない。
#
# ★受領確認（type=ack）は宛先を問わず反応起動させない（Codex🟡13）：絞り込みを適用していない
#   エージェント（chat/partner/overseer/rally/konjaku）では、今も ack だけで25分の処理が起動しうる。
#   ack は定義上「受け取りました」で、応答も分析も要らない。ただし社長からの便は type によらず
#   起動対象に残す＝取りこぼす側でなく余分に起動する側へ倒す。
# 数えるだけの純粋な関数にしてあるのは、この判定を単体でテストできるようにするため。
#
# ★JSON は grep でなく実際にパースする（Codex🔴2）：grep だと (a)`"to" : "x"`（コロン前の空白）や
#   タブ・改行での整形を取りこぼし、(b)本文に `"from": "president"` という文字列が含まれるだけで
#   社長便と誤認する。実際 07-31 は dispatch が pending=1 で起動したのにエージェント本人は
#   「実ファイル0件」と記録しており、数え方が食い違っていた。python3 で1tickに1回だけ全便を読み、
#   「宛先 送り主 種別 パス」のタブ区切り索引にしてから awk で引く（プロセスは毎分1つ・誤認ゼロ）。
#   壊れた／書き込み途中の JSON は件数だけ数えて通知する＝黙って無視しない。
MAILBOX_INDEX="$PROJ/data/overseer/.mailbox-index"
MAILBOX_INVALID=0

build_mailbox_index() {
  local out rc
  out=$("$PY" - "$MAILBOX_NEW" <<'PYEOF'
import json, os, sys
d = sys.argv[1]
rows, bad = [], 0
try:
    names = sorted(os.listdir(d))
except OSError:
    sys.exit(3)
for n in names:
    if not n.endswith(".json"):
        continue
    p = os.path.join(d, n)
    if not os.path.isfile(p):
        continue
    if "\t" in p or "\n" in p:      # 索引の区切りを壊す名前は扱わない（無視でなく不正として数える）
        bad += 1
        continue
    try:
        with open(p, encoding="utf-8") as f:
            o = json.load(f)
        if not isinstance(o, dict):
            raise ValueError("not an object")
    except Exception:
        bad += 1                    # 書き込み途中・破損。宛先が読めない以上ここでは振り分けられない
        continue
    rows.append("\t".join(str(o.get(k, "")) for k in ("to", "from", "type")) + "\t" + p)
# 1行目は必ず不正件数。宛先名と衝突しない印にしてあるので、以降の awk では素通りする
print("#invalid\t%d\t\t" % bad)
sys.stdout.write("\n".join(rows) + ("\n" if rows else ""))
PYEOF
) ; rc=$?
  [ "$rc" -eq 0 ] || return 1       # 呼び出し側が MAILBOX_OK=0 にする（idle に化けさせない）
  if ! { printf '%s\n' "$out" >"$MAILBOX_INDEX.tmp" && mv -f "$MAILBOX_INDEX.tmp" "$MAILBOX_INDEX"; }; then
    rm -f "$MAILBOX_INDEX.tmp" 2>/dev/null || true
    return 1
  fi
  MAILBOX_INVALID=$(awk -F'\t' '$1=="#invalid" {print $2; exit}' "$MAILBOX_INDEX" 2>/dev/null)
  [[ "${MAILBOX_INVALID:-}" =~ ^[0-9]+$ ]] || MAILBOX_INVALID=0
  return 0
}

# 宛先 to の便すべて（件数表示用）
mailbox_all() { awk -F'\t' -v t="$1" '$1==t {print $4}' "$MAILBOX_INDEX" 2>/dev/null; }

# 反応起動の引き金になる便のパス（改行区切り）。無進捗の検知でも同じ集合を使う＝判定を食い違わせない
mailbox_triggers() {
  local to="$1" urgent_only="${2:-0}"
  if [ "$urgent_only" = "1" ]; then
    awk -F'\t' -v t="$to" '$1==t && $2=="president" {print $4}' "$MAILBOX_INDEX" 2>/dev/null
  else
    awk -F'\t' -v t="$to" '$1==t && ($3!="ack" || $2=="president") {print $4}' "$MAILBOX_INDEX" 2>/dev/null
  fi
}

# 返り値＝「起動対象の件数 待機に回した件数」（スペース区切り1行）
count_pending() {
  local to="$1" urgent_only="${2:-0}" n u
  n=$(mailbox_all "$to" | grep -c '[^[:space:]]')
  u=$(mailbox_triggers "$to" "$urgent_only" | grep -c '[^[:space:]]')
  printf '%s %s\n' "$u" "$((n - u))"
}


# --- 振り分け：宛先 mailbox に未読があれば（または daily で強制されていれば）当該モードを起動 ---
# 引数：表示ラベル / スラッシュコマンド / mailbox 宛先(to) / [社長便だけで起動するか(1)]
#       → 行った action 文字列を ACTIONS に積む
declare -a ACTIONS=()
dispatch() {
  local label="$1" slash="$2" to="$3" urgent_only="${4:-0}"
  local pending defer force action rc
  # daily（強制）モードでは強制対象だけ動かす。他エージェントの pending 処理は反応tickに任せ、
  # daily の保持時間を最短にして取りこぼし／横入りを防ぐ（Codex指摘：daily中に全dispatchが走る問題）。
  if [ "$MODE" = "daily" ] && [ "$FORCE_AGENT" != "$to" ]; then
    ACTIONS+=("$label:-:skip(daily)")
    return 0
  fi
  # new/ が健全な時だけ数える。find なので glob 非展開や空ディレクトリでも誤検知しない
  defer=0
  if [ "$MAILBOX_OK" -eq 1 ]; then
    read -r pending defer <<<"$(count_pending "$to" "$urgent_only")"
  else
    pending=0
  fi
  [[ "${pending:-}" =~ ^[0-9]+$ ]] || pending=0
  [[ "${defer:-}"   =~ ^[0-9]+$ ]] || defer=0
  force=0; [ "$FORCE_AGENT" = "$to" ] && force=1
  action="idle"
  # 冷却で見送った daily の後追い（上部の定義参照）。冷却が明けた最初の normal tick が一度だけ肩代わりする。
  # 印が今日のものでなければ捨てる＝その日の daily cron が自分で来るので、古い借金を溜め込まない。
  local due_file; due_file=$(daily_due_file "$label")
  if [ "$force" -eq 0 ] && [ -f "$due_file" ]; then
    if [ "$(cat "$due_file" 2>/dev/null)" != "$(date +%F)" ]; then
      rm -f "$due_file" 2>/dev/null || true
    elif [ "$(cooldown_remain "$label")" -eq 0 ]; then
      force=1
      echo "$(now) [daily-due] $label ＝冷却で見送った定時実行を肩代わりします" >>"$LOG"
    fi
  fi
  if [ "$pending" -gt 0 ] || [ "$force" -eq 1 ]; then
    # 直前が異常終了していたら、冷ます時間を置いてから再挑戦する（上部の定義参照）。
    # pending は消費せず残す＝待つだけで、仕事そのものは取りこぼさない。
    local cd_left; cd_left=$(cooldown_remain "$label")
    if [ "$cd_left" -gt 0 ]; then
      local cd_min=$(( (cd_left + 59) / 60 ))   # 切り上げ。表示とログで同じ値を使う
      action="cooldown(${cd_min}分)"
      # daily は「後で必ずやる」印を残してから見送る＝その日の解析を落とさない（Codex🔴1）
      if [ "$force" -eq 1 ]; then
        action="$action(daily順延)"
        printf '%s\n' "$(date +%F)" >"$due_file" 2>/dev/null \
          || echo "$(now) [warn] $label の daily順延の記録に失敗＝今日の定時実行が落ちます" >>"$LOG"
      fi
      echo "$(now) [cooldown] $label は直前が異常終了＝あと ${cd_min}分 待ってから再挑戦します（pending=$pending・仕事は消していません）" >>"$LOG"
      ACTIONS+=("$label:$pending:$action")
      return 0
    fi
    [ "$force" -eq 1 ] && action="daily" || action="handle($pending)"
    # 前回の実行が「終了処理まで到達できずに消えた」痕跡（上部の定義参照）
    local inflight; inflight=$(inflight_file "$label")
    if [ -f "$inflight" ]; then
      rm -f "$inflight" 2>/dev/null || true
      fail "$label-died"; action="$action(DIED)"
      alert "ヘッドレス $label は前回、終了処理まで到達せずに消えていました（監督プロセスごと OOM で殺された・強制終了・再起動などの可能性）。$(cooldown_apply "$label")。"
      ACTIONS+=("$label:$pending:$action")
      return 0
    fi
    if ! printf '%s %s\n' "$$" "$(now)" >"$inflight" 2>/dev/null; then
      # 状態を保存できないまま重い処理を始めると、失敗しても記録が残らず毎分再実行になる
      fail "$label-inflight-write"; action="$action(NOSTATE)"
      alert "ヘッドレス $label の実行中マーカーを書けませんでした（$inflight）。記録できない状態で重い処理は始めないため、今回は起動を見送ります。"
      ACTIONS+=("$label:$pending:$action")
      return 0
    fi
    # 起動の引き金になった便を控えておく＝完走後に1件も減っていなければ「無進捗」として冷やす（Codex🔴5）。
    # これが無いと、exit 0 で返しつつ受信箱を処理しないループが毎分25分ジョブを起動し続ける。
    local trig_before; trig_before=$(mailbox_triggers "$to" "$urgent_only")
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
    # MYAGENT_AGENT：エージェント別の追加制限用（comms＝外部入力を読むため書き込み先を
    # data/comms/・site/comms/ に限定し外部送信系 Bash を拒否＝2026-07-28 Codexレビュー反映）
    # choom -n 800：OOM時にカーネルがこの claude（と子孫）を優先的に殺す＝社長の tmux を守る（上部の定義参照）
    # 実行前後の oom_kill 差分で「タイムアウトの137」と「OOM で殺された137」を見分ける（Codex🟡）。
    # choom -n 800 を付けた結果、この claude は OOM の第一候補になった＝137=OOM の経路が現実的になり、
    # 素朴に 137=タイムアウトと決め打つと「25分でタイムアウト」と誤報して原因調査を誤らせる。
    local oom_pre oom_post log_off
    oom_pre=$(oom_kill_count)
    log_off=$(stat -c%s "$LOG" 2>/dev/null || echo 0)   # この実行が書いた分だけを後で読むための目印
    MYAGENT_UNATTENDED=1 MYAGENT_AGENT="$to" timeout --kill-after=30s "${tmo}s" "${CHOOM[@]}" "$CLAUDE" -p "$slash" --permission-mode acceptEdits 2>&1 | sed 's/^/» /' >>"$LOG"
    # ログ側（sed >>$LOG）の失敗も拾う（Codex🟡11）＝ログが書けない状況ではクールダウンの記録も
    # 書けない可能性が高く、この安全機構そのものが効かなくなる。ログに書けないので Slack で鳴らす。
    local -a pipe_rc; pipe_rc=("${PIPESTATUS[@]}")
    rc=${pipe_rc[0]}
    rm -f "$inflight" 2>/dev/null || true   # ここまで来た＝終了処理に到達した（結果の良し悪しは以降で判定）
    if [ "${pipe_rc[1]:-0}" -ne 0 ]; then
      fail "$label-logwrite"
      alert "ヘッドレス $label の実行ログを記録できませんでした（ディスク満杯・権限などの可能性）。クールダウン等の状態も書けない恐れがあります。"
    fi
    # --- クレジット切れの判定（2026-08-03 社長承認）---
    # 契機＝08-03、社長が partner へ投函した2通に半日返事が返らなかった。原因は claude 側の
    # クレジット枯渇で、この場合 claude は「エラー」ではなく exit 0 を返し、案内を1行出して4秒で終わる。
    # つまり無進捗として検知はできたが、通知文が「便が処理されていません」だったため
    # 社長には原因が分からず、そのうえ連続2回目として6時間ロックされていた。
    #   ・原因をそのまま通知に出す（ログには出ていたのに伝えていなかった＝静かに壊れるのと同じ）
    #   ・連続回数に数えない（こちらの不具合ではない。補充後に長く止まったままにしない）
    #   ・ただし毎分叩いても無駄なので30分だけ冷ます＝補充されれば30分以内に自力で復帰する
    if grep -qiE "out of usage credits|/usage-credits|usage limit reached|reached your usage limit" \
         <(tail -c "+$((log_off + 1))" "$LOG" 2>/dev/null); then
      fail "$label-nocredit"; action="$action(NOCREDIT)"
      cooldown_hold "$label" "$COOLDOWN_1ST"
      alert "ヘッドレス $label が実行できません＝**クレジットが尽きています**（claude が案内だけ出して終了）。補充するまで無人処理は動きません。仕事は消していません（未処理 $pending 件は残置）。$((COOLDOWN_1ST / 60))分おきに自動で再挑戦するので、補充すれば自然に再開します。" \
        "$PROJ/data/overseer/.last-alert-nocredit"
      [ "$to" = "partner" ] && partner_alert "クレジットが尽きているため朝礼・返信ができません。補充をお願いします（お預かりした用件は消えていません）。"
      ACTIONS+=("$label:$pending:$action")
      return 0
    fi
    if [ "$rc" -ne 0 ]; then
      oom_post=$(oom_kill_count)
      # タイムアウト以外の異常終了にも冷却をかける（Codex🔴4）＝「24分走って exit 1」の繰り返しも
      # タイムアウトと同じ負荷になる。ここで一度だけ進め、分岐は通知文の出し分けに専念する。
      local cd_msg; cd_msg=$(cooldown_apply "$label")
      if [ "$rc" -eq 137 ] && [[ "${oom_pre:-}" =~ ^[0-9]+$ ]] && [[ "${oom_post:-}" =~ ^[0-9]+$ ]] \
         && [ "$oom_post" -gt "$oom_pre" ]; then
        fail "$label-oomkill"; action="$action(OOMKILL)"
        alert "ヘッドレス $label がメモリ不足で強制終了されました（OOM kill・実行中に oom_kill が $((oom_post - oom_pre)) 件増加）。タイムアウトではありません。空きメモリ: $(mem_avail_mb)（$cd_msg）" \
          "$PROJ/data/overseer/.last-alert-oom"
        [ "$to" = "partner" ] && partner_alert "朝礼がメモリ不足で強制終了されました（OOM kill）。時間切れではなくメモリ側の問題です。"
      elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        fail "$label-timeout"; action="$action(TIMEOUT)"
        alert "ヘッドレス $label が$((tmo/60))分でタイムアウトしました（pending=$pending force=$force）。$cd_msg（すぐ再実行すると同じ結果になり負荷だけ倍になるため）。"
        [ "$to" = "partner" ] && partner_alert "朝礼が制限時間（$((tmo/60))分）内に終わりませんでした。台帳・掲示板が重くなっている可能性があります。"
      else
        fail "$label-fail($rc)"; action="$action(ERR$rc)"
        alert "ヘッドレス $label が異常終了しました（exit=$rc pending=$pending force=$force）。$cd_msg。設定・認証の誤りなら、間を置いても直りません＝ログをご確認ください。"
        [ "$to" = "partner" ] && partner_alert "朝礼が異常終了しました（終了コード $rc）。生存確認リンクとログをご確認ください。"
      fi
    else
      # 完走。ただし「起動の引き金になった便が1件も減っていない」＝無進捗なら冷やす（Codex🔴5）。
      # exit 0 を返しつつ受信箱を処理しないループは、毎分25分ジョブを起動し続ける最悪の形になる。
      local progressed=1
      if [ -n "$trig_before" ]; then
        progressed=0
        local tf
        while IFS= read -r tf; do
          [ -n "$tf" ] || continue
          [ -e "$tf" ] || { progressed=1; break; }
        done <<<"$trig_before"
      fi
      if [ "$progressed" -eq 0 ]; then
        fail "$label-noprogress"; action="$action(NOPROG)"
        alert "ヘッドレス $label は正常終了しましたが、起動の引き金になった便が1件も処理されていません（new/ に残ったまま＝このままだと次の tick で同じ処理が再起動します）。$(cooldown_apply "$label")。"
      else
        # 一度こけただけの重い日を、以後ずっと引きずらない
        cooldown_clear "$label" || true
        rm -f "$due_file" 2>/dev/null || true   # 肩代わりした daily はここで完了扱い
      fi
    fi
  fi
  # 待機に回した便は「idle」に化けさせない＝定時待ちが何通あるかを毎tickの1行で見えるようにする
  [ "$defer" -gt 0 ] && [ "$action" = "idle" ] && action="defer($defer)"
  ACTIONS+=("$label:$pending:$action")
}

# --- 索引を作る。作れなければ受信箱を不健全として扱う＝「未読ゼロ」に化けさせない（Codex🔴3） ---
if [ "$MAILBOX_OK" -eq 1 ]; then
  if ! build_mailbox_index; then
    MAILBOX_OK=0
    fail "mailbox-index"
    alert "mailbox の索引を作成できませんでした（$MAILBOX_NEW）。今回の tick は受信処理をスキップします。"
  elif [ "$MAILBOX_INVALID" -gt 0 ]; then
    # 宛先が読めない便は誰にも振り分けられない＝黙って消えるのを防ぐため必ず鳴らす
    fail "mailbox-invalid($MAILBOX_INVALID)"
    alert "mailbox に読めない便が $MAILBOX_INVALID 件あります（JSON の破損か書き込み途中）。宛先が判定できないため、どのエージェントにも振り分けられていません。"
  fi
fi

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
# 第4引数の 1 ＝反応tickでは社長からの便だけで起動する（上の count_pending の注記を参照）。
# 開発からの report/ack/fyi は待機に回し、定時の解析でまとめて処理する＝本番はもう直っており急がない。
dispatch "hp-loop:ycom"     "/hp-loop ycom"     "hp-loop-ycom"     1
dispatch "hp-loop:yoshida"  "/hp-loop yoshida"  "hp-loop-yoshida"  1
dispatch "hp-loop:fujisaka" "/hp-loop fujisaka" "hp-loop-fujisaka" 1
dispatch "hp-loop:yokohawaii" "/hp-loop yokohawaii" "hp-loop-yokohawaii" 1
# rally / konjaku は daily が月曜だけ＝待機に回すと最大7日待つ。社長の判断待ちのため従来どおり全便で起動する
dispatch "hp-loop:rally"    "/hp-loop rally"    "hp-loop-rally"
dispatch "hp-loop:konjaku"  "/hp-loop konjaku"  "hp-loop-konjaku"
# ブログ：診断(blog-loop)→執筆/下書き投稿(blog-write)。HP解析とは別時刻の daily で回す（05:00/05:30）。
# blog-loop-ycom は web-hanasaka の事実回答等で反応tick起動もする。blog-write-ycom は daily強制専用キー（mailbox受信なし）。
dispatch "blog-loop:ycom"    "/blog-loop ycom"    "blog-loop-ycom"    1
dispatch "blog-write:ycom"   "/blog-write ycom"   "blog-write-ycom"
# 既存記事の改善（B）：元記事は触らず改善版を下書き複製で作る。新規(blog-write)とは別ループ・別時刻。
dispatch "blog-improve:ycom" "/blog-improve ycom" "blog-improve-ycom"
# Chatwork蒸留：daily強制専用キー（mailbox受信なし）。起動は bin/comms-tick.sh の新着ガード経由
# （2hおき 6-22時・前回蒸留以降の raw 新着ゼロなら claude を起動しない＝2026-07-27 社長合意）
dispatch "comms" "/comms" "comms"

# --- 3) ハートビート（毎回・Web可視・書き込み失敗も検知＝Codex🔴2） ---
HB_LINE="agent-tick alive: $(now) | mode=$MODE force=${FORCE_AGENT:-none} | ${ACTIONS[*]:-none} | status=$(status_str)"
mkdir -p "$(dirname "$HEARTBEAT_WEB")" 2>/dev/null
if ! { printf '%s\n' "$HB_LINE" >"$HEARTBEAT_WEB.tmp" && mv -f "$HEARTBEAT_WEB.tmp" "$HEARTBEAT_WEB"; }; then
  fail "heartbeat-write"
  alert "ハートビートの書き込みに失敗しました（$HEARTBEAT_WEB）。ディスク/権限を確認してください。"
fi

# --- ログ（heartbeat 失敗も反映した最終 status を記録） ---
echo "$(now) [tick] mode=$MODE force=${FORCE_AGENT:-none} | ${ACTIONS[*]:-none} | status=$(status_str)" >>"$LOG"
