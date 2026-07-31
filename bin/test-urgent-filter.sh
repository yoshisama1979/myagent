#!/usr/bin/env bash
# 反応起動の絞り込み（agent-tick.sh の count_pending）の回帰テスト。
#
# 判断軸は「社長が待っているか」の一点（社長の指示 2026-07-31）。
# 社長からの便は即起動、それ以外は待機に回して定時の解析でまとめて処理する。
#
# 設計：ロジックを書き写さず、実ソースから該当ブロックを抽出して実行する。
# 触ったら必ず流すこと：bash bin/test-urgent-filter.sh
set -u

PROJ_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "$PROJ_REAL/bin/agent-tick.sh" ]; then
  echo "❌ bin/agent-tick.sh が見つからない（起動位置がおかしい）: $PROJ_REAL" >&2
  exit 2
fi
SRC="$PROJ_REAL/bin/agent-tick.sh"

PASS=0; NG=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
ng() { NG=$((NG+1)); echo "  ❌ $1"; [ $# -ge 2 ] && echo "      → $2"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "期待=[$2] 実際=[$3]"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
MB="$T/new"; mkdir -p "$MB"

awk '/^# --- 反応起動の対象を数える/,/^# --- 振り分け：宛先 mailbox/' "$SRC" | sed '$d' > "$T/block.sh"
grep -q 'count_pending()' "$T/block.sh" || { echo "❌ 抽出失敗：count_pending が無い（マーカーが変わった？）" >&2; exit 2; }

cat >"$T/harness.sh" <<EOS
MAILBOX_NEW="$MB"
EOS
grep -q "$MB" "$T/harness.sh" || { echo "❌ 置換失敗：本物の mailbox を触る危険があるため中止" >&2; exit 2; }

count() { ( set -u; . "$T/harness.sh"; . "$T/block.sh"; count_pending "$1" "${2:-0}" ); }

# msg <ファイル名> <to> <from> <type>
msg() {
  printf '{"id": "%s", "to": "%s", "from": "%s", "type": "%s", "subject": "テスト", "body": "本文"}\n' \
    "$1" "$2" "$3" "$4" > "$MB/$1.json"
}
clear_mb() { rm -f "$MB"/*.json 2>/dev/null || true; }

echo "=== 反応起動の絞り込み ==="

# 1) 空
eq "受信箱が空なら 0 0" "0 0" "$(count hp-loop-ycom 1)"

# 2) 絞り込みなし＝ack 以外は全部数える（従来動作の非回帰）
clear_mb
msg m1 hp-loop-ycom web-hanasaka report
msg m2 hp-loop-ycom president     request
eq "絞り込みなしなら ack 以外は全件数える" "2 0" "$(count hp-loop-ycom 0)"
eq "第2引数を省略しても同じ" "2 0" "$(count hp-loop-ycom)"

# 3) 社長便だけで起動、残りは待機
eq "社長1通＋開発1通 → 起動1・待機1" "1 1" "$(count hp-loop-ycom 1)"

# 3b) ack は絞り込みの有無にかかわらず起動させない（Codex🟡13）
#     ＝絞り込み未適用のエージェント（chat/partner/overseer/rally/konjaku）を ack で起こさないため
clear_mb
msg k1 overseer web-hanasaka ack
msg k2 overseer yoshida-dev  report
eq "絞り込みなしでも ack は待機に回る" "1 1" "$(count overseer 0)"
clear_mb
msg k3 overseer web-hanasaka ack
eq "ack だけなら絞り込みなしでも起動しない" "0 1" "$(count overseer 0)"

# 3c) ただし社長からの ack は起動する（取りこぼす側でなく余分に起動する側へ倒す）
clear_mb
msg k4 overseer president ack
eq "社長からの ack は絞り込みなしでも起動する" "1 0" "$(count overseer 0)"
eq "社長からの ack は絞り込みありでも起動する" "1 0" "$(count overseer 1)"

# 3d) 社長便と非ack便が混在しても重複して数えない（sort -u の確認）
clear_mb
msg k5 overseer president request
msg k6 overseer web-hanasaka report
eq "社長便と非ack便を二重に数えない" "2 0" "$(count overseer 0)"

# 4) 今日の事故の再現：ack 2通だけ → 起動しない
clear_mb
msg a1 hp-loop-ycom web-hanasaka ack
msg a2 hp-loop-ycom web-hanasaka ack
eq "受領ack 2通では起動しない（07-31 の事故）" "0 2" "$(count hp-loop-ycom 1)"

# 5) report も待機（本番はもう直っている＝急がない）
clear_mb
msg r1 hp-loop-ycom web-hanasaka report
msg r2 hp-loop-ycom yoshida-dev  report
eq "実装完了報告だけでは起動しない" "0 2" "$(count hp-loop-ycom 1)"

# 5b) mailbox_triggers は「引き金になった便のパス」を返す（無進捗検知が同じ集合を使うため）
clear_mb
msg t1 hp-loop-ycom president   request
msg t2 hp-loop-ycom web-hanasaka report
eq "引き金の一覧は社長便だけ（絞り込みあり）" "$MB/t1.json" \
   "$( ( set -u; . "$T/harness.sh"; . "$T/block.sh"; mailbox_triggers hp-loop-ycom 1 ) )"

# 6) 種別ではなく送り主で判断している（社長の ack でも起動する＝取りこぼさない側に倒す）
clear_mb
msg p1 hp-loop-ycom president ack
eq "社長からなら種別を問わず起動する" "1 0" "$(count hp-loop-ycom 1)"

# 7) 宛先違いは数えない
clear_mb
msg x1 hp-loop-yoshida president request
eq "他サイト宛は数えない" "0 0" "$(count hp-loop-ycom 1)"
eq "本来の宛先では数える" "1 0" "$(count hp-loop-yoshida 1)"

# 8) 待機に回した便を消していない（次の daily が拾える）
clear_mb
msg d1 hp-loop-ycom web-hanasaka report
count hp-loop-ycom 1 >/dev/null
[ -f "$MB/d1.json" ] && ok "待機に回した便はファイルとして残る（消さない）" \
  || ng "待機に回した便はファイルとして残る" "消えている＝仕事を捨てている"

# 9) 大量でも数え違えない
clear_mb
for i in $(seq 1 12); do msg "b$i" hp-loop-ycom web-hanasaka report; done
for i in $(seq 1 3);  do msg "c$i" hp-loop-ycom president   request; done
eq "15通（社長3・開発12）→ 起動3・待機12" "3 12" "$(count hp-loop-ycom 1)"

# 10) 出力形式（呼び出し側が read で2値に分解できること）
read -r a b <<<"$(count hp-loop-ycom 1)"
if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]]; then
  ok "出力は「数字 数字」の1行"
else
  ng "出力は「数字 数字」の1行" "a=[$a] b=[$b]"
fi

echo
echo "=== 呼び出し側の配線 ==="

for site in ycom yoshida fujisaka yokohawaii; do
  grep -qE "dispatch \"hp-loop:$site\".*\"hp-loop-$site\" +1" "$SRC" \
    && ok "hp-loop:$site は社長便のみで起動" \
    || ng "hp-loop:$site は社長便のみで起動" "第4引数 1 が付いていない"
done
grep -qE 'dispatch "blog-loop:ycom".*"blog-loop-ycom" +1' "$SRC" \
  && ok "blog-loop:ycom は社長便のみで起動" || ng "blog-loop:ycom は社長便のみで起動"

# 月曜だけの daily しか無いループは、待機に回すと最大7日待つので対象外のまま（意図的）
for site in rally konjaku; do
  grep -qE "dispatch \"hp-loop:$site\".*\"hp-loop-$site\" +1" "$SRC" \
    && ng "hp-loop:$site は絞り込みの対象外" "daily が月曜だけなので待機に回すと最大7日待つ" \
    || ok "hp-loop:$site は絞り込みの対象外（daily が週1のため・意図的）"
done

# 社長との対話窓口は絞らない（絞る意味がない＝そもそも社長からしか来ない）
for a in chat partner overseer; do
  grep -qE "dispatch \"$a\" .*\" +1$" "$SRC" \
    && ng "$a は従来どおり" "絞り込みが付いている" \
    || ok "$a は従来どおり（絞り込みなし）"
done

grep -q 'action="defer($defer)"' "$SRC" \
  && ok "待機件数が tick の1行に出る（idle に化けない）" \
  || ng "待機件数が tick の1行に出る" "待機が見えないと溜まっていることに気づけない"

echo
echo "=== 構文チェック ==="
bash -n "$SRC" && ok "agent-tick.sh の構文" || ng "agent-tick.sh の構文"

echo
echo "合計: 合格 $PASS ／ 不合格 $NG"
[ "$NG" -eq 0 ] || exit 1
