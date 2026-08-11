#!/usr/bin/env bash
# HP解析ツール群 bin/hp-audit.sh・bin/hp-compete.py・bin/hp-serp.sh・bin/hp-shot.sh の回帰テスト。
#
# 契機＝2026-08-11、testing.md §7「無人ループが実行するツール 21本のうちテストが無い 13本」を
# 減らす作業の8本目（最後）。4本を1スイートにしたのは、hp-loop の日次解析が
# 「hp-audit で取る → hp-compete で比べる → hp-shot/hp-serp で見る」と一本の鎖で動くため。
#
# 守りたい不変条件：
#   (1) **取れなかったものを取れたことにしない**（fetch_ok=false・exit 3。捏造は分析全体を汚す）
#   (2) HTTP GET だけ（file:// 等を弾く）＝読み取り専用ツールの境界
#   (3) 競合比較の「ギャップ」は決定論（同じ入力なら同じ施策候補が出る）
#   (4) node 解決ラッパは **cron の空環境（PATH に nvm が無い）でも動く**
#       ＝これが効かないと解析ループが無言で止まる（[[reference_allowlist-bash-prefix-gap]] と同型の事故）
#
# ⚠️ ネットワークへは出ない：hp-audit.sh は curl をスタブして固定HTMLを食わせる。
#    hp-compete は hp-audit を偽スクリプトへ差し替える。ドメインは example.test の架空名。
#    hp-shot/hp-serp は引数なしで usage を出させるだけ（ブラウザは起動しない）。
# 触ったら必ず流すこと：bash bin/test-hp-tools.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in hp-audit.sh hp-compete.py hp-serp.sh hp-shot.sh; do
  [ -f "$PROJ/bin/$f" ] || { echo "❌ 起動位置がおかしい: $PROJ/bin/$f" >&2; exit 2; }
done

T="$(mktemp -d)"
case "$T" in /tmp/*) ;; *) echo "❌ テストの作業先が /tmp の外: $T" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fakebin" "$T/rec"
REC="$T/rec"; export REC

P=0; N=0
say_ok(){ P=$((P+1)); printf '  ✅ %s\n' "$1"; }
say_ng(){ N=$((N+1)); printf '  ❌ %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      → %s\n' "$2"; fi; }
has(){ case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_in(){     if has "$1" "$2"; then say_ok "$3"; else say_ng "$3" "$(printf '%s' "$2" | tr '\n' '|' | cut -c1-240)"; fi; }
want_not_in(){ if has "$1" "$2"; then say_ng "$3" "$(printf '%s' "$2" | tr '\n' '|' | cut -c1-240)"; else say_ok "$3"; fi; }
want_eq(){     if [ "$1" = "$2" ]; then say_ok "$3"; else say_ng "$3" "実際=[$1] 期待=[$2]"; fi; }

# --- curl のスタブ（固定HTMLを返す。HTTPコード・curl終了コードは環境変数で操れる）---
cat > "$T/fakebin/curl" <<'CURLEOF'
#!/usr/bin/env bash
out=""; prev=""; url=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
[ -n "$out" ] && cp "$HP_FIXTURE" "$out"
printf '%s\t%s\t%s\t0.123' "${HP_CODE:-200}" "${HP_FINAL:-$url}" "$(wc -c < "$HP_FIXTURE")"
exit "${HP_CURL_EXIT:-0}"
CURLEOF
chmod +x "$T/fakebin/curl"

cat > "$T/page.html" <<'HTMLEOF'
<!DOCTYPE html><html lang="ja"><head>
<title>架空工務店｜注文住宅</title>
<meta name="description" content="架空県で注文住宅を手がける架空工務店です。設計から施工まで一貫して承ります。地域密着で30年の実績。">
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
<link rel="canonical" href="https://example.test/">
<meta property="og:title" content="架空工務店"><meta property="og:image" content="https://example.test/og.png">
<meta name="twitter:card" content="summary">
<script type="application/ld+json">{"@type":"LocalBusiness","name":"架空工務店"}</script>
<script type="application/ld+json">{ こわれたJSON </script>
<meta name="generator" content="WordPress 6.5">
</head><body>
<h1>注文住宅</h1><h1>二つ目のH1</h1>
<h2>施工事例</h2><h2>料金</h2><h3>坪単価</h3>
<img src="/a.png" alt="外観"><img src="/b.png"><img src="/c.png">
<a href="/contact/">お問い合わせ</a><a href="tel:0120-000-000">電話</a>
<a href="mailto:info@example.test">メール</a><a href="https://line.me/R/ti/p/@x">LINE</a>
<form action="/contact/"><input name="n"></form>
</body></html>
HTMLEOF
printf '' > "$T/empty.html"

audit(){ # audit <fixture> <追加env...> -- <引数...>
  local fx="$1"; shift
  OUT="$(HP_FIXTURE="$T/$fx" PATH="$T/fakebin:$PATH" env "$@" bash "$PROJ/bin/hp-audit.sh" \
         https://example.test/ --json 2>&1 </dev/null)"; RC=$?
}
raw(){ OUT="$(HP_FIXTURE="$T/page.html" PATH="$T/fakebin:$PATH" bash "$PROJ/bin/hp-audit.sh" "$@" 2>&1 </dev/null)"; RC=$?; }
# JSON からキーを辿って1つの値を出す（eval は使わない：辿り方だけを受け取る）
jq_(){ printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)
' "$@" 2>/dev/null; }
jq_len(){ printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[int(k)] if isinstance(d, list) else d[k]
print(len(d))
' "$@" 2>/dev/null; }

echo "=== hp-audit: 入口の検証（読み取り専用ツールの境界）==="
raw
want_eq "$RC" "1" "URL 無しは使い方を出して終了コード1"
want_in "使い方" "$OUT" "使い方を出す"
raw https://example.test/ --nosuch
want_eq "$RC" "1" "不明なオプションを弾く"
raw https://a.example.test/ https://b.example.test/
want_eq "$RC" "1" "URL の複数指定を弾く（どちらを見たか分からない結果を作らない）"
for u in "file:///etc/passwd" "ftp://example.test/" "example.test"; do
  raw "$u"
  if [ "$RC" -eq 1 ]; then say_ok "★$u を弾く（HTTP GET のみ）"; else say_ng "$u を弾く" "rc=$RC"; fi
done
raw https://example.test/ --match=x
want_eq "$RC" "1" "--match は --links と併用でなければ弾く"
raw https://example.test/ --links --match=contact
want_eq "$RC" "0" "--links との併用は通る"
want_in "/contact/" "$OUT" "--match で絞った内部リンクを出す"
raw https://example.test/ --text
want_in "注文住宅" "$OUT" "--text は本文テキストを出す"
want_not_in "<h1>" "$OUT" "--text はタグを出さない"

echo
echo "=== hp-audit: 構造シグナルの抽出（固定HTML）==="
audit page.html --
want_eq "$RC" "0" "取得できたら終了コード0"
want_eq "$(jq_ fetch_ok)" "True" "fetch_ok=true"
want_eq "$(jq_ http_code)" "200" "HTTPコードを記録"
want_eq "$(jq_ title_len)" "10" "title の文字数（全角を1字と数える）"
want_eq "$(jq_ description_len)" "50" "description の文字数"
want_eq "$(jq_ cms)" "WordPress 6.5" "generator から CMS とバージョンを拾う"
want_in "https://example.test/" "$(jq_ canonical)" "canonical を拾う"
want_eq "$(jq_ headings h1)" "2" "h1 の数"
want_eq "$(jq_ headings h2)" "2" "h2 の数"
want_eq "$(jq_ images no_alt)" "2" "alt 欠落の画像数"
want_eq "$(jq_ links tel)" "1" "電話リンク"
want_eq "$(jq_ links contact)" "1" "問い合わせ導線"
want_eq "$(jq_ cv line_present)" "True" "LINE 導線の有無"
want_eq "$(jq_ cv form_count)" "1" "フォーム数"
want_in "0120-000-000" "$(jq_ cv tel_numbers)" "電話番号を抽出"
want_eq "$(jq_len ogp)" "2" "OGP の項目数"
want_eq "$(jq_len twitter)" "1" "Twitter カードの項目数"
want_eq "$(jq_ jsonld 0 parse_ok)" "True" "妥当な JSON-LD は parse_ok"
want_eq "$(jq_ jsonld 1 parse_ok)" "False" "★壊れた JSON-LD を『あることにしない』"
want_in "LocalBusiness" "$(jq_ jsonld 0 types)" "構造化データの型を拾う"

echo
echo "--- 課題（issues）として言語化する ---"
iss="$(jq_ issues)"
want_in "ズーム禁止" "$iss" "viewport のズーム禁止を課題にする（アクセシビリティ）"
want_in "h1 が複数" "$iss" "h1 の重複を課題にする"
want_in "alt欠落" "$iss" "alt 欠落を課題にする"
want_in "JSON-LD のパースに失敗" "$iss" "壊れた構造化データを課題にする"

echo
echo "=== hp-audit: ★取れなかったものを取れたことにしない ==="
audit page.html HP_CODE=404
want_eq "$RC" "3" "404 は終了コード3"
want_eq "$(jq_ fetch_ok)" "False" "404 を fetch_ok=true にしない"
audit page.html HP_CODE=500
want_eq "$RC" "3" "500 も終了コード3"
audit page.html HP_CURL_EXIT=28
want_eq "$RC" "3" "curl がタイムアウトしたら終了コード3"
want_eq "$(jq_ fetch_ok)" "False" "タイムアウトを成功にしない"
want_eq "$(jq_ curl_exit)" "28" "curl の終了コードを記録する（原因の切り分け用）"
audit empty.html --
want_eq "$RC" "3" "本文が空なら終了コード3（0バイトを『問題なし』にしない）"
want_eq "$(jq_ fetch_ok)" "False" "空ボディを成功にしない"
audit page.html HP_FINAL=https://example.test/ja/
want_eq "$(jq_ final_url)" "https://example.test/ja/" "リダイレクト後のURLを記録する"

echo
echo "=== hp-compete: 比較とギャップ抽出 ==="
py_out="$(python3 - "$PROJ" "$T" <<'PYEOF'
import contextlib, importlib.util, io, json, os, stat, sys
from pathlib import Path
proj, T = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("hpcompete", proj / "bin/hp-compete.py")
hc = importlib.util.module_from_spec(spec); spec.loader.exec_module(hc)

P = N = 0
def ok(m, d=""):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

print("  --- 判定の部品 ---")
(ok if hc.in_range(20, 10, 35) else ng)("範囲内は True")
(ok if not hc.in_range(9, 10, 35) else ng)("下限未満は False")
(ok if not hc.in_range(36, 10, 35) else ng)("上限超過は False")
(ok if hc.in_range(10, 10, 35) and hc.in_range(35, 10, 35) else ng)("両端は範囲内")
(ok if not hc.in_range(None, 10, 35) else ng)("None は False（欠測を『適正』にしない）")
(ok if not hc.in_range("20", 10, 35) else ng)("文字列は False（型で守る）")
(ok if hc.label("u", 0) == "自社" and hc.label("u", 2) == "競合2" else ng)("並びのラベル")
(ok if hc.jsonld_types({"jsonld": [{"types": ["A", "B"]}, {"types": ["A"]}]}) == ["A", "B", "A"]
   else ng)("構造化データ型を平らに集める")
(ok if hc.jsonld_types({}) == [] else ng)("jsonld が無くても落ちない")
(ok if hc.jsonld_types({"jsonld": [{"types": [1]}]}) == ["1"] else ng)("型が文字列でなくても落ちない")

print("  --- 指標のまとめ方 ---")
d = {"http_code": 200, "cms": "WordPress", "size_bytes": "2048", "title_len": 20,
     "description_len": 80, "canonical": ["https://x/"],
     "ogp": {"og:title": 1}, "twitter": {},
     "jsonld": [{"types": ["A"], "parse_ok": True, "looks_disabled": False},
                {"types": ["B"], "parse_ok": False, "looks_disabled": False},
                {"types": ["C"], "parse_ok": True, "looks_disabled": True}],
     "headings": {"h1": 1, "h2": 4, "h3": 3}, "links": {"total": 40},
     "images": {"no_alt": 2},
     "cv": {"tel_numbers": ["0120"], "line_present": False, "form_count": 1,
            "cv_anchors": [{"text": "問い合わせ"}]},
     "issues": ["a", "b"]}
m = hc.metrics(d)
(ok if m["jsonld"] == 1 else ng)("★壊れた/無効化された構造化データを『有効』に数えない", m["jsonld"])
(ok if m["jsonld_types"] == ["A", "B", "C"] else ng)("型の一覧は重複を畳んで並べる", m["jsonld_types"])
(ok if m["size_kb"] == 2 else ng)("バイト数を KB へ丸める", m["size_kb"])
(ok if hc.metrics({**d, "size_bytes": "不明"})["size_kb"] == 0 else ng)("数値でない容量は 0（落ちない）")
(ok if m["sections"] == 7 else ng)("コンテンツの厚み＝h2+h3", m["sections"])
(ok if m["canonical"] is True and m["twitter"] == 0 else ng)("有無は真偽・個数は数で持つ")
(ok if hc.metrics({})["sections"] == 0 else ng)("空の監査結果でも落ちない")

print("  --- ギャップ（競合が勝っている点＝施策候補）---")
def M(**kw):
    base = dict(jsonld=0, jsonld_types=[], title_len=20, desc_len=80, ogp=1, canonical=True,
                sections=6, line=False, forms=1, cv_anchors=1)
    base.update(kw); return base
g = hc.gaps(M(), M(jsonld=1, jsonld_types=["LocalBusiness"]))
(ok if any("構造化データ(JSON-LD)あり" in x for x in g) else ng)("競合だけ構造化データを持つ", g)
g = hc.gaps(M(jsonld=1, jsonld_types=["A"]), M(jsonld=2, jsonld_types=["A", "FAQPage"]))
(ok if any("FAQPage" in x for x in g) else ng)("自社に無い型だけを挙げる", g)
(ok if not any("自社は無し" in x for x in g) else ng)("既に持っている分は重ねて言わない")
g = hc.gaps(M(title_len=60), M(title_len=30))
(ok if any("title が適正長" in x for x in g) else ng)("title の長さ", g)
(ok if not hc.gaps(M(title_len=30), M(title_len=60)) else ng)(
    "★競合が範囲外・自社が適正なら『ギャップ』にしない（逆向きに出さない）")
g = hc.gaps(M(desc_len=10), M(desc_len=100))
(ok if any("meta description が適正長" in x for x in g) else ng)("description の長さ", g)
(ok if any("OGP あり" in x for x in hc.gaps(M(ogp=0), M(ogp=3))) else ng)("OGP の有無")
(ok if any("canonical" in x for x in hc.gaps(M(canonical=False), M(canonical=True))) else ng)("canonical の有無")
(ok if any("コンテンツが厚い" in x for x in hc.gaps(M(sections=2), M(sections=8))) else ng)(
    "見出しセクション数の有意差")
(ok if not hc.gaps(M(sections=6), M(sections=7)) else ng)(
    "★わずかな差は『厚い』と言わない（1.5倍かつ8以上を有意差とする）")
(ok if not hc.gaps(M(sections=0), M(sections=7)) else ng)("自社0でも8未満なら騒がない（下限8）")
(ok if any("LINE導線" in x for x in hc.gaps(M(line=False), M(line=True))) else ng)("LINE 導線")
(ok if any("フォーム数" in x for x in hc.gaps(M(forms=1), M(forms=3))) else ng)("フォーム数")
(ok if any("CV導線アンカー" in x for x in hc.gaps(M(cv_anchors=1), M(cv_anchors=4))) else ng)("CV導線の多さ")
(ok if not hc.gaps(M(cv_anchors=1), M(cv_anchors=3)) else ng)("差が3未満なら騒がない")
(ok if hc.gaps(M(), M()) == [] else ng)("互角なら空（無理に施策をひねり出さない）")
(ok if hc.gaps(M(jsonld=2, jsonld_types=["A"], sections=20, line=True, forms=9, cv_anchors=9), M()) == []
   else ng)("★自社が全面的に勝っていても空（自社優位を『伸びしろ』と誤報しない）")
a, b = M(), M(jsonld=1, jsonld_types=["X"], line=True)
(ok if hc.gaps(a, b) == hc.gaps(a, b) else ng)("同じ入力なら同じ結果（決定論）")

print("  --- hp-audit の呼び出し（失敗を握りつぶさない）---")
def fake_audit(body, rc=0):
    p = T / "fake-hp-audit.sh"
    p.write_text("#!/usr/bin/env bash\ncat <<'X'\n%s\nX\nexit %d\n" % (body, rc), encoding="utf-8")
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    hc.HP_AUDIT = str(p)

fake_audit('{"url":"https://example.test/","fetch_ok":true,"title_len":20}')
r = hc.audit("https://example.test/")
(ok if r.get("fetch_ok") is True else ng)("正常な JSON をそのまま返す", r)
fake_audit('{"url":"https://example.test/","fetch_ok":false,"error":"取得失敗"}', rc=3)
r = hc.audit("https://example.test/")
# 「fetch_ok が False」だけを見ると、JSON を捨てて自前のエラー dict を返す実装でも通ってしまう。
# **hp-audit 自身が書いた error 文言が残っているか**まで見る（監査不能の理由を握りつぶさない）。
(ok if r.get("fetch_ok") is False and r.get("error") == "取得失敗" else ng)(
    "★exit 3 でも hp-audit の JSON を読む（監査不能の理由を捨てない）", r)
fake_audit("これはJSONではありません")
r = hc.audit("https://example.test/")
(ok if r["fetch_ok"] is False and "JSON 解析失敗" in r["error"] else ng)("壊れた出力は失敗として扱う", r)
fake_audit("", rc=1)
r = hc.audit("https://example.test/")
(ok if r["fetch_ok"] is False and "出力なし" in r["error"] else ng)("空の出力も失敗として扱う", r)
hc.HP_AUDIT = str(T / "no-such-tool.sh")
r = hc.audit("https://example.test/")
(ok if r["fetch_ok"] is False and "見つからない" in r["error"] else ng)("hp-audit が無いことを黙らない", r)

print(f"###COUNT {P} {N}")
PYEOF
)"
printf '%s\n' "$py_out" | grep -v '^###COUNT'
pn="$(printf '%s' "$py_out" | sed -n 's/^###COUNT \([0-9]*\) \([0-9]*\)$/\1 \2/p')"
if [ -n "$pn" ]; then P=$((P + ${pn%% *})); N=$((N + ${pn##* })); else say_ng "hp-compete の python ブロックが最後まで走らなかった"; fi

echo
echo "--- hp-compete 全体：比較の基準が無ければ失敗と言う ---"
cat > "$T/fake-audit-fail.sh" <<'FEOF'
#!/usr/bin/env bash
echo '{"url":"x","fetch_ok":false,"error":"取得失敗"}'
exit 3
FEOF
chmod +x "$T/fake-audit-fail.sh"
python3 - "$PROJ" "$T" <<'PYEOF' > "$T/compete-out.txt" 2>&1
import subprocess, sys, textwrap
from pathlib import Path
proj, T = Path(sys.argv[1]), Path(sys.argv[2])
src = (proj / "bin/hp-compete.py").read_text(encoding="utf-8")
# HP_AUDIT だけを偽物に差し替えた複製を作って main() を丸ごと回す（本体は書き換えない）
patched = src.replace("HP_AUDIT = os.path.join(BIN_DIR, 'hp-audit.sh')",
                      "HP_AUDIT = %r" % str(T / "fake-audit-fail.sh"))
(T / "compete_copy.py").write_text(patched, encoding="utf-8")
r = subprocess.run([sys.executable, str(T / "compete_copy.py"),
                    "https://self.example.test/", "https://rival.example.test/"],
                   capture_output=True, text=True, timeout=60)
print("RC=%d" % r.returncode)
print(r.stdout)
PYEOF
cout="$(cat "$T/compete-out.txt")"
want_in "RC=3" "$cout" "★自社の取得に失敗したら終了コード3（比較したふりをしない）"
want_in "自社サイトの取得に失敗" "$cout" "理由を言う"
want_in "⛔" "$cout" "失敗を目立たせる"

echo
echo "=== node 解決ラッパ（cron の空環境で無言停止しないこと）==="
cat > "$T/fakebin/node" <<'NODEEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/nodeargs"
NODEEOF
chmod +x "$T/fakebin/node"
for w in hp-shot hp-serp; do
  rm -f "$REC/nodeargs"
  PATH="$T/fakebin:$PATH" bash "$PROJ/bin/$w.sh" "第 一 引数" --flag v >/dev/null 2>&1
  first="$(sed -n '1p' "$REC/nodeargs" 2>/dev/null)"
  want_eq "$first" "$PROJ/bin/$w.mjs" "$w.sh は自分の .mjs を起動する（コピペ違いをしない）"
  rest="$(sed -n '2,$p' "$REC/nodeargs" 2>/dev/null | tr '\n' '|')"
  want_eq "$rest" "第 一 引数|--flag|v|" "$w.sh は引数を分割せずそのまま渡す（空白を含む値）"
done
# ★本命：PATH に node が無い cron 相当の環境。nvm から解決できず 127 で死ぬと解析ループが無言停止する。
for w in hp-shot hp-serp; do
  out="$(env -i HOME="$HOME" PATH=/usr/bin:/bin timeout 30 bash "$PROJ/bin/$w.sh" 2>&1)"; rc=$?
  if [ "$rc" -eq 127 ]; then
    say_ng "★$w.sh: PATH に node が無い空環境でも起動できる" "exit 127（node を解決できていない）"
  elif has "usage" "$out"; then
    say_ok "★$w.sh: PATH に node が無い空環境でも node を解決して起動できる"
  else
    say_ng "★$w.sh: 空環境での起動" "rc=$rc out=$(printf '%s' "$out" | head -1)"
  fi
done

echo
printf '合計: 合格 %s ／ 不合格 %s\n' "$P" "$N"
[ "$N" -eq 0 ] || exit 1
