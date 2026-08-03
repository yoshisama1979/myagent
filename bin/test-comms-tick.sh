#!/bin/bash
# comms-tick の起動判定だけを偽ツリーで検証する（claude は起動しない）
set -u
T="${CLAUDE_JOB_DIR:-/home/vpsuser/.claude/jobs/b2e1f4c5}/tmp/tick-test"
SRC=/home/vpsuser/projects/myagent/bin/comms-tick.sh
pass=0; fail=0

setup() {  # $1: gmail raw を作るか
  rm -rf "$T"; mkdir -p "$T/bin" "$T/data/comms/chatwork/raw" "$T/site/comms"
  [ "$1" = "gm" ] && mkdir -p "$T/data/comms/gmail/raw"
  printf '#!/bin/bash\necho "STUB-AGENT-TICK $*"\nexit 0\n' > "$T/bin/agent-tick.sh"
  chmod +x "$T/bin/agent-tick.sh"
  sed "s#^PROJ=.*#PROJ=\"$T\"#" "$SRC" > "$T/bin/comms-tick.sh"
  chmod +x "$T/bin/comms-tick.sh"
  : > "$T/site/comms/index.html"
}
check() {  # $1=名前 $2=期待文字列 $3=出力
  if printf '%s' "$3" | grep -q "$2"; then echo "  ✅ $1"; pass=$((pass+1))
  else echo "  ❌ $1 — 期待:[$2] 実際:[$3]"; fail=$((fail+1)); fi
}

echo "1) マーカーが両rawより新しい → 不起動"
setup gm
touch -d '2020-01-01' "$T/data/comms/chatwork/raw/a.jsonl" "$T/data/comms/gmail/raw/b.jsonl"
touch "$T/data/comms/chatwork/.last-distill"
check "skip" "\[skip\]" "$("$T/bin/comms-tick.sh" 2>&1)"

echo "2) メール側だけ新着 → 起動"
setup gm
touch -d '2020-01-01' "$T/data/comms/chatwork/raw/a.jsonl"
touch -d '2020-01-02' "$T/data/comms/chatwork/.last-distill"
touch "$T/data/comms/gmail/raw/b.jsonl"
check "run" "STUB-AGENT-TICK daily comms" "$("$T/bin/comms-tick.sh" 2>&1)"

echo "3) Chatwork側だけ新着 → 起動（非回帰）"
setup gm
touch -d '2020-01-01' "$T/data/comms/gmail/raw/b.jsonl"
touch -d '2020-01-02' "$T/data/comms/chatwork/.last-distill"
touch "$T/data/comms/chatwork/raw/a.jsonl"
check "run" "STUB-AGENT-TICK daily comms" "$("$T/bin/comms-tick.sh" 2>&1)"

echo "4) メールrawディレクトリ無し → warn だが chatwork 判定は継続（skip できる）"
setup nogm
touch -d '2020-01-01' "$T/data/comms/chatwork/raw/a.jsonl"
touch "$T/data/comms/chatwork/.last-distill"
out=$("$T/bin/comms-tick.sh" 2>&1)
check "warn出力" "メールの raw ディレクトリがありません" "$out"
check "chatworkはskip判定" "\[skip\]" "$out"

echo "5) マーカー無し（初回） → 起動"
setup gm
touch "$T/data/comms/chatwork/raw/a.jsonl"
check "run" "STUB-AGENT-TICK daily comms" "$("$T/bin/comms-tick.sh" 2>&1)"

echo "6) Chatwork rawディレクトリ無し → 非0終了（非回帰）"
setup gm
rm -rf "$T/data/comms/chatwork/raw"
out=$("$T/bin/comms-tick.sh" 2>&1); rc=$?
check "warn" "raw ディレクトリがありません" "$out"
[ "$rc" -ne 0 ] && { echo "  ✅ 非0終了 (rc=$rc)"; pass=$((pass+1)); } || { echo "  ❌ 非0終了しなかった"; fail=$((fail+1)); }

echo
echo "合計: 合格 $pass ／ 不合格 $fail"
rm -rf "$T"
[ "$fail" -eq 0 ]
