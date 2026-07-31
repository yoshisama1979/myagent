#!/bin/bash
# OOM対策（2026-07-31 社長承認）の回帰テスト。触ったら必ず流す。
#   ① agent-tick.sh：ヘッドレス claude に choom を付けて社長の tmux を巻き添えにしない
#   ③ system-health.py：メモリ・swap・巨大プロセスの計測と警告／agent-tick.sh：OOM kill の即時通知
# 方針＝ロジックを書き写さない。実ソースから該当ブロックを取り出して動かす（写経はテストが嘘をつく）。
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 対象ソースが実在する場所から起動されたことを確かめる。別の場所へコピーして走らせると
# PROJ が別ツリーに解決され、grep 系の検証が「対象が無いので不一致＝不合格」や、
# 逆に無関係なファイルを見て通ってしまう。テストが嘘をつく前に落とす。
for f in bin/agent-tick.sh bin/system-health.py; do
  [ -f "$PROJ/$f" ] || { echo "❌ 起動位置が不正: $PROJ/$f が無い（リポジトリ内から実行すること）"; exit 2; }
done
T="${CLAUDE_JOB_DIR:-${TMPDIR:-/tmp}}/oom-guard-test.$$"
mkdir -p "$T"
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
ng()  { echo "  ❌ $1 — $2"; fail=$((fail+1)); }
chk() { if printf '%s' "$3" | grep -q -- "$2"; then ok "$1"; else ng "$1" "期待:[$2] 実際:[$3]"; fi; }
chkn(){ if printf '%s' "$3" | grep -q -- "$2"; then ng "$1" "鳴ってはいけない:[$2]"; else ok "$1"; fi; }

echo "① choom（メモリ枯渇時に社長の机を守る）"
chk "起動行に choom が入っている" 'CHOOM\[@\]' "$(grep -n 'timeout --kill-after' "$PROJ/bin/agent-tick.sh")"
chk "choom 不在環境では空配列にフォールバック" 'CHOOM=()' "$(grep -n 'command -v choom' -A0 -B0 "$PROJ/bin/agent-tick.sh"; grep -n 'CHOOM=()' "$PROJ/bin/agent-tick.sh")"
if command -v choom >/dev/null 2>&1; then
  got=$(choom -n 800 -- bash -c 'bash -c "cat /proc/self/oom_score_adj"' 2>&1)
  [ "$got" = "800" ] && ok "oom_score_adj 800 が子プロセスへ継承される" || ng "継承" "実際:[$got]"
  rc=$(timeout --kill-after=2s 5s choom -n 800 -- bash -c 'exit 42'; echo $?)
  [ "$rc" = "42" ] && ok "choom 越しでも終了コードが伝播（timeout の判定が壊れない）" || ng "終了コード" "実際:[$rc]"
  rc=$(timeout --kill-after=1s 1s choom -n 800 -- sleep 20; echo $?)
  [ "$rc" = "124" ] && ok "choom 越しでもタイムアウト検知(124)が効く" || ng "タイムアウト" "実際:[$rc]"
else
  ok "choom 不在環境（フォールバック経路のみ検証）"
fi

echo
echo "③-A system-health.py：メモリ警告のロジック"
# Python 側の不合格をシェルの集計へ必ず伝える（Codex🔴：以前は終了コードを見ておらず、
# Python の assertion が全滅してもスクリプト全体が合格していた＝テストが嘘をつく状態だった）
if python3 - "$PROJ" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sh", sys.argv[1] + "/bin/system-health.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p, f = 0, 0
def chk(name, cond, extra=""):
    global p, f
    if cond: print(f"  ✅ {name}"); p += 1
    else:    print(f"  ❌ {name} — {extra}"); f += 1

def mem(oom=14, avail=80, swap=17, top=None):
    # 実値(kB)と表示用の割合を必ず整合させる。片方だけ設定すると、実値で判定する本体を
    # テストが正しく検証できない（この不整合を、丸め修正後のテストが実際に検出した）。
    total, sw_total = 6000 * 1024, 2048 * 1024
    return {"total_kb": total, "avail_kb": total * avail // 100, "avail_pct": avail,
            "swap_total_kb": sw_total, "swap_used_kb": sw_total * swap // 100, "swap_used_pct": swap,
            "oom_kill_total": oom,
            "top": top if top is not None else [{"name": "claude", "rss_kb": 400 * 1024}]}
def snap(oom): return {"mem": {"oom_kill_total": oom}}
def has(ws, s): return any(s in w for w in ws)

chk("初回（前回スナップショットなし）は OOM を鳴らさない", not has(m.mem_warnings(mem(), None), "OOM kill"))
chk("前回に mem キーが無い（旧形式）でも落ちず鳴らさない", not has(m.mem_warnings(mem(), {"ts": "x"}), "OOM kill"))
w = m.mem_warnings(mem(oom=16), snap(14))
chk("14→16 で『2件発生』を鳴らす", has(w, "OOM kill が 2 件発生"), w)
chk("増減なしなら鳴らない（同じ事故で毎日鳴り続けない）", not has(m.mem_warnings(mem(oom=16), snap(16)), "OOM kill"))
chk("カウンタ巻き戻り＝再起動では鳴らない", not has(m.mem_warnings(mem(oom=3), snap(16)), "OOM kill"))
chk("空き14%で逼迫を鳴らす", has(m.mem_warnings(mem(avail=14), None), "空きメモリ"))
chk("空き15%（閾値ちょうど）では鳴らさない", not has(m.mem_warnings(mem(avail=15), None), "空きメモリ"))
chk("swap 80% で鳴らす", has(m.mem_warnings(mem(swap=80), None), "swap 使用"))
chk("swap 60%（閾値ちょうど）では鳴らさない", not has(m.mem_warnings(mem(swap=60), None), "swap 使用"))
hog = [{"name": "2.1.220", "rss_kb": 3400 * 1024}]
chk("単一プロセスが RAM の56%で暴走を鳴らす（今回の実データ相当）",
    has(m.mem_warnings(mem(top=hog), None), "2.1.220 が RAM の"))
chk("通常サイズのプロセスでは鳴らさない", not has(m.mem_warnings(mem(), None), "暴走の疑い"))
chk("計測不能(None)は黙らず故障として鳴らす", has(m.mem_warnings(None, None), "メモリ計測ができない"))
chk("oom_kill カウンタ非対応(None)でも警告側は落ちない",
    isinstance(m.mem_warnings(mem(oom=None), snap(5)), list))
# --- Codex🟡：判定は丸める前の実値で行う（表示だけ丸める）---
def mem_raw(avail_kb=None, swap_used_kb=None, rss_kb=None):
    total = 6000 * 1024
    return {"total_kb": total, "avail_kb": avail_kb if avail_kb is not None else total // 2,
            "avail_pct": round(100 * (avail_kb if avail_kb is not None else total // 2) / total),
            "swap_total_kb": 2048 * 1024, "swap_used_kb": swap_used_kb or 0,
            "swap_used_pct": round(100 * (swap_used_kb or 0) / (2048 * 1024)),
            "oom_kill_total": 1,
            "top": [{"name": "claude", "rss_kb": rss_kb if rss_kb is not None else 1024}]}
m146 = mem_raw(avail_kb=int(6000 * 1024 * 0.146))     # 実値14.6% → 表示は15%に丸まる
chk("空き14.6%（表示は15%に丸まる）でも見逃さない", has(m.mem_warnings(m146, None), "空きメモリ"),
    m.mem_warnings(m146, None))
chk("その丸め値では旧実装なら見逃していた（前提の確認）", m146["avail_pct"] == 15, m146["avail_pct"])
chk("空き15.4%（表示も15%）では鳴らさない",
    not has(m.mem_warnings(mem_raw(avail_kb=int(6000 * 1024 * 0.154)), None), "空きメモリ"))
sw604 = mem_raw(swap_used_kb=int(2048 * 1024 * 0.604))
chk("swap 60.4%（表示は60%）でも見逃さない", has(m.mem_warnings(sw604, None), "swap 使用"))
hog409 = mem_raw(rss_kb=int(6000 * 1024 * 0.409))
chk("プロセス40.9%（整数除算なら40%扱い）でも見逃さない",
    has(m.mem_warnings(hog409, None), "が RAM の"))
# --- Codex🟡：None が1件挟まっても比較相手を遡って見つける ---
chk("has_oom_counter が None 入りスナップショットを弾く",
    m.has_oom_counter({"mem": {"oom_kill_total": 5}}) and not m.has_oom_counter({"mem": {"oom_kill_total": None}})
    and not m.has_oom_counter({"ts": "x"}))
chk("memory_health() が実機で必要なキーを返す",
    all(k in (m.memory_health() or {}) for k in ("total_kb", "avail_pct", "swap_used_pct", "oom_kill_total", "top")))
print(f"  （Python側 合格 {p} ／ 不合格 {f}）")
raise SystemExit(1 if f else 0)
PY
then ok "③-A Python側の assertion がすべて合格"
else ng "③-A Python側" "不合格あり（上の❌行を参照）／または import 失敗"
fi

echo
echo "③-B agent-tick.sh：OOM kill の即時検知（実ソースからブロックを抽出して実行）"
BLOCK="$T/oom-block.sh"
# ヘルパー定義（oom_kill_count / mem_avail_mb）ごと取り出す＝スタブで代用せず実装を検証する
awk '/^# --- proc 読み取りヘルパー/,/^# --- 多重起動防止/' "$PROJ/bin/agent-tick.sh" \
  | sed '$d' > "$T/raw-block.sh"
grep -q 'oom_kill_count()' "$T/raw-block.sh" || ng "ヘルパーの抽出" "oom_kill_count の定義が範囲に入っていない"
[ -s "$T/raw-block.sh" ] || { ng "OOMブロックの抽出" "見つからない（マーカーが変わった？）"; }
# /proc を偽物に差し替え（置換できなければ本物を読んで偽の合格になるので必ず検証する）
sed -e "s#/proc/vmstat#$T/vmstat#g" -e "s#/proc/meminfo#$T/meminfo#g" "$T/raw-block.sh" > "$BLOCK"
grep -q "$T/vmstat" "$BLOCK" || ng "vmstat の差し替え" "置換されなかった＝本物の /proc を読んでしまう"
printf 'MemAvailable:  4800000 kB\n' > "$T/meminfo"

run_block() { # $1=oom値（-なら oom_kill 行なし） $2=alertの戻り値（既定0＝通知成功）
  if [ "$1" = "-" ]; then printf 'nr_free_pages 100\n' > "$T/vmstat"
  else printf 'nr_free_pages 100\noom_kill %s\npgfault 5\n' "$1" > "$T/vmstat"; fi
  {
    echo 'set -uo pipefail'
    echo "PROJ=\"$T\""; echo "LOG=\"$T/tick.log\""; echo 'now() { echo TS; }'
    # alert は第2引数（独立スロットル用ファイル）も受け取れることを検証するため両方出す。
    # 戻り値を差し替えられるようにして「Slack投稿が失敗した回」を再現する（Codex🔴）。
    echo "alert() { echo \"ALERT: \$1\"; echo \"THROTTLE: \${2:-（既定）}\"; return ${2:-0}; }"
    echo 'fail()  { echo "FAIL: $1"; }'
    cat "$BLOCK"
  } > "$T/run.sh"
  bash "$T/run.sh" 2>&1
}
mkdir -p "$T/data/overseer"

out=$(run_block 14)
chkn "初回（状態ファイルなし）は鳴らない" "ALERT" "$out"
[ "$(cat "$T/data/overseer/.oom-count" 2>/dev/null)" = "14" ] && ok "初回でも現在値を記録する" || ng "初回の記録" "$(cat "$T/data/overseer/.oom-count" 2>/dev/null)"

out=$(run_block 14)
chkn "変化なしでは鳴らない" "ALERT" "$out"

out=$(run_block 17)
chk  "14→17 で通知する" "ALERT: メモリ枯渇" "$out"
chk  "件数が正しい（3件）" "3 件強制終了" "$out"
chk  "空きメモリを本文に載せる" "4687MB" "$out"
chk  "故障として status にも記録する" "FAIL: oom-kill(3)" "$out"
chk  "独立スロットルを使う（fetch失敗等に握り潰されない）" "THROTTLE: .*\.last-alert-oom" "$out"
# alert() 本体が第2引数を受け取り、既定は $LAST_ALERT のままであること（既存呼び出しの非回帰）
chk  "alert() が第2引数でスロットル先を差し替えられる" 'throttle="${2:-\$LAST_ALERT}"' \
     "$(grep -A2 '^alert() {' "$PROJ/bin/agent-tick.sh")"
chk  "alert() の書き込み先も差し替え後を使う" 'date +%s >"\$throttle"' \
     "$(sed -n '/^alert() {/,/^}/p' "$PROJ/bin/agent-tick.sh")"

out=$(run_block 17)
chkn "同じ値で再実行しても再通知しない（重複防止）" "ALERT" "$out"

out=$(run_block 2)
chkn "カウンタ巻き戻り＝再起動では鳴らない" "ALERT" "$out"
[ "$(cat "$T/data/overseer/.oom-count")" = "2" ] && ok "再起動後は値だけ更新する" || ng "巻き戻し後の値" "$(cat "$T/data/overseer/.oom-count")"

rm -f "$T/data/overseer/.oom-count"
out=$(run_block -)
chkn "vmstat に oom_kill 行が無い環境でも鳴らない" "ALERT" "$out"
[ ! -f "$T/data/overseer/.oom-count" ] && ok "測れない環境では状態ファイルを作らない" || ng "非対応環境" "状態ファイルができた"

# ── Codex🔴：通知に失敗した回はカウンタを進めない（進めるとその OOM は永久に失われる）──
echo "20" > "$T/data/overseer/.oom-count"
: > "$T/tick.log"
out=$(run_block 25 1)          # alert が失敗（戻り値1）を返す
chk  "通知失敗を検知してログに残す" "通知に失敗＝カウンタを据え置き" "$(cat "$T/tick.log" 2>/dev/null)"
[ "$(cat "$T/data/overseer/.oom-count")" = "20" ] && ok "通知失敗時はカウンタを据え置く" \
  || ng "据え置き" "実際:[$(cat "$T/data/overseer/.oom-count")]（進めると次回は差分ゼロで永久に鳴らない）"
out=$(run_block 25 0)          # 次の tick では通知に成功する
chk  "次の tick で同じ OOM を再通知する" "ALERT: メモリ枯渇" "$out"
chk  "再通知の件数も据え置いた分を含む（20→25＝5件）" "5 件強制終了" "$out"
[ "$(cat "$T/data/overseer/.oom-count")" = "25" ] && ok "通知成功後はカウンタを進める" \
  || ng "成功後の更新" "実際:[$(cat "$T/data/overseer/.oom-count")]"

# ── Codex🟡：状態ファイルの破損を無言で「初回」に化けさせない ──
printf 'こわれた値\n' > "$T/data/overseer/.oom-count"
out=$(run_block 30)
chk  "破損した状態ファイルを故障として記録する" "FAIL: oom-count-broken" "$out"
chkn "破損時は差分不明なので鳴らさない" "ALERT" "$out"
[ "$(cat "$T/data/overseer/.oom-count")" = "30" ] && ok "破損後は現在値で復旧する" || ng "復旧" "$(cat "$T/data/overseer/.oom-count")"

# ── Codex🟡：原子的更新（中間ファイルを残さない）──
[ -z "$(ls "$T/data/overseer/".oom-count.tmp 2>/dev/null)" ] && ok "一時ファイルを残さない" || ng "一時ファイル" ".oom-count.tmp が残っている"

# ── Codex🔴：判定がメインロックより前にあること（実行中でも検知できる）──
lock_line=$(grep -n 'exec 9>"\$LOCK"' "$PROJ/bin/agent-tick.sh" | cut -d: -f1)
oom_line=$(grep -n 'OOM kill の検知' "$PROJ/bin/agent-tick.sh" | cut -d: -f1)
alert_line=$(grep -n '^alert() {' "$PROJ/bin/agent-tick.sh" | cut -d: -f1)
[ -n "$oom_line" ] && [ -n "$lock_line" ] && [ "$oom_line" -lt "$lock_line" ] \
  && ok "OOM 判定がメインロックより前にある（ヘッドレス実行中でも検知できる）" \
  || ng "配置" "OOM判定=$oom_line / メインロック=$lock_line（内側だと最大25分遅れる）"
[ -n "$alert_line" ] && [ "$alert_line" -lt "$oom_line" ] && ok "alert() が OOM 判定より前に定義されている" \
  || ng "alert定義位置" "alert=$alert_line / OOM=$oom_line"
chk "OOM 判定が専用ロックで直列化されている" 'flock -n 8' "$(sed -n "${oom_line},${lock_line}p" "$PROJ/bin/agent-tick.sh")"

# ── Codex🟡：終了コード137 を OOM とタイムアウトで区別する ──
chk "137 の分類に oom_kill 差分を使っている" 'oom_post" -gt "\$oom_pre' \
    "$(grep -A2 'rc" -eq 137' "$PROJ/bin/agent-tick.sh")"
chk "OOM で殺された場合は TIMEOUT でなく OOMKILL として記録する" 'label-oomkill' \
    "$(grep -n 'label-oomkill' "$PROJ/bin/agent-tick.sh")"

echo
echo "=== 構文チェック ==="
bash -n "$PROJ/bin/agent-tick.sh" && ok "agent-tick.sh の構文" || ng "agent-tick.sh の構文" "bash -n 失敗"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$PROJ/bin/system-health.py" \
  && ok "system-health.py の構文" || ng "system-health.py の構文" "parse 失敗"

rm -rf "$T"
echo
echo "合計（このスクリプト分）: 合格 $pass ／ 不合格 $fail"
[ "$fail" -eq 0 ]
