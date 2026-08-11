#!/usr/bin/env bash
# bin/check-ssl.sh（弊社管理ドメインの SSL 有効期限チェック）の回帰テスト。
#
# 契機＝2026-08-11、testing.md §7「無人ループが実行するツール 21本のうちテストが無い 13本」を
# 減らす作業の7本目。§2 の条件①③に当たる＝定期実行され、しきい値で 🔴/🟡/✅ を判定する。
# 壊れ方は「静か」：判定が甘くなれば**証明書が切れるまで誰も気づかない**（サイト全滅）。
# 逆に取得失敗を ✅ に混ぜると「見ているつもり」になる＝失敗は必ず ⚠️ として数える。
#
# ⚠️ 実 TLS 接続はしない（openssl をスタブ）。**Slack へも絶対に送らない**：
#    本体は `bash "$SCRIPT_DIR/slack.sh"` を呼ぶ作りなので、一時ディレクトリに偽プロジェクトを組み、
#    そこへ check-ssl.sh の実物と**偽 slack.sh** を置いて流す（本番 bin/slack.sh は起動されない）。
#    ドメイン名はすべて example.test の架空名。
# 触ったら必ず流すこと：bash bin/test-check-ssl.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/check-ssl.sh" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fakebin" "$T/rec" "$T/data/ssl-check"
cp "$PROJ/bin/check-ssl.sh" "$T/bin/check-ssl.sh"

REC="$T/rec"; export REC
SSL_FIX="$T/certs.tsv"; export SSL_FIX

# 偽 slack.sh（本番の送信経路を物理的に塞ぐ）。本文を記録するだけ。
cat > "$T/bin/slack.sh" <<'SLACKEOF'
#!/usr/bin/env bash
cat > "$REC/slack-body"
echo "(テスト用スタブ: Slack へは送っていません)"
SLACKEOF
chmod +x "$T/bin/slack.sh"

# 偽 openssl：s_client はホスト名を次段へ渡すだけ、x509 は台帳から notAfter を返す。
cat > "$T/fakebin/openssl" <<'OSSLEOF'
#!/usr/bin/env bash
case "${1:-}" in
  s_client)
    host=""; prev=""
    for a in "$@"; do [ "$prev" = "-servername" ] && host="$a"; prev="$a"; done
    cat >/dev/null 2>&1
    printf 'HOST=%s\n' "$host"
    ;;
  x509)
    IFS= read -r line || true
    host="${line#HOST=}"
    val="$(awk -F'\t' -v h="$host" '$1==h{print $2; exit}' "$SSL_FIX")"
    [ -z "$val" ] && exit 1
    [ "$val" = "FAIL" ] && exit 1
    printf 'notAfter=%s\n' "$val"
    ;;
  *) exit 1 ;;
esac
OSSLEOF
chmod +x "$T/fakebin/openssl"
export PATH="$T/fakebin:$PATH"

P=0; N=0
say_ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
say_ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      → %s\n' "$2"; fi; }
has(){ case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(printf '%s' "$2" | tr '\n' '|' | cut -c1-260)"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(printf '%s' "$2" | tr '\n' '|' | cut -c1-260)"; else say_ok "$3"; fi; }
want_eq(){     if [ "$1" = "$2" ]; then say_ok "$3"; else say_ng "$3" "実際=[$1] 期待=[$2]"; fi; }

# 「今日から N 日後」の証明書期限。**LC_ALL=C 必須**＝日本語ロケールだと月が「11月」になり、
# openssl の英語表記（Nov）と食い違って本体が「日付解釈に失敗」を返す（最初にここで踏んだ）。
after(){ LC_ALL=C date -u -d "+$1 days 12 hours" '+%b %e %H:%M:%S %Y GMT'; }

certs(){ : > "$SSL_FIX"; for kv in "$@"; do printf '%s\n' "$kv" >> "$SSL_FIX"; done; }
domains(){ printf '%s\n' "$@" > "$T/list.txt"; }
run(){ rm -f "$REC"/*; OUT="$(cd "$T" && bash "$T/bin/check-ssl.sh" "$@" 2>&1 </dev/null)"; RC=$?; }

echo "=== 引数と一覧ファイル ==="
run --nosuch
want_eq "$RC" "1" "不明なオプションは終了コード1"
want_in "不明なオプション" "$OUT" "何が悪いか言う"
run "$T/no-such-list.txt"
want_eq "$RC" "1" "一覧ファイルが無ければ止まる（0件を『全部OK』と偽らない）"
want_in "見つかりません" "$OUT" "見つからないことを言う"
certs "$(printf 'a.example.test\t%s' "$(after 100)")"
printf 'a.example.test\n' > "$T/data/ssl-check/domains.txt"
run
want_in "a.example.test" "$OUT" "引数無しなら data/ssl-check/domains.txt を使う"

echo
echo "=== 判定（しきい値：緊急≤7日 / 警告≤30日）==="
certs "$(printf 'ok.example.test\t%s' "$(after 100)")" \
      "$(printf 'warn.example.test\t%s' "$(after 20)")" \
      "$(printf 'crit.example.test\t%s' "$(after 3)")" \
      "$(printf 'expired.example.test\t%s' "$(after -5)")"
domains ok.example.test warn.example.test crit.example.test expired.example.test
run "$T/list.txt"
want_in "✅ OK	ok.example.test" "$OUT" "100日先は ✅ OK"
want_in "🟡 警告	warn.example.test" "$OUT" "20日先は 🟡 警告"
want_in "🔴 緊急	crit.example.test" "$OUT" "3日先は 🔴 緊急"
want_in "🔴 緊急	expired.example.test" "$OUT" "期限切れも 🔴 緊急"
want_in "残り-" "$OUT" "期限切れは残日数が負で出る（切れている事実を隠さない）"
want_in "🔴緊急 2 / 🟡警告 1 / ✅OK 1 / ⚠️ERROR 0" "$OUT" "見出しの件数が合う"
want_in "対象 4件" "$OUT" "対象件数が合う"
want_eq "$RC" "2" "🔴 があれば終了コード2（cron が検知できる）"

echo
echo "--- しきい値は環境変数で変えられる ---"
OUT="$(cd "$T" && CRIT_DAYS=25 WARN_DAYS=60 bash "$T/bin/check-ssl.sh" "$T/list.txt" 2>&1 </dev/null)"
want_in "🔴 緊急	warn.example.test" "$OUT" "CRIT_DAYS=25 なら20日先は 🔴 に上がる"
OUT="$(cd "$T" && CRIT_DAYS=25 WARN_DAYS=120 bash "$T/bin/check-ssl.sh" "$T/list.txt" 2>&1 </dev/null)"
want_in "🟡 警告	ok.example.test" "$OUT" "WARN_DAYS=120 なら100日先は 🟡 に上がる"
want_in "しきい値：緊急 ≤25日 / 警告 ≤120日" "$OUT" "使ったしきい値を本文に明記する"

echo
echo "=== 取得できなかったものを ✅ に混ぜない ==="
certs "$(printf 'ok.example.test\t%s' "$(after 100)")" \
      "$(printf 'down.example.test\tFAIL')" \
      "$(printf 'weird.example.test\tまったく日付でない文字列')"
domains ok.example.test down.example.test weird.example.test
run "$T/list.txt"
want_in "⚠️ ERROR	down.example.test" "$OUT" "接続・証明書取得の失敗は ⚠️ ERROR"
want_in "接続/証明書取得に失敗" "$OUT" "失敗の理由を書く"
want_in "⚠️ ERROR	weird.example.test" "$OUT" "日付として解釈できない値も ⚠️ ERROR"
want_in "日付解釈に失敗" "$OUT" "解釈失敗と分けて書く"
want_in "⚠️ERROR 2" "$OUT" "ERROR も件数に数える"
want_in "✅OK 1" "$OUT" "失敗を OK に数えない"
want_eq "$RC" "0" "ERROR だけなら終了コードは0（🔴 のときだけ2）"
first="$(printf '%s' "$OUT" | sed -n '5p')"
want_in "⚠️ ERROR" "$first" "危険なもの（ERROR）が一覧の先頭に来る"

echo
echo "--- 残日数の昇順に並ぶ ---"
certs "$(printf 'far.example.test\t%s' "$(after 200)")" \
      "$(printf 'near.example.test\t%s' "$(after 10)")" \
      "$(printf 'mid.example.test\t%s' "$(after 60)")"
domains far.example.test mid.example.test near.example.test
run "$T/list.txt"
order="$(printf '%s' "$OUT" | grep -oE '(far|mid|near)\.example\.test' | tr '\n' ' ')"
want_eq "$order" "near.example.test mid.example.test far.example.test " "危険な順（残日数の少ない順）に並べる"

echo
echo "=== 一覧ファイルの書式 ==="
certs "$(printf 'a.example.test\t%s' "$(after 100)")" \
      "$(printf 'b.example.test\t%s' "$(after 100)")"
printf '%s\n' "# 見出しコメント" "" "  a.example.test  " "b.example.test # 行内コメント" "   " > "$T/list.txt"
run "$T/list.txt"
want_in "対象 2件" "$OUT" "コメント行・空行・空白だけの行は数えない"
want_in "a.example.test" "$OUT" "前後の空白を落として問い合わせる"
want_in "b.example.test" "$OUT" "行内コメントを落として問い合わせる"
want_not_in "行内コメント" "$OUT" "行内コメントをドメイン名に混ぜない"
printf 'a.example.test' > "$T/list.txt"      # 最終行に改行が無い
run "$T/list.txt"
want_in "対象 1件" "$OUT" "最終行に改行が無くても読み落とさない"

echo
echo "=== Slack 送信（明示したときだけ・本番へは出さない）==="
certs "$(printf 'ok.example.test\t%s' "$(after 100)")"
domains ok.example.test
run "$T/list.txt"
if [ -f "$REC/slack-body" ]; then say_ng "★--slack が無ければ送らない"; else say_ok "★--slack が無ければ送らない"; fi
run --slack "$T/list.txt"
if [ -f "$REC/slack-body" ]; then say_ok "--slack で送る"; else say_ng "--slack で送る"; fi
want_in "SSL有効期限チェック" "$(cat "$REC/slack-body" 2>/dev/null)" "本文はレポートそのもの"
run --slack --only-problems "$T/list.txt"
if [ -f "$REC/slack-body" ]; then say_ng "★--only-problems で問題なしなら送らない（無駄打ちしない）"; else say_ok "★--only-problems で問題なしなら送らない（無駄打ちしない）"; fi
want_in "スキップ" "$OUT" "送らなかったことを画面には出す（黙らない）"
certs "$(printf 'crit.example.test\t%s' "$(after 3)")"
domains crit.example.test
run --slack --only-problems "$T/list.txt"
if [ -f "$REC/slack-body" ]; then say_ok "--only-problems でも問題があれば送る"; else say_ng "--only-problems でも問題があれば送る"; fi
certs "$(printf 'down.example.test\tFAIL')"
domains down.example.test
run --slack --only-problems "$T/list.txt"
if [ -f "$REC/slack-body" ]; then say_ok "取得失敗も『問題あり』として送る（沈黙させない）"; else say_ng "取得失敗も『問題あり』として送る"; fi

echo
echo "=== 通知本文に秘密を入れない（automation.md §2）==="
certs "$(printf 'ok.example.test\t%s' "$(after 100)")"
domains ok.example.test
run --slack "$T/list.txt"
body="$(cat "$REC/slack-body")"
want_not_in "TOKEN" "$body" "トークン類の語が本文に出ない"
want_not_in "$T" "$body" "ローカルのパスを本文に出さない"
want_in "JST" "$body" "確認時刻を JST で明記する"
want_in "ok.example.test" "$body" "公開情報（ドメイン・期限・残日数）だけを載せる"

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
