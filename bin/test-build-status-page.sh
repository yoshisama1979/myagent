#!/usr/bin/env bash
# test-build-status-page.sh ── bin/build-status-page.py の回帰テスト
#
# なぜ要るか（rules/testing.md §2）：cron で毎日動き・ファイルを書き・**判定ロジック（誘導）**を持つ。
# とくに見張るのは「根拠のない誘導を出さないこと」と「合図が無いときに黙って空にしないこと」。
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; }

echo "── §1 誘導の判定（judgment だけを直接叩く）"
python3 - "$PROJ" <<'PYX'
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
print(f"__R__ {P} {N}")
PYX
if [ $? -eq 0 ]; then PASS=$((PASS+10)); else FAIL=$((FAIL+1)); fi

echo "── §2 生成物（本番の site/ を汚さない＝生成先を確認するだけ）"
grep -q 'OUT = os.path.join(ROOT, "site/business/status.html")' "$PROJ/bin/build-status-page.py" \
  && ok "生成先が site/business/status.html に固定されている" || ng "生成先が変わっている"
grep -q 'ledger-watch.py' "$PROJ/bin/build-status-page.py" \
  && ok "数字の正は ledger-watch（ページ側で集計し直さない）" || ng "独自集計をしている疑い"
grep -q -- '--no-api' "$PROJ/bin/build-status-page.py" \
  && ok "board-brief を --no-api で叩く（毎日 cron なので外部APIを使わない）" || ng "外部APIを叩いている"

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
