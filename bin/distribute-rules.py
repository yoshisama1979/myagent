#!/usr/bin/env python3
"""claude-rules テンプレートを案件へ配る（版を刻んで、配った先を記録する）。

テンプレートは git submodule ではなく**コピー配布**なので、配ったあとは各案件の中で
独立して古びていく。そこで配布のたびに **版（どのテンプレを・いつ・どのコミットの状態で
配ったか）** を `.claude/rules-version` に刻む。現場から届く通知（bin/rule-report.sh）は
この版を件名に載せるので、受け取った側は

    git log <版のSHA>..HEAD --oneline -- claude-rules/<template>/

を引くだけで「その指摘はもう直っているか」を機械で判定できる。版を現場に書かせない
（＝書き忘れが起きない）のがこの設計の肝。

  pack  <template> <配布先名> [--out DIR]   配布用の一式を組み立てて tar.gz にする（別マシン向け）
  apply <template> <配布先パス> [--yes]     このマシン上のディレクトリへ直接配る（既定は下見）
  list                                      どこに何版を配ったかの一覧

【上書きの方針】ルール層は毎回上書きし、**中身が育つファイルは無いときだけ置く**。
`documents/`・`project-config.md`・`Design.sample.md`・`.claude/rules/private.md` は
案件の記録そのものなので、配布で消してはいけない。
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent
SRC = PROJ / "claude-rules"
# レジストリの置き場は環境変数で差し替えられる＝テストが本番の記録に触れずに済む
REGISTRY = Path(os.environ.get("RULES_DIST_REGISTRY") or PROJ / "data/rules-distribution.md")
JST = timezone(timedelta(hours=9))
TEMPLATES = ("website", "websystem")

# 配布のたびに上書きしてよいか＝そのファイルが「テンプレの内容」か「案件の記録」か。
# 案件の記録はここに挙げ、**無いときだけ置く**（あれば触らない）。
KEEP_IF_EXISTS = (
    "project-config.md",          # 案件固有の値（パス・URL・担当・共有ファイルの所有者 等）
    "Design.sample.md",           # 案件側で Design.md にして育てる雛形
    "documents/",                 # handoff・pending-issues・rule-improvements・仕様 …案件の記録そのもの
    ".claude/rules/private.md",   # 環境の癖・検証の落とし穴（案件ごとに溜まる）
)

REGISTRY_HEADER = """# claude-rules 配布先レジストリ

`claude-rules/` テンプレートを **どの案件に・どの版で** 配ったかの一覧。テンプレートは
コピー配布なので、ここを見ないと「その案件がいまどの版を持っているか」が分からない。

- 更新は `python3 bin/distribute-rules.py pack|apply`（手で編集しない）
- 版の読み方：`<テンプレ>@<配布日>/<そのテンプレを最後に触ったコミット>`
- **その指摘はもう直っているか**：`git log <SHA>..HEAD --oneline -- claude-rules/<テンプレ>/`
- 履歴はこのファイルの git log を見る（1案件1行で最新だけを持つ）

| 配布先 | テンプレ | 版 | 配布日 | 方法 |
|--------|----------|----|--------|------|
"""


def now():
    return datetime.now(JST)


def die(msg):
    sys.exit(f"❌ {msg}")


def template_dir(name):
    if name not in TEMPLATES:
        die(f"テンプレートは {' / '.join(TEMPLATES)} のどちらかです: {name}")
    d = SRC / name
    if not d.is_dir():
        die(f"テンプレートがありません: {d}")
    return d


def git(*args):
    return subprocess.run(["git", "-C", str(PROJ), *args],
                          capture_output=True, text=True, check=True).stdout.strip()


def make_version(name, allow_dirty=False):
    """`<template>@<配布日>/<SHA>`。未コミットの変更があるときは既定で止める。

    SHA が指すものと配ったものが違うと、受け取り側の「もう直っているか」の判定が
    まるごと嘘になる。だから汚れている作業ツリーからは配らせない。
    """
    rel = f"claude-rules/{name}/"
    dirty = git("status", "--porcelain", "--", rel)
    if dirty and not allow_dirty:
        die(f"{rel} に未コミットの変更があります。版と中身がズレるので、先にコミットしてください:\n"
            + "\n".join("   " + l for l in dirty.splitlines())
            + "\n   （承知のうえで配るなら --allow-dirty）")
    sha = git("log", "-1", "--format=%h", "--abbrev=12", "--", rel)
    if not sha:
        die(f"{rel} のコミットが見つかりません")
    if dirty:
        sha += "+dirty"
    return f"{name}@{now():%Y-%m-%d}/{sha}"


def check_name(name):
    """レジストリの表に入れてよい名前か。`|` や改行が入ると表が壊れ、
    壊れた行は次の書き戻しで扱いに困る＝記録の取りこぼしの入口になる。"""
    n = (name or "").strip()
    if not n:
        die("配布先の名前が空です")
    if any(c in n for c in "|\r\n"):
        die(f"配布先の名前に | や改行は使えません（レジストリの表が壊れます）: {name!r}")
    return n


def keep(rel):
    """配布先に既にあれば触らないファイルか（案件の記録）。

    末尾が `/` のものだけディレクトリ配下をまとめて指す。前方一致にすると
    `project-config.md` が `project-config.md.sample` まで拾ってしまい、
    テンプレ側にそういう名前を足した日に黙って更新されなくなる。
    """
    return any(rel.startswith(k) if k.endswith("/") else rel == k for k in KEEP_IF_EXISTS)


def plan(name, dest):
    """(相対パス, 動作) の一覧。動作は 'overwrite' / 'create' / 'skip'。"""
    src = template_dir(name)
    out = []
    for p in sorted(src.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(src).as_posix()
        exists = (dest / rel).exists()
        if keep(rel):
            out.append((rel, "skip" if exists else "create"))
        else:
            out.append((rel, "overwrite" if exists else "create"))
    return out


def safe_target(dest, rel):
    """配布先の中に収まる書き込み先を返す（シンボリックリンクで外に出さない）。

    `dest/rules` が外を指すリンクだと、上書きが**配布先でない場所**を壊す。
    配布は破壊的な操作なので、疑わしければ書かずに止める。
    """
    root = os.path.realpath(dest)
    target = dest / rel
    # **作る前に**途中のリンクを見る。mkdir はリンクを辿るので、作ってから検査すると
    # その時点でもう配布先の外にディレクトリができている。
    cur = dest
    for part in Path(rel).parts[:-1]:
        cur = cur / part
        if cur.is_symlink():
            die(f"配布先の途中がシンボリックリンクです: {cur.relative_to(dest)}（辿った先を壊します）")
    target.parent.mkdir(parents=True, exist_ok=True)
    parent = os.path.realpath(target.parent)
    if parent != root and not parent.startswith(root + os.sep):
        die(f"配布先の外を指すリンクがあります: {rel} → {parent}")
    if target.is_symlink():
        die(f"配布先のファイルがシンボリックリンクです: {rel}（上書きすると別の場所を壊します）")
    return target


def copy_tree(name, dest, items):
    src = template_dir(name)
    for rel, act in items:
        if act == "skip":
            continue
        shutil.copy2(src / rel, safe_target(dest, rel))


def stamp(dest, version):
    vf = safe_target(dest, ".claude/rules-version")
    vf.write_text(version + "\n", encoding="utf-8")
    return vf


ROW_RE = re.compile(r"^\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|$")
BROKEN_MARK = "<!-- 以下は書式が壊れていて解釈できなかった行です。消さずに残しています。 -->"


def load_registry():
    """(配布先 -> (テンプレ, 版, 配布日, 方法), 解釈できなかった行)。

    **解釈できない行は捨てない。** 捨てて書き戻すと、表が少し壊れただけで
    その配布先の記録が黙って消える（どの案件に何版を配ったか分からなくなる）。
    版はバッククォートを剥がして持つ＝書き戻しで付け直すので、そのまま持つと
    更新のたびに ``` が増えていく。
    """
    rows, broken = {}, []
    if not REGISTRY.is_file():
        return rows, broken
    for line in REGISTRY.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|") or set(line) <= set("|-: "):
            continue                                   # 表以外・区切り行はヘッダから作り直す
        m = ROW_RE.match(line)
        if not m:
            broken.append(line)
            continue
        dest, tpl, ver, day, how = (g.strip() for g in m.groups())
        if dest == "配布先":
            continue                                   # 見出し行
        if tpl not in TEMPLATES:
            broken.append(line)
            continue
        rows[dest] = (tpl, ver.strip("`"), day, how)
    return rows, broken


def record(dest_name, name, version, how):
    rows, broken = load_registry()
    rows[dest_name] = (name, version, f"{now():%Y-%m-%d}", how)
    out = [REGISTRY_HEADER.rstrip("\n")]
    for d in sorted(rows):
        out.append("| {} | {} | `{}` | {} | {} |".format(d, *rows[d]))
    if broken:
        out += ["", BROKEN_MARK, *broken]
        print(f"⚠️ 解釈できない行が {len(broken)} 行ありました。消さずに末尾へ残しています（手で直してください）",
              file=sys.stderr)
    out.append("")
    tmp = REGISTRY.with_name(REGISTRY.name + ".tmp")
    tmp.write_text("\n".join(out), encoding="utf-8")
    os.replace(tmp, REGISTRY)


def show_plan(items):
    n = {"overwrite": 0, "create": 0, "skip": 0}
    for _, a in items:
        n[a] += 1
    print(f"  上書き {n['overwrite']} / 新規 {n['create']} / 触らない {n['skip']}")
    for rel, a in items:
        if a == "skip":
            print(f"    - 触らない : {rel}  ← 案件の記録")


def cmd_pack(args):
    dest_name = check_name(args.dest_name)
    version = make_version(args.template, args.allow_dirty)
    # 既定の出力先は data/cache/ 配下（.gitignore 済み）＝配布物の tar.gz を git に入れない
    outdir = Path(args.out or PROJ / "data/cache/rules-dist")
    outdir.mkdir(parents=True, exist_ok=True)
    stem = version.replace("/", "_").replace("@", "_")
    with tempfile.TemporaryDirectory() as td:
        staging = Path(td) / args.template
        items = [(rel, "create") for rel, _ in plan(args.template, staging)]
        copy_tree(args.template, staging, items)
        stamp(staging, version)
        tgz = outdir / f"{stem}.tar.gz"
        with tarfile.open(tgz, "w:gz") as tf:
            tf.add(staging, arcname=args.template)
    record(dest_name, args.template, version, "pack")
    print(f"✅ 配布用パッケージを作りました: {tgz}")
    print(f"   版: {version}（{len(items)} ファイル・.claude/rules-version に刻印済み）")
    print(f"   配布先として「{dest_name}」をレジストリに記録しました。")
    print()
    print("   受け取り側での展開（案件のルートで）:")
    print(f"     tar xzf {tgz.name} && cp -rn {args.template}/. . && rm -rf {args.template}")
    print("   ※ `cp -rn` は既存ファイルを上書きしません。ルール層を更新するときは")
    print("      documents/・project-config.md・.claude/rules/private.md を残したうえで")
    print("      それ以外を上書きしてください（この 4 つが案件の記録です）。")


def cmd_apply(args):
    dest = Path(args.dest).resolve()
    if not dest.is_dir():
        die(f"配布先がありません: {dest}")
    if SRC in dest.parents or dest == SRC:
        die("テンプレート自身には配れません")
    # myagent 自身（およびその親）へ配ると、このリポジトリの CLAUDE.md / rules/ を
    # テンプレで踏み潰す。配布は上書きを伴うので、疑わしい行き先は入口で止める。
    if dest == PROJ or dest in PROJ.parents:
        die(f"myagent 自身（またはその親）には配れません: {dest}")
    dest_name = check_name(args.dest_name or dest.name)
    version = make_version(args.template, args.allow_dirty)
    items = plan(args.template, dest)
    print(f"配布先: {dest}")
    print(f"版    : {version}")
    show_plan(items)
    if not args.yes:
        print()
        print("下見だけです。実行するなら --yes を付けてください。")
        return
    copy_tree(args.template, dest, items)
    vf = stamp(dest, version)
    record(dest_name, args.template, version, "apply")
    print(f"✅ 配りました。版を刻印: {vf}")


def cmd_list(_args):
    if not REGISTRY.is_file():
        print("まだ配布の記録がありません")
        return
    print(REGISTRY.read_text(encoding="utf-8"))
    print("※ その指摘がもう直っているかは次で引けます:")
    print("   git log <版のSHA>..HEAD --oneline -- claude-rules/<テンプレ>/")


def main(argv=None):
    ap = argparse.ArgumentParser(description="claude-rules テンプレートの配布と版の刻印")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("pack", help="配布用の一式を tar.gz にする（別マシンの案件向け）")
    p.add_argument("template", choices=TEMPLATES)
    p.add_argument("dest_name", help="配布先の名前（レジストリに載る）")
    p.add_argument("--out", help="出力先ディレクトリ（既定 data/cache/rules-dist/・git 追跡外）")
    p.add_argument("--allow-dirty", action="store_true", help="未コミットの変更があっても配る")
    p.set_defaults(func=cmd_pack)

    p = sub.add_parser("apply", help="このマシン上のディレクトリへ直接配る")
    p.add_argument("template", choices=TEMPLATES)
    p.add_argument("dest", help="配布先ディレクトリ")
    p.add_argument("--dest-name", help="レジストリに載せる名前（既定はディレクトリ名）")
    p.add_argument("--yes", action="store_true", help="実際に書き込む（既定は下見のみ）")
    p.add_argument("--allow-dirty", action="store_true", help="未コミットの変更があっても配る")
    p.set_defaults(func=cmd_apply)

    p = sub.add_parser("list", help="どこに何版を配ったか")
    p.set_defaults(func=cmd_list)

    args = ap.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
