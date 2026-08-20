#!/usr/bin/env bash
# bin/mailbox.sh（拠点横断メールボックス API のクライアント）の回帰テスト。
#
# 契機＝2026-08-11、testing.md §7「無人ループが実行するツール 21本のうちテストが無い 13本」を
# 減らす作業の2本目。§2 の条件に当たる＝①無人ループ（各モードの配信）から呼ばれる
# ②状態を書く（data/mailbox/new/ へ投函）③判定を持つ（送信者/受信者の許可リスト・型・格納先）。
#
# ここで守りたい不変条件は2つ：
#  (1) **トークンを argv に載せない**。`-H "Authorization: Bearer xxx"` だと ps / /proc から
#      他ユーザーに見える。実装は umask 077 の一時 config 経由で渡す設計なので、それを機械で見張る。
#  (2) **local-send の宛先ガード**。from はファイル名(mid)に入るためパストラバーサルの入口になり、
#      宛先を間違えると「消費する dispatch が無い」孤児メッセージになる（総称 hp-loop 廃止の経緯）。
#
# ⚠️ 本番の .env・data/mailbox/ には触れない：一時ディレクトリに**偽プロジェクトを組み、
#    bin/mailbox.sh の実物をコピーして**流す（ROOT_DIR がスクリプト位置から決まる作りのため）。
#    curl はスタブに差し替える＝ネットワークへ一切出ない。トークンは架空の値だけを使う。
# 触ったら必ず流すこと：bash bin/test-mailbox.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/mailbox.sh" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/data/mailbox/new" "$T/fakebin" "$T/rec"
cp "$PROJ/bin/mailbox.sh" "$T/bin/mailbox.sh"

FAKE_TOKEN="mbx-TESTONLY-0123456789"      # 架空。本番トークンは読まない・出さない
REC="$T/rec"

# --- curl のスタブ（ネットワークに出ない／argv と --config の中身を記録する）---
cat > "$T/fakebin/curl" <<'CURLEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/argv"
cfg="" prev=""
for a in "$@"; do
  [ "$prev" = "--config" ] && cfg="$a"
  prev="$a"
done
if [ -n "$cfg" ] && [ -f "$cfg" ]; then
  stat -c '%a' "$cfg" > "$REC/cfgmode"
  cat "$cfg" > "$REC/cfgbody"
  printf '%s' "$cfg" > "$REC/cfgpath"
fi
case " $* " in *" --data-binary "*) cat > "$REC/stdin" ;; esac
echo '{"ok":true}'
CURLEOF
chmod +x "$T/fakebin/curl"
export REC
export PATH="$T/fakebin:$PATH"

P=0; N=0
say_ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
say_ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      → %s\n' "$2"; fi; }
has(){ case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"; else say_ok "$3"; fi; }
want_eq(){     if [ "$1" = "$2" ]; then say_ok "$3"; else say_ng "$3" "実際=[$1] 期待=[$2]"; fi; }

mk_env(){ printf '%s\n' "$@" > "$T/.env"; }
reset_rec(){ rm -f "$REC"/*; }
# mailbox.sh を1回走らせて OUT / RC に結果を入れる（標準入力は既定で空＝パイプ待ちにしない）
run_mb(){ reset_rec; OUT="$(bash "$T/bin/mailbox.sh" "$@" 2>&1 </dev/null)"; RC=$?; }
run_mb_stdin(){ local body="$1"; shift; reset_rec; OUT="$(printf '%s' "$body" | bash "$T/bin/mailbox.sh" "$@" 2>&1)"; RC=$?; }
argv(){ cat "$REC/argv" 2>/dev/null; }
newfiles(){ ls -1 "$T/data/mailbox/new" 2>/dev/null; }

mk_env "MAILBOX_URL=http://100.64.0.1/tools/mailbox/" "MAILBOX_TOKEN=$FAKE_TOKEN"

echo "=== 起動前提のチェック ==="
mv "$T/.env" "$T/.env.bak"
run_mb inbox
if [ "$RC" -ne 0 ]; then want_in ".env" "$OUT" ".env が無ければ止まる"; else say_ng ".env が無ければ止まる" "rc=$RC"; fi
mv "$T/.env.bak" "$T/.env"
mk_env "MAILBOX_TOKEN=$FAKE_TOKEN"
run_mb inbox
if [ "$RC" -ne 0 ]; then want_in "MAILBOX_URL" "$OUT" "MAILBOX_URL 未設定なら止まる"; else say_ng "MAILBOX_URL 未設定なら止まる" "rc=$RC"; fi
mk_env "MAILBOX_URL=http://100.64.0.1/tools/mailbox/"
run_mb inbox
if [ "$RC" -ne 0 ]; then want_in "MAILBOX_TOKEN" "$OUT" "MAILBOX_TOKEN 未設定なら止まる"; else say_ng "MAILBOX_TOKEN 未設定なら止まる" "rc=$RC"; fi
mk_env "MAILBOX_URL=http://100.64.0.1/tools/mailbox/" "MAILBOX_TOKEN=$FAKE_TOKEN"
run_mb bogus-command
if [ "$RC" -ne 0 ]; then want_in "不明なコマンド" "$OUT" "不明なコマンドは止まる"; else say_ng "不明なコマンドは止まる" "rc=$RC"; fi
run_mb
want_eq "$RC" "1" "引数無しは使い方を出して終了コード1"
want_in "inbox" "$OUT" "使い方に有効なコマンドが載る"
run_mb approve M-1
want_eq "$RC" "2" "approve は未実装として終了コード2（黙って成功しない）"

echo
echo "=== トークンの渡し方（automation.md §2・ps から見えないこと）==="
run_mb inbox
want_eq "$RC" "0" "inbox が成功する"
want_not_in "$FAKE_TOKEN" "$(argv)" "トークンが curl の argv に現れない（ps/proc 漏れの防止）"
want_not_in "$FAKE_TOKEN" "$OUT" "トークンが標準出力・ログに出ない"
want_in "Authorization: Bearer $FAKE_TOKEN" "$(cat "$REC/cfgbody" 2>/dev/null)" "トークンは --config 経由で渡る"
want_eq "$(cat "$REC/cfgmode" 2>/dev/null)" "600" "一時 config は本人のみ読める権限（umask 077）"
if [ -e "$(cat "$REC/cfgpath" 2>/dev/null)" ]; then say_ng "実行後に一時 config を消す"; else say_ok "実行後に一時 config を消す"; fi

echo
echo "=== URL の組み立て ==="
run_mb inbox
want_in "http://100.64.0.1/tools/mailbox/?action=inbox" "$(argv)" "末尾スラッシュを正規化して ?action=inbox"
run_mb inbox yoshida-dev
want_in "action=inbox&to=yoshida-dev" "$(argv)" "宛先指定は &to= で付く"
run_mb done M-20260811T090000-overseer-abc123
want_in "action=done&id=M-20260811T090000-overseer-abc123" "$(argv)" "done は id 付きで叩く"
want_in "POST" "$(argv)" "done は POST"
run_mb done
if [ "$RC" -ne 0 ]; then say_ok "done の id 省略は止まる"; else say_ng "done の id 省略は止まる" "rc=$RC"; fi

echo
echo "=== send の JSON 生成（クォート・日本語・改行が壊れないこと）==="
run_mb send --to yoshida-dev --subject '見積"A"の件' --type report --thread t-1 '本文の1行目' '2語目'
want_eq "$RC" "0" "send が成功する"
want_in "action=send" "$(argv)" "?action=send を叩く"
want_in "Content-Type: application/json" "$(argv)" "JSON として送る"
J="$(cat "$REC/stdin" 2>/dev/null)"
py(){ printf '%s' "$J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[sys.argv[1]])' "$1" 2>/dev/null; }
want_eq "$(py to)" "yoshida-dev" "to が乗る"
want_eq "$(py subject)" '見積"A"の件' "件名の二重引用符と日本語が壊れない"
want_eq "$(py type)" "report" "--type が乗る"
want_eq "$(py thread)" "t-1" "--thread が乗る"
want_eq "$(py body)" "本文の1行目 2語目" "引数の本文は空白で連結される"
want_eq "$(py needs_approval)" "False" "既定は承認待ちにしない"
run_mb send --to yoshida-dev --subject "件名" --needs-approval "本文"
J="$(cat "$REC/stdin")"
want_eq "$(py needs_approval)" "True" "--needs-approval で社長ゲート(hold/)へ回す"
run_mb_stdin "$(printf '1行目\n2行目')" send --to yoshida-dev --subject "件名"
J="$(cat "$REC/stdin")"
want_eq "$(py body)" "$(printf '1行目\n2行目')" "本文をパイプから受け取れる（改行も保つ）"
run_mb send --to yoshida-dev --subject "件名" -- --to にせもの
J="$(cat "$REC/stdin")"
want_eq "$(py to)" "yoshida-dev" "-- 以降はフラグに見えても本文として扱う"
want_eq "$(py body)" "--to にせもの" "-- 以降が本文になる"
run_mb send --subject "件名" "本文"
if [ "$RC" -ne 0 ]; then want_in "--to" "$OUT" "--to 無しは止まる"; else say_ng "--to 無しは止まる" "rc=$RC"; fi
run_mb send --to yoshida-dev
if [ "$RC" -ne 0 ]; then say_ok "件名も本文も無ければ止まる（空メールを投げない）"; else say_ng "件名も本文も無ければ止まる" "rc=$RC"; fi

echo
echo "=== local-send（同一マシン内投函・セキュリティの核）==="
run_mb local-send --from overseer --to yoshida-dev --subject "内部調整" "本文です"
want_eq "$RC" "0" "登録済みの送信者→受信者は通る"
MID="$(printf '%s' "$OUT" | tail -1)"
want_in "M-" "$MID" "id を標準出力に返す"
F="$T/data/mailbox/new/$MID.json"
if [ -f "$F" ]; then say_ok "new/ に投函される"; else say_ng "new/ に投函される" "$MID / $(newfiles)"; fi
jq_(){ python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$F" "$1" 2>/dev/null; }
want_eq "$(jq_ from)" "overseer" "from を記録する"
want_eq "$(jq_ to)" "yoshida-dev" "to を記録する"
want_eq "$(jq_ needs_approval)" "False" "local-send は常に承認不要（外部送信の近道にさせない）"
want_eq "$(jq_ body)" "本文です" "本文の日本語が壊れない"
if printf '%s' "$MID" | grep -qE '^M-[0-9]{8}T[0-9]{6}-overseer-[0-9a-f]{6}$'; then
  say_ok "id は M-<日時>-<送信者>-<乱数6桁>"; else say_ng "id は M-<日時>-<送信者>-<乱数6桁>" "$MID"; fi
if [ -z "$(ls -1 "$T/data/mailbox/new" | grep -v '\.json$' || true)" ]; then
  say_ok "書き込み途中の一時ファイルを残さない（dispatcher が拾わない）"
else say_ng "書き込み途中の一時ファイルを残さない" "$(newfiles)"; fi
want_not_in "curl" "$(ls "$REC" 2>/dev/null)" "local-send は HTTP を経由しない（curl を呼ばない）"
if [ -f "$REC/argv" ]; then say_ng "local-send で curl を呼ばない" "$(argv)"; else say_ok "local-send で curl を呼ばない"; fi

run_mb local-send --from overseer --to yoshida-dev --subject "2通目" "本文"
MID2="$(printf '%s' "$OUT" | tail -1)"
if [ "$MID" != "$MID2" ]; then say_ok "連続投函で id が衝突しない"; else say_ng "連続投函で id が衝突しない" "$MID"; fi

echo
echo "--- 宛先ガード（孤児メッセージ・なりすまし・パストラバーサル）---"
deny(){ # deny <説明> <引数...>
  local d="$1"; shift
  local before after
  before="$(newfiles | wc -l)"
  run_mb "$@"
  after="$(newfiles | wc -l)"
  if [ "$RC" -ne 0 ] && [ "$before" = "$after" ]; then say_ok "$d"
  else say_ng "$d" "rc=$RC 件数 $before→$after"; fi
}
deny "未登録の送信者は拒否"                 local-send --from nobody-agent --to yoshida-dev --subject s b
deny "president を名乗れない（人間の代弁禁止）" local-send --from president --to yoshida-dev --subject s b
deny "未登録の宛先は拒否"                   local-send --from overseer --to nobody-dev --subject s b
deny "廃止された総称 hp-loop 宛は拒否（消費する dispatch が無い＝孤児化）" \
     local-send --from overseer --to hp-loop --subject s b
deny "from にパス記号を入れられない（mid に入る＝../ の入口）" \
     local-send --from ../../etc --to yoshida-dev --subject s b
deny "to にパス記号を入れられない"          local-send --from overseer --to "../evil" --subject s b
deny "from にスラッシュを入れられない"      local-send --from "a/b" --to yoshida-dev --subject s b
deny "不正な --type は拒否"                 local-send --from overseer --to yoshida-dev --type destroy --subject s b
deny "--from 省略は拒否"                    local-send --to yoshida-dev --subject s b
deny "--to 省略は拒否"                      local-send --from overseer --subject s b
deny "件名も本文も無ければ拒否"             local-send --from overseer --to yoshida-dev

run_mb local-send --from hp-loop-ycom --to web-hanasaka --subject "解析レポート" "本文"
want_eq "$RC" "0" "サイト別ループ hp-loop-<site> は送信者になれる（実装担当への配信）"
run_mb local-send --from blog-loop-ycom --to web-hanasaka --subject "ブログ解析" "本文"
want_eq "$RC" "0" "blog-loop-<client> も送信者になれる"

# ── 相談レーンの申し送り経路（2026-08-19）──────────────────────
# ★「通すべきものが通るか」も検証する：talk を名簿に入れ忘れていたため、
#   /talk の申し送りコマンドは**書いた時点から一度も成功していなかった**（実機テストで発覚）。
run_mb local-send --from talk --to partner --subject "深掘り依頼" "本文"
want_eq "$RC" "0" "★talk → partner の申し送りが通る（相談役が深掘りを渡す唯一の経路）"

# ── 後勝ちによる偽装の封じ（2026-08-19 Codexレビュー）────────────
# 呼び出し側のガードは最初の値を見て許可する。実装が最後の値を採ると、
# 検査時と実行時で送信者・宛先が変わる＝talk が overseer を名乗って任意の宛先へ投函できた。
# ⚠️ --from だけを重複させる（--to も一緒に重複させると --to 側の検査で落ちてしまい、
#    --from の検査が効いているかを確かめられない＝変異テストで実際に素通りした）
deny "★--from の重複は拒否（後勝ちで送信者を偽装させない）" \
     local-send --from talk --to partner --from overseer --subject s b
deny "★--from と --to を同時に重複させても拒否" \
     local-send --from talk --to partner --from overseer --to yoshida-dev --subject s b
deny "★--to の重複は拒否" \
     local-send --from talk --to partner --to yoshida-dev --subject s b
deny "--subject の重複も拒否" \
     local-send --from overseer --to yoshida-dev --subject a --subject b "本文"

# ── 無人実行では自分の名しか名乗れない ──────────────────────────
# 名簿を通るだけだと、外部入力に誘導されたモードが他モードを騙って内部指示を投函でき、
# 受け手はそれを正規の依頼として実行する（指示注入が横に伝播する経路）。
MYAGENT_AGENT=talk run_mb local-send --from overseer --to yoshida-dev --subject s "本文"
if [ "$RC" -ne 0 ]; then want_in "自分" "$OUT" "★無人実行で他人を名乗ると拒否される"
else say_ng "無人実行で他人を名乗ると拒否される" "rc=$RC"; fi
MYAGENT_AGENT=talk run_mb local-send --from talk --to partner --subject s "本文"
want_eq "$RC" "0" "無人実行でも自分の名なら通る"
run_mb local-send --from overseer --to yoshida-dev --subject s "本文"
want_eq "$RC" "0" "有人セッション（MYAGENT_AGENT なし）は従来どおり代筆できる"

mv "$T/data/mailbox/new" "$T/data/mailbox/new.off"
run_mb local-send --from overseer --to yoshida-dev --subject s b
if [ "$RC" -ne 0 ]; then want_in "new/" "$OUT" "new/ が無ければ止まる（黙って作らない）"; else say_ng "new/ が無ければ止まる" "rc=$RC"; fi
mv "$T/data/mailbox/new.off" "$T/data/mailbox/new"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
