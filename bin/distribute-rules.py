#!/usr/bin/env python3
"""claude-rules テンプレートを案件へ配る（版を刻んで、配った先を記録する）。

テンプレートは git submodule ではなく**コピー配布**なので、配ったあとは各案件の中で
独立して古びていく。そこで配布のたびに **版（どのテンプレを・いつ・どのコミットの状態で
配ったか）** を `.claude/rules-version` に刻む。現場から届く通知（bin/rule-report.sh）は
この版を件名に載せるので、受け取った側は

    git log <版のSHA>..HEAD --oneline -- claude-rules/<template>/

を引くだけで「その指摘はもう直っているか」を機械で判定できる。版を現場に書かせない
（＝書き忘れが起きない）のがこの設計の肝。

  pack  <profile> <配布先名> [--out DIR]    配布用の一式を組み立てて tar.gz にする（別マシン向け）
  apply <profile> <配布先パス> [--yes]      このマシン上のディレクトリへ直接配る（既定は下見）
  list                                      どこに何版を配ったかの一覧

【プロファイル＝配る層の組み合わせ】配る単位は「層（`claude-rules/<層>/`）を順に重ねたもの」。
いまは層が1つずつなので `website` / `websystem` は従来どおりの1層だが、公開面と機能面の
両方が必要な案件（ユーザー向けサービス）には**複数層を重ねて配る**ための器をここに持たせてある。
層を足すときに触るのは `PROFILES` の1箇所だけ（`TEMPLATES` という名前は旧称）。

🚨 **同じ相対パスを2つの層が持っていたら、配る前にエラーで止める。** 黙って後の層で上書きすると
「どちらが正か」が配布先でしか分からなくなる（テンプレート設計原則②＝重複定義しない）。

【上書きの方針】ルール層は毎回上書きし、**中身が育つファイルは無いときだけ置く**。
`documents/`・`project-config.md`・`Design.sample.md`・`.claude/rules/private.md` は
案件の記録そのものなので、配布で消してはいけない。
"""
import argparse
import json
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
# テンプレの置き場とレジストリは環境変数で差し替えられる＝テストが本番の記録・本番の層に
# 触れずに済む（本番のレジストリを書き換えるテストは、落ちた日に記録を壊す）。
SRC = Path(os.environ.get("RULES_SRC") or PROJ / "claude-rules")
REGISTRY = Path(os.environ.get("RULES_DIST_REGISTRY") or PROJ / "data/rules-distribution.md")
JST = timezone(timedelta(hours=9))

# 配る単位＝プロファイル。値は **重ねる順に並べた層** で、後の層が先の層より優先されることは
# ない（同じパスがあればエラー＝原則②）。順序は版の2行目と `plan` の走査順を決めるだけ。
#
# 🚨 **一覧の正は `claude-rules/profiles.json` ひとつ。** 読む側が Python（ここと
# `bin/rule-reporter.py`）と PHP（`site/tools/rules/index.php`）に分かれていて言語を
# またぐので、コードに同じ一覧を3つ書くのをやめ、データに1つ置いて全員が読む形にした。
# 層を足すときに触るのもそのファイルだけ。
PROFILES_FILE = Path(os.environ.get("RULES_PROFILES") or SRC / "profiles.json")


def die(msg):
    # 読み込み時（load_profiles）から呼ぶので、他の関数より前に置く
    sys.exit(f"❌ {msg}")


# プロファイル名・層名に許す形。🚨 **これは飾りではない。** 層名はそのままディレクトリ名に
# なるので（`SRC / layer`）、絶対パスを書くと pathlib の仕様で `claude-rules/` が丸ごと捨てられ、
# **テンプレートの外のファイルが配られる**（2026-10-28 の Codex レビューで実証）。プロファイル名も
# 一時ディレクトリ名・tar の arcname・配信先ディレクトリ名になる。名前はコード内の定数ではなく
# **JSON 由来の値**なので、ここで形を絞るのが唯一の関門。現場の `bin/rule-report.sh` も同じ形で判定する。
# 🚨 **同じ形の判定が3箇所にある**（ここ・`site/tools/rules/index.php`・配布物の
# `bin/rule-report.sh`）。言語が違うので1つに統合できない代わりに、**いちばん狭い現場の
# bash に合わせて同一の文字集合にし、`bin/test-distribute-rules.sh` が3つの一致を見張る**。
# ズレると「配布はできるのに現場の報告が別スレッドへ落ちる」が黙って起きる。
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def load_profiles(path=None):
    """{プロファイル名: (層, …)}。壊れていたら黙って既定に落ちずに止める。

    黙って既定へ落ちると「配ったつもりの層が入っていない」配布物ができる。
    配布は上書きを伴うので、疑わしければ配らない。**どんな形で壊れていても
    トレースバックではなく `❌ …` で止める**（人が読んで直せるように）。
    """
    p = Path(path or PROFILES_FILE)
    if not p.is_file():
        die(f"配布プロファイルの定義がありません: {p}")
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except ValueError as e:
        die(f"配布プロファイルの定義が JSON として読めません: {p}（{e}）")
    if not isinstance(data, dict):
        die(f"配布プロファイルの定義がオブジェクトではありません: {p}")
    raw = data.get("profiles")
    if not isinstance(raw, dict) or not raw:
        die(f"profiles.json の `profiles` が「空でないオブジェクト」ではありません: {p}")
    out = {}
    for name, layers in raw.items():
        if not NAME_RE.match(name):
            die(f"profiles.json のプロファイル名が使えません: {name!r}"
                "（英小文字・数字・ハイフンのみ／先頭は英数字）")
        if not isinstance(layers, list) or not layers:
            die(f"profiles.json の {name!r} が「層名の配列」になっていません: {layers!r}")
        for l in layers:
            if not isinstance(l, str) or not NAME_RE.match(l):
                die(f"profiles.json の {name!r} の層名が使えません: {l!r}"
                    "（英小文字・数字・ハイフンのみ／先頭は英数字）")
        if len(set(layers)) != len(layers):
            die(f"profiles.json の {name!r} に同じ層が2回入っています: {layers!r}")
        out[name] = tuple(layers)
    return out


PROFILES = load_profiles()
TEMPLATES = tuple(sorted(PROFILES))   # 旧称。外から参照している箇所の互換のために残す

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
- 版の読み方：`<プロファイル>@<配布日>/<その層のどれかを最後に触ったコミット>`
- **その指摘はもう直っているか**：`git log <SHA>..HEAD --oneline -- claude-rules/<層>/…`
  （層の内訳は配布先の `.claude/rules-version` の2行目。層が1つだけのプロファイルでは2行目を付けない）
- 履歴はこのファイルの git log を見る（1案件1行で最新だけを持つ）

| 配布先 | プロファイル | 版 | 配布日 | 方法 |
|--------|--------------|----|--------|------|
"""


def now():
    return datetime.now(JST)


def profile_layers(name):
    """プロファイル名 → [(層名, ディレクトリ)]（重ねる順）。"""
    if name not in PROFILES:
        die(f"配布プロファイルは {' / '.join(sorted(PROFILES))} のいずれかです: {name}")
    out = []
    for layer in PROFILES[name]:
        d = SRC / layer
        # 名前は NAME_RE で絞ってあるが、解決後も **SRC の直下**であることを確かめる
        # （記号を増やした日に、検証をすり抜ける組み合わせが生まれても外へ出ない）
        if os.path.dirname(os.path.realpath(d)) != os.path.realpath(SRC):
            die(f"層がテンプレート置き場の直下にありません: {layer!r} → {d}")
        if not d.is_dir():
            die(f"層がありません: {d}（PROFILES[{name!r}] が指しています）")
        out.append((layer, d))
    return out


def profiles_rel():
    """`profiles.json` のリポジトリ相対パス。リポジトリ外（テストで差し替えた）なら None。"""
    try:
        return PROFILES_FILE.resolve().relative_to(PROJ.resolve()).as_posix()
    except ValueError:
        return None


def layer_rels(name):
    """そのプロファイルが使う層＋`profiles.json` の、リポジトリ相対パス（git に渡す形）。

    🚨 **`profiles.json` を必ず含める。** 層の追加・削除・順序の変更は**配布物の中身を変える**のに、
    層ディレクトリだけを見ていると「層を1つ足したのに版が進まない・dirty とも言われない」が起きる。
    受け取り側は版の SHA を起点に `git log <SHA>..HEAD` で変更点を読むので、そこに出ない変更が
    配られると**「その指摘はもう直っているか」の判定がまるごと嘘になる**（この機構の存在理由）。
    """
    rels = [f"claude-rules/{layer}/" for layer in PROFILES[name]]
    pr = profiles_rel()
    if pr:
        rels.append(pr)
    return rels


def git(*args):
    return subprocess.run(["git", "-C", str(PROJ), *args],
                          capture_output=True, text=True, check=True).stdout.strip()


def make_version(name, allow_dirty=False):
    """`<profile>@<配布日>/<SHA>`。未コミットの変更があるときは既定で止める。

    SHA が指すものと配ったものが違うと、受け取り側の「もう直っているか」の判定が
    まるごと嘘になる。だから汚れている作業ツリーからは配らせない。

    SHA は **そのプロファイルが使う層のどれかを最後に触ったコミット**。層が複数あっても
    1個で足りるのは、受け取り側の引き方が `git log <SHA>..HEAD -- <層…>` だから
    （層ごとの内訳は版の2行目＝`layer_note` が持つ）。
    """
    profile_layers(name)                       # 名前と層の存在をここで確かめる
    rels = layer_rels(name)
    dirty = git("status", "--porcelain", "--", *rels)
    if dirty and not allow_dirty:
        die("未コミットの変更があります（" + " ".join(rels) + "）。"
            "版と中身がズレるので、先にコミットしてください:\n"
            + "\n".join("   " + l for l in dirty.splitlines())
            + "\n   （承知のうえで配るなら --allow-dirty）")
    sha = git("log", "-1", "--format=%h", "--abbrev=12", "--", *rels)
    if not sha:
        # 層がまだ git に入っていない（新設直後・RULES_SRC でテンプレ置き場を差し替えた等）。
        # この状態の版は「もう直っているか」を引けないので、既定では配らせない。
        if not allow_dirty:
            die("コミットが見つかりません（" + " ".join(rels) + "）。"
                "版から変更点を引けないので配れません。\n"
                "   （承知のうえで配るなら --allow-dirty）")
        sha = "nogit"
    if dirty:
        sha += "+dirty"
    return f"{name}@{now():%Y-%m-%d}/{sha}"


def layer_note(name):
    """版の2行目（`layers: common=<sha> site=<sha>`）。**1層のプロファイルでは None**。

    1層のときに何も足さないのは、刻印を**従来とバイト単位で同じ**に保つため
    （稼働中の案件は `head -1` で読んでいるので壊れないが、差分が出ない方が安全）。
    """
    layers = PROFILES[name]
    if len(layers) < 2:
        return None
    parts = []
    for layer in layers:
        sha = git("log", "-1", "--format=%h", "--abbrev=12", "--", f"claude-rules/{layer}/")
        parts.append(f"{layer}={sha or 'nogit'}")
    return "layers: " + " ".join(parts)


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
    """(相対パス, 動作, 層) の一覧。動作は 'overwrite' / 'create' / 'skip'。

    🚨 **同じ相対パスを2つの層が持っていたらエラーで止める。** 後の層で黙って上書きすると、
    どちらが正かが配布先でしか分からなくなる（原則②＝重複定義しない）。面ごとの違いは
    別ファイル名の追補として置く。
    """
    out, owner = [], {}
    for layer, src in profile_layers(name):
        for p in sorted(src.rglob("*")):
            if not p.is_file():
                continue
            rel = p.relative_to(src).as_posix()
            if rel in owner:
                die(f"同じパスが2つの層にあります: {rel}\n"
                    f"   {owner[rel]} と {layer} の両方が持っています。"
                    "どちらが正かを決めて1つにしてください（原則②＝重複定義しない）。")
            owner[rel] = layer
            exists = (dest / rel).exists()
            if keep(rel):
                act = "skip" if exists else "create"
            else:
                act = "overwrite" if exists else "create"
            out.append((rel, act, layer))
    out.sort(key=lambda row: row[0])
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
    srcs = dict(profile_layers(name))
    for rel, act, layer in items:
        if act == "skip":
            continue
        shutil.copy2(srcs[layer] / rel, safe_target(dest, rel))


def stamp(dest, version, note=None):
    """`.claude/rules-version` を書く。1行目が版・2行目以降は層の内訳（任意）。

    現場（`bin/rules-update.sh`・`bin/rule-report.sh`）は **`head -1` しか読まない**ので、
    2行目を足しても既存の案件の挙動は変わらない。
    """
    vf = safe_target(dest, ".claude/rules-version")
    text = version + "\n"
    if note:
        text += note + "\n"
    vf.write_text(text, encoding="utf-8")
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
        if tpl not in PROFILES:
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


def show_plan(items, layers=()):
    n = {"overwrite": 0, "create": 0, "skip": 0}
    per = {}
    for rel, a, layer in items:
        n[a] += 1
        per[layer] = per.get(layer, 0) + 1
    if len(layers) > 1:
        print("  層    : " + " + ".join(f"{l}（{per.get(l, 0)}）" for l in layers))
    print(f"  上書き {n['overwrite']} / 新規 {n['create']} / 触らない {n['skip']}")
    for rel, a, _layer in items:
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
        items = [(rel, "create", layer) for rel, _, layer in plan(args.template, staging)]
        copy_tree(args.template, staging, items)
        stamp(staging, version, layer_note(args.template))
        tgz = outdir / f"{stem}.tar.gz"
        with tarfile.open(tgz, "w:gz") as tf:
            tf.add(staging, arcname=args.template)
    record(dest_name, args.template, version, "pack")
    print(f"✅ 配布用パッケージを作りました: {tgz}")
    print(f"   版: {version}（{len(items)} ファイル・.claude/rules-version に刻印済み）")
    print(f"   配布先として「{dest_name}」をレジストリに記録しました。")
    if len(PROFILES[args.template]) > 1:
        print(f"   層: {' + '.join(PROFILES[args.template])}（内訳は .claude/rules-version の2行目）")
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
    show_plan(items, PROFILES[args.template])
    if not args.yes:
        print()
        print("下見だけです。実行するなら --yes を付けてください。")
        return
    copy_tree(args.template, dest, items)
    vf = stamp(dest, version, layer_note(args.template))
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
    p.add_argument("template", metavar="profile", choices=sorted(PROFILES),
                   help="配布プロファイル（層の組み合わせ）")
    p.add_argument("dest_name", help="配布先の名前（レジストリに載る）")
    p.add_argument("--out", help="出力先ディレクトリ（既定 data/cache/rules-dist/・git 追跡外）")
    p.add_argument("--allow-dirty", action="store_true", help="未コミットの変更があっても配る")
    p.set_defaults(func=cmd_pack)

    p = sub.add_parser("apply", help="このマシン上のディレクトリへ直接配る")
    p.add_argument("template", metavar="profile", choices=sorted(PROFILES),
                   help="配布プロファイル（層の組み合わせ）")
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
