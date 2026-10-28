#!/usr/bin/env python3
"""claude-rules テンプレートの「配ってよい版」を公開する（各案件が取りに来る元）。

配布には2つの経路がある：

  1. 手渡し   … bin/distribute-rules.py pack|apply（初回。トークンが無い案件にも渡せる）
  2. 取りに来させる … ここで公開した版を、各案件の bin/rules-update.sh が Tailscale 経由で取る

公開は**社長の明示操作**にしてある。`claude-rules/` を編集している最中の版が現場へ流れると、
途中の状態を全案件が一斉に受け取ることになるので、「配ってよい」と決めた瞬間だけ更新する。

  publish <profile> [--allow-dirty]    そのプロファイルの層を重ねたものを配信対象にする
  status                               いま何版を配信しているか
  unpublish <profile>                  配信を止める（受け口は 503 を返す）

プロファイル＝配る層の組み合わせ（正は `bin/distribute-rules.py` の `PROFILES`）。
出力先 data/cache/rules-release/<profile>/（git 追跡外・いつでも publish し直せる）
  package.tar.gz  配布物一式（.claude/rules-version と .claude/rules-keep を同梱）
  meta.json       版・公開日時・サイズ・SHA256（受け取り側が壊れた取得を検出できる）
  changelog.tsv   そのテンプレを触ったコミットの一覧（受け取り側が「自分の版より後の変更」を読む）
"""
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent
RELEASE = Path(os.environ.get("RULES_RELEASE_DIR") or PROJ / "data/cache/rules-release")
JST = timezone(timedelta(hours=9))
CHANGELOG_MAX = 200        # 何コミット分を配るか（受け取り側は自分の版までしか読まない）
SUBJECT_MAX = 300          # 件名の切り詰め（このリポジトリのコミット件名は長い）


def _load_distribute():
    """配布ロジック（版の作り方・上書きの方針）は bin/distribute-rules.py が正。

    同じ判断を2箇所に書くと、片方だけ直した日に「手渡しでは守られるのに、
    取りに来たら上書きされるファイル」が生まれる。ハイフン付きのファイル名は
    import できないので、ファイルパスから読み込む。
    """
    path = Path(__file__).with_name("distribute-rules.py")
    spec = importlib.util.spec_from_file_location("distribute_rules", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dr = _load_distribute()


def now():
    return datetime.now(JST)


def die(msg):
    sys.exit(f"❌ {msg}")


def changelog(profile):
    """そのプロファイルの**層のどれか**を触ったコミットを新しい順に (sha, 日付, 件名) で返す。

    受け取り側は「自分が持っている版の SHA」を目印にここから上だけを読む＝
    更新すると何が変わるのかを、こちらに聞かずに読める。層が複数あるときは
    まとめて1本の履歴にする（受け取り側は層の区別なく「自分に配られる変更」を読みたい）。
    """
    out = subprocess.run(
        ["git", "-C", str(PROJ), "log", f"-n{CHANGELOG_MAX}",
         "--format=%h%x09%ad%x09%s", "--date=short", "--abbrev=12",
         "--", *dr.layer_rels(profile)],
        capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        sha, day, subject = parts
        subject = subject.replace("\t", " ").strip()
        if len(subject) > SUBJECT_MAX:
            subject = subject[:SUBJECT_MAX] + "…"
        rows.append((sha, day, subject))
    return rows


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_publish(args):
    template = args.template
    version = dr.make_version(template, args.allow_dirty)
    # 🚨 公開は7案件が取りに来る口。SHA を引けない版（層が git に入っていない）を公開すると、
    # 受け取り側が「自分の版より後の変更」を changelog から辿れなくなる＝更新の判断ができない。
    # `--allow-dirty` は `+dirty`（SHA はある）までの逃げ道で、SHA が無い版の公開は許さない。
    if "nogit" in version.split("/", 1)[1]:
        die(f"版の SHA を引けないので公開できません: {version}\n"
            "   層をコミットしてから publish してください"
            "（受け取り側が changelog から変更点を辿れなくなります）")
    outdir = RELEASE / template
    outdir.mkdir(parents=True, exist_ok=True)

    # 配布物・版・変更点は3ファイルに分かれていて、まとめて差し替えられない。途中で取りに
    # 来られると「meta の SHA256 と実体が違う」瞬間が生まれる（受け取り側は安全側に倒れて
    # 中断するが、更新が不安定になる）。公開中は受け口に隠してもらう。
    marker = outdir / ".publishing"
    marker.write_text(now().isoformat(timespec="seconds") + "\n", encoding="utf-8")

    with tempfile.TemporaryDirectory() as td:
        staging = Path(td) / template
        items = [(rel, "create", layer) for rel, _, layer in dr.plan(template, staging)]
        dr.copy_tree(template, staging, items)
        dr.stamp(staging, version, dr.layer_note(template))
        # 「配布で消してはいけないファイル」を同梱する。受け取り側がこの一覧を読んで守る＝
        # 守る対象の正は distribute-rules.py の KEEP_IF_EXISTS ひとつだけになる
        # （現場のスクリプトに同じ一覧を書くと、足した日に片方だけ古くなる）。
        keep = staging / ".claude/rules-keep"
        keep.write_text("".join(k + "\n" for k in dr.KEEP_IF_EXISTS), encoding="utf-8")

        tmp_tgz = outdir / ".package.tar.gz.tmp"
        with tarfile.open(tmp_tgz, "w:gz") as tf:
            tf.add(staging, arcname=template)
        tgz = outdir / "package.tar.gz"
        os.replace(tmp_tgz, tgz)               # 取得中に差し替わっても半端なファイルを配らない

    rows = changelog(template)
    tmp_log = outdir / ".changelog.tsv.tmp"
    tmp_log.write_text("".join("\t".join(r) + "\n" for r in rows), encoding="utf-8")
    os.replace(tmp_log, outdir / "changelog.tsv")

    meta = {
        "template": template,                  # キー名は互換のため据え置き（値はプロファイル名）
        "profile": template,
        "layers": list(dr.PROFILES[template]),
        "version": version,
        "sha": version.split("/", 1)[1],
        "published_at": now().isoformat(timespec="seconds"),
        "size": tgz.stat().st_size,
        "sha256": sha256_of(tgz),
        "files": len(items) + 2,               # 版と守る一覧の2ファイルを足して同梱する
    }
    tmp_meta = outdir / ".meta.json.tmp"
    tmp_meta.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp_meta, outdir / "meta.json")
    marker.unlink()                            # ここで初めて新しい版が見えるようになる

    print(f"✅ 配信する版を更新しました: {version}")
    print(f"   置き場 : {outdir}")
    print(f"   一式   : {meta['files']} ファイル / {meta['size']:,} バイト")
    print(f"   層     : {' + '.join(dr.PROFILES[template])}")
    print(f"   変更点 : この層を触ったコミット {len(rows)} 件を同梱")
    print()
    print("   各案件のエージェントは次で受け取れます（人に確認してから適用する作り）:")
    print("     bash bin/rules-update.sh          # 確認だけ")
    print("     bash bin/rules-update.sh --apply  # 適用")


def cmd_unpublish(args):
    outdir = RELEASE / args.template
    if not outdir.is_dir():
        print(f"ℹ️ {args.template} はもともと配信していません")
        return
    shutil.rmtree(outdir)
    print(f"✅ {args.template} の配信を止めました（受け口は 503 not_published を返します）")
    print("   すでに受け取った案件のファイルは戻りません。取り消したいのは配布でなく")
    print("   トークンなら bin/rule-reporter.py revoke を使ってください。")


def cmd_status(_args):
    any_found = False
    for template in sorted(dr.PROFILES):
        meta_path = RELEASE / template / "meta.json"
        if not meta_path.is_file():
            print(f"{template:<12} 未公開")
            continue
        any_found = True
        if (RELEASE / template / ".publishing").exists():
            print(f"{template:<12} ⚠️ 公開が途中で終わっています（配信は止まっています）。publish し直してください")
            continue
        m = json.loads(meta_path.read_text(encoding="utf-8"))
        latest = dr.git("log", "-1", "--format=%h", "--abbrev=12", "--",
                        *dr.layer_rels(template))
        stale = "" if m.get("sha", "").startswith(latest) else f"  ⚠️ 最新は {latest}（未公開の変更あり）"
        print(f"{template:<12} {m['version']}  公開 {m['published_at'][:16].replace('T', ' ')}{stale}")
    if any_found:
        print()
        print("※ 公開してある版だけが各案件に配られます。直したら publish し直してください。")


def main(argv=None):
    ap = argparse.ArgumentParser(description="claude-rules テンプレートの配信版を公開する")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("publish", help="そのプロファイルの層を重ねたものを配信対象にする")
    p.add_argument("template", metavar="profile", choices=sorted(dr.PROFILES),
                   help="配布プロファイル（層の組み合わせ）")
    p.add_argument("--allow-dirty", action="store_true", help="未コミットの変更があっても公開する")
    p.set_defaults(func=cmd_publish)

    p = sub.add_parser("unpublish", help="配信を止める")
    p.add_argument("template", metavar="profile", choices=sorted(dr.PROFILES),
                   help="配布プロファイル")
    p.set_defaults(func=cmd_unpublish)

    p = sub.add_parser("status", help="いま何版を配信しているか")
    p.set_defaults(func=cmd_status)

    args = ap.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
