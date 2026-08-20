#!/bin/bash
# journal-mcp-export.sh — MFクラウドの仕訳帳を MCP 経由で取り、閲覧用CSVへ落とす（F-017）。
#
# 社長決定（2026-08-18・案①）＝仕訳帳の画面は人間が見るために残し、データは MCP で定期更新する。
# これで社長の「MFでエクスポート → journal-check.php にアップロード」という手作業が要らなくなる。
#
# 使い方:
#   bash bin/journal-mcp-export.sh --seed          # 初回だけ：既存アップロード分を起点として写す
#   bash bin/journal-mcp-export.sh                 # 日次：直近 WINDOW_DAYS 日の差分を取り込む
#   bash bin/journal-mcp-export.sh --dry-run       # 取得と検算だけ（CSVは書き換えない）
#   bash bin/journal-mcp-export.sh --fy 2025       # 年度を指定
#
# 設計の核（rules/automation.md）:
#   ・MCP は Claude セッションからしか呼べないので、取得だけヘッドレス claude にやらせる。
#     **claude がやるのは「戻り値を書き写す」ことだけ**で、金額の税込計算・日付書式・削除検知・
#     貸借検算は journal-mcp-merge.py（決定的なPython）が持つ＝LLM に判断させない。
#   ・窓を丸ごと書き写させると量も誤りも増えるので、まず index（取引No と update_time だけ）を
#     取り、**版が変わったものだけ**中身を書き写させる。日々の転記は数件で済む。
#   ・④停止条件＝取得・検算に失敗したら**前回CSVをそのまま残し**、status.json に失敗を刻んで
#     非0で終わる。画面は status.json の「最終更新日時」を出すので、古いデータが黙って
#     最新の顔をすることはない。
#
# cron（合意後に登録）:
#   30 1 * * * /home/vpsuser/projects/myagent/bin/journal-mcp-export.sh >> .../journal-mcp.log 2>&1
set -uo pipefail

# --- cron 環境対策：claude が内部で使う node 等のため PATH/HOME を明示 ---
# cron の PATH は /usr/bin:/bin しか無く、フック（node 実行）が「node: not found」で落ちる。
# 取得そのものは通るが、毎晩ログにエラーが混ざって本当の異常が埋もれる。agent-tick.sh と同じ手当て。
export HOME="${HOME:-/home/vpsuser}"
export PATH="/home/vpsuser/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
# node は nvm 配下にあり、上の固定パスには入らない。バージョン番号を焼き付けると
# node 更新のたびに黙って壊れるので、その時点の最新版を実行時に拾う。
if ! command -v node >/dev/null 2>&1; then
  _nvm_bin=$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)
  [ -n "${_nvm_bin:-}" ] && export PATH="$_nvm_bin:$PATH"
fi

# テストから差し替えられるようにしておく（本番は既定値のまま＝cron から素で呼べる）
PROJ="${MYAGENT_PROJ:-/home/vpsuser/projects/myagent}"
FIN="$PROJ/data/financial"
OUTDIR="$FIN/generated/journal-mcp"
STAGING="$OUTDIR/.staging"
STATUS="$OUTDIR/status.json"
CLAUDE="${CLAUDE:-/home/vpsuser/.local/bin/claude}"
# OOM のとき、カーネルにこの claude（と子孫）を最優先で殺させる＝社長の tmux を守る。
# 深夜 cron では overseer 等の claude と並ぶ時間帯があり、実測で claude 2本＝5.3GB を占めた
# 前例がある（VPS は RAM 5.8GB）。agent-tick.sh と同じ作法に揃える。
# choom が無い環境では黙って素通りする＝取得そのものは止めない。
if command -v choom >/dev/null 2>&1; then CHOOM=(choom -n 800 --); else CHOOM=(); fi
MODEL="${JOURNAL_MCP_MODEL:-claude-sonnet-5}"
WINDOW_DAYS="${WINDOW_DAYS:-35}"
TIMEOUT_SEC="${JOURNAL_MCP_TIMEOUT:-900}"
# 日付は1箇所で決める＝年度判定も窓も同じ「今日」を見る（テストで固定できる）
TODAY="${JOURNAL_MCP_TODAY:-$(TZ=Asia/Tokyo date "+%Y-%m-%d")}"

now() { TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(now) $*"; }

# --- 引数 -------------------------------------------------------------------
SEED=0; DRY=0; FY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seed)    SEED=1 ;;
    --dry-run) DRY=1 ;;
    --fy)      FY="${2:-}"; shift ;;
    *) echo "ERROR: 不明なオプション: $1" >&2; exit 1 ;;
  esac
  shift
done

# 会計年度は4月始まり（CLAUDE.md）。3月までは前年がFY。
if [ -z "$FY" ]; then
  y=${TODAY%%-*}; m=$(echo "$TODAY" | cut -d- -f2)
  FY=$y; [ "$((10#$m))" -lt 4 ] && FY=$((y - 1))
fi
OUT="$OUTDIR/FY${FY}.csv"
SIDECAR="$OUTDIR/FY${FY}.updates.json"
SRC="$FIN/journal/FY${FY}.csv"

mkdir -p "$OUTDIR" || exit 1

# --- 状態の記録（成功でも失敗でも必ず1回書く） -------------------------------
# ★画面はこの status.json だけを見て「最終更新日時」を出す。**成功したときだけ**
#   last_success を進める＝失敗しても前回の日時が残り、古さが画面に出る。
write_status() {
  local state="$1" note="$2" rows="${3:-}" journals="${4:-}"
  local prev_success=""
  [ -f "$STATUS" ] && prev_success=$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('last_success') or '')
except Exception: print('')" "$STATUS" 2>/dev/null)
  local success="$prev_success"
  [ "$state" = "ok" ] && success="$(now)"
  STATE="$state" NOTE="$note" ROWS="$rows" JOURNALS="$journals" \
  LAST_RUN="$(now)" LAST_SUCCESS="$success" FYV="$FY" \
  python3 -c "
import json,os
p=os.environ
json.dump({
  'state': p['STATE'], 'note': p['NOTE'], 'fy': int(p['FYV']),
  'last_run': p['LAST_RUN'], 'last_success': p['LAST_SUCCESS'] or None,
  'rows': int(p['ROWS']) if p['ROWS'] else None,
  'journals': int(p['JOURNALS']) if p['JOURNALS'] else None,
}, open(os.environ['STATUS_PATH'],'w'), ensure_ascii=False, indent=1)
" 2>/dev/null
}
export STATUS_PATH="$STATUS"

fail() {
  log "[error] $1"
  write_status "error" "$1"
  # 見張りが黙らないように Slack へ（本文に金額・取引先は出さない＝公開してよい粒度だけ）
  if [ -x "$PROJ/bin/slack.sh" ] && [ "${JOURNAL_MCP_NO_SLACK:-0}" != "1" ]; then
    printf '⚠️ 仕訳帳の自動取得に失敗しました（FY%s）\n%s\n前回のCSVはそのまま残しています。画面の「最終更新日時」で古さを確認してください。\n' \
      "$FY" "$1" | bash "$PROJ/bin/slack.sh" >/dev/null 2>&1 || true
  fi
  exit 1
}

# --- --seed：既存アップロード分を起点として写す（LLM を使わない） ------------
if [ "$SEED" = "1" ]; then
  [ -f "$SRC" ] || fail "起点にする仕訳帳がありません: $SRC"
  # 列と引用符を書き出し側に揃えるため、merge の読み書きをそのまま通す
  python3 - "$SRC" "$OUT" "$PROJ/bin/journal-mcp-merge.py" <<'PY' || fail "起点CSVの正規化に失敗しました"
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_file_location("jm", sys.argv[3])
jm = importlib.util.module_from_spec(spec); spec.loader.exec_module(jm)
rows = jm.read_csv(pathlib.Path(sys.argv[1]))
if not rows:
    print("起点CSVが空です", file=sys.stderr); sys.exit(1)
jm.write_csv(pathlib.Path(sys.argv[2]), rows)
print(f"{len(rows)}行 / {len({r[0] for r in rows})}仕訳 を起点として写しました")
PY
  rows=$(python3 -c "
import importlib.util,pathlib
s=importlib.util.spec_from_file_location('jm','$PROJ/bin/journal-mcp-merge.py')
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
r=m.read_csv(pathlib.Path('$OUT')); print(len(r))")
  printf '{}' > "$SIDECAR"
  write_status "ok" "起点として data/financial/journal/FY${FY}.csv を写しました（--seed）" "$rows" ""
  log "[seed] $OUT を作成しました（$rows 行）"
  log "[seed] 次は引数なしで実行すると直近 ${WINDOW_DAYS} 日ぶんを MCP から取り込みます"
  exit 0
fi

# --- 日次：窓を決める -------------------------------------------------------
FY_START="${FY}-04-01"
FY_END="$((FY + 1))-03-31"
WIN_END="$TODAY"
WIN_START=$(TZ=Asia/Tokyo date -d "$TODAY -${WINDOW_DAYS} days" '+%Y-%m-%d')
# 年度をまたがない（またぐと MF は「その日を含む会計期間」で返すので窓の意味が壊れる）
[[ "$WIN_START" < "$FY_START" ]] && WIN_START="$FY_START"
[[ "$WIN_END" > "$FY_END" ]] && WIN_END="$FY_END"

[ -f "$OUT" ] || fail "起点CSVがありません。先に --seed を実行してください: $OUT"

# ★毎回まっさらにする★＝前回の失敗で残った index/changed を今回の取得結果と
#   取り違えると、取れていないのに「取れた」ことになる（黙って古いデータを最新扱いする最悪の形）。
rm -rf "$STAGING"; mkdir -p "$STAGING" || fail "作業ディレクトリを作れません: $STAGING"

REL_STAGING="data/financial/generated/journal-mcp/.staging"
REL_SIDECAR="data/financial/generated/journal-mcp/FY${FY}.updates.json"

PROMPT=$(cat <<EOP
MFクラウド会計の仕訳を MCP から取得して2つのファイルに書き出してください。これは無人実行です。人に質問せず、以下だけを行ってください。

【手順】
1. $REL_SIDECAR を Read で読む（無ければ空の {} とみなす）。中身は {"取引No": "update_time"} です。
2. mcp__mfc-ca__mfc_ca_getJournals を start_date=$WIN_START end_date=$WIN_END per_page=100 page=1 で呼ぶ。
   戻り値の metadata.total_pages を見て、**全ページを page=2,3,... と最後まで**呼ぶ（件数は聞かずに全部取る）。
3. mcp__mfc-ca__mfc_ca_getJournals を start_date=$FY_START end_date=$FY_END per_page=1 page=1 で1回だけ呼び、
   metadata.total_count（年度全体の仕訳件数）を控える。
4. $REL_STAGING/index.jsonl を Write で作る。2で取れた**全仕訳**について1行1件、
   {"n": <number>, "u": "<update_time>"} の JSON を並べる（他の情報は書かない）。
5. $REL_STAGING/changed.json を Write で作る。形は
   {"fy_total_count": <3の値>, "journals": [ ... ]}
   journals には、2で取れた仕訳のうち **1のファイルに number が無い、または update_time が異なるものだけ**を、
   **getJournals が返した JSON オブジェクトのまま一字一句変えずに**入れる（キーを省略しない・値を丸めない・
   金額を計算しない・順序を変えない）。該当が無ければ空配列にする。

【禁止】
・仕訳の作成・更新（書き込み系ツール）は使わない。
・$REL_STAGING 以外へ書かない。
・要約・整形・省略をしない（省略すると仕訳帳が壊れます）。

完了したら「done <index.jsonlの行数> <changed.jsonのjournals件数>」とだけ出力してください。
EOP
)

log "[run] FY${FY} 窓 ${WIN_START}〜${WIN_END} を取得します（model=$MODEL timeout=${TIMEOUT_SEC}s）"
cd "$PROJ" || fail "プロジェクトルートへ移動できません"

out=$(MYAGENT_UNATTENDED=1 MYAGENT_AGENT=finance \
  timeout --kill-after=30s "${TIMEOUT_SEC}s" "${CHOOM[@]}" \
  "$CLAUDE" -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
  --allowedTools mcp__mfc-ca__mfc_ca_getJournals Read Write </dev/null 2>&1)
rc=$?
echo "$out" | sed 's/^/» /'
[ "$rc" -eq 0 ] || fail "claude の取得が失敗しました（rc=$rc・timeout の可能性）"

[ -s "$STAGING/index.jsonl" ] || fail "index.jsonl が作られませんでした（MCP認証切れの可能性）"
[ -s "$STAGING/changed.json" ] || fail "changed.json が作られませんでした"

# --- マージ・検算・書き出し -------------------------------------------------
args=(--staging "$STAGING" --out "$OUT" --sidecar "$SIDECAR"
      --window-start "$WIN_START" --window-end "$WIN_END")
[ "$DRY" = "1" ] && args+=(--dry-run)

merge_out=$(python3 "$PROJ/bin/journal-mcp-merge.py" "${args[@]}" 2>&1)
mrc=$?
echo "$merge_out" | sed 's/^/» /'

case "$mrc" in
  0) ;;
  3) log "[warn] 件数が MF と合いません（DRIFT）。--seed でやり直すか MF を確認してください" ;;
  *) fail "検算に失敗したため書き換えを中止しました（rc=$mrc）" ;;
esac

if [ "$DRY" = "1" ]; then
  log "[dry-run] CSVは書き換えていません"
  exit 0
fi

rows=$(printf '%s' "$merge_out" | grep -oP 'OK: \K[0-9]+' | tail -1)
jrn=$(printf '%s' "$merge_out" | grep -oP 'OK: [0-9]+行 / \K[0-9]+' | tail -1)
if [ "$mrc" = "3" ]; then
  write_status "warn" "取り込みは成功しましたが MF との件数が一致しません（--seed で作り直しを検討）" "$rows" "$jrn"
else
  write_status "ok" "MCP から取り込みました（窓 ${WIN_START}〜${WIN_END}）" "$rows" "$jrn"
fi
rm -rf "$STAGING"
log "[ok] $OUT を更新しました（${rows}行 / ${jrn}仕訳）"
exit 0
