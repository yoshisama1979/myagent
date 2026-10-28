#!/usr/bin/env python3
"""ルール通知トークン（reporter ロール）の発行・失効・一覧。

claude-rules テンプレを使う各案件から「ルールの問題」を一方向で通知させるための
投函専用トークンを管理する。解析↔開発のやり取りに使う agent トークン（bin/mailbox.sh）
とは目的も権限も別物で、reporter は `rule-kaizen` 宛の send しかできない
（受信箱も done も 403。判定は site/tools/mailbox/index.php 側）。

ここが握る「取り消せること」：
  - トークン表そのものがホワイトリスト＝載っていないトークンは 403
  - 失効は行の削除でなく revoked:true ＋ 理由（後から「そんな番号あったか」にしない）
  - expires_at で放置トークンが永久に生きるのを構造的に防ぐ（既定 365 日）
  - 最終使用（日時・接続元IP）は API 側が data/mailbox/.state/ に記録し、list で並べる
    ＝把握していない場所から使われたら、見覚えのない IP として出る

トークン値を出すのは issue の1回だけ。台帳（data/rule-reporters.md・git 追跡）には
番号と案件名しか書かない＝台帳を見せてもトークンは漏れない。

このトークン1本で、案件は2つのことができる（受け口は別・鍵は共通）：
  - ルールの問題を目安箱へ投函する（tools/mailbox/・投函のみ）
  - 自分のテンプレートの最新版を取りに来る（tools/rules/・読み取りのみ）
どちらも失効させれば同時に止まる。取りに来られるのは発行時に紐づけた template だけ。
`--template` に渡すのは**配布プロファイル名**（配る層の組み合わせ）で、一覧の正は
`claude-rules/profiles.json`（同じ一覧をこのファイルに書き写さない）。

使い方:
  python3 bin/rule-reporter.py issue <案件名> --template website [--days 365]
  python3 bin/rule-reporter.py revoke <RR-NNN|案件名> --reason "理由"
  python3 bin/rule-reporter.py list
"""
import argparse
import contextlib
import fcntl
import importlib.util
import json
import os
import re
import secrets
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent
# 置き場は環境変数で差し替えられる＝テストが本番のトークン表・台帳に触れずに済む
# （本番の値は読まない・書かないのが automation.md §2 の前提）。
TOKENS = Path(os.environ.get("RULE_REPORTER_TOKENS") or PROJ / "data/secrets/mailbox-tokens.json")
LEDGER = Path(os.environ.get("RULE_REPORTER_LEDGER") or PROJ / "data/rule-reporters.md")
STATE = Path(os.environ.get("RULE_REPORTER_STATE") or PROJ / "data/mailbox/.state")

JST = timezone(timedelta(hours=9))
ROLE = "reporter"
def load_templates():
    """配布プロファイルの一覧。**読み取りと検証は `bin/distribute-rules.py` が正。**

    一覧の実体は `claude-rules/profiles.json` ひとつだが、**読み方を2箇所に書くと判断が割れる**。
    実際に割れていた（2026-10-28 の Codex レビュー）：`{"profiles": ["website"]}` という形で
    distribute-rules は落ち、こちらは「プロファイル名が1つある」として通してしまった。
    ハイフン付きのファイル名は import できないのでパスから読み込む（`bin/rules-publish.py` と同じ手）。
    """
    path = Path(__file__).with_name("distribute-rules.py")
    spec = importlib.util.spec_from_file_location("distribute_rules", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)      # 定義が壊れていればここで `❌ …` で止まる
    return tuple(sorted(mod.PROFILES))


TEMPLATES = load_templates()
PREFIX = "rr-"                      # agent_id の接頭辞（agent トークンと一目で見分ける）
LEDGER_HEADER = """# ルール通知トークン 発行台帳（rule-reporter）

`claude-rules` テンプレを使う案件が「ルールの問題」を目安箱（`rule-kaizen`）へ**一方向で**
通知するためのトークンの発行記録。**トークン値はここには書かない**（実体は
`data/secrets/mailbox-tokens.json`・git 追跡外）。このファイルは「誰に・いつ・いつまで出したか」
を社長がいつでも見られるようにするための台帳。

- 発行・失効は `python3 bin/rule-reporter.py issue|revoke`（手で編集しない＝表と台帳がズレる）
- 最終使用（日時・接続元IP）は `python3 bin/rule-reporter.py list` で見る
- 失効は行を消さず「失効」に変える。**消すと後から「そんな番号あったか」が分からなくなる**

| 番号 | 案件 | テンプレ | agent_id | 発行日 | 期限 | 状態 | 失効日 | 備考・失効理由 |
|------|------|----------|----------|--------|------|------|--------|----------------|
"""


def now():
    return datetime.now(JST)


def table_lock_wrapped(fn):
    """表を書き換えるサブコマンドをロックの中で走らせる。"""
    def wrapper(args):
        with table_lock():
            return fn(args)
    return wrapper


@contextlib.contextmanager
def table_lock():
    """トークン表の「読む→変える→置き換える」を直列化する。

    VPS には複数のエージェントセッションが同居していて、同時に issue/revoke が走ると
    後勝ちで片方の更新が消える（lost update）。消えるのは**本番の鍵表**なので、
    発行したはずのトークンが効かない／失効したはずのトークンが生きている、という
    気づきにくい形で壊れる。ロックは表の隣に置く（表そのものは置き換えるため）。
    """
    if not TOKENS.parent.is_dir():
        sys.exit(f"❌ トークン表の置き場がありません: {TOKENS.parent}")
    fd = os.open(str(TOKENS) + ".lock", os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def load_tokens():
    if not TOKENS.is_file():
        sys.exit(f"❌ トークン表がありません: {TOKENS}")
    with open(TOKENS, encoding="utf-8") as f:
        d = json.load(f)
    if not isinstance(d, dict):
        sys.exit("❌ トークン表の形式が不正です（オブジェクトではありません）")
    return d


def save_tokens(d):
    """一時ファイル + rename で原子的に置き換える（途中で壊れると全エージェントが 403 になるため）。"""
    tmp = TOKENS.with_suffix(".json.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, TOKENS)


def entries(d):
    """**発行した**投函専用トークンを (token, entry) で返す。

    `reporter_id` を持つものだけ＝このスクリプトが発行したもの。受信専用の sink
    （`rule-kaizen`）も権限を絞るため role は reporter だが、発行物ではないので
    台帳にも一覧にも出さない。"""
    return [(t, e) for t, e in d.items()
            if isinstance(e, dict) and e.get("role") == ROLE and e.get("reporter_id")]


def next_number(d):
    used = []
    for _, e in entries(d):
        m = re.fullmatch(r"RR-(\d+)", str(e.get("reporter_id", "")))
        if m:
            used.append(int(m.group(1)))
    return f"RR-{(max(used) + 1) if used else 1:03d}"


def slug(name):
    return re.sub(r"[^a-z0-9-]+", "-", name.strip().lower()).strip("-")


def make_id(project, explicit):
    """案件名（表示用・日本語可）から agent_id 用の識別子を決める。

    agent_id は API 側で英数字とハイフンに限られる（ファイル名・メッセージID に入るため）。
    日本語の案件名から機械的に削ると "テスト案件A" → "a" のような**意味のない識別子が黙って
    できる**ので、英数字だけで書かれていない案件名は --id を必須にする（黙って劣化させない）。
    """
    if explicit:
        s = slug(explicit)
        if s != explicit.strip().lower() or not s:
            sys.exit(f"❌ --id は英小文字・数字・ハイフンだけで指定してください: {explicit!r}")
        return s
    if not re.fullmatch(r"[A-Za-z0-9 _-]+", project.strip()):
        sys.exit(f"❌ 案件名 {project!r} に英数字以外が含まれます。\n"
                 f"   --id で識別子を指定してください（例: --id yoshida-dental）")
    s = slug(project)
    if not s:
        sys.exit(f"❌ 案件名から識別子を作れません: {project!r}（--id で指定してください）")
    return s


def find(d, key):
    """RR-NNN でも案件名（agent_id の接尾辞）でも引けるようにする。"""
    hits = [
        (t, e) for t, e in entries(d)
        if key in (e.get("reporter_id"), e.get("project"))
        or e.get("agent_id") in (key, PREFIX + slug(key))
    ]
    if not hits:
        sys.exit(f"❌ 該当する発行がありません: {key}")
    if len(hits) > 1:
        # 同じ案件に再発行していると表示名では複数当たる。失効済みは失効し直す必要がないので、
        # 有効なものが1つに絞れるならそれを対象にする（絞れなければ番号を出してもらう）。
        live = [h for h in hits if not h[1].get("revoked")]
        if len(live) != 1:
            sys.exit(f"❌ 複数一致しました: {[e.get('reporter_id') for _, e in hits]}（番号で指定してください）")
        hits = live
    return hits[0]


def write_ledger(d):
    """台帳はトークン表から毎回組み立て直す（正はトークン表・台帳は読むための写し）。"""
    rows = sorted(entries(d), key=lambda x: x[1].get("reporter_id", ""))
    out = [LEDGER_HEADER.rstrip("\n")]
    for _, e in rows:
        state = "失効" if e.get("revoked") else "有効"
        out.append("| {} | {} | {} | `{}` | {} | {} | {} | {} | {} |".format(
            e.get("reporter_id", ""), e.get("project", ""), e.get("template", "—"), e.get("agent_id", ""),
            e.get("issued_at", "")[:10], e.get("expires_at", ""), state,
            (e.get("revoked_at") or "")[:10], e.get("note", "") or e.get("revoked_reason", "") or "",
        ))
    out.append("")
    tmp = LEDGER.with_name(LEDGER.name + ".tmp")     # 途中で落ちても台帳を半端な状態にしない
    tmp.write_text("\n".join(out), encoding="utf-8")
    os.replace(tmp, LEDGER)


def seen_of(agent_id):
    p = STATE / f"seen-{agent_id}.json"
    if not p.is_file():
        return None
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


@table_lock_wrapped
def cmd_issue(args):
    d = load_tokens()
    project = args.project
    agent_id = PREFIX + make_id(project, args.id)
    for _, e in entries(d):
        if e.get("agent_id") == agent_id and not e.get("revoked"):
            sys.exit(f"❌ {agent_id} には有効なトークンがすでにあります（{e.get('reporter_id')}）。"
                     f"作り直すならまず revoke してください")
    if any(isinstance(e, dict) and e.get("agent_id") == agent_id and e.get("role") != ROLE
           for e in d.values()):
        sys.exit(f"❌ {agent_id} は別ロールで使われています（名前を変えてください）")

    number = next_number(d)
    token = "rr_" + secrets.token_hex(24)
    if token in d:
        sys.exit("❌ トークンが衝突しました（もう一度実行してください）")
    d[token] = {
        "agent_id": agent_id,
        "role": ROLE,
        "reporter_id": number,
        "project": project,
        "template": args.template,
        "issued_at": now().isoformat(timespec="seconds"),
        "expires_at": (now() + timedelta(days=args.days)).strftime("%Y-%m-%d"),
        "revoked": False,
    }
    save_tokens(d)
    write_ledger(d)

    print(f"✅ {number} を発行しました（案件: {project} / agent_id: {agent_id} / テンプレ: {args.template}）")
    print(f"   期限: {d[token]['expires_at']}（{args.days} 日）")
    print()
    print("   配布先の .env に入れる3行（この値を表示するのはこの1回だけ）:")
    print("     RULE_REPORT_URL=http://<この VPS の Tailscale IP>/tools/mailbox/")
    print("     RULE_UPDATE_URL=http://<この VPS の Tailscale IP>/tools/rules/")
    print(f"     RULE_REPORT_TOKEN={token}")
    print()
    print("   ⚠️ この値はコミット・ログ・チャットに貼らないこと。台帳には番号しか残りません。")


@table_lock_wrapped
def cmd_revoke(args):
    d = load_tokens()
    token, e = find(d, args.key)
    if e.get("revoked"):
        print(f"ℹ️ {e.get('reporter_id')} はすでに失効しています（{e.get('revoked_at', '')[:10]}）")
        return
    e["revoked"] = True
    e["revoked_at"] = now().isoformat(timespec="seconds")
    e["revoked_reason"] = args.reason
    save_tokens(d)
    write_ledger(d)
    print(f"✅ {e.get('reporter_id')}（{e.get('agent_id')}）を失効しました。以後の投函は 403 で弾かれます")
    print(f"   理由: {args.reason}")


def cmd_list(_args):
    d = load_tokens()
    rows = sorted(entries(d), key=lambda x: x[1].get("reporter_id", ""))
    if not rows:
        print("発行済みのルール通知トークンはありません")
        return
    today = now().strftime("%Y-%m-%d")
    fetched = []
    print(f"{'番号':<8} {'案件':<18} {'状態':<6} {'期限':<11} {'最終使用':<18} {'接続元':<16} 当日/通算")
    print("-" * 100)
    for _, e in rows:
        exp = (e.get("expires_at") or "").strip()   # 空＝期限なし（"" < today で期限切と誤判定しない）
        if e.get("revoked"):
            state = "失効"
        elif exp and exp < today:
            state = "期限切"
        else:
            state = "有効"
        s = seen_of(e.get("agent_id", "")) or {}
        last = (s.get("last_seen") or "")[:16].replace("T", " ") or "—"
        print(f"{e.get('reporter_id', ''):<8} {e.get('project', ''):<18} {state:<6} "
              f"{e.get('expires_at', ''):<11} {last:<18} {s.get('last_ip', '—'):<16} "
              f"{s.get('today', 0)}/{s.get('total', 0)}")
        if s.get("last_rules_version"):
            fetched.append((e, s))
    if fetched:
        # 「どの案件がいまどの版を持っているか」。取りに来た記録は API が同じ状態ファイルに
        # 残すので、別に配布台帳へ書き戻さなくても分かる（書き戻しは取りこぼす）。
        print()
        print("最後に取りに来たルールの版:")
        for e, s in fetched:
            when = (s.get("last_rules_at") or "")[:16].replace("T", " ")
            print(f"  {e.get('reporter_id', ''):<8} {e.get('project', ''):<18} "
                  f"{s['last_rules_version']}  ({when} / {s.get('last_rules_action', '')})")
    print()
    print("※ 見覚えのない接続元から使われていたら、その番号を revoke してください:")
    print("   python3 bin/rule-reporter.py revoke RR-NNN --reason \"理由\"")


def main(argv=None):
    ap = argparse.ArgumentParser(description="ルール通知トークンの発行・失効・一覧")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("issue", help="案件に投函専用トークンを発行する")
    p.add_argument("project", help="案件名（台帳に載る表示名。日本語可）")
    p.add_argument("--template", required=True, choices=TEMPLATES, metavar="PROFILE",
                   help="この案件が使うテンプレート（これ以外は取りに来られない）")
    p.add_argument("--id", help="agent_id に使う識別子（英小文字・数字・ハイフン）。"
                                "案件名が英数字だけでないときは必須")
    p.add_argument("--days", type=int, default=365, help="有効日数（既定 365）")
    p.set_defaults(func=cmd_issue)

    p = sub.add_parser("revoke", help="失効させる（行は消さず理由を残す）")
    p.add_argument("key", help="RR-NNN / 案件名 / agent_id")
    p.add_argument("--reason", required=True, help="失効理由（台帳に残る）")
    p.set_defaults(func=cmd_revoke)

    p = sub.add_parser("list", help="発行状況と最終使用を一覧する")
    p.set_defaults(func=cmd_list)

    args = ap.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
