#!/usr/bin/env bash
# ルール文面の整合の回帰テスト（bin/guard-unattended-edits.py・bin/kaizen.py と対で読む）。
#
# 契機＝2026-09-27 社長ご承認のルール改訂6件のうち ②（O-079）と ⑥。2つとも同じ型の欠陥だった：
#   ② rules/modes/overseer.md Step 0-4 が「from-president.md に反映済みと書き添える」と命じていたが、
#      guard-unattended-edits.py が無人セッションのその書き込みを**物理的に拒否**する。
#      規定から10日、誰も実行できない手順が残っていた（同型が rules/modes/hp-loop.md にもあった）。
#   ⑥ data/hp-improve/skill-kaizen.md を 2026-09-20 に道しるべへ畳んだのに、9本以上が今も旧の器へ
#      「記録せよ」と命じていた。道具側（kaizen.py lint）は止めるが、指示が残る限り毎サイクルぶつかる。
#
# ここで固定するのは「ルールの文面が、機械が拒否する場所・畳んだ器を指していないこと」。
# 文面は人が書くので、同じ食い違いが二度入らないようにするのはテスト側の仕事（rules/testing.md）。
# 触ったら必ず流すこと：bash bin/test-rules-consistency.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/guard-unattended-edits.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import glob, importlib.util, os, re, sys
from pathlib import Path

proj = Path(sys.argv[1])
# ゲート対象の判定は **guard 本体に聞く**（表を二重に持たない）
spec = importlib.util.spec_from_file_location("guard", proj / "bin/guard-unattended-edits.py")
guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)

P = N = 0
def ok(m):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

# 走査対象＝**実際に読まれる指示ファイル全部**（部分だけ見て「どのルールも」と言わない＝Codex 指摘）
RULES = sorted(glob.glob(str(proj / "rules/modes/*.md"))) + \
        sorted(glob.glob(str(proj / "rules/*.md"))) + \
        sorted(glob.glob(str(proj / ".claude/commands/*.md"))) + \
        sorted(glob.glob(str(proj / ".claude/rules/*.md"))) + \
        [str(proj / f) for f in ("CLAUDE.md", "SYSTEM.md", "OVERVIEW.md") if (proj / f).exists()]
def rel(p): return os.path.relpath(p, proj)

HIST = re.compile(r"^\|\s*\d+\.\d+\s*\|\s*20\d\d-\d\d-\d\d")   # 改訂履歴の行＝過去の事実なので直さない
# 「AI がそこへ**印を書く**」と読める言い方だけを拾う。ファイル名が出てくるだけの行
# （「社長のみ書く・AIは読むだけ」「from-president.md の未対応項目を反映」等）は違反ではない。
# 緩くすると毎回赤くなり、赤が赤として働かなくなる（ledger-discipline §2）。
MARK = ("反映済み", "書き添え", "済み印", "処理済みと", "印を付", "対応：Cycle",
        "に追記", "へ追記", "末尾へ", "に書き足", "に記入", "へ記入", "に書き込", "へ書き込",
        "を更新し", "に印", "へ印")
NOT_A_WRITE = ("社長のみ", "読むだけ", "読み取り専用", "❌", "不可", "社長が書く", "社長が追記",
               "書き込まない")   # ←「そこには書かない」と明言している行（②の改訂後の文面）
RETIRED = "data/hp-improve/skill-kaizen.md"

# 「そこへ書いてよい」ファイル＝**有人だけが動かす代筆の経路**（guard は有人には効かない）。
# ここに足すときは理由を書くこと。黙って増えたら、この試験は何も守らなくなる。
HUMAN_ONLY = {
    ".claude/commands/hp-reply.md": "社長のコメントを代筆追記する専用コマンド（有人のみ・追記だけ）",
    ".claude/commands/chat.md":     "Slack の会話を溜める有人コマンド（代筆追記）",
    "rules/modes/triage.md":        "第1窓口＝有人。社長の回答を各レーンへ書き戻すのが仕事",
    ".claude/commands/triage.md":   "同上（コマンド側の写し）",
}

NEAR = 60   # ファイル名からこの文字数の内に印を書く言い方があれば「そこへ書け」と読む

def gated_write_lines(path):
    """そのファイルの中で「AI がゲート対象の置き場へ印を書け」と読める行を返す。

    ⚠️ **これは地の文の検査なので完全ではない**（Codex 指摘 2026-09-27）。
      文面をいくら賢く読んでも、書き方を変えれば抜けられる。**最後の担保はフック本体**
      （`guard-unattended-edits.py` が実行時に拒否する）で、この検査は「10日間 誰も気づかなかった」を
      繰り返さないための**早期の合図**。だから緩めず・広げすぎず、Red の固定入力で働きを確かめる。
    """
    out = []
    for i, ln in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        if HIST.match(ln.strip()) or "from-president.md" not in ln:
            continue
        if any(x in ln for x in NOT_A_WRITE):
            continue
        for m in re.finditer(r"[\w./<>-]*from-president\.md", ln):
            cand = m.group(0).lstrip("`").lstrip()
            if not (guard.is_gated(cand) or guard.is_gated(cand.split("/")[-1])):
                continue
            near = ln[m.end(): m.end() + NEAR] + ln[max(0, m.start() - NEAR): m.start()]
            if any(x in near for x in MARK):
                out.append((i, ln.strip()[:120]))
                break
    return out


print("=== ② ガードが止める場所に手順を書いていない（O-079・2026-09-27 改訂）===")
bad = []
for p in RULES:
    r = rel(p)
    hits = gated_write_lines(p)
    if hits and r not in HUMAN_ONLY:
        bad += [f"{r}:{i} {t}" for i, t in hits]
if bad:
    ng(f"ゲート対象への書き込みを指示しているルールがある（{len(bad)}件）", "／".join(bad[:3]))
else:
    ok(f"どのルールも from-president.md への書き込みを無人に命じていない（例外{len(HUMAN_ONLY)}件は有人の代筆）")
# 例外が実在すること＝綴りが変わって「例外が空回り」になっていないか
missing = [f for f in HUMAN_ONLY if not (proj / f).exists()]
(ok if not missing else ng)(f"有人の例外{len(HUMAN_ONLY)}件はすべて実在する" + (f"（欠け: {missing}）" if missing else ""))
# 🔴7-b：ファイル単位の免除は「その中に無人向けの命令が紛れても検査されない」＝**免除の根拠を中身で確かめる**。
#   代筆の経路であることを自分で名乗っていない免除は、免除として認めない。
weak = [f for f in HUMAN_ONLY
        if not any(x in (proj / f).read_text(encoding="utf-8")
                   for x in ("追記のみ", "代筆", "有人"))]
if weak:
    ng("免除したファイルは自分で「代筆／追記のみ／有人」と名乗っている", f"名乗っていない: {weak}")
else:
    ok("免除したファイルは自分で「代筆／追記のみ／有人」と名乗っている")

print("\n=== ⑥ 畳んだ器へ書けと指示していない（2026-09-20 に3層へ分割）===")
bad = []
for p in RULES:
    for i, ln in enumerate(open(p, encoding="utf-8").read().split("\n"), 1):
        if RETIRED in ln and not HIST.match(ln.strip()):
            bad.append(f"{rel(p)}:{i}")
if bad:
    ng(f"畳んだ器 {RETIRED} を今も指しているルールがある（{len(bad)}件）", "／".join(bad[:5]))
else:
    ok(f"どのルールも畳んだ器を指していない（改訂履歴の記述は対象外＝過去の事実）")

print("\n=== ④⑤ triage の起動時 必須2節（2026-09-27 新設）===")
tri = (proj / "rules/modes/triage.md").read_text(encoding="utf-8")
for head in ("### 起動時：前回以降の警報", "### 起動時：窓口別・社長がすべきこと"):
    (ok if head in tri else ng)(f"節がある（{head}）")
# 「0件でも出す」が両方の節に入っていること＝無言で省くと「静かなのか壊れたのか」が分からない
secs = [tri.split(h, 1)[1].split("\n### ", 1)[0] for h in
        ("### 起動時：前回以降の警報", "### 起動時：窓口別・社長がすべきこと") if h in tri]
(ok if len(secs) == 2 and all("0件" in x for x in secs) else ng)(
    "どちらの節も「0件なら0件と書く」を明記している")
(ok if len(secs) == 2 and "窓口の中身は開かない" in secs[1] else ng)(
    "窓口別の節は「窓口の中身は開かない」を明記している")
(ok if len(secs) == 2 and "社長でなければ" in secs[1] else ng)(
    "窓口別の節は「社長でなければできないものに限る」を明記している")
# 出典に挙げた機械が実在すること＝ルールが存在しない道具を指していないか
named = set(re.findall(r"bin/[\w.-]+\.(?:py|sh)", "".join(secs))) | \
        set(re.findall(r"data/[\w./<>-]+\.(?:jsonl|log)", "".join(secs)))
missing = sorted(n for n in named if "<" not in n and not (proj / n).exists())
(ok if named and not missing else ng)(
    f"出典に挙げた機械{len(named)}件はすべて実在する" + (f"（欠け: {missing}）" if missing else ""))
# ⑤ の解析の行が読む値は ledger-watch が持っていること（正を2つ持たない）
spec2 = importlib.util.spec_from_file_location("lw", proj / "bin/ledger-watch.py")
lw = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(lw)
(ok if callable(getattr(lw, "pickups", None)) else ng)(
    "「宛先が最後に取りに来た日」は ledger-watch.py が持つ（ルール側で数え直さない）")

print("\n=== 検査そのものが働くこと（Red の担保）===")
import tempfile
T = Path(tempfile.mkdtemp())
if not str(T).startswith("/tmp"):
    print(f"❌ テストの作業先が /tmp の外: {T}", file=sys.stderr); sys.exit(2)
f1 = T / "violation.md"
f1.write_text("4. 読んだ節に「反映済み YYYY-MM-DD」を書き添える（data/overseer/from-president.md）\n", encoding="utf-8")
(ok if gated_write_lines(f1) else ng)("ゲート対象への書き込み指示を見つけられる")
f2 = T / "hist.md"
f2.write_text("| 0.2 | 2026-06-08 | カイゼン台帳 `data/hp-improve/skill-kaizen.md` を運用開始 |\n", encoding="utf-8")
(ok if HIST.match(f2.read_text().strip()) else ng)("改訂履歴の行は対象外にできる")
f3 = T / "other-words.md"
f3.write_text("`data/partner/from-president.md` の該当節に「対応：Cycle 012」を記入する\n", encoding="utf-8")
(ok if gated_write_lines(f3) else ng)("別の言い方（記入する）でも見つけられる")
f4 = T / "far.md"
f4.write_text("`data/overseer/from-president.md` を読む。" + "あ" * 200 + "掲示板に反映済みと残す\n",
              encoding="utf-8")
(ok if not gated_write_lines(f4) else ng)("離れた場所の「反映済み」は違反にしない（鳴りっぱなしにしない）")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
