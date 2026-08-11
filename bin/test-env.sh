#!/usr/bin/env bash
# 共有ヘルパー bin/_env.py（.env の読み取り）の回帰テスト。
#
# 契機＝2026-08-11 の最適化スライス第1号。同じ 24 行の実装が gmail-fetch.py と
# calendar-fetch.py に1文字違わず重複していたのを1箇所へ集約した（rules/refactoring.md §6）。
# ここで固定するのは**移行前の既存実装の挙動そのもの**＝共通化で規約が変わっていないこと。
# 変わっていたら「静かな仕様変更」になり、鍵が読めない／余計な引用符が付くなどの形で
# 認証だけが落ちる（しかも .env は git 管理外なので再現が難しい）。
#
# ⚠️ 秘密値は一切扱わない（テストは架空のキーと値だけを一時ディレクトリに書く）。
# 触ったら必ず流すこと：bash bin/test-env.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/_env.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import importlib.util, sys, tempfile
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("_env", proj / "bin/_env.py")
env = importlib.util.module_from_spec(spec)
spec.loader.exec_module(env)

P = N = 0
def ok(m, d=""):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

# 本番の .env に触れない（testing.md §6-1）
T = Path(tempfile.mkdtemp())
if not str(T).startswith("/tmp"):
    print(f"❌ テストの作業先が /tmp の外: {T}", file=sys.stderr); sys.exit(2)

def val(key, text):
    f = T / ".env"
    f.write_text(text, encoding="utf-8")
    return env.env_value(key, env_file=f)

print("=== 基本 ===")
(ok if val("A", "A=1\nB=2\n") == "1" else ng)("キーの値を返す")
(ok if val("B", "A=1\nB=2\n") == "2" else ng)("2つ目以降のキーも引ける")
(ok if val("C", "A=1\n") == "" else ng)("無いキーは空文字（例外にしない）")
(ok if env.env_value("A", env_file=T / "no-such.env") == "" else ng)("ファイルが無くても空文字")

print("\n=== 区切りと空白（既存規約の据え置き）===")
(ok if val("A", "  A  =  1  \n") == "1" else ng)("キー・値の前後の空白は落とす")
(ok if val("A", "A=\n") == "" else ng)("値が空なら空文字")
(ok if val("URL", "URL=https://x/?a=1&b=2\n") == "https://x/?a=1&b=2" else ng)(
    "値の中の = は壊さない（最初の = だけで割る）")

print("\n=== 引用符（1組だけ外す）===")
(ok if val("A", 'A="1"\n') == "1" else ng)("二重引用符を外す")
(ok if val("A", "A='1'\n") == "1" else ng)("単引用符を外す")
(ok if val("A", 'A=""1""\n') == '"1"' else ng)("外すのは1組だけ（内側は残す）")
(ok if val("A", 'A="1\n') == '"1' else ng)("片側だけの引用符は外さない（値の一部）")
(ok if val("A", "A=\"1'\n") == "\"1'" else ng)("種類が違う引用符の組は外さない")

print("\n=== 無視する行 ===")
(ok if val("A", "# A=9\nA=1\n") == "1" else ng)("コメント行は無視")
(ok if val("A", "\n\n   \nA=1\n") == "1" else ng)("空行は無視")
(ok if val("A", "これは説明文\nA=1\n") == "1" else ng)("= を含まない行は無視")
(ok if val("A", "  # A=9\nA=1\n") == "1" else ng)("インデントされたコメントも無視")

print("\n=== 重複キーは最初の1つ（後勝ちにすると別の鍵を掴む）===")
(ok if val("A", "A=first\nA=second\n") == "first" else ng)("最初の定義を採用")
(ok if val("A", "# A=commented\nA=real\n") == "real" else ng)("コメントアウトされた定義は数えない")

print("\n=== 前方一致の取り違えを起こさない ===")
(ok if val("TOKEN", "TOKEN_SUB=x\nTOKEN=y\n") == "y" else ng)("TOKEN_SUB を TOKEN と誤認しない")
(ok if val("TOKEN_SUB", "TOKEN=y\nTOKEN_SUB=x\n") == "x" else ng)("逆順でも正しく引く")

print("\n=== 壊れた入力で落ちない ===")
f = T / ".env"
f.write_bytes(b"A=\xff\xfe not utf-8\nB=2\n")
try:
    got = env.env_value("B", env_file=f)
    (ok if got == "2" else ng)(f"不正なバイトがあっても後続行を読める（{got!r}）")
except Exception as e:
    ng("不正なバイトで例外", repr(e))
(ok if val("A", "A=1") == "1" else ng)("最終行に改行が無くても読める")

print("\n=== 既定のパスはプロジェクト直下の .env を絶対パスで指す ===")
(ok if env.ENV_FILE == proj / ".env" else ng)(f"ENV_FILE={env.ENV_FILE}")
(ok if env.ENV_FILE.is_absolute() else ng)(
    "絶対パス（相対パスだと cron で作業ディレクトリが違うとき黙って読めない）")

print("\n=== 移行元と同じ挙動か（gmail-fetch / calendar-fetch の旧実装を再現して突き合わせ）===")
def legacy(key, path):
    """移行前に2ファイルへ重複していた実装（コミット 3fea8d7 時点の写し）"""
    if not path.is_file():
        return ""
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip() != key:
            continue
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        return v
    return ""

cases = ["A=1\n", '  A = " 1 " \n', "# A=9\nA=1\n", "A=\nB=2\n", "A=first\nA=second\n",
         "URL=https://x/?a=1&b=2\n", "A='x'\n", 'A=""1""\n', "A=1", "TOKEN_SUB=x\nTOKEN=y\n"]
diff = []
for text in cases:
    for key in ("A", "B", "URL", "TOKEN", "TOKEN_SUB", "MISSING"):
        f.write_text(text, encoding="utf-8")
        a, b = env.env_value(key, env_file=f), legacy(key, f)
        if a != b:
            diff.append((text, key, a, b))
(ok if not diff else ng)(f"{len(cases)}パターン×6キー＝60通りで旧実装と完全一致", diff[:3])

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
