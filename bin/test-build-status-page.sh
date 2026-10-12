#!/usr/bin/env bash
# test-build-status-page.sh ── bin/build-status-page.py の回帰テスト
#
# なぜ要るか（rules/testing.md §2）：cron で毎日動き・ファイルを書き・**判定ロジック（誘導）**を持つ。
# とくに見張るのは「根拠のない誘導を出さないこと」と「合図が無いときに黙って空にしないこと」。
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
# 第2引数＝「何が困るか」。落ちた行だけ見て直せるようにする
ng() { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; [ -n "${2:-}" ] && printf '       → %s\n' "$2"; return 0; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

echo "── §1 誘導の判定（judgment だけを直接叩く）"
# ★旧：`if [ $? -eq 0 ]; then PASS=$((PASS+10))` と**件数を手で書いて**いた。python 側の chk は
#   NG を印字するだけで終了コードを変えないため、**中で落ちても合計は「不合格 0」**だった
#   （K-952 と同じ形＝落ちているのに緑に見える）。__R__ 行から実際の件数を取り込む。
SEC1="$(python3 - "$PROJ" <<'PYX'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1] + "/bin/build-status-page.py")
bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
P = N = 0
def chk(c, m):
    global P, N
    if c: P += 1; print(f"  ok   {m}")
    else: N += 1; print(f"  NG   {m}")

empty = {"accumulators": [], "mailbox": [], "decisions": [], "desks": []}
g = bs.guidance(empty, 0)
chk(len(g) == 1 and "合図なし" in g[0][1], "合図が無いときは黙って空にせず「合図なし」と言う")

g = bs.guidance(empty, 1)
chk(any(d == "/board" for d, _, _ in g), "board-brief が exit 1 なら /board へ誘導する")
g = bs.guidance(empty, 2)
chk(any("異常終了" in w for _, w, _ in g), "exit 2（故障）を「期日が来た」と混ぜない")

d = dict(empty, accumulators=[
    {"flag": "🔴", "path": "data/x/big.md", "ratio": 7.8, "per_week": 82 * 1024},
    {"flag": "🔴", "path": "data/x/small.md", "ratio": 1.1, "per_week": 2 * 1024},
    {"flag": "🟡", "path": "data/x/flat.md", "ratio": 3.0, "per_week": -1},
])
g = bs.guidance(d, 0)
why = [w for _, w, _ in g]
chk(any("big.md" in w and "7.8倍" in w and "+82KB" in w for w in why),
    "いちばん増えている器を、上限比と週あたりの実測つきで名指しする")
chk(not any("flat.md" in w for w in why), "🟡（超過だが横ばい）では誘導しない＝鳴りっぱなしにしない")

d = dict(empty, mailbox=[{"to": "lane-a", "box": "new", "count": 3, "oldest": 48},
                         {"to": "lane-b", "box": "new", "count": 1, "oldest": 2}])
why = [w for _, w, _ in bs.guidance(d, 0)]
chk(any("lane-a" in w and "48日" in w for w in why), "7日以上の滞留を最古のものから名指しする")
chk(not any("lane-b" in w for w in why), "数日の滞留では誘導しない")

d = dict(empty, desks=[{"desk": "finance", "what": "経理", "last": None, "days": None},
                       {"desk": "board", "what": "方向", "last": "2026-09-01", "days": 20},
                       {"desk": "triage", "what": "窓口", "last": "2026-09-12", "days": 1}])
why = [w for _, w, _ in bs.guidance(d, 0)]
chk(any("一度も開いていません" in w for w in why), "一度も開いていない窓口を出す")
chk(any("20日 開いていません" in w for w in why), "長く開いていない窓口を出す（14日以上）")
chk(not any("窓口" == w for w in why), "最近開いた窓口では誘導しない")

# ★ledger-watch は対応表やセッションログが読めないとき、推定値を出さずに空の一覧と
#   desks_error を返す（fail-closed）。ここで読まないと「窓口0件＝合図なし（健全）」と
#   描かれて、作った安全装置が沈黙に化ける（2026-10-12・Codex🔴 2回目）。
d = dict(empty, desks=[], desks_error="窓口の対応表を読めません＝窓口の最終利用日は判定できません")
g = bs.guidance(d, 0)
why = [w for _, w, _ in g]
chk(any("判定できません" in w for w in why), "★窓口を判定できなかったことを誘導に出す")
chk(not any("合図なし" in w for w in why), "★判定できなかったときに「合図なし（健全）」と言わない")
chk(g[0][2] == "red", "★判定不能は赤で出す")
# ★「最優先」はコメントだけでは守れない。他の合図が全部あるときに**先頭そのもの**が
#   判定不能であることを見る（旧テストは他の合図が無い入力で色だけ見ていた＝Codex🔴 3回目）。
busy = {"accumulators": [{"flag": "🔴", "path": "data/x/big.md", "ratio": 7.8, "per_week": 82 * 1024}],
        "mailbox": [{"to": "lane-a", "oldest": 48}], "decisions": [],
        "desks": [], "desks_error": "窓口の対応表を読めません"}
g = bs.guidance(busy, 1)                     # board の期日・器の🔴・便の滞留も同時にある
chk("判定できません" in g[0][1], f"★他の合図が全部あっても判定不能が先頭に来る（実際の先頭={g[0][1][:24]}）")

# ★判定不能の窓口（未来の日時・stat 失敗で日付を落とした分）を「一度も開いていません」と
#   誘導しない。社長がいま使っている窓口を未使用と呼ぶ経路になる（Codex🔴 3回目）。
d = dict(empty, desks=[{"desk": "product", "what": "サービス改善", "last": None, "days": None,
                        "status": "unknown"},
                       {"desk": "intake", "what": "取り込み", "last": None, "days": None,
                        "status": "never"}])
why = [w for _, w, _ in bs.guidance(d, 0)]
chk(any("product" in n for n, _, _ in bs.guidance(d, 0)), "判定不能の窓口も行として出す")
chk(not any("product" in n and "一度も開いていません" in w for n, w, _ in bs.guidance(d, 0)),
    "★status=unknown の窓口を「一度も開いていません」と誘導しない")
chk(any("intake" in n and "一度も開いていません" in w for n, w, _ in bs.guidance(d, 0)),
    "status=never の窓口はこれまで通り「一度も開いていません」と誘導する")
d2 = dict(empty, desks=[{"desk": "dev", "what": "開発", "last": "2026-10-12", "days": 0}],
          desks_error="一部を判定できません＝未来の日時のログ 1本")
why2 = [w for _, w, _ in bs.guidance(d2, 0)]
chk(any("判定できません" in w for w in why2), "一部だけ判定できないときも申告する（日付が出ていても黙らない）")
print(f"__R__ {P} {N}")
PYX


)"
printf '%s\n' "$SEC1" | grep -v '^__R__'
R1="$(printf '%s\n' "$SEC1" | sed -n 's/^__R__ //p')"
if [ -n "$R1" ]; then
  PASS=$((PASS + ${R1% *})); FAIL=$((FAIL + ${R1#* }))
else
  ng "§1 が合計行を出さずに終わった" "例外で落ちると0項目として数えられる（K-952）"
fi

echo "── §2 生成物（本番の site/ を汚さない＝生成先を確認するだけ）"
grep -q 'OUT = os.path.join(ROOT, "site/business/status.html")' "$PROJ/bin/build-status-page.py" \
  && ok "生成先が site/business/status.html に固定されている" || ng "生成先が変わっている"
grep -q 'ledger-watch.py' "$PROJ/bin/build-status-page.py" \
  && ok "数字の正は ledger-watch（ページ側で集計し直さない）" || ng "独自集計をしている疑い"
grep -q -- '--no-api' "$PROJ/bin/build-status-page.py" \
  && ok "board-brief を --no-api で叩く（毎日 cron なので外部APIを使わない）" || ng "外部APIを叩いている"

echo "── §2.5 生成したHTML（配線を通す・本番の site/ は書き換えない）"
# ★§1 は guidance() を直接叩くだけ＝**表のHTMLを作る部分を1行も通っていない**（Codex🟡）。
#   判定不能の行は表側にも足したので、入力を差し替えて生成物まで見る。
SEC25="$(python3 - "$PROJ" "$TMPD" <<'PYH'
import importlib.util, json, sys, os
spec = importlib.util.spec_from_file_location("bs", sys.argv[1] + "/bin/build-status-page.py")
bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
P = N = 0
def chk(c, m):
    global P, N
    if c: P += 1; print(f"  ok   {m}")
    else: N += 1; print(f"  NG   {m}")

out = os.path.join(sys.argv[2], "status.html")
bs.OUT = out                                  # 本番の site/business/status.html を書き換えない
data = {"generated": "2026-10-12T00:00:00+09:00", "since": "2026-07-24", "snapshots": 1,
        "accumulators": [], "mailbox": [], "pickups": [], "decisions": [],
        "desks": [{"desk": "product", "what": "サービス改善", "last": None, "days": None,
                   "how": None, "status": "unknown"}],
        "desks_error": "一部を判定できません＝未来の日時のログ 1本 <script>x</script>",
        "unreadable": 0, "threshold_error": None}
bs.run = lambda cmd, timeout=600: (0, json.dumps(data, ensure_ascii=False))
bs.build()
h = open(out, encoding="utf-8").read()
chk("判定できません" in h, "判定不能が生成したHTMLに出る（表と誘導の配線が通っている）")
chk("判定不能" in h, "窓口の表に「判定不能」の字が出る（空の表にしない）")
chk("一度も開いていません" not in h, "status=unknown を「一度も開いていません」と書かない")
chk("<script>x</script>" not in h and "&lt;script&gt;" in h, "エラー文字列を HTML エスケープする")
print(f"__R__ {P} {N}")
PYH
)"
printf '%s\n' "$SEC25" | grep -v '^__R__'
R25="$(printf '%s\n' "$SEC25" | sed -n 's/^__R__ //p')"
if [ -n "$R25" ]; then
  PASS=$((PASS + ${R25% *})); FAIL=$((FAIL + ${R25#* }))
else
  ng "§2.5 が合計行を出さずに終わった" "例外で落ちると0項目として数えられる（K-952）"
fi

echo "── §3 実際に生成されたページ（本番）"
F="$PROJ/site/business/status.html"
if [ -f "$F" ]; then
  ok "ページが存在する"
  grep -q 'いま開くべき窓口' "$F" && ok "誘導が先頭にある（数字の羅列にしない）" || ng "誘導の節が無い"
  grep -qE 'よしだ歯科|滋賀トヨタ|樋口|渡邉' "$F" && ng "取引先名・実名が載っている" || ok "取引先名・実名を出していない"
  grep -qiE '(token|secret|password)[^<]{0,8}[=:][^<]{0,4}[A-Za-z0-9_-]{16,}' "$F" && ng "秘密値が載っている" || ok "秘密値を出していない"
  grep -q '判断をしません' "$F" && ok "「このページは判断しない」と明記している" || ng "判断しない旨が無い"
else ng "ページが生成されていない"; fi

echo "── §4 結線（作ったのに繋いでいない、を防ぐ）"
grep -q 'business/status.html' "$PROJ/site/office/index.html" \
  && ok "ダッシュボード（3Dオフィス）のメニューから辿れる" || ng "どこからも辿れない"
crontab -l 2>/dev/null | grep -q 'build-status-page.py' \
  && ok "cron に登録されている（毎日更新される）" || ng "cron に無い＝古いページが残り続ける"

echo
echo "合計: 合格 ${PASS} ／ 不合格 ${FAIL}"
[ "$FAIL" -eq 0 ]
