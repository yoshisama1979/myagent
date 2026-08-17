#!/usr/bin/env python3
"""precommit-guard.py — コミット直前に「入ってはいけないもの」を機械で止める（pre-commit フック本体）。

契機＝2026-08-12 社長判断「無人で動くエージェントにコミットを許可する。ただし柵を先に作る」。
背景の実測＝この時点で未コミット 146件・最古 06-26（47日）。無人エージェント（統括・hp-loop・
blog-loop・partner 等）は cron で動きコミット権を持たないため、成果物が git の外に溜まり続け、
`git checkout` 一発で消える状態だった（testing.md v0.3 が「バックアップの欠落は故障」と定めた形）。

**コミットを許可する側に倒す**代わりに、共有作業ツリー特有の事故を git 層で止める：
  1. 秘密値の混入（値の形だけを見る＝識別子名には当てない）
  2. 実名・取引先名の混入（**リストは git 外から読む**＝この検知器自身に名前を書かない）
  3. git 外にすべきファイルの取り込み（.gitignore 済みでも -f で入り得る）
  4. 無人実行での社長ゲート対象ファイルの変更（guard-unattended-edits.py の git 層版）
  5. 他エージェントの領域の巻き込み（MYAGENT_AGENT ごとの許可パス）
  6. 壊れたファイルの保存（JSON がパースできない／HTML のタグ数が合わない）

**判定は guard() 1関数に集約**し、テストが直接叩く（testing.md §2）。
緊急時の抜け道は git 標準の `--no-verify`（このスクリプト側に off スイッチは作らない）。
"""
import fnmatch
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 社長ゲート対象＝無人実行では変更できない（rules/modes/overseer.md v0.3 と同じ範囲）
GATED_FILES = ("SYSTEM.md", "CLAUDE.md")
GATED_PREFIXES = ("rules/", ".claude/")

# エージェントごとの書き込み許可パス。**ここに載っているエージェントだけ**厳格に縛る
# （未登録は universal な検査だけ通す＝間違った許可リストで正当なコミットを塞がないため。
#  絞りたくなったら行を足す。それが唯一の締め方）。
AGENT_PATHS = {
    "overseer":      ["site/overseer/"],
    "hp-loop-*":     ["data/hp-loop/", "site/hp-analysis/"],
    # site/drafts/ は 2026-08-17 に git 管理外へ（草案＝副次成果物）。
    # 許可に残すと「コミットしてよい」と誤読されるので外す（ステージすれば [git外] 検査が止める）。
    "blog-loop-*":   ["data/blog-loop/", "site/hp-analysis/"],
    "memo":          ["site/notes.html"],
}

# 秘密値：**値の形**だけを拾う。`if not bot.startswith("xoxb-")` のような
# 「識別子名としての言及」に当てると本物のコードが commit できなくなる
# （2026-08-12 実測＝素の grep だと追跡ファイル5本が誤検知した）。
SECRET_PATTERNS = [
    ("Slack トークン",      re.compile(r"xox[baprs]-[A-Za-z0-9]{8,}-[A-Za-z0-9-]{8,}")),
    ("秘密鍵",              re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("Google API キー",     re.compile(r"AIza[0-9A-Za-z_\-]{30,}")),
    ("Bearer トークンの実値", re.compile(r"Bearer\s+[A-Za-z0-9._\-]{20,}")),
    ("秘密値の代入",        re.compile(
        r"(?i)(refresh_token|client_secret|access_token|api[_-]?token|app_password)"
        r"\s*[\"']?\s*[:=]\s*[\"']?([A-Za-z0-9._\-/+]{16,})")),
]
# 雛形・記入例は対象外（`.env.example` の `API_TOKEN=your-chatwork-token` 等）
SECRET_EXEMPT = ("*.example", "*.sample", "*.sample.*", "*-sample.*", "*.example.*")
# 「明らかに埋めていない値」は秘密ではない
PLACEHOLDER = re.compile(r"(?i)^(your|xxx+|todo|dummy|sample|example|changeme|<)")

# 実名・取引先名の一覧は **git 外**（data/secrets/ は .gitignore 済み）から読む。
# 検知器に名前を書いたら、その検知器自身が漏洩になる。
DENY_NAMES_FILE = os.path.join(ROOT, "data", "secrets", "deny-names.txt")


def load_deny_names(path=DENY_NAMES_FILE):
    """伏せるべき固有名詞の一覧。無ければ空（＝この検査はスキップ）。"""
    try:
        with open(path, encoding="utf-8") as f:
            return [ln.strip() for ln in f
                    if ln.strip() and not ln.lstrip().startswith("#")]
    except OSError:
        return []


def is_gated(path):
    return path in GATED_FILES or path.startswith(GATED_PREFIXES)


def allowed_prefixes(agent):
    """エージェント名から許可パスを引く。未登録なら None（＝この検査は行わない）。"""
    if not agent:
        return None
    for pattern, paths in AGENT_PATHS.items():
        if fnmatch.fnmatch(agent, pattern):
            return paths
    return None


def _exempt_from_secret_scan(path):
    base = os.path.basename(path)
    return any(fnmatch.fnmatch(base, p) for p in SECRET_EXEMPT)


def secret_hits(path, added_text):
    """追加された行に秘密値の**実値**が含まれていれば (種別, 抜粋) を返す。"""
    if _exempt_from_secret_scan(path):
        return []
    out = []
    for label, pat in SECRET_PATTERNS:
        for m in pat.finditer(added_text or ""):
            value = m.group(2) if m.lastindex and m.lastindex >= 2 else m.group(0)
            if PLACEHOLDER.match(value):
                continue                      # 雛形の穴埋め文字列は秘密ではない
            out.append((label, m.group(0)[:24]))
    return out


def name_hits(added_text, names):
    return [n for n in names if n and n in (added_text or "")]


def integrity_problems(path, content):
    """壊れたまま保存させない。JSON はパース、site/ の HTML は div の釣り合いを見る。"""
    out = []
    if content is None:
        return out
    if path.endswith(".json"):
        try:
            json.loads(content)
        except Exception as e:                                        # noqa: BLE001
            out.append(f"JSON として壊れている（{type(e).__name__}）")
    if path.startswith("site/") and path.endswith(".html"):
        o, c = content.count("<div"), content.count("</div>")
        if o != c:
            out.append(f"HTML の div が釣り合わない（<div>={o} / </div>={c}）")
    return out


def guard(staged, *, agent=None, unattended=False, ignored=(), deny_names=()):
    """コミットを止めるべき理由の一覧を返す（空ならコミット可）。判定はここ1箇所。

    staged: [{"path": str, "added": str, "content": str|None}, ...]
    ignored: .gitignore 対象なのにステージされているパスの集合
    """
    problems = []
    paths = [s["path"] for s in staged]

    for p in sorted(set(ignored) & set(paths)):
        problems.append(f"[git外] {p} は .gitignore 対象です（-f で強制追加された疑い）。"
                        f"秘密・クライアント情報が git に入る経路なので止めます")

    if unattended:
        for p in sorted(p for p in paths if is_gated(p)):
            problems.append(f"[社長ゲート] {p} は無人実行では変更できません"
                            f"（rules/modes/overseer.md v0.3）。有人セッションで反映してください")

    allow = allowed_prefixes(agent)
    if allow is not None:
        for p in sorted(paths):
            if not any(p.startswith(a) for a in allow):
                problems.append(
                    f"[領域外] {agent} は {p} をコミットできません"
                    f"（許可: {' / '.join(allow)}）。共有作業ツリーなので、"
                    f"他エージェントの書きかけを巻き込む経路になります")

    for s in staged:
        for label, excerpt in secret_hits(s["path"], s.get("added")):
            problems.append(f"[秘密値] {s['path']} に {label} らしき値（{excerpt}…）")
        for n in name_hits(s.get("added"), deny_names):
            problems.append(f"[実名] {s['path']} に伏せるべき固有名詞が含まれます"
                            f"（該当語は表示しません・{len(n)}文字）")
        for msg in integrity_problems(s["path"], s.get("content")):
            problems.append(f"[破損] {s['path']}: {msg}")
    return problems


# ---------------------------------------------------------------- git 側の配線

def _git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)


def collect_staged():
    r = _git("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR")
    paths = [p for p in r.stdout.split("\0") if p]
    out = []
    for p in paths:
        added = "\n".join(
            ln[1:] for ln in _git("diff", "--cached", "-U0", "--", p).stdout.splitlines()
            if ln.startswith("+") and not ln.startswith("+++"))
        content = _git("show", f":{p}").stdout or None
        out.append({"path": p, "added": added, "content": content})
    return out


def ignored_paths(paths):
    if not paths:
        return set()
    r = subprocess.run(["git", "check-ignore", "--stdin"], cwd=ROOT,
                       input="\n".join(paths), capture_output=True, text=True)
    return {p for p in r.stdout.splitlines() if p}


def main():
    staged = collect_staged()
    if not staged:
        return 0
    problems = guard(
        staged,
        agent=os.environ.get("MYAGENT_AGENT"),
        unattended=os.environ.get("MYAGENT_UNATTENDED") == "1",
        ignored=ignored_paths([s["path"] for s in staged]),
        deny_names=load_deny_names(),
    )
    if not problems:
        return 0
    print("⛔ コミットを止めました（bin/precommit-guard.py）", file=sys.stderr)
    for p in problems:
        print(f"   - {p}", file=sys.stderr)
    print("   → 直してから再度コミットしてください。"
          "意図的に通す場合のみ `git commit --no-verify`（理由をコミットメッセージに書くこと）",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
