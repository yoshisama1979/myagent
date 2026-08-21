#!/usr/bin/env bash
# 認証切れ・短すぎる完走の検知（agent-tick.sh）の回帰テスト。
#
# 契機＝2026-08-19 20:10〜08-20 10:10 の約14時間、claude の OAuth 失効で全ループが全滅したのに
#       status=ok を出し続け、社長へ一度も通知されなかった。claude は exit 0 で終わるため
#       rc では分からず、定時実行は「処理すべき便が0」なので無進捗判定も効かなかった。
#
# 設計：判定ロジックを書き写さず、**実ソースから正規表現と閾値を抜き出して**検証する
#       （写した瞬間に「テストだけ正しい」状態が生まれる＝test-cooldown.sh と同じ方針）。
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJ/bin/agent-tick.sh"
[ -f "$SRC" ] || { echo "❌ agent-tick.sh が見つからない: $SRC" >&2; exit 2; }

P=0; N=0
ok() { P=$((P+1)); echo "  ✅ $1"; }
ng() { N=$((N+1)); echo "  ❌ $1"; [ $# -ge 2 ] && echo "      → $2"; }

# --- 実ソースから認証判定の正規表現を抜き出す ---
PAT=$(grep -oE '"\^» \*\([^"]*\)"' "$SRC" | head -1 | sed 's/^"//;s/"$//')
[ -n "$PAT" ] || { echo "❌ 認証判定の正規表現を抽出できない（実装が変わった？）" >&2; exit 2; }

hit() { printf '%s\n' "$1" | grep -qiE "$PAT"; }

echo "=== 実際に起きた文言を捕まえるか（実ログから採取）==="
hit '» Failed to authenticate: OAuth session expired and could not be refreshed' \
  && ok "★2026-08-20 に実際に14時間出続けた文言（OAuth失効）" \
  || ng "実際の文言を捕まえられない＝同じ事故がまた黙って起きる"
hit '» Not logged in · Please run /login' && ok "未ログインの案内" || ng "未ログインを捕まえられない"
hit '» Invalid API key · Please run /login' && ok "APIキー不正" || ng "APIキー不正を捕まえられない"
hit '» failed to authenticate: oauth session expired' && ok "大文字小文字を問わない" || ng "小文字だと捕まえられない"

echo
echo "=== 誤検知しないか（ここが緩いと狼少年になる）==="
hit '» 統括の報告：昨夜 OAuth session expired で全ループが停止していました' \
  && ng "★エージェントが事故を報告した本文で誤検知する（行頭固定が効いていない）" \
  || ok "★報告本文の中に同じ語が出ても鳴らない（ログ行の行頭に固定している）"
hit '» 認証まわりの設計を見直します（Failed to authenticate の扱い）' \
  && ng "文中の言及で誤検知する" || ok "文中の言及では鳴らない"
hit '» サイクル完了。掲示板を更新しました' && ng "通常出力で誤検知する" || ok "通常の完了出力では鳴らない"
hit '2026-08-20 07:00:01 JST [run] claude -p /partner 起動' \
  && ng "制御行で誤検知する" || ok "制御マーカー行では鳴らない（» 接頭辞が無い）"

echo
echo "=== 仕事の形跡が無い完走の見張り（文言に依存しない層）==="
# ★数値や文字列を grep するのではなく、**実ソースの判定関数を読み込んで実際に呼ぶ**。
#   2026-08-20、最初は「60秒未満なら異常」を grep するだけのテストで 20/20 合格していたが、
#   その実装はその晩に正常な /memo-intake（43秒）を誤報した＝テストが防御を検証していなかった。
eval "$(sed -n '/^QUICK_SEC=/,/^}/p' "$SRC")"
if ! declare -F run_looks_broken >/dev/null; then
  echo "❌ run_looks_broken を実ソースから読み込めない（実装が変わった？）" >&2; exit 2
fi
say() { if run_looks_broken "$1" "$2"; then echo hit; else echo quiet; fi; }

# 実測値（data/overseer/tick.log から集計・2026-08-20）
[ "$(say 6 202)" = hit ]   && ok "★実際の認証切れ partner 08-20 07:00（6秒/202B）を鳴らす" || ng "実事故を見逃す"
[ "$(say 4 200)" = hit ]   && ok "★実際の認証切れ comms（4秒/200B）を鳴らす" || ng "実事故を見逃す"
[ "$(say 43 1342)" = quiet ] \
  && ok "★昨夜 誤報した正常系 /memo-intake（43秒/1342B・入力0件）では鳴らさない" \
  || ng "正常な空バッチを誤報する＝毎晩鳴って通知が信用されなくなる"
[ "$(say 60 1606)" = quiet ] && ok "正常な最短サイクル（60秒/1606B）では鳴らさない" || ng "正常系を誤報"
[ "$(say 900 4855)" = quiet ] && ok "正常な通常サイクル（900秒/4855B）では鳴らさない" || ng "正常系を誤報"

# 片方だけでは鳴らさない（2条件が揃ったときだけ＝誤報を減らす設計）
[ "$(say 5 5000)" = quiet ]  && ok "速いが大量に書いた実行は鳴らさない（仕事はしている）" || ng "片側だけで鳴る"
[ "$(say 600 100)" = quiet ] && ok "遅いが何も書かない実行は鳴らさない（別の異常として扱う）" || ng "片側だけで鳴る"

# 測れなかったときは鳴らさない（誤報より見逃しを選ぶ）
[ "$(say '' '')" = quiet ] && ok "値が取れないときは鳴らさない" || ng "空値で鳴る"
[ "$(say abc 100)" = quiet ] && ok "数値でない値で鳴らない" || ng "非数値で鳴る"

# 閾値そのものが実測から離れていないか（将来の変更で誤報側へ寄るのを防ぐ）
[ "$QUICK_SEC" -gt 6 ] && [ "$QUICK_SEC" -lt 43 ] \
  && ok "秒の閾値が「実事故6秒」と「正常43秒」の間にある（${QUICK_SEC}秒）" \
  || ng "秒の閾値が実測の外" "QUICK_SEC=$QUICK_SEC"
[ "$QUICK_BYTES" -gt 202 ] && [ "$QUICK_BYTES" -lt 1342 ] \
  && ok "出力量の閾値が「実事故202B」と「正常1342B」の間にある（${QUICK_BYTES}B）" \
  || ng "出力量の閾値が実測の外" "QUICK_BYTES=$QUICK_BYTES"

grep -q 'elapsed=$(( $(mono_sec) - started ))' "$SRC" \
  && ok "経過時間に単調増加時計を使う（実行中の時刻補正で負にならない）" || ng "壁時計のまま"
grep -q 'last-alert-tooquick-\$label' "$SRC" \
  && ok "★スロットルがラベル別（あるループの通知が別ループの本物の異常を握り潰さない）" \
  || ng "スロットルが共用＝1時間に1件しか鳴らない"

echo
echo "=== 通知が claude に依存していないか（認証が死んでも届く必要がある）==="
ALERT=$(sed -n '/^alert() {/,/^}/p' "$SRC")
printf '%s' "$ALERT" | grep -qE 'slack-poll\.py"? post' \
  && ok "★通知は Slack の Bot トークン経由（claude を通さない＝認証が死んでいても届く）" \
  || ng "通知が claude 経由＝認証切れのときに通知そのものが出せない"
printf '%s' "$ALERT" | grep -q 'claude' && ng "alert が claude を呼んでいる" || ok "alert は claude を呼ばない"

# ★実際に「ログが書けない」状況を作って、それでも通知が送られるか確かめる。
#   静的検査だけでは足りない（2026-08-20 Codexレビュー：ディスク満杯は、まさに警報を出したい
#   場面のひとつなのに、送信結果のリダイレクト先が書けず**コマンドごと実行されなかった**）。
AT=$(mktemp -d)
mkdir -p "$AT/ro" "$AT/bin"
printf '#!/bin/bash\ncat > "%s/sent.txt"\n' "$AT" > "$AT/bin/slack-poll.py"
chmod +x "$AT/bin/slack-poll.py"
chmod 500 "$AT/ro"                     # ここへは書けない＝ログ書き込みが失敗する状況
(
  LOG="$AT/ro/tick.log"; PROJ="$AT"; PY="$AT/bin/slack-poll.py"
  LAST_ALERT="$AT/throttle"
  now() { echo "テスト時刻"; }
  eval "$(sed -n '/^alert() {/,/^}/p' "$SRC")"
  alert "ログが書けない状況のテスト警報"
) >/dev/null 2>&1
if [ -s "$AT/sent.txt" ]; then
  ok "★ログが書けなくても通知は送信される（ディスク満杯でも黙らない）"
else
  ng "ログが書けないと通知そのものが出せない＝最も鳴ってほしい場面で黙る"
fi
grep -q 'テスト警報' "$AT/sent.txt" 2>/dev/null \
  && ok "送信本文に警報内容が入っている" || ng "本文が欠けている"
[ -f "$AT/throttle" ] && ok "送信成功時はスロットルを更新する" || ng "スロットルが更新されない＝毎回鳴る"
chmod 700 "$AT/ro" 2>/dev/null; rm -rf "$AT"

echo
echo "=== 判定の置き場所（ここを間違えると到達しない）==="
auth_line=$(grep -n 'label-noauth' "$SRC" | head -1 | cut -d: -f1)
rc_line=$(grep -n 'if \[ "$rc" -ne 0 \]; then' "$SRC" | head -1 | cut -d: -f1)
quick_line=$(grep -n 'label-tooquick' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$auth_line" ] && [ -n "$rc_line" ] && [ "$auth_line" -lt "$rc_line" ]; then
  ok "認証判定が rc 分岐より前にある（rc=0 で終わるので後ろだと到達しない）"
else
  ng "認証判定の位置が不正" "auth=$auth_line rc=$rc_line"
fi
[ -n "$quick_line" ] && ok "短すぎる完走の判定が存在する" || ng "短すぎる完走の判定が無い"

echo
echo "=== 復旧の道が残っているか ==="
auth_block=$(sed -n "$((auth_line - 2)),$((auth_line + 8))p" "$SRC")
printf '%s' "$auth_block" | grep -q 'cooldown_hold' \
  && ok "★連続失敗に数えず冷却だけかける（こちらの不具合ではない・再ログインで自力復帰する）" \
  || ng "連続失敗に数えている＝再ログインしても長時間ロックされたままになる"
printf '%s' "$auth_block" | grep -q '再ログイン' \
  && ok "★通知に「社長の操作が要る」と書いてある（クレジット切れと違い待っても直らない）" \
  || ng "何をすればよいか通知に書いていない"
printf '%s' "$auth_block" | grep -q 'last-alert-noauth' \
  && ok "専用のスロットル先を使う（他の警報に握り潰されない）" || ng "スロットルが共用"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
