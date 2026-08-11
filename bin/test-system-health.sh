#!/usr/bin/env bash
# system-health.py（毎日 cron・警報の元）の回帰テスト。
#
# 契機＝2026-08-11 O-035。skill-kaizen 台帳が 251KB へ再肥大し、真因は
# 「K-405・K-422 の2エントリが後続の気づき114件を箇条書きで飲み込んでいた」こと。
# 同型は O-019（K-330 が97件を飲み込み169KB）で一度起きており、**2回とも数週間気づけなかった**。
# 理由＝台帳ルールは「気づきは独立見出し ### K-NNN で足す」と宣言していたが機械の担保が無く、
# サイズ閾値は「合計」しか見ないため 1本が台帳の6割を占める形の異常をすり抜けた。
# ここで固定するのは entry_shape()／shape_warnings()＝その「形の異常」の判定ロジック。
#
# ⚠️ 現状このスイートは形の判定だけを覆う（メモリ・故障集計・ローテは未カバー＝rules/testing.md §7 の🟡は据え置き）。
# 触ったら必ず流すこと：bash bin/test-system-health.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/system-health.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import importlib.util, os, sys, tempfile
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("sh", proj / "bin/system-health.py")
sh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sh)

P = N = 0
def ok(m):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

# 本番のファイルに触れない（testing.md §6-1）。読み取り専用の関数だが ROOT ごと隔離する
T = Path(tempfile.mkdtemp())
sh.ROOT = str(T)
if not str(T).startswith("/tmp"):
    print(f"❌ テストの作業先が /tmp の外: {T}", file=sys.stderr); sys.exit(2)

def write(name, text):
    p = T / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    return name

def warns_for(text):
    n = write("ledger.md", text)
    return sh.shape_warnings(sh.entry_shape(n))

print("=== 正常な台帳＝警告を出さない（誤検知は警報を無視させる毒）===")
normal = "# 台帳\n\n" + "".join(
    f"### K-{i}: 気づき{i}\n- 観察：短い本文\n- ステータス：⏳未反映\n\n" for i in range(1, 40))
(ok if warns_for(normal) == [] else ng)(f"独立見出し39本・各1行未満なら無警告（{warns_for(normal)}）")

print("\n=== 飲み込み＝O-019／O-035 の再現（これを検知できないと意味がない）===")
swallow = ("# 台帳\n\n### K-422: 台帳肥大を指摘する\n"
           + "".join(f"- **K-{500+i}（partner・2026-08-0{i%9}）｜気づき**：本文\n" for i in range(20))
           + "\n### K-423: 別の気づき\n- 観察：本文\n")
w = warns_for(swallow)
(ok if len(w) == 1 and "飲み込み" in w[0] else ng)(f"20件を配下に抱えた1本を検知（{w}）")
(ok if "K-422" in w[0] else ng)("警告文に該当エントリの見出しが入る（どれを直すか分かる）")
(ok if "O-019" in w[0] else ng)("同型の前例を警告文に添える（毎回ゼロから調べ直さない）")

print("\n=== 境界：上限ちょうどは鳴らさない・1件超えたら鳴る ===")
def swallowed(n):
    return ("# 台帳\n\n### K-1: 見出し\n"
            + "".join(f"- **K-{600+i}（partner・2026-08-11）｜x**：本文\n" for i in range(n)))
(ok if warns_for(swallowed(sh.SWALLOW_MAX)) == [] else ng)(f"{sh.SWALLOW_MAX}件までは正常（引用や関連参照はありうる）")
(ok if len(warns_for(swallowed(sh.SWALLOW_MAX + 1))) == 1 else ng)(f"{sh.SWALLOW_MAX+1}件で警告")

print("\n=== 巨大エントリ（飲み込みでなく素で長い）===")
big = "# 台帳\n\n### K-9: 長すぎるエントリ\n- " + ("あ" * 4000) + "\n"
w = warns_for(big)
(ok if len(w) == 1 and "単体" in w[0] and "KB" in w[0] else ng)(f"1本が上限超なら KB を添えて警告（{w}）")
(ok if "%" in w[0] else ng)("台帳全体に占める割合を出す（＝ローテすべきか判断できる）")
small = "# 台帳\n\n### K-9: ふつう\n- " + ("あ" * 100) + "\n"
(ok if warns_for(small) == [] else ng)("上限内は無警告")

print("\n=== 二重に鳴らさない（飲み込み＋巨大の両方に該当しても1件）===")
both = ("# 台帳\n\n### K-7: 飲み込みかつ巨大\n"
        + "".join(f"- **K-{700+i}（partner・2026-08-11）｜x**：{'あ'*300}\n" for i in range(10)))
w = warns_for(both)
(ok if len(w) == 1 and "飲み込み" in w[0] else ng)(f"原因の本命（飲み込み）だけを言う（{w}）")

print("\n=== 壊れた入力で落ちない（監視自身が無言停止しない）===")
(ok if sh.entry_shape("no-such-file.md") is None else ng)("存在しないファイルは None（例外を投げない）")
(ok if sh.shape_warnings(None) == [] else ng)("None を渡しても空リスト")
(ok if warns_for("") == [] else ng)("空ファイルは無警告")
(ok if warns_for("見出しの無い本文だけ\n") == [] else ng)("### が1つも無くても無警告")

print("\n=== 実データ形式：本番の skill-kaizen を読める（パースの前提が崩れていない）===")
real = sh.ROOT
sh.ROOT = str(proj)
shp = sh.entry_shape("data/hp-improve/skill-kaizen.md")
(ok if shp and shp["entries"] else ng)(f"本番台帳を見出し単位に割れる（{len(shp['entries']) if shp else 0}本）")
(ok if sh.shape_warnings(shp) == [] else ng)(f"退避後の本番台帳は無警告（{sh.shape_warnings(shp)}）")
sh.ROOT = real

print("\n=== 本番ツールが git に入っていない（2026-08-11 の1ヶ月放置の再発防止）===")
(ok if sh.tool_debt_warnings([]) == [] else ng)("未コミットゼロなら無警告")
(ok if sh.tool_debt_warnings([("bin/x.py", 0.5), ("bin/y.sh", 2.9)]) == [] else ng)(
    f"{sh.TOOL_DEBT_DAYS}日以内は無警告（作業中のものを毎回鳴らさない）")
w = sh.tool_debt_warnings([("bin/ga4-fetch.py", 30.2)])
(ok if len(w) == 1 else ng)(f"閾値超えで警告（{len(w)}件）")
(ok if "ga4-fetch.py" in w[0] and "30日" in w[0] else ng)(f"ファイル名と放置日数を出す（{w[0][:60]}…）")
(ok if "復元できない" in w[0] else ng)("なぜ問題かを添える（コミット作法でなくバックアップの欠落）")
w = sh.tool_debt_warnings([(f"bin/t{i}.py", 10 + i) for i in range(6)])
(ok if len(w) == 1 and "6本" in w[0] and "ほか3本" in w[0] else ng)(
    f"多数でも1行に畳む・件数は正確（{w[0][:70]}…）")
(ok if w[0].index("t5.py") < w[0].index("t4.py") else ng)("古い順に並べる（直すべき順）")
(ok if sh.tool_debt_warnings([("bin/x.py", 30)], max_days=90) == [] else ng)("閾値は引数で変えられる")
w = sh.tool_debt_warnings(None)
(ok if len(w) == 1 and "診断不能" in w[0] else ng)(
    "git が使えないときは「0件」でなく診断不能として鳴らす（監視の無言停止を防ぐ）")

print("\n=== 使い捨てスクリプトは対象外（_tmp_ は消す約束のもの）===")
ents = sh.uncommitted_tools()
(ok if ents is None or all("_tmp_" not in p for p, _ in ents) else ng)(
    f"_tmp_ を含まない（{[p for p, _ in (ents or []) if '_tmp_' in p]}）")
(ok if ents is None or isinstance(ents, list) else ng)("本番リポジトリで実行しても落ちない")

print("\n=== コードの層：`_tmp_` 残骸（『済んだら削除』の約束の違反だけ鳴らす）===")
(ok if sh.code_layer_warnings({"tmp": [], "untested": []}) == [] else ng)("残骸ゼロなら無警告")
(ok if sh.code_layer_warnings({"tmp": [{"name": "_tmp_a.py", "days": 3.0}], "untested": []}) == [] else ng)(
    f"{sh.TMP_MAX_DAYS}日以内は無警告（作業中の使い捨てを毎日鳴らさない）")
w = sh.code_layer_warnings({"tmp": [{"name": "_tmp_crop.py", "days": 21.4}], "untested": []})
(ok if len(w) == 1 and "_tmp_crop.py" in w[0] and "21日" in w[0] else ng)(f"閾値超えは名前と日数を出す（{w[0][:50] if w else '—'}…）")
(ok if w and "testing.md §1" in w[0] else ng)("なぜ問題かの根拠（どのルールの約束か）を添える")
many = {"tmp": [{"name": f"_tmp_{i}.py", "days": 10 + i} for i in range(6)], "untested": []}
w = sh.code_layer_warnings(many)
(ok if len(w) == 1 and "6本" in w[0] and "ほか3本" in w[0] else ng)(f"多数でも1行に畳む・件数は正確（{w[0][:60] if w else '—'}…）")
(ok if w and w[0].index("_tmp_5.py") < w[0].index("_tmp_4.py") else ng)("古い順に並べる（呼び出し側の並びに依存しない）")
(ok if sh.code_layer_warnings({"tmp": [{"name": "_tmp_a.py", "days": 30}], "untested": []},
                              max_tmp_days=90) == [] else ng)("閾値は引数で変えられる")

print("\n=== コードの層：無担保ツールは『増えたとき』だけ鳴らす（既知の積み残しで警報疲れさせない）===")
cur = {"tmp": [], "untested": ["ga4-fetch.py", "gsc-fetch.py"]}
(ok if sh.code_layer_warnings(cur) == [] else ng)("前回スナップショットが無ければ黙る（初回に13本を全部『新規』と誤報しない）")
(ok if sh.code_layer_warnings(cur, {"untested": ["ga4-fetch.py", "gsc-fetch.py"]}) == [] else ng)(
    "同じ顔ぶれが続くだけなら鳴らさない（積み残しは testing.md §7 の表が持つ）")
w = sh.code_layer_warnings(cur, {"untested": ["ga4-fetch.py"]})
(ok if len(w) == 1 and "gsc-fetch.py" in w[0] and "ga4-fetch.py" not in w[0] else ng)(
    f"新しく載った1本だけを名指しする（{w[0][:60] if w else '—'}…）")
(ok if sh.code_layer_warnings({"tmp": [], "untested": ["a.py"]},
                              {"untested": ["a.py", "b.py"]}) == [] else ng)("テストが付いて減ったときは鳴らさない")
(ok if sh.code_layer_warnings(None) == [] and sh.code_layer_warnings({}) == [] else ng)(
    "空・None を渡しても落ちない")

print("\n=== コードの層：重複の数え方（数字が信用を失うと統括は起票をやめる）===")
src = [("a.py", 'ENV = os.path.join(ROOT, ".env")\n'),
       ("b.py", 'x = os.environ.get("HOME")\n'),          # ← `.env` に部分一致する罠
       ("c.py", 'from _env import env_value\nv = env_value("K")  # .env を読む\n'),
       ("_env.py", 'ENV_FILE = PROJ / ".env"\n'),
       ("d.sh", 'set -a; . "$PROJ/.env"; set +a\n'),
       ("e.py", 'import fcntl\nfcntl.flock(fh, fcntl.LOCK_EX)\nos.replace(tmp, path)\n'),
       ("f.sh", 'flock -n 9 || exit 0\n')]
d = sh.dup_impls(src)
(ok if d.get(".env の自作読み込み") == ["a.py"] else ng)(
    f"os.environ を .env と誤認しない・共有ヘルパー利用者と _env.py 自身は除く（{d.get('.env の自作読み込み')}）")
(ok if d.get(".env の自作読み込み(shell)") == ["d.sh"] else ng)(f"shell も数える（{d.get('.env の自作読み込み(shell)')}）")
(ok if d.get("flock の自作") == ["e.py"] else ng)(f"python の flock は呼び出しの形で見る（{d.get('flock の自作')}）")
(ok if d.get("flock の自作(shell)") == ["f.sh"] else ng)(f"shell の flock はコマンドの形で見る（{d.get('flock の自作(shell)')}）")
(ok if d.get("atomic write の自作(os.replace)") == ["e.py"] else ng)(f"atomic write（{d.get('atomic write の自作(os.replace)')}）")
(ok if sh.dup_impls([]) == {} else ng)("該当ゼロならキー自体を作らない")
(ok if "system-health.py" in sh.DUP_EXCLUDE else ng)("検知器自身は対象外（自分のパターン定義で自分を数えない）")

print("\n=== コードの層：本番リポジトリで実測できる（パースの前提が崩れていない）===")
sh.ROOT = str(proj)
tools, tested = sh.loop_tools(), sh.tested_tools()
(ok if tools and all("/" not in t for t in tools) else ng)(f"無人ループのツールを列挙できる（{len(tools)}本）")
(ok if all(os.path.isfile(os.path.join(str(proj), "bin", t)) for t in tools) else ng)(
    "実在するものだけ（許可リストに残った消済みツールを数えない）")
(ok if "system-health.py" in tested and "agent-tick.sh" in tested else ng)(
    "テストが冒頭で名乗る対象を拾える（別名テスト test-cooldown→agent-tick も）")
(ok if "hp-audit.sh" not in tested else ng)("本文でしか言及されないツールを『テスト済み』にしない")
ch = sh.code_churn(days=14)
(ok if ch is None or (ch["added"] >= 0 and ch["net"] == ch["added"] - ch["removed"]) else ng)(
    f"増減を実測できる（{ch}）")
cl = sh.code_layer()
(ok if set(cl) >= {"churn", "tmp", "loop_tools", "untested", "dup"} else ng)(f"スナップショット用の形が揃う（{sorted(cl)}）")
(ok if isinstance(cl["untested"], list) and all(t in tools for t in cl["untested"]) else ng)(
    f"テスト無しは無人ループのツールの部分集合（{len(cl['untested'])}本）")
sh.ROOT = str(T)

print("\n=== 読み取り専用（監視が台帳を書き換えない）===")
before = sorted(p.name for p in T.iterdir())
sh.entry_shape("ledger.md"); sh.shape_warnings(sh.entry_shape("ledger.md"))
(ok if sorted(p.name for p in T.iterdir()) == before else ng)("entry_shape/shape_warnings はファイルを増減させない")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
