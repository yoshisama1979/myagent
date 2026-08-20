#!/bin/bash
# talk-tick（相談レーン）の回帰テスト。claude は偽物に差し替えて起動判定・セッション継続・
# 失敗時のふるまいだけを検証する（rules/testing.md §2 の必須3条件に該当＝無人ループから
# 呼ばれる／状態ファイルを書く／判定ロジックを持つ）。
#
# 使うデータはすべて架空。実在の取引先名・社長の実発言は1件も置かない。
set -u
T="${CLAUDE_JOB_DIR:-/tmp/claude-1000/-home-vpsuser-projects-myagent/b2e1f4c5-60cb-41a3-b088-44c2fb617439/scratchpad}/talk-test"
SRC="$(cd "$(dirname "$0")" && pwd)/talk-tick.sh"
pass=0; fail=0
ok() { echo "  ✅ $1"; pass=$((pass+1)); }
ng() { echo "  ❌ $1${2:+ — $2}"; fail=$((fail+1)); }

setup() {
  rm -rf "$T"; mkdir -p "$T/bin" "$T/data/mailbox/new" "$T/data/slack"
  # 偽 claude：呼ばれた引数を1行ずつ記録して、指定の終了コードで返る
  # 偽 claude：呼ばれた引数を記録し、既定では「仕事をした」＝担当スレッドの便を cur/ へ移す。
  # FAKE_NOOP=1 にすると「喋ったが便を処理しない」（＝2026-08-19 に実機で起きた壊れ方を再現）。
  cat > "$T/bin/claude" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_CALLS"
echo "（偽claudeの出力）"
if [ "${FAKE_NOOP:-0}" != "1" ] && [ "${FAKE_RC:-0}" = "0" ]; then
  ts=""
  for a in "$@"; do case "$a" in /talk\ *) ts="${a#/talk }";; esac; done
  if [ -n "$ts" ]; then
    for f in "$FAKE_PROJ"/data/mailbox/new/*.json; do
      [ -e "$f" ] || continue
      grep -q "\"thread_ts\":\"$ts\"" "$f" && rm -f "$f"
    done
  fi
fi
exit "${FAKE_RC:-0}"
FAKE
  chmod +x "$T/bin/claude"
  # 偽 slack.sh：鳴らした本文を記録するだけ（外へは出さない）
  cat > "$T/bin/slack.sh" <<'FAKE'
#!/bin/bash
cat >> "$FAKE_SLACK"
FAKE
  chmod +x "$T/bin/slack.sh"
  : > "$T/calls.txt"; : > "$T/slack.txt"
  export FAKE_CALLS="$T/calls.txt" FAKE_SLACK="$T/slack.txt" FAKE_RC=0 FAKE_PROJ="$T"
  unset FAKE_NOOP
}

mail() {  # mail <ファイル名> <to> <thread_ts>
  cat > "$T/data/mailbox/new/$1" <<JSON
{"id":"$1","from":"president","to":"$2","type":"request",
 "slack":{"thread_ts":"$3","channel":"C_TEST"},
 "subject":"架空の相談","body":"テスト用の架空メッセージです"}
JSON
}

run() {
  MYAGENT_PROJ="$T" MYAGENT_PY="$(command -v python3)" CLAUDE="$T/bin/claude" \
  TALK_LOG="$T/talk.log" "$@" bash "$SRC" 2>&1
}
calls() { cat "$T/calls.txt"; }
# ⚠️ grep -c は0件でも「0」を出したうえで exit 1 を返す。`|| echo 0` を足すと "0\n0" になり
#    [ "$(ncalls)" -eq 0 ] が integer expected で落ちる（2026-08-19 自分で踏んだ）。wc なら1行。
ncalls() { wc -l < "$T/calls.txt" | tr -d " "; }

echo "=== 起動しない条件（ここが崩れると毎分claudeが立ち上がって費用が出る）==="
setup; run >/dev/null
[ "$(ncalls)" -eq 0 ] && ok "受信ゼロなら claude を起動しない" || ng "受信ゼロで起動した"
setup; mail a.json partner 111.1; run >/dev/null
[ "$(ncalls)" -eq 0 ] && ok "宛先が talk でない便では起動しない" || ng "他人宛で起動した"
setup; cat > "$T/data/mailbox/new/b.json" <<'J'
{"id":"b","to":"talk","body":"スレッド情報が無い便"}
J
run >/dev/null
[ "$(ncalls)" -eq 0 ] && ok "thread_ts が無い便では起動しない（返信先が無い）" || ng "宛先不明で起動した"
setup; printf 'これはJSONではない' > "$T/data/mailbox/new/broken.json"; out=$(run)
[ "$(ncalls)" -eq 0 ] && ok "壊れた便があっても落ちない・起動しない" || ng "壊れた便で起動した"

echo
echo "=== スレッド単位で捌く ==="
setup; mail a.json talk 111.1; mail b.json talk 111.1; mail c.json talk 222.2; run >/dev/null
[ "$(ncalls)" -eq 2 ] && ok "同じスレッドの2通はまとめて1回・別スレッドは別回（計2回）" \
  || ng "起動回数が違う" "$(ncalls)回"
calls | grep -q -- "-p /talk 111.1" && ok "スレッドts をコマンド引数で渡す" || ng "引数が違う" "$(calls)"

echo
echo "=== ★セッション継続（この器の主目的）==="
setup; mail a.json talk 111.1; run >/dev/null
[ -f "$T/data/mailbox/new/a.json" ] && ng "成功したのに便が new/ に残っている（偽claudeの想定崩れ）" \
  || ok "成功したら便が受信箱から消える（処理済みへ移る）"
sid=$(calls | grep -o -- '--session-id [0-9a-f-]*' | head -1 | awk '{print $2}')
[ -n "$sid" ] && ok "初回は --session-id で新しいセッションを立てる" || ng "初回にsession-idが無い" "$(calls)"
rm -f "$T"/data/mailbox/new/*.json; : > "$T/calls.txt"
mail d.json talk 111.1; run >/dev/null
calls | grep -q -- "--resume $sid" \
  && ok "★2通目は同じスレッドの --resume＝会話が続く（社長が前提を説明し直さない）" \
  || ng "2通目がresumeでない" "$(calls)"
rm -f "$T"/data/mailbox/new/*.json; : > "$T/calls.txt"
mail e.json talk 999.9; run >/dev/null
calls | grep -q -- "--session-id" && ok "別スレッドは別セッション（会話が混ざらない）" || ng "別スレッドでresumeした" "$(calls)"

echo
echo "=== ★正常終了しても仕事をしていなければ成功にしない ==="
setup; mail a.json talk 111.1; FAKE_NOOP=1 run >/dev/null
grep -q 'no-progress' "$T/talk.log" \
  && ok "★rc=0でも便が減っていなければ [no-progress] と記録する（喋っただけを成功にしない）" \
  || ng "無進捗を成功として記録した" "$(tail -3 "$T/talk.log")"
grep -q '"fails": *"1"' "$T/data/slack/talk-state.json" \
  && ok "無進捗は失敗として数える（冷却が効く＝毎分空振りしない）" || ng "failsが増えていない"
[ -f "$T/data/mailbox/new/a.json" ] && ok "無進捗でも便は残る（社長の質問を失わない）" || ng "便が消えた"

echo
echo "=== 失敗したとき（黙って便を捨てない・毎分燃やさない）==="
setup; mail a.json talk 111.1; FAKE_RC=9 run >/dev/null
[ -f "$T/data/mailbox/new/a.json" ] && ok "★失敗しても便を new/ に残す（社長の質問を消さない）" || ng "便が消えた"
grep -q '"fails": *"1"' "$T/data/slack/talk-state.json" && ok "連続失敗を数える" \
  || ng "失敗が記録されていない" "$(cat "$T/data/slack/talk-state.json" 2>/dev/null)"
grep -q '"session": *""' "$T/data/slack/talk-state.json" \
  && ok "★失敗時はセッションを捨てる（壊れたIDを握って毎分失敗し続けない）" || ng "sessionが残った"
: > "$T/calls.txt"; FAKE_RC=9 run >/dev/null
[ "$(ncalls)" -eq 0 ] && ok "★冷却中は起動しない（失敗を毎分くり返して費用を垂れ流さない）" || ng "冷却中に起動した"
[ -s "$T/slack.txt" ] && ng "1回目の失敗で社長に鳴らした（狼少年）" || ok "1回の失敗では鳴らさない"

echo
echo "=== 冷却が明けたら自分で戻る ==="
python3 - "$T/data/slack/talk-state.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s["111.1"]["cooldown_until"]="0"
json.dump(s, open(p,"w"))
PY
: > "$T/calls.txt"; FAKE_RC=9 run >/dev/null
[ "$(ncalls)" -eq 1 ] && ok "冷却明けに再挑戦する（永久に黙り込まない）" || ng "再挑戦しなかった"
grep -q '連続2回' "$T/slack.txt" && grep -q 'rc=9' "$T/slack.txt" \
  && ok "★連続2回目で社長に鳴らす＋原因(rc)を本文に書く（黙って止まらない）" \
  || ng "2回目でも鳴らさない" "$(cat "$T/slack.txt")"

echo
echo "=== 成功したら状態を戻す ==="
python3 - "$T/data/slack/talk-state.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s["111.1"]["cooldown_until"]="0"
json.dump(s, open(p,"w"))
PY
: > "$T/calls.txt"; run >/dev/null
grep -q '"fails": *"0"' "$T/data/slack/talk-state.json" && ok "成功で連続失敗をリセット" || ng "failsが戻らない"
calls | grep -q -- '--session-id' && ok "捨てたあとは新しいセッションで立て直す" || ng "古いsessionを使った" "$(calls)"

echo
echo "=== ★進捗は件数でなく便IDで測る（並行fetchに揺さぶられない）==="
# 実行中に同じスレッドへ新着が1通入る状況を偽claudeで再現する。
setup; mail a.json talk 111.1
cat > "$T/bin/claude" <<'FAKE2'
#!/bin/bash
echo "$*" >> "$FAKE_CALLS"
ts=""; for a in "$@"; do case "$a" in /talk\ *) ts="${a#/talk }";; esac; done
# 担当分は正しく処理し、同時に「fetchが新着を入れた」状況を作る（＝件数は変わらない）
rm -f "$FAKE_PROJ"/data/mailbox/new/a.json
cat > "$FAKE_PROJ/data/mailbox/new/late.json" <<J
{"id":"late","to":"talk","slack":{"thread_ts":"$ts"},"body":"実行中に届いた新着"}
J
exit 0
FAKE2
chmod +x "$T/bin/claude"
run >/dev/null
grep -q '\[ok\]' "$T/talk.log" \
  && ok "★担当分を処理していれば、実行中に新着が入っても成功と判定する（件数だと誤判定した）" \
  || ng "並行の新着で無進捗と誤判定した" "$(tail -2 "$T/talk.log")"
grep -q '"fails": *"0"' "$T/data/slack/talk-state.json" && ok "誤って失敗に数えない" || ng "failsが増えた"

echo
echo "=== ★無進捗ではセッションを捨てない（重複返信を防ぐ）==="
setup; mail a.json talk 111.1; FAKE_NOOP=1 run >/dev/null
sid1=$(python3 -c "import json;print(json.load(open('$T/data/slack/talk-state.json'))['111.1'].get('session',''))")
[ -n "$sid1" ] \
  && ok "★正常終了・便が残る場合はセッションを保持（次回は自分の発言履歴を見て done だけやり直せる）" \
  || ng "無進捗でセッションを捨てた＝次回は白紙から始まり同じ質問に重複返信する"
setup; mail a.json talk 111.1; FAKE_RC=9 run >/dev/null
sid2=$(python3 -c "import json;print(json.load(open('$T/data/slack/talk-state.json'))['111.1'].get('session',''))")
[ -z "$sid2" ] && ok "実行そのものが失敗した場合はセッションを捨てる（壊れたIDを握らない）" || ng "壊れたsessionを保持した"

echo
echo "=== ★状態を保存できないときは打ち切る（毎分燃やさない）==="
setup; mail a.json talk 111.1; mail b.json talk 222.2; mail c.json talk 333.3
# ⚠️ ディレクトリごと読み取り専用にしてはいけない：ロックファイルすら作れず、
#    状態保存に到達する前にスクリプトが終わる＝検証したい経路を通らない。
#    状態ファイルの位置をディレクトリにして「そこだけ書けない」状態を作る。
mkdir -p "$T/data/slack/talk-state.json"
out=$(run 2>&1); rmdir "$T/data/slack/talk-state.json" 2>/dev/null
grep -q 'fatal' "$T/talk.log" && ok "★保存失敗を [fatal] として記録する" \
  || ng "保存失敗を黙って無視した" "$(tail -3 "$T/talk.log")"
[ "$(ncalls)" -le 1 ] \
  && ok "★保存できない状態で次のスレッドへ進まない（冷却が効かず毎分起動し続けるのを防ぐ）" \
  || ng "保存できないのに走り続けた" "$(ncalls)回"
grep -q '保存できません' "$T/slack.txt" && ok "保存失敗を社長へ鳴らす（黙って止まらない）" || ng "鳴らさなかった"

echo
echo "=== ★通知は成功するまで再試行する ==="
setup; mail a.json talk 111.1
printf '#!/bin/bash\ncat >/dev/null\nexit 1\n' > "$T/bin/slack.sh"; chmod +x "$T/bin/slack.sh"
FAKE_RC=9 run >/dev/null
python3 - "$T/data/slack/talk-state.json" <<'PYX'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s["111.1"]["cooldown_until"]="0"
json.dump(s, open(p,"w"))
PYX
FAKE_RC=9 run >/dev/null
grep -c 'warn.*通知に失敗' "$T/talk.log" | grep -qv '^0$' \
  && ok "★通知に失敗したら印を付けず、次回また鳴らそうとする（1回きりで黙り込まない）" \
  || ng "通知失敗を握り潰した" "$(tail -3 "$T/talk.log")"
python3 -c "
import json,sys
s=json.load(open('$T/data/slack/talk-state.json'))
sys.exit(0 if not s['111.1'].get('alerted') else 1)" \
  && ok "送れていないのに「通知済み」の印を付けない" || ng "送れていないのに印が付いた"

echo
echo "=== 暴発の歯止め ==="
setup; for i in 1 2 3 4 5; do mail "m$i.json" talk "33$i.1"; done
run >/dev/null
[ "$(ncalls)" -eq 3 ] && ok "1tickの上限3スレッド（まとめて来ても一度に燃やさない）" || ng "上限が効かない" "$(ncalls)回"
setup; mail a.json talk 111.1
( exec 9>"$T/data/slack/.talk.lock"; flock 9; sleep 2 ) &
sleep 0.3; run >/dev/null; wait
[ "$(ncalls)" -eq 0 ] && ok "前回がまだ喋っていれば見送る（多重起動しない）" || ng "多重起動した"

echo
echo "=== 秘密・実データを持ち込んでいない ==="
# ⚠️ 実IDをこのファイルに書いてはいけない：それ自体が「git に実IDを入れる」ことになり、
#    検知器が検知対象を持ち込む自己矛盾になる（このリポジトリで過去に踏んだ形）。
#    そこで **実行時に .env から実値を読んで** それが本体に現れないかを見る。
#    副次的に、こちらのほうが正しい＝ハードコードした推測ではなく「今の実IDそのもの」を検査する。
TARGETS="$SRC $(dirname "$SRC")/../.claude/commands/talk.md"
ENVF="$(dirname "$SRC")/../.env"
leak=""
for k in SLACK_REPORT_CHANNEL_ID SLACK_PARTNER_CHANNEL_ID SLACK_CHANNEL_ID SLACK_BOT_TOKEN SLACK_WEBHOOK_URL; do
  v=$(grep -E "^\s*$k=" "$ENVF" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r')
  [ -n "$v" ] && [ "${#v}" -ge 8 ] || continue
  grep -qF -- "$v" $TARGETS 2>/dev/null && leak="$leak $k"
done
if [ -n "$leak" ]; then
  ng "本体かコマンドファイルに .env の実値が混ざっている（$leak）"
else
  ok "実チャンネルID・トークンを1つも含まない（.env の実値と突き合わせて確認）"
fi

echo
echo "=== 相談レーンが重い処理に巻き込まれない（配置の不変条件）==="
AT="$(dirname "$SRC")/agent-tick.sh"
fetch_line=$(grep -n 'slack-poll.py fetch' "$AT" | head -1 | cut -d: -f1)
lock_line=$(grep -n 'exec 9>"\$LOCK"' "$AT" | head -1 | cut -d: -f1)
if [ -n "$fetch_line" ] && [ -n "$lock_line" ] && [ "$fetch_line" -lt "$lock_line" ]; then
  ok "★新着の取り込みがメインロックより前にある（hp-loop が25分回っていても相談が届く）"
else
  ng "取り込みがメインロックの内側に戻っている" "fetch=$fetch_line / lock=$lock_line＝相談の返事が最大25分遅れる"
fi
grep -q 'flock -n 7' "$AT" && ok "取り込みは専用ロックで直列化されている（last-seen の二重進行を防ぐ）" \
  || ng "取り込みのロックが無い" "同時に2本走ると新着を取りこぼす"
grep -q 'talk-tick.sh' "$AT" && ok "agent-tick 側に相談レーンの所在が書いてある（追える）" \
  || ng "分離の事実がヘッダに無い"
grep -qE '^\s*dispatch "talk"' "$AT" \
  && ng "★agent-tick が talk を抱えている（重いレーンに相乗りして分離の意味が消える）" \
  || ok "★agent-tick は talk を扱わない（レーンが分かれている）"

echo
echo "=== 文字が壊れていない（警報が読めなければ黙って壊れているのと同じ）==="
if python3 - "$SRC" "$(dirname "$SRC")/../.claude/commands/talk.md" <<'MOJI'
import io, re, sys
# UTF-8 の日本語を latin-1 として書いてしまった跡（二重エンコード）を**行内で**探す。
# ⚠️ 「行全体が latin-1 に再エンコードできるか」で見てはいけない：一部だけ化けた行
#    （置換で先頭だけ壊すなど、実際に起きやすい形）は正常な日本語が混ざるため
#    再エンコードに失敗し、検査が素通りする（2026-08-19 変異テストで実際に素通りした）。
# 二重エンコードは必ず「先頭バイト(U+00C0-U+00FF)＋継続バイト(U+0080-U+00BF)」の並びになる。
# 正常な日本語・英語・記号にはこの並びは現れない。
PAT = re.compile(r"[\u00c0-\u00ff][\u0080-\u00bf]")
bad = []
for path in sys.argv[1:]:
    try:
        lines = io.open(path, encoding="utf-8").read().split("\n")
    except Exception:
        continue
    for i, l in enumerate(lines):
        if PAT.search(l):
            bad.append(f"{path}:{i+1}")
if bad:
    print(" ".join(bad[:5])); sys.exit(1)
MOJI
then ok "日本語が二重エンコードで壊れていない（ログ・Slack警報が読める）"
else ng "文字化けした行がある（$?）＝壊れたときの案内が読めない"; fi

echo
echo "合計: 合格 $pass ／ 不合格 $fail"
[ "$fail" -eq 0 ] || exit 1
