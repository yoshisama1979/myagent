#!/usr/bin/env bash
# test-kaizen.sh ── bin/kaizen.py（skill-kaizen の見出し解釈・ロック付き採番・退避・書式検査）の回帰テスト
#
# Red 先行・2026-09-14 triage 依頼（data/triage/handoff-dev-skill-kaizen-20260914.md）。
# 固定する実害：
#   ① `## K-NNN` を項目と数えず直前の `###` に飲み込み、件数を半分に・「8KB超の9件」を捏造した（O-019・O-035 と同型の3回目）
#   ② 9系統がロック無しで「最大番号+1」を取りに行き、ID が62種衝突した（O-077・K-637）
#   ③ 退避が全ループの毎日の追記と衝突すると、追記を上書きして消す
# 本番の台帳は使わない（KAIZEN_* で一時ファイルへ向ける）。
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$PROJ/bin/kaizen.py"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
L="$TMP/skill-kaizen.md"; A="$TMP/skill-kaizen-archive.md"
export KAIZEN_LEDGER="$L" KAIZEN_ARCHIVE="$A" KAIZEN_LOCK="$TMP/.skill-kaizen.lock"
k() { python3 "$TOOL" "$@" 2>&1; }
jq1() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
spec_of() { python3 "$TOOL" list | python3 -c "
import sys,json;d=json.load(sys.stdin);e=[x for x in d['entries'] if x['id']==sys.argv[1]][0];print(f\"{e['line']}:{e['hash']}\")" "$1" 2>/dev/null; }
fixture() {
cat > "$L" <<'MD'
# hp-improve スキル改善ログ（カイゼン台帳）

## 運用ルール

- 追記は `### K-NNN` の独立見出しで末尾に

## エントリ形式

```
### K-NNN — タイトル（モード・日付）
```

### 📦 2026-08-11 退避分の索引（K番号で grep）

### K-001 — あ
本文あ

### K-002 — い
ステータス：✅反映済み(2026-01-01)

## K-003 — う（書式外）
本文う

### K-003 — え（重複）
本文え

### K-partner-702 — お
本文お
MD
printf '### K-010 — 過去の分\n本文\n' > "$A"
}
fixture

echo "── §1 見出しの解釈（## も ### も1項目・見本と索引は数えない）"
out="$(k list)"
[ "$(printf '%s' "$out" | jq1 'd["count"]')" = "5" ] && ok "## と ### の K 見出しを1項目ずつ数える（5件）" || ng "件数が 5 でない: $(printf '%s' "$out" | head -c 300)"
[ "$(printf '%s' "$out" | jq1 '",".join(e["id"] for e in d["entries"])')" = "K-001,K-002,K-003,K-003,K-partner-702" ] \
  && ok "並び順どおりに ID を返す（接頭辞つき K-partner-702 も）" || ng "ID の並びが違う"
printf '%s' "$out" | grep -q '"K-NNN"' && ng "コードブロック内の見本 K-NNN を項目にした" || ok "コードブロック内の見本（K-NNN）は項目にしない"
[ "$(printf '%s' "$out" | jq1 'len(d["offformat"])')" = "1" ] && ok "書式外（## K-）を1件と申告する" || ng "書式外の申告が違う"
[ "$(printf '%s' "$out" | jq1 'd["duplicates"].get("K-003")')" = "2" ] && ok "重複 ID（K-003×2）を申告する" || ng "重複の申告が違う"
[ "$(printf '%s' "$out" | jq1 '[e["decided"] for e in d["entries"] if e["id"]=="K-002"][0]')" = "True" ] && ok "反映済み・却下のエントリは decided" || ng "decided の判定が違う"
[ "$(printf '%s' "$out" | jq1 'd["over_8kb"]')" = "0" ] && ok "8KB超の数を返す（飲み込みで水増ししない）" || ng "8KB超の数が違う"

printf '```\n' | cat - "$L" > "$TMP/unclosed.md"
[ "$(KAIZEN_LEDGER="$TMP/unclosed.md" python3 "$TOOL" list | jq1 'd["count"]')" = "5" ] && ok "閉じていないコードブロックがあっても後ろの見出しを隠さない（実物の台帳がこの形）" || ng "閉じていないコードブロックで項目が消えた"
out="$(KAIZEN_LEDGER="$TMP/unclosed.md" python3 "$TOOL" lint 2>&1 || true)"
printf '%s' "$out" | grep -q '閉じていない' && ok "閉じていないコードブロックを lint で申告する" || ng "閉じていないコードブロックを申告しない"

echo "── §1b normalize（重複IDに枝番・## K- を ### K- へ。2026-09-15 社長ご決定＝振り直さない）"
cp "$L" "$TMP/norm.md"; printf '### K-003b — 既存の枝番\n本文\n' >> "$TMP/norm.md"
before="$(cat "$TMP/norm.md")"
KAIZEN_LEDGER="$TMP/norm.md" KAIZEN_IDMAP="$TMP/idmap.md" python3 "$TOOL" normalize > "$TMP/dry.json" 2>&1
[ "$(cat "$TMP/norm.md")" = "$before" ] && ok "既定は下見だけ（台帳を書き換えない）" || ng "下見で台帳が変わった"
grep -q 'K-003c' "$TMP/dry.json" && ok "下見に付け替え案（既存の K-003b を避けて K-003c）が出る" || ng "下見に付け替え案が無い: $(head -c 300 "$TMP/dry.json")"
[ ! -e "$TMP/idmap.md" ] && ok "下見では対応表を作らない" || ng "下見で対応表を作った"
KAIZEN_LEDGER="$TMP/norm.md" KAIZEN_IDMAP="$TMP/idmap.md" python3 "$TOOL" normalize --apply >/dev/null 2>&1
n="$(KAIZEN_LEDGER="$TMP/norm.md" python3 "$TOOL" list)"
[ "$(printf '%s' "$n" | jq1 'len(d["duplicates"])')" = "0" ] && ok "適用後は重複IDが0" || ng "適用後も重複: $(printf '%s' "$n" | jq1 'd["duplicates"]')"
[ "$(printf '%s' "$n" | jq1 'len(d["offformat"])')" = "0" ] && ok "適用後は ## K- が0（### に揃う）" || ng "## K- が残った"
[ "$(printf '%s' "$n" | jq1 'd["count"]')" = "6" ] && ok "件数は変わらない（6）" || ng "件数が変わった"
grep -q '^### K-003 — う（書式外）' "$TMP/norm.md" && grep -q '^### K-003c — え（重複）' "$TMP/norm.md" && ok "先に書かれた方が元の番号を保ち、後の方に枝番" || ng "付け替えの向きが違う: $(grep -n 'K-003' "$TMP/norm.md")"
grep -q '本文え' "$TMP/norm.md" && grep -q '^## エントリ形式' "$TMP/norm.md" && ok "本文と K 以外の ## 見出しは触らない" || ng "本文か K 以外の見出しが変わった"
grep -q 'K-003' "$TMP/idmap.md" && grep -q 'K-003c' "$TMP/idmap.md" && ok "対応表（旧ID→新ID）を残す" || ng "対応表が無い"
grep -q 'え（重複）' "$TMP/idmap.md" && ng "対応表に見出しの文言を写した（取引先名が git へ出うる）" || ok "対応表に見出しの文言を写さない（ID・行・日付だけ）"
KAIZEN_LEDGER="$TMP/norm.md" KAIZEN_IDMAP="$TMP/idmap.md" python3 "$TOOL" normalize --apply 2>&1 | grep -q '"changes": \[\]' && ok "2回目は何もしない（冪等）" || ng "2回目にも付け替えた"

echo "── §2 採番（ロック付き・### の独立見出しで末尾に足す）"
id="$(printf '本文です' | k add --title 'テストの気づき' --lane dev)"
[ "$id" = "K-011" ] && ok "台帳と archive を通した素の K 番号の最大+1（K-partner は数えない）" || ng "採番が違う: $id"
tail -3 "$L" | grep -q '^### K-011 — テストの気づき（dev・20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]）$' && ok "### の独立見出し（タイトル・レーン・日付）で末尾に足す" || ng "見出しの形が違う: $(tail -3 "$L" | head -1)"
tail -1 "$L" | grep -q '本文です' && ok "本文は標準入力から" || ng "本文が入らない"
printf '' | k add --title 空 >/dev/null; [ $? -ne 0 ] && ok "本文が空なら足さない" || ng "空本文を足した"
printf 'b' | k add --title $'改行\n入り' >/dev/null; [ $? -ne 0 ] && ok "タイトルに改行を入れさせない（見出しを壊さない）" || ng "改行入りタイトルを通した"
printf 'b' | k add >/dev/null; [ $? -ne 0 ] && ok "タイトル無しは足さない" || ng "タイトル無しを通した"
: > "$TMP/ids.txt"
for i in 1 2 3 4 5 6 7 8; do ( printf "並行$i" | python3 "$TOOL" add --title "並行$i" --lane t >> "$TMP/ids.txt" 2>/dev/null ) & done; wait
[ "$(wc -l < "$TMP/ids.txt")" = "8" ] && [ "$(sort -u "$TMP/ids.txt" | wc -l)" = "8" ] && ok "8本同時に足しても番号が衝突しない" || ng "同時追記で番号が衝突/欠落: $(tr '\n' ' ' < "$TMP/ids.txt")"
[ "$(k list | jq1 'd["count"]')" = "14" ] && ok "8本とも台帳に残る（上書きで消えない）" || ng "同時追記で消えた: $(k list | jq1 'd["count"]')"

echo "── §3 ロック（退避など手作業の書き換えを追記と衝突させない）"
python3 "$TOOL" lock -- python3 -c "import time;time.sleep(2)" & H=$!
python3 -c "import time;time.sleep(0.5)"
out="$(printf x | KAIZEN_LOCK_WAIT=0.3 python3 "$TOOL" add --title 待ち 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'ロック' && ok "ロック中は待ち時間を過ぎたら足さずに止まる" || ng "ロック中に足した/黙った: rc=$rc $out"
wait "$H"
k lock -- true >/dev/null; [ $? -eq 0 ] && ok "lock -- <コマンド> はコマンドの終了コードを返す" || ng "lock の終了コードが違う"

echo "── §4 退避（原文無改変・中身が変わっていたら何もしない）"
fixture
s1="$(spec_of K-001)"
out="$(k move "$s1")"; rc=$?
[ "$rc" = "0" ] && ok "line:hash 指定で退避できる" || ng "退避に失敗: $out"
python3 -c "import sys;t=open(sys.argv[1],encoding='utf-8').read();assert '### K-001 — あ\n本文あ' in t" "$A" 2>/dev/null && ok "archive に原文のまま移る" || ng "archive の中身が原文と違う"
grep -q '^### K-001 — あ' "$L" && ng "台帳に残っている" || ok "台帳から消える"
grep -q '^### K-010 — 過去の分' "$A" && ok "archive の既存分を消さない（末尾に足す）" || ng "archive の既存分が消えた"
[ "$(k list | jq1 'd["count"]')" = "4" ] && ok "退避後の件数が1件減る" || ng "退避後の件数が違う"
s2="$(spec_of K-002)"
sed -i 's/^### K-002 — い$/### K-002 — い（誰かが直した）/' "$L"
cp "$L" "$TMP/L.before"; cp "$A" "$TMP/A.before"
out="$(k move "$s2")"; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$L" "$TMP/L.before" && cmp -s "$A" "$TMP/A.before" && ok "list の後に中身が変わっていたら、台帳も archive も1文字も動かさない" || ng "変わった中身を動かした: rc=$rc"
out="$(k move 'abc:def')"; [ $? -ne 0 ] && ok "壊れた指定を弾く" || ng "壊れた指定を通した"
cp "$L" "$TMP/L.before"; s3="$(spec_of K-003)"
out="$(k move "$s3" '999:deadbeef0000')"; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$L" "$TMP/L.before" && ok "複数指定のうち1つでも合わなければ全部やめる（半端に動かさない）" || ng "一部だけ動かした"

echo "── §5 lint（書式外・重複を追記した側に返す）"
fixture
out="$(k lint)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '書式外' && printf '%s' "$out" | grep -q 'K-003' && ok "書式外と重複があれば非0で名指しする" || ng "lint が黙った: rc=$rc"
printf '### K-001 — あ\n本文\n' > "$L"
k lint >/dev/null; [ $? -eq 0 ] && ok "きれいな台帳なら 0" || ng "きれいな台帳で非0"

echo
echo "合計: 合格 ${PASS} ／ 不合格 ${FAIL}"
[ "$FAIL" -eq 0 ]
