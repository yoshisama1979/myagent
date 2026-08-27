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
# ★閾値と判定関数を実ソースから読み込む。範囲は「閾値の定義」から
#   「run_looks_broken の終わり」まで＝間に関数が増えても取りこぼさない
#   （2026-08-25、run_looks_silent を足したら手前で切れて読み込めなくなった）。
# ★閾値と判定関数を実ソースから読み込む。
#   範囲を「閾値〜最初の }」にすると、間に関数が増えたとき手前で切れる
#   （2026-08-25、run_looks_silent を足して実際に切れた）。
#   かといって「閾値〜run_looks_broken()」だと開き括弧だけを取り込んで構文が壊れる。
#   よって閾値の定義行だけを取り、関数は関数ごとに取る。
eval "$(grep -E '^(QUICK|SILENT)_[A-Z]+=' "$SRC")"
eval "$(sed -n '/^run_looks_silent()/,/^}/p' "$SRC")"
eval "$(sed -n '/^done_signature()/,/^}/p' "$SRC")"
eval "$(sed -n '/^run_looks_broken()/,/^}/p' "$SRC")"
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
echo "=== ★長時間かけて何も出力しない実行を捕まえる（2026-08-25 実測）==="
# 8/24・8/25 の定時の朝礼は、claude が1行も出力せずに25分の制限時間まで居座っていた。
# 「速すぎる」判定は形が逆で捕まえられず、しかも当時は fetch のログが同じファイルに
# 混ざって「5,278バイト書いた」ように見えていた＝二重に見逃していた。
sil() { if run_looks_silent "$1" "$2"; then echo hit; else echo quiet; fi; }
[ "$(sil 1501 0)" = hit ] \
  && ok "★25分動いて出力ゼロを鳴らす（8/25 の朝礼で実際に起きた形）" || ng "沈黙を見逃す"
[ "$(sil 1501 5278)" = quiet ] \
  && ok "★出力があれば鳴らさない（＝claude の出力を分離しないと②も効かない）" || ng "出力があるのに鳴る"
[ "$(sil 43 1342)" = quiet ]  && ok "正常・入力0件では鳴らない" || ng "正常系を誤報"
[ "$(sil 900 4855)" = quiet ] && ok "正常・通常サイクルでは鳴らない" || ng "正常系を誤報"
[ "$(sil 6 202)" = quiet ]    && ok "速くて短い実行は別判定に任せる（二重に鳴らさない）" || ng "重複して鳴る"
[ "$(sil 299 100)" = quiet ]  && ok "5分未満は沈黙とみなさない" || ng "境界が違う"
[ "$(sil '' '')" = quiet ]    && ok "値が取れないときは鳴らさない" || ng "空値で鳴る"

echo
echo "=== ★★ 出力量で測ると「わざと黙るモード」を故障扱いする（2026-08-27 実害13件）★★ ==="
# comms は rules/modes/comms.md により**標準出力に出さない**設計（クライアント名が tick.log に
# 残るのを防ぐため）。最終報告は固定形式1行だけ＝45〜66バイト。SILENT_BYTES=200 では必ず鳴る。
# 導入から3日で鳴った13件は全部これで、本物の異常は1件も無かった。
sg() { if run_looks_silent "$1" "$2" "$3"; then echo hit; else echo quiet; fi; }

[ "$(done_signature comms)" = "comms done:" ] \
  && ok "★comms の完了署名が定義されている（rules/modes/comms.md の固定形式1行）" \
  || ng "comms の署名が引けない" "got=$(done_signature comms)"
[ -z "$(done_signature partner)" ] && ok "署名を持たないモードは空を返す（従来判定へ落ちる）" || ng "余計な署名"
[ "$(done_signature 'hp-loop:ycom')" = "$(done_signature hp-loop)" ] \
  && ok "サイト付きラベル（hp-loop:ycom）でもモード名で引ける" || ng "ラベルの分解が違う"

# 実測値：8/27 に誤報した6回はすべて 400〜1234秒 / 66〜68バイト
[ "$(sg 400 66 1)" = quiet ] \
  && ok "★誤報した実測値（400秒/66B・完了行あり）で鳴らさない" || ng "同じ誤報を繰り返す"
[ "$(sg 1234 66 1)" = quiet ] \
  && ok "★誤報した実測値（1234秒/66B・完了行あり）で鳴らさない" || ng "同じ誤報を繰り返す"
[ "$(sg 752 68 1)" = quiet ] && ok "★誤報した実測値（752秒/68B・完了行あり）で鳴らさない" || ng "同じ誤報を繰り返す"

# 署名を持つモードで署名が無い＝量が多くても未完了（量で見るより厳しくなる）
[ "$(sg 600 0 0)" = hit ] \
  && ok "★comms が完了行を出さずに終わったら鳴らす（本物の沈黙は見逃さない）" || ng "沈黙を見逃す"
[ "$(sg 600 5000 0)" = hit ] \
  && ok "★大量に出力していても完了行が無ければ鳴らす（量より署名が強い）" || ng "量に騙される"
[ "$(sg 299 0 0)" = quiet ] && ok "署名が無くても5分未満なら鳴らさない（境界は据え置き）" || ng "境界が違う"

# 署名を持たないモードは従来どおり（既存の防御を壊していない）
[ "$(sg 1501 0 '')" = hit ]    && ok "署名を持たないモードは従来どおり量で判定（25分/0B は鳴る）" || ng "既存判定が壊れた"
[ "$(sg 1501 5278 '')" = quiet ] && ok "署名を持たないモードは出力があれば鳴らない" || ng "既存判定が壊れた"

echo
echo "=== ★ タイムアウトの進捗は成果物で測る（出力量では測れない）==="
# 実測 2026-08-27：claude -p は**終わるまで標準出力に1バイトも書かない**（5〜30秒を5秒ごとに
# 採取して全部0バイト）。打ち切られた実行は必ず0バイトになるため、
# 「0バイト＝そもそも何も出していない」は常に誤り。実際 8/27 のタイムアウト4本は
# 全部、台帳・掲示板を更新してから切られていた（朝礼は #report への投稿まで完了）。
grep -q 'そもそも何も出していません' "$SRC" \
  && ng "タイムアウトで「そもそも何も出していない」と断定する文言が残っている（常に誤り）" \
  || ok "★出力量から進捗を断定する文言が消えている"
# ★配線（呼び出し側）は関数を単体で試すだけでは守れない＝変異テストで2件素通りした。
#   引数の渡し忘れ・定数への差し替えを、呼び出しの形そのもので固定する。
grep -qF 'run_looks_silent "$elapsed" "$out_bytes" "$signed"' "$SRC" \
  && ok "★沈黙判定に完了署名を渡している（渡し忘れると comms の誤報が丸ごと復活する）" \
  || ng "署名が判定に渡っていない"
grep -qF 'touched=$(work_touched "$wstamp")' "$SRC" \
  && ok "★進捗を実測している（定数に差し替わると常に「動き出せていない」と誤診する）" \
  || ng "進捗が実測されていない"
grep -q 'wstamp' "$SRC" && ok "測定の基準ファイルを実行前に置いている" || ng "基準時刻が無い"
grep -q 'touched" -gt 0' "$SRC" \
  && ok "★成果物が更新されていれば「途中まで進んでいた」と伝える" || ng "進捗の出し分けが無い"

# work_touched 単体（本番ディレクトリを触らない一時領域で）
eval "$(sed -n '/^work_touched()/,/^}/p' "$SRC")"
WT=$(mktemp -d); PROJ="$WT"; mkdir -p "$WT/data" "$WT/site"
stamp="$WT/stamp"; touch -d '2026-08-27 10:00:00' "$stamp"
touch -d '2026-08-27 09:00:00' "$WT/data/old.md"
[ "$(work_touched "$stamp")" = "0" ] && ok "基準より古い成果物は数えない" || ng "古い分まで数える" "$(work_touched "$stamp")"
touch -d '2026-08-27 11:00:00' "$WT/site/new1.html" "$WT/data/new2.md"
[ "$(work_touched "$stamp")" = "2" ] && ok "実行中に更新された成果物を数える" || ng "件数が違う" "$(work_touched "$stamp")"
touch -d '2026-08-27 11:00:00' "$WT/data/noise.log" "$WT/data/.hidden" "$WT/data/x.lock"
[ "$(work_touched "$stamp")" = "2" ] \
  && ok "★ログ・ロック・隠しファイルは成果物に数えない（毎回必ず更新されるため）" \
  || ng "ノイズを成果物に数える" "$(work_touched "$stamp")"
[ "$(work_touched "$WT/no-such-file")" = "0" ] && ok "基準ファイルが無ければ0（落ちない）" || ng "基準欠落で壊れる"
rm -rf "$WT"; PROJ="$(cd "$(dirname "$SRC")/.." && pwd)"

echo
echo "=== ★claude の出力と取り込み(fetch)のログを混ぜない ==="
# 取り込みをメインロックの外へ出したため、claude 実行中に fetch が同じログへ並行して書く。
# 「この実行が書いた分」で測ると、claude が何も出していなくても他人のログで水増しされる。
grep -q 'ctmp=$(mktemp' "$SRC" \
  && ok "★claude の出力を専用ファイルへ捕まえてから記録に流す" || ng "同じログに直接流している"
grep -q 'out_bytes=$(stat -c%s "$ctmp"' "$SRC" \
  && ok "★出力量は claude 専用ファイルから測る（fetch のログが混ざらない）" || ng "混ざった量で測っている"
grep -q 'out_bytes=$(( $(stat -c%s "$LOG"' "$SRC" \
  && ng "★ログ全体の増分で測っている（fetch のログで水増しされる）" || ok "ログ全体の増分では測っていない"
grep -q 'label-silent' "$SRC" && ok "沈黙を専用の失敗種別で記録する" || ng "種別が無い"
# ★この検査は 2026-08-25 に「出力バイト数で言い分ける」ことを固定していたが、
#   claude -p は終わるまで1バイトも出さない＝打ち切られた実行は必ず0バイトなので、
#   固定していた区別そのものが成立していなかった（2026-08-27 実測で判明）。
#   言い分けること自体は正しいので、根拠を**実行中に更新された成果物の件数**へ置き換える。
grep -q '途中までは進んでいました' "$SRC" && grep -q '動き出せていない可能性' "$SRC" \
  && ok "★タイムアウト時も「進んでいた」と「動き出せていない」を言い分ける（根拠は成果物の更新）" \
  || ng "言い分けが無い＝台帳が重いのだと誤診させる"

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
echo "=== 「claude が動き出す前に落ちた」判定の作法が守られているか ==="
# クレジット切れ・認証切れは同じ形の7行ブロックで、うち3行（cooldown_hold / ACTIONS+= / return 0）は
# どちらも同一。関数に切り出そうとしても **早期 return は呼び出し元でしか書けない**＝
# いちばん間違えやすい部分を閉じ込められないため、まとめずに「作法が守られているか」を機械で見張る。
# 次に3つ目を足す人がコピペで1行落としたときに、ここで落ちる。
# silent（長時間かけて何も出さない）も同じ作法で扱う＝冷却が無いと $70級の処理が空回りし続ける。
# ただし早期 return はしない（完走側の分岐なので、そこで処理が終わる）＝対象の検査を分ける。
blk=$(awk '/label-silent/{f=1} f{print} f && /partner_alert/{exit}' "$SRC")
printf '%s' "$blk" | grep -q 'cooldown_hold' \
  && ok "silent: 冷却をかける（毎分 \$70級の処理を空回りさせない）" \
  || ng "silent: cooldown_hold が無い＝空回りが止まらない"
printf '%s' "$blk" | grep -qE 'last-alert-silent-\$label' \
  && ok "silent: 専用スロットルをラベル別に使う" || ng "silent: スロットルが共用"

for kind in nocredit noauth; do
  # 該当ブロック＝`fail "$label-<kind>"` から直後の `return 0` まで
  blk=$(awk -v k="$kind" '
    $0 ~ ("label-" k) {f=1}
    f {print}
    f && /return 0/ {exit}' "$SRC")
  [ -n "$blk" ] || { ng "$kind ブロックを抽出できない"; continue; }
  printf '%s' "$blk" | grep -q 'cooldown_hold' \
    && ok "$kind: 冷却をかける（毎分claudeを起動し続けない）" \
    || ng "$kind: cooldown_hold が無い＝毎分起動して費用が止まらない"
  printf '%s' "$blk" | grep -q 'cooldown_apply' \
    && ng "$kind: cooldown_apply を使っている＝連続失敗に数えられ復旧後も長時間ロックされる" \
    || ok "$kind: 連続失敗には数えない（こちらの不具合ではない）"
  printf '%s' "$blk" | grep -q 'ACTIONS+=' \
    && ok "$kind: ACTIONS に積む（heartbeat の status に出る）" \
    || ng "$kind: ACTIONS+= が無い＝status 行に現れず気づけない"
  printf '%s' "$blk" | grep -q 'return 0' \
    && ok "$kind: 早期 return する（下の rc 分類まで流れて二重に鳴らさない）" \
    || ng "$kind: return 0 が無い＝そのまま流れて二重通知になる"
  printf '%s' "$blk" | grep -qE 'last-alert-[a-z]+' \
    && ok "$kind: 専用スロットルを使う（他の警報に握り潰されない）" \
    || ng "$kind: スロットルが共用"
done

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
