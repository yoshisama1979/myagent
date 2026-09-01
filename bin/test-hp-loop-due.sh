#!/bin/bash
# test-hp-loop-due — 解析ペース判定（bin/hp-loop-due.py）の回帰スイート。
# rules/testing.md §2 の必須条件に全部該当する（①無人ループから呼ばれる ②判定ロジックを持つ）。
# ※このツールは状態ファイルを書かない設計なので、③は該当しない（＝壊れる状態が無い）。
#
# 規律（rules/testing.md §6）：
#   ・本番ファイルに触れない（config は一時ディレクトリの架空表を使う）
#   ・cron 相当の空環境（env -i）でも流す
#   ・合否は終了コード（0=全合格）＋末尾に「合計: 合格 N ／ 不合格 M」
#   ・テストデータは架空の site-key（実クライアント名を出さない）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
TOOL="bin/hp-loop-due.py"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-hp-loop-due.XXXXXX") || exit 2
# 書き先が一時ディレクトリの外なら即終了（test-calendar-fetch の型）
case "$TMP" in
  /tmp/*|/var/tmp/*|"${TMPDIR:-/nonexistent}"/*) : ;;
  *) echo "危険: 一時ディレクトリが想定外の場所です: $TMP"; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
ng()   { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
check_exit() { # 説明 期待コード コマンド...
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" -eq "$want" ]; then ok "$desc（exit=$got）"; else ng "$desc（期待 exit=$want / 実際 $got）"; fi
}

# ---- 架空の config を作る（実クライアント名は使わない）----
CFG="$TMP/config.md"
cat > "$CFG" <<'EOF'
# ダミー設定

## 対象サイト登録表（この表は読まれてはいけない＝罠）

| site-key | サイト |
|---|---|
| `trap-site` | 読まれたら不合格 |

## 解析ペース（テスト用）

| site-key | 解析ペース | cron 起動時刻 | 備考 |
|----------|-----------|--------------|------|
| `alpha` | 3日 | 02:00 | ずらし0 |
| `bravo` | 3日 | 02:30 | ずらし1 |
| `charlie` | 1日 | 03:00 | ずらし2・毎日 |
| `delta` | 7日 | 03:30 | ずらし3 |
| `echo-x` | — | 04:00 | 手動＝表から除外される |

## 別の節

| site-key | 解析ペース |
|---|---|
| `after-section` | 99日 |
EOF

echo "=== 1. 基本の判定（3日ごと・ずらしで分散する）==="
# 2026-09-04 の通し番号 % 3 == 0 が alpha（ずらし0）。実測で基準日を固定する。
BASE=$(python3 - <<'PY'
import datetime
d=datetime.date(2026,9,1)
while d.toordinal()%3!=0: d+=datetime.timedelta(days=1)
print(d.isoformat())
PY
)
D0="$BASE"
D1=$(date -d "$BASE +1 day" +%F)
D2=$(date -d "$BASE +2 day" +%F)
D3=$(date -d "$BASE +3 day" +%F)
check_exit "alpha は基準日に走る"        0 python3 "$TOOL" alpha   --config "$CFG" --date "$D0" -q
check_exit "alpha は翌日は走らない"      1 python3 "$TOOL" alpha   --config "$CFG" --date "$D1" -q
check_exit "alpha は翌々日も走らない"    1 python3 "$TOOL" alpha   --config "$CFG" --date "$D2" -q
check_exit "alpha は3日後にまた走る"     0 python3 "$TOOL" alpha   --config "$CFG" --date "$D3" -q
check_exit "bravo は基準日には走らない"  1 python3 "$TOOL" bravo   --config "$CFG" --date "$D0" -q
check_exit "bravo は翌日に走る（ずらし1）" 0 python3 "$TOOL" bravo --config "$CFG" --date "$D1" -q

echo "=== 2. ペース1日＝毎日走る ==="
for i in 0 1 2 3 4; do
  d=$(date -d "$BASE +$i day" +%F)
  check_exit "charlie は $d に走る" 0 python3 "$TOOL" charlie --config "$CFG" --date "$d" -q
done

echo "=== 3. 月をまたいでも連続日にならない（crontab の */3 を採らなかった理由）==="
# 8/31 と 9/1 の両方が解析日になっていないことを、7日ペースの delta で確認する
A=$(python3 "$TOOL" delta --config "$CFG" --date 2026-08-31 -q; echo $?)
B=$(python3 "$TOOL" delta --config "$CFG" --date 2026-09-01 -q; echo $?)
if [ "$A$B" = "00" ]; then ng "月またぎで2日連続に走ってしまった（8/31 と 9/1 の両方）"
else ok "月またぎで2日連続にならない（8/31=$A 9/1=$B）"; fi

echo "=== 4. 表から除外される行 ==="
check_exit "「—」の行は未登録扱い＝判定不能(2)" 2 python3 "$TOOL" echo-x --config "$CFG" --date "$D0" -q
check_exit "未知の site-key は判定不能(2)"      2 python3 "$TOOL" unknown-site --config "$CFG" --date "$D0" -q
check_exit "他の節の表は読まない（罠1）"        2 python3 "$TOOL" trap-site --config "$CFG" --date "$D0" -q
check_exit "次の見出し以降は読まない（罠2）"    2 python3 "$TOOL" after-section --config "$CFG" --date "$D0" -q

echo "=== 5. 壊れた設定は「判定不能(2)」＝黙って止めない（fail-open の材料）==="
BAD="$TMP/bad.md"; printf '# 節が無い設定\n' > "$BAD"
check_exit "「解析ペース」節が無い"      2 python3 "$TOOL" alpha --config "$BAD" --date "$D0" -q
BAD2="$TMP/bad2.md"
printf '## 解析ペース\n\n| site-key | 解析ペース |\n|---|---|\n| `alpha` | ときどき |\n' > "$BAD2"
check_exit "数字として読めないペース"    2 python3 "$TOOL" alpha --config "$BAD2" --date "$D0" -q
BAD3="$TMP/bad3.md"
printf '## 解析ペース\n\n| site-key | 解析ペース |\n|---|---|\n| `alpha` | 0日 |\n' > "$BAD3"
check_exit "0日は不正（無限ループ防止）" 2 python3 "$TOOL" alpha --config "$BAD3" --date "$D0" -q
check_exit "config が存在しない"         2 python3 "$TOOL" alpha --config "$TMP/nope.md" --date "$D0" -q
BAD4="$TMP/bad4.md"
printf '## 解析ペース\n\n| site-key | 解析ペース |\n|---|---|\n| `alpha` | 3日 |\n| `bravo` | 3日 |\n| `alpha` | 5日 |\n' > "$BAD4"
check_exit "site-key の重複は判定不能（下の行が黙って無視されるのを防ぐ）" 2 \
  python3 "$TOOL" alpha --config "$BAD4" --date "$D0" -q
check_exit "日付の書式が不正"            2 python3 "$TOOL" alpha --config "$CFG" --date "2026/09/01" -q

echo "=== 6. --schedule ==="
check_exit "--schedule は site 無しで動く" 0 python3 "$TOOL" --schedule --config "$CFG" --date "$D0"
if python3 "$TOOL" --schedule --config "$CFG" --date "$D0" 2>/dev/null | grep -q 'trap-site'; then
  ng "--schedule に他の節の行が混ざった"
else ok "--schedule に他の節の行が混ざらない"; fi

echo "=== 7. cron 相当の空環境（env -i）でも動く ==="
check_exit "env -i で解析日の判定" 0 \
  env -i HOME=/home/vpsuser PATH=/usr/local/bin:/usr/bin:/bin python3 "$TOOL" alpha --config "$CFG" --date "$D0" -q
check_exit "env -i で対象外の判定" 1 \
  env -i HOME=/home/vpsuser PATH=/usr/local/bin:/usr/bin:/bin python3 "$TOOL" alpha --config "$CFG" --date "$D1" -q

echo "=== 8. 本番 config が実際に読める（表の書式が壊れていないか）==="
if python3 "$TOOL" --schedule >/dev/null 2>&1; then ok "本番 data/hp-loop/config.md を読めた"
else ng "本番 data/hp-loop/config.md の「解析ペース」表を読めない"; fi
N=$(python3 "$TOOL" --schedule 2>/dev/null | grep -c '^[a-z]')
if [ "${N:-0}" -ge 6 ]; then ok "本番の表に6サイト以上が登録されている（$N 件）"
else ng "本番の表の登録が6サイト未満（$N 件）"; fi
# 1日に走る本数が偏っていないか（分散の確認＝同日に集中すると25分枠に戻ってしまう）
MAXN=$(python3 "$TOOL" --schedule 2>/dev/null | sed -n 's/^日別の本数：//p' | tr ' ' '\n' | sed -n 's/.*=//p' | sort -rn | head -1)
if [ "${MAXN:-99}" -le 3 ]; then ok "同じ日に走るのは最大 ${MAXN} 本（分散できている）"
else ng "同じ日に ${MAXN} 本が集中している（ずらしが効いていない）"; fi

echo "=== 9. agent-tick.sh のゲート本体（実ソースから抽出して流す＝test-cooldown と同じ型）==="
# ロジックを書き写さない。本体を直せばテストが自動で追随する。
GATE="$TMP/gate.sh"
awk '/^  # --- 解析ペースのゲート/,/^  # -{20,}$/' bin/agent-tick.sh > "$GATE"
if ! grep -q 'hp-loop-due.py' "$GATE"; then
  ng "ゲートの抽出に失敗（マーカーが変わった？）"
else
  ok "ゲートを実ソースから抽出できた"
  # 抽出した断片を関数に包んで、周りだけ差し替える
  RUN="$TMP/run.sh"
  {
    echo 'PROJ="'"$PWD"'"'
    echo 'PY=python3'
    echo 'LOG=/dev/null'
    echo 'now() { echo TEST; }'
    echo 'fail() { echo "FAIL:$1" >>"$LAUNCHLOG"; }'
    echo 'declare -a ACTIONS=()'
    echo 'gate() {'
    echo '  local to="$1" force="$2" pending="$3" defer="$4" label=test action=idle'
    cat "$GATE"
    echo '  echo "LAUNCH" >>"$LAUNCHLOG"'   # ← ゲートを通り抜けたら起動する、の代役
    echo '  echo "ACTION:$action" >>"$LAUNCHLOG"'
    echo '  echo "BYPASS:${cadence_bypass:-0}" >>"$LAUNCHLOG"'
    echo '}'
  } > "$RUN"

  gate_result() { # gate_result <to> <force> <pending> <defer> → LAUNCH / SKIP
    LAUNCHLOG="$TMP/launch.txt"; : > "$LAUNCHLOG"
    ( export LAUNCHLOG; source "$RUN"; gate "$1" "$2" "$3" "$4" >/dev/null 2>&1 )
    if grep -q LAUNCH "$LAUNCHLOG"; then echo LAUNCH; else echo SKIP; fi
  }
  # 本番 config の実値で判定するので、今日ペース内／外のサイトを実測して使う
  DUE_SITE=""; OFF_SITE=""
  for s in ycom yoshida fujisaka yokohawaii rally konjaku; do
    if python3 "$TOOL" "$s" -q >/dev/null 2>&1; then [ -z "$DUE_SITE" ] && DUE_SITE="$s"
    else [ -z "$OFF_SITE" ] && OFF_SITE="$s"; fi
  done
  if [ -z "$DUE_SITE" ] || [ -z "$OFF_SITE" ]; then
    ng "今日ペース内・ペース外の両方のサイトが揃わない（分散が壊れている）"
  else
    ok "今日ペース内=$DUE_SITE ／ ペース外=$OFF_SITE を実測で選べた"
    eqr() { local d="$1" want="$2" got; got=$(gate_result "$3" "$4" "$5" "$6")
            if [ "$got" = "$want" ]; then ok "$d（$got）"; else ng "$d（期待 $want / 実際 $got）"; fi; }
    eqr "ペース内の日は起動する"                     LAUNCH "hp-loop-$DUE_SITE" 1 0 0
    eqr "ペース外＋新着なしは起動しない"             SKIP   "hp-loop-$OFF_SITE" 1 0 0
    eqr "ペース外でも社長便があれば起動する"         LAUNCH "hp-loop-$OFF_SITE" 1 1 0
    eqr "ペース外でも実装担当の報告(defer)で起動する" LAUNCH "hp-loop-$OFF_SITE" 1 0 2
    eqr "未登録サイトは判定不能→起動する(fail-open)" LAUNCH "hp-loop-nosuchsite"  1 0 0
    eqr "hp-loop 以外のレーンには効かない"           LAUNCH "partner"            1 0 0
    eqr "force=0（反応tick）には効かない"            LAUNCH "hp-loop-$OFF_SITE" 0 0 0
    # --- 2026-09-01 Codexレビューで見つかった3件の再発防止 ---
    # ①（🔴）ペース外を未読で押し切った日は、理由が action に残る＝heartbeat から消えない。
    #        以前は直後の `action="daily"` が無条件に上書きしていた。
    LAUNCHLOG="$TMP/launch.txt"; : > "$LAUNCHLOG"
    ( export LAUNCHLOG; source "$RUN"; gate "hp-loop-$OFF_SITE" 1 0 2 >/dev/null 2>&1 )
    if grep -q 'ACTION:daily(新着2)' "$LAUNCHLOG"; then ok "ペース外×未読の日は理由が action に残る（daily(新着2)）"
    else ng "action に理由が残らない（heartbeat から消える）" "$(grep '^ACTION:' "$TMP/launch.txt")"; fi
    # ②（🔴）そのとき cadence_bypass=1 が立つ＝完走後の無進捗検査が「全未読」に切り替わる前提。
    #        立たないと、報告を処理しないまま正常終了しても警報が鳴らず日次運転へ黙って戻る。
    if grep -q 'BYPASS:1' "$TMP/launch.txt"; then ok "ペース外×未読の日は cadence_bypass=1（検査対象が全未読になる）"
    else ng "cadence_bypass が立たない＝無進捗検査が素通りする"; fi
    # 通常の解析日には立たないこと（常時1だと検査対象が変わりっぱなしになる）
    LAUNCHLOG="$TMP/launch.txt"; : > "$LAUNCHLOG"
    ( export LAUNCHLOG; source "$RUN"; gate "hp-loop-$DUE_SITE" 1 0 0 >/dev/null 2>&1 )
    if grep -q 'BYPASS:0' "$TMP/launch.txt"; then ok "通常の解析日は cadence_bypass=0（従来どおりの検査）"
    else ng "通常の解析日にも cadence_bypass が立っている"; fi
    # ③（🔴）判定不能は **未読があっても** failures に残る。
    #        以前は `! cmd` が exit 1 と 2 を同じ真に潰し、未読がある間は設定破損を握り潰していた。
    LAUNCHLOG="$TMP/launch.txt"; : > "$LAUNCHLOG"
    ( export LAUNCHLOG; source "$RUN"; gate "hp-loop-nosuchsite" 1 0 5 >/dev/null 2>&1 )
    if grep -q 'FAIL:.*cadence-unreadable' "$TMP/launch.txt"; then ok "未読があっても判定不能は failures に残る（exit 1 と 2 を潰さない）"
    else ng "未読があると設定破損が握り潰される＝静かに壊れる経路が復活している"; fi
    if grep -q LAUNCH "$TMP/launch.txt"; then ok "判定不能＋未読でも起動する（fail-open）"
    else ng "判定不能＋未読で起動しない＝黙って解析が止まる"; fi

    # fail-open のときは黙らない（failures.jsonl に残る）ことも確認する
    LAUNCHLOG="$TMP/launch.txt"; : > "$LAUNCHLOG"
    ( export LAUNCHLOG; source "$RUN"; gate "hp-loop-nosuchsite" 1 0 0 >/dev/null 2>&1 )
    if grep -q 'FAIL:.*cadence-unreadable' "$LAUNCHLOG"; then ok "判定不能は failures に記録される（黙らない）"
    else ng "判定不能なのに failures へ記録されない＝静かに壊れる経路"; fi
  fi
fi

echo "=== 10. ゲートの外にある「効き目の担保」（実ソースを静的に検査）==="
# §9 は dispatch() から抽出したゲート断片だけを動かす。ところが 2026-09-01 の Codex レビューで
# 見つかった 🔴 のうち2件は **断片の外** にあった＝断片だけ見ていると「直したのにテストは通る」
# という最悪の形になる。ここはソースそのものを検査して、担保が外れたら落とす。

# ①（🔴）ゲートが付けた理由 daily(新着N) を、直後の action 上書きが消さないこと。
if awk '/if \[ "\$action" = "idle" \]; then/{g=NR}
        /action="daily"/{ if (g && NR-g<=2) {print "OK"; exit} }' bin/agent-tick.sh | grep -q OK; then
  ok "action=\"daily\" の上書きが「idle のときだけ」に守られている"
else
  ng "action の無条件上書きが復活＝ペース外×未読で走った理由が heartbeat から消える"
fi

# ②（🔴）完走後の無進捗検査の対象が、cadence_bypass で全未読へ切り替わること。
if grep -q 'cadence_bypass" -eq 1' bin/agent-tick.sh && \
   awk '/cadence_bypass" -eq 1/{f=NR} f && NR>f && NR<=f+2 && /trig_before=\$\(mailbox_all/{print "OK"; exit}' \
       bin/agent-tick.sh | grep -q OK; then
  ok "ペース外×未読で走った回は、無進捗検査の対象が全未読(mailbox_all)になる"
else
  ng "検査対象が triggers のまま＝報告を処理せず正常終了しても警報が鳴らない（日次運転へ黙って戻る）"
fi

# ③ ゲートが判定ツールを **1回だけ** 呼ぶこと（`! cmd` で exit 1 と 2 を潰した回帰の再発防止）。
CALLS=$(awk '/^  # --- 解析ペースのゲート/,/^  # -{20,}$/' bin/agent-tick.sh | grep -c 'hp-loop-due.py')
if [ "${CALLS:-0}" -eq 1 ]; then ok "ゲートは判定ツールを1回だけ呼ぶ（exit 1 と 2 を区別できる形）"
else ng "判定ツールを ${CALLS} 回呼んでいる＝2回目の `! cmd` が exit 2 を握り潰す形に戻っている"; fi

# ④ 判定式が1箇所しかないこと（--schedule の予定表と実際に走る日が食い違わない）
N=$(grep -c 'toordinal() - offset' "$TOOL")
if [ "${N:-0}" -eq 1 ]; then ok "ペース判定の式はソース中1箇所だけ（due_on）"
else ng "判定式が ${N} 箇所に散っている＝片方だけ直すと予定表が実際とズレる"; fi

# ⑤ 基準日を shell から渡している（python の date.today() との基準ズレを構造的に排除）
if awk '/^  # --- 解析ペースのゲート/,/^  # -{20,}$/' bin/agent-tick.sh | grep -q -- '--date "\$(date +%F)"'; then
  ok "基準日を --date で明示的に渡している"
else ng "基準日を渡していない（shell と python で日付がずれる余地が残る）"; fi

echo
echo "合計: 合格 ${PASS} ／ 不合格 ${FAIL}"
[ "$FAIL" -eq 0 ]
