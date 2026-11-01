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

終了コード（🚨 呼び出し側の契約）:
  0 … 成功／1 … 拒否・引数の誤り（何も書いていない）
  3 … **正（トークン表）には入ったが、台帳を組み直せなかった。** やり直してはいけない
      （`issue` のやり直しはトークンの二重発行になる）。標準出力はそのまま保管・引き渡し、
      原因を直してから `rebuild` で台帳を追いつかせる。`set -e` で回すときは 3 を失敗として
      中断させないこと（2026-11-01 の Codex 指摘。現状このスクリプトの呼び出し側は無い）。
  🚨 この 3 と「出力を出し切る」保証が効くのは**通常の例外のとき**だけ。トークン表を保存した
      あとに Ctrl-C・SIGTERM・強制終了が入ると、**正にだけ入ってトークン値を誰も受け取って
      いない行**が残りうる（`issue` のみ）。その場合は `list` でその番号を見つけて `revoke`
      してから発行し直す（台帳は `rebuild` で揃う）。

使い方:
  python3 bin/rule-reporter.py issue <案件名> --template website [--days 365]
  python3 bin/rule-reporter.py revoke <RR-NNN|案件名> --reason "理由"
  python3 bin/rule-reporter.py migrated <RR-NNN|案件名> [--item TB-019] [--on 2026-11-01]
  python3 bin/rule-reporter.py rebuild          # 台帳を組み直す（列や書き方を変えたとき）
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
VALID_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
# 手当ての名前。番号の形に限る＝台帳の列と表のキーに自由文を入れない（列がずれる・検索できない）
VALID_ITEM = re.compile(r"[A-Za-z]{1,6}-\d{1,4}")
# 印の入れ物そのものが読めないとき＝**どの手当ても「不明」**。番号ごとの判定でもこれを破損に数える
# （数えないと、入れ物が壊れた案件が番号別の一覧では「申告なし」に化ける）
ALL_BROKEN = "(記録そのものの形が壊れています)"
UNNAMED = "名前が読めない項目"      # 名前が読めない印の件数だけを出すときの頭（中身は出さない）
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

- 発行・失効・手当ての記録は `python3 bin/rule-reporter.py issue|revoke|migrated`（手で編集しない＝表と台帳がズレる）
- 最終使用（日時・接続元IP）は `python3 bin/rule-reporter.py list` で見る
- 失効は行を消さず「失効」に変える。**消すと後から「そんな番号あったか」が分からなくなる**
- 「手当て」列＝**案件側で1回だけ必要な手作業**の済み具合（例: TB-019＝更新スクリプトの自己上書き）。
  🚨 **印が入るのは案件からの申告があったときだけ。** こちらに残る記録（`list` の「最後に取りに来た版」）は
  **取りに来たこと**しか示さず、**適用できたことの証拠にならない**（TB-019 は取得の後で落ちる）。
  入れ方＝`python3 bin/rule-reporter.py migrated <RR-NNN|案件名> --item TB-019 [--on 済んだ日]`

| 番号 | 案件 | テンプレ | agent_id | 発行日 | 期限 | 状態 | 手当て | 失効日 | 備考・失効理由 |
|------|------|----------|----------|--------|------|------|--------|--------|----------------|
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


def order_key(e):
    """行の新しさ（発行日時, 番号）。どちらか読めなければ None＝順番を決められない。

    🚨 文字列の辞書順で並べると、欠損・形の違い・未来の文字列で「最新」を取り違える。
    🚨 日時は秒までなので**同じ秒の行が複数できる**（続けて発行すると実際に起きる）。番号
    （RR-NNN）は発行順に増えるので第2キーに使う＝JSON の並び順に結果を左右させない。
    タイムゾーンが無い値は JST として扱う（混ぜて比べると TypeError で落ちる）。
    """
    try:
        t = datetime.fromisoformat(str(e.get("issued_at", "")))
    except (TypeError, ValueError):
        return None
    m = re.fullmatch(r"RR-(\d+)", str(e.get("reporter_id", "")))
    if not m:
        return None
    return (t if t.tzinfo else t.replace(tzinfo=JST), int(m.group(1)))


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
            sys.exit(f"❌ --id は英小文字・数字・ハイフンだけで指定してください: {cell(explicit)!r}")
        return s
    if not re.fullmatch(r"[A-Za-z0-9 _-]+", project.strip()):
        # 🚨 拒否するときも伏字（案件名に貼られたトークンがそのまま端末とログに残る）
        sys.exit(f"❌ 案件名 {cell(project)!r} に英数字以外が含まれます。\n"
                 f"   --id で識別子を指定してください（例: --id yoshida-dental）")
    s = slug(project)
    if not s:
        sys.exit(f"❌ 案件名から識別子を作れません: {cell(project)!r}（--id で指定してください）")
    return s


def find(d, key):
    """RR-NNN でも案件名（agent_id の接尾辞）でも引けるようにする。"""
    hits = [
        (t, e) for t, e in entries(d)
        if key in (e.get("reporter_id"), e.get("project"))
        or e.get("agent_id") in (key, PREFIX + slug(key))
    ]
    if not hits:
        sys.exit(f"❌ 該当する発行がありません: {cell(key)}")
    if len(hits) > 1:
        # 同じ案件に再発行していると表示名では複数当たる。失効済みは失効し直す必要がないので、
        # 有効なものが1つに絞れるならそれを対象にする（絞れなければ番号を出してもらう）。
        live = [h for h in hits if not h[1].get("revoked")]
        if len(live) != 1:
            sys.exit(f"❌ 複数一致しました: {[e.get('reporter_id') for _, e in hits]}（番号で指定してください）")
        hits = live
    return hits[0]


TOKEN_LIKE = re.compile(r"rr_[0-9a-f]{16,}")


def redact(v):
    """トークンらしき値を伏字にする。

    案件名・失効理由は人が書く自由文で、**台帳（git 追跡）と画面に無条件で出る**。誤って
    `rr_…` を貼られたらそのまま残るので、出すところで落とす（入力は拒否しない＝失効は
    急ぐ操作で、理由の書き方で止めたくない）。
    """
    return TOKEN_LIKE.sub("rr_…（伏字）", str(v if v is not None else ""))


def cell(v):
    """表のセル1つ分に整える。

    🚨 `|` と改行をそのまま書くと**列がずれる**＝失効理由に `|` を1つ入れただけで、以降の列が
    1つずつ隣へ動き「状態」の欄に日付が出るような、気づきにくい誤表示になる（理由や備考は
    人が書く自由文なので実際に起こりうる）。全角の `｜` に置き換えて、意味は残しつつ列を守る。
    """
    return redact(v).replace("|", "｜").replace("\r", " ").replace("\n", " ")


def parse_day(v):
    """`YYYY-MM-DD` として実在する日なら date を返す（読めなければ None）。

    🚨 形だけ見て通すと `2026-99-99` が通る。文字列の辞書順比較で済ませると
    `"ちょっと先"` や `"2099/01/01"` が「期限内」に化ける（どちらも実際に起きうる＝
    API 側は読めない期限を fail-closed で弾くので、台帳だけ「有効」と言うと食い違う）。
    """
    if not isinstance(v, str) or not VALID_DATE.fullmatch(v):
        return None
    try:
        return datetime.strptime(v, "%Y-%m-%d").date()
    except ValueError:          # 2026-99-99・2026-02-30 のような存在しない日
        return None


def valid_day(v):
    """申告日として読めるか（**書くときと同じ検査を読むときにもかける**）。未来は申告日にならない。"""
    day = parse_day(v)
    return day is not None and day <= now().date()


def read_migrations(e):
    """印を読んで (済み, 取消済み, 読めない) に分ける。

    🚨 **「申告が来ていない」「取り消した」「印が壊れている」を同じ字で出さない。** 同じにすると、
    本当は済んでいた案件が黙って未申告に混ざり、直す対象として浮かばない（この道具で
    何度も踏んだ型＝判定不能を健全・未使用と同じ見え方にしない）。取り消しも、**消した痕跡**が
    無いと「一度も申告が来ていない」と区別できず、あとから「そんな申告あったか」が分からない
    （台帳の規律＝失効を行の削除でなく印で残すのと同じ理由。2026-11-01 の Codex 指摘）。
    """
    if "migrations" not in e:
        return [], [], []       # 欄が無い＝まだ申告が来ていない
    # 空の dict も「印が1つも無い」＝未申告として扱う（どの番号についても何も言っていない）。
    # 🚨 取り消しが `{}` を残す作りなら「取消済み」が未申告に戻るが、取り消しは**痕跡を残す**
    #    形にしたのでそうならない。本番のトークン表に `migrations` を持つ行は0件（2026-11-01 実測）
    #    ＝旧い形の `{}` は存在しない。引き継ぎでは「欄がある」こと自体を最新の状態として使う。
    m = e["migrations"]
    if not isinstance(m, dict):
        # 🚨 JSON の null もここに入る。`e.get()` で取ると**キーが無いのと同じ形**になり、
        #    壊れた記録が「申告なし」に化ける（2026-11-01 の Codex 指摘）。
        return [], [], [ALL_BROKEN]
    done, undone, broken, unnamed = [], [], [], 0
    for item, rec in m.items():
        at = rec.get("at") if isinstance(rec, dict) else None
        if not (isinstance(item, str) and VALID_ITEM.fullmatch(item)):
            # 🚨 読めない名前は**中身を出さない**＝台帳は git 追跡なので、誤ってトークンのような値が
            #    入っていた場合に書き込んでしまう（2026-11-01 の Codex 指摘）。件数だけ数える。
            unnamed += 1
            continue
        has_off = isinstance(rec, dict) and "undone_at" in rec
        off = rec.get("undone_at") if isinstance(rec, dict) else None
        if has_off and not valid_day(off):
            # 🚨 取消の日付が読めないのに `at` を見て「済み」に倒すと、**取り消したものが
            #    済みに化ける**（取消が壊れたのか無効なのか区別できない状態＝判定不能）。
            #    キーがあるかどうかで先に分ける（2026-11-01 の Codex 指摘）。
            broken.append(item)
        elif has_off:
            undone.append((item, off))  # 取り消した痕跡（済みにも破損にも数えない）
        elif valid_day(at):
            done.append((item, at))
        else:
            broken.append(item)         # 名前は番号の形だけ＝出しても秘密にならない
    if unnamed:
        broken.append(f"{UNNAMED}{unnamed}件")
    key = lambda x: (x[1], x[0])        # noqa: E731
    return (sorted(done, key=key, reverse=True), sorted(undone, key=key, reverse=True),
            sorted(broken))


def box_unreadable(broken):
    """その案件の印が部分的にでも読めないか。

    🚨 名前の読めない印が1つでもあると、**それがその番号の申告だった可能性**を否定できない
    （名前そのものが壊れているので突き合わせられない）。なので番号別の判定で「未申告」と
    言い切らず破損として出す＝判定できないものを「申告が来ていない」と同じ字にしない。
    """
    return any(b == ALL_BROKEN or b.startswith(UNNAMED) for b in broken)


def migrations_text(e):
    done, undone, broken = read_migrations(e)
    parts = [f"{item} {at}" for item, at in done]
    parts += [f"{item} 取消（{off}）" for item, off in undone]
    if broken:
        parts.append("⚠ 記録破損（{}）".format("・".join(broken)))
    return " / ".join(parts) or "—"


def state_of(e, today):
    """台帳と一覧で同じ判定を使う（**状態を2箇所で決めると食い違う**）。

    実際に食い違っていた（2026-11-01 の Codex レビュー）＝台帳は `revoked` だけを見ていたので、
    期限の切れた案件を「有効」と書き、同じ案件を `list` は「期限切」と出していた。
    """
    if e.get("revoked"):
        return "失効"
    # str() を通す＝表に数値や配列が入っていても落ちない（正を書き換えたあとに落ちると復旧案内が出ない）
    exp = str(e.get("expires_at") or "").strip()   # 空＝期限なし（期限切と誤判定しない）
    if not exp:
        return "有効"
    day = parse_day(exp)
    if day is None:
        # 🚨 読めない期限を「有効」に倒さない。API は読めない期限を 500 で弾く（fail-closed）ので、
        #    ここで「有効」と書くと台帳だけが健全に見えて、実際には投函も取得もできない状態になる。
        return "期限不明"
    return "期限切" if day < datetime.strptime(today, "%Y-%m-%d").date() else "有効"


def write_ledger(d):
    """台帳はトークン表から毎回組み立て直す（正はトークン表・台帳は読むための写し）。"""
    rows = sorted(entries(d), key=lambda x: str(x[1].get("reporter_id", "")))
    out = [LEDGER_HEADER.rstrip("\n")]
    today = now().strftime("%Y-%m-%d")
    for _, e in rows:
        state = state_of(e, today)
        out.append("| {} | {} | {} | `{}` | {} | {} | {} | {} | {} | {} |".format(
            cell(e.get("reporter_id", "")), cell(e.get("project", "")), cell(e.get("template", "—")),
            cell(e.get("agent_id", "")),
            cell(str(e.get("issued_at", ""))[:10]), cell(e.get("expires_at", "")), state,
            cell(migrations_text(e)),
            cell(str(e.get("revoked_at") or "")[:10]),
            cell(e.get("note", "") or e.get("revoked_reason", "") or ""),
        ))
    out.append("")
    tmp = LEDGER.with_name(LEDGER.name + ".tmp")     # 途中で落ちても台帳を半端な状態にしない
    tmp.write_text("\n".join(out), encoding="utf-8")
    os.replace(tmp, LEDGER)


def persist(d, what):
    """正（トークン表）を置き換えてから台帳を組み直す。

    🚨 **ファイル単位では原子的だが、2つのファイルの間は原子的でない。** 表の置き換えが
    成功して台帳の書き込みが落ちると「正は入っているのに台帳は古い」状態が残る。例外のまま
    落とすと、操作した人は**失敗したと読んでやり直す**＝`issue` ならトークンが二重に出る。
    なのでここで掴み、「正には入った・やり直さなくてよい・台帳だけ rebuild が要る」と言う。
    """
    save_tokens(d)
    try:
        write_ledger(d)
    except Exception as ex:     # noqa: BLE001 ── 🚨 OSError だけでは足りない
        # 表の中身が想定外の型でも組み立てで落ちうる（型は潰したが、潰し漏れでも同じ事故になる）。
        # ここで掴まないと traceback だけが出て「正は入っている」ことが伝わらず、やり直されてしまう。
        # BaseException にはしない（Ctrl-C は握りつぶさない）。
        print(f"⚠️ {what}はトークン表（正）に入りましたが、台帳を書けませんでした: {ex}\n"
              f"   🚨 やり直さないでください（正には入っています）。原因を直してから:\n"
              f"      python3 bin/rule-reporter.py rebuild", file=sys.stderr)
        return False
    return True


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

    # 🚨 手当てが済んだのは**案件**で、トークン行ではない。失効→再発行（期限切れの更新・
    #    識別子の打ち直し＝RR-013→RR-014 で実際にあった）のたびに印が消えると、済んだ案件が
    #    「未申告」に戻って同じ依頼をもう一度出してしまう。前の行から読める印を引き継ぐ。
    #
    # 🚨 引き継ぐのは**いちばん新しい行だけ**（全履歴の寄せ集めにしない）。寄せ集めると、
    #    `--undo` で取り消した印が**古い行に残っている分から復活する**（2026-11-01 の Codex 指摘）。
    #    取り消しは現在の行からしか消えないので、履歴を合算した瞬間に訂正が無かったことになる。
    #    `migrations` の欄を持つ行だけを候補にする＝取り消して空になった行（`{}`）も
    #    「この案件の最新の状態」として効く。欄を持たない古い行はこの仕組みの前の行なので飛ばす。
    prev = [e for _, e in entries(d)
            if e.get("agent_id") == agent_id and "migrations" in e]
    carried, kept_broken, undecided, carry_note = None, 0, "", ""
    if args.carry_from:
        # 🚨 識別子を打ち直す再発行（RR-013→RR-014 で実際にあった）では agent_id が変わるので
        #    自動では引き継げない。案件名で推測すると**別の案件の印を持ち込む**（表示名は重複を
        #    許している）ので、**どの行から引き継ぐかは人が指定する**（2026-11-01 の Codex 指摘）。
        if not re.fullmatch(r"RR-\d+", args.carry_from):
            # 番号に限る＝案件名や agent_id で引けると、打ち間違いで別の行を拾いやすい
            sys.exit(f"❌ --carry-from は RR-NNN の形で指定してください: {cell(args.carry_from)!r}")
        _, src = find(d, args.carry_from)
        if str(src.get("project", "")) != project:
            # 🚨 **別案件の印を持ち込めない**ようにする。番号の打ち間違いで、やっていない案件が
            #    「済み」になるのがいちばん危ない（2026-11-01 の Codex 指摘）。案件名で一致を見る
            #    のは、引き継ぎの判断を人がしていることの確認＝推測ではない。
            sys.exit(f"❌ {src.get('reporter_id')} は案件名が違います"
                     f"（{cell(src.get('project'))} ≠ {cell(project)}）。\n"
                     f"   別案件の手当ての記録は引き継げません（番号の打ち間違いではありませんか）")
        if "migrations" not in src:
            sys.exit(f"❌ {src.get('reporter_id')} に手当ての記録はありません"
                     f"（--carry-from を外すか、別の番号を指定してください）")
        box = src.get("migrations")
        carried = ({k: (dict(v) if isinstance(v, dict) else v) for k, v in box.items()}
                   if isinstance(box, dict) else box)
        kept_broken = len(read_migrations(src)[2])
        carry_note = f"{src.get('reporter_id')} から"
    elif prev:
        stamped = [(order_key(e), e) for e in prev]
        if any(k is None for k, _ in stamped):
            # 🚨 順番が決まらないまま引き継ぐと、取り消した印の復活にも、済みの取りこぼしにも
            #    倒れる（どちらに倒れるかも読めない）。推測せず引き継がず、その旨を言う。
            undecided = "前の発行の日時か番号が読めないため"
        else:
            stamped.sort(key=lambda x: x[0])
            src = stamped[-1][1]
            # 🚨 **最新行の印をそのまま（読めない分も含めて）引き継ぐ。** 読めない印を落とすと、
            #    新しい行は「判定不能」ではなく「未申告」になり、**判定できなかったことが
            #    発行の瞬間だけの警告で消える**（2026-11-01 の Codex 指摘）。また、読めない名前の
            #    印と読める済み印が同居しているとき、読めない分だけ落とすと**その番号が「済み」に
            #    確定してしまう**（読めない印がその番号の取消だった可能性を切り捨てる）。
            #    丸ごと運べば、新しい行でも同じ判定（破損は破損・取消は取消）になる。
            box = src.get("migrations")
            carried = ({k: (dict(v) if isinstance(v, dict) else v) for k, v in box.items()}
                       if isinstance(box, dict) else box)
            _done, _undone, broken = read_migrations(src)
            kept_broken = len(broken)

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
    if (prev or args.carry_from) and not undecided:
        d[token]["migrations"] = carried    # 空の dict も「最新の状態」として運ぶ
    ok = persist(d, "発行")

    print(f"✅ {number} を発行しました（案件: {cell(project)} / agent_id: {agent_id} "
          f"/ テンプレ: {args.template}）")
    print(f"   期限: {d[token]['expires_at']}（{args.days} 日）")
    shown, undone_shown, _ = read_migrations(d[token])
    if shown or undone_shown:
        print(f"   {carry_note or '前の発行'}の手当ての記録を引き継ぎました: "
              + " / ".join([f"{i} {at}" for i, at in shown]
                           + [f"{i} 取消（{off}）" for i, off in undone_shown]))
    elif args.carry_from and not kept_broken:
        # 中身が空でも「引き継いだ」ことは言う＝黙ると、指定したのに効かなかったように見える
        print(f"   {carry_note}手当ての記録を引き継ぎました（読める印は無し＝未申告のまま）")
    if kept_broken:
        # 読めない印も運ぶ＝新しい行でも「判定不能」として残る（記録し直すまで消えない）
        print(f"   ⚠️ 読めない印 {kept_broken}件もそのまま引き継ぎました"
              f"（この案件は判定不能のままです＝migrated で記録し直してください）")
    if undecided:
        print(f"   ⚠️ {undecided}、手当ての記録を引き継いでいません"
              f"（済んでいるなら migrated で記録し直してください）")
    if not args.carry_from and not prev:
        # 識別子を打ち直した再発行は agent_id が変わる＝自動では見つからない。黙らずに案内する
        same_name = [e for _, e in entries(d)
                     if e.get("project") == project and e.get("agent_id") != agent_id
                     and "migrations" in e]
        if same_name:
            print(f"   ⚠️ 同じ案件名の過去の発行が {len(same_name)}件あります"
                  f"（{'・'.join(str(e.get('reporter_id')) for e in same_name)}）。"
                  f"識別子を変えた再発行なら、手当ての記録は自動では引き継ぎません:")
            if len(same_name) == 1:
                print(f"      python3 bin/rule-reporter.py issue … --carry-from "
                      f"{same_name[0].get('reporter_id')}")
            else:
                # 🚨 候補が複数あるのに1つを選んだコマンドを出すと、**こちらが推測した番号**を
                #    人がそのまま打つ（別案件・古い状態の取り込みを誘導する）。番号は挙げるだけ
                print("      python3 bin/rule-reporter.py issue … --carry-from "
                      "<上の番号から1つ選んでください>")
    live_same = [e for _, e in entries(d)
                 if e.get("project") == project and not e.get("revoked")
                 and e.get("agent_id") != agent_id]
    if live_same:
        # 🚨 同じ案件名の有効な行が複数＝一覧の件数が「案件の数」にならない（行の数になる）
        print(f"   ⚠️ 同じ案件名で有効な行がほかに {len(live_same)}件あります"
              f"（{'・'.join(str(e.get('reporter_id')) for e in live_same)}）。"
              f"古いほうを revoke しないと、手当ての一覧で同じ案件が二重に数えられます")
    print()
    print("   配布先の .env に入れる3行（この値を表示するのはこの1回だけ）:")
    print("     RULE_REPORT_URL=http://<この VPS の Tailscale IP>/tools/mailbox/")
    print("     RULE_UPDATE_URL=http://<この VPS の Tailscale IP>/tools/rules/")
    print(f"     RULE_REPORT_TOKEN={token}")
    print()
    print("   ⚠️ この値はコミット・ログ・チャットに貼らないこと。台帳には番号しか残りません。")
    # 🚨 終了コードを返すのはトークンを出し切ったあと（台帳が書けなくても、この値は失うと戻らない）
    return None if ok else 3


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
    ok = persist(d, "失効")
    print(f"✅ {e.get('reporter_id')}（{e.get('agent_id')}）を失効しました。以後の投函は 403 で弾かれます")
    print(f"   理由: {cell(args.reason)}")
    return None if ok else 3


@table_lock_wrapped
def cmd_migrated(args):
    """「案件側で1回だけ要る手作業」が済んだことを記録する。

    🚨 **これは申告を書き写すだけの道具で、済んだことの検証はしていない。** 検証できないのには
    理由がある＝こちらに残るのは「取りに来た」記録（`data/mailbox/.state/`）だけで、TB-019 は
    **取得したあとに落ちる**ので、取りに来た事実は適用の成否を区別しない。案件側の版の刻印を
    こちらへ送らせる仕掛けは `common/bin/rules-update.sh` を変えることになり、**その移行が済むまでは
    触れない**（TB-018／TB-020 と同じ条件）ので、当面は申告が唯一の材料。
    """
    item = args.item
    if not VALID_ITEM.fullmatch(item):
        sys.exit(f"❌ --item は TB-019 のような番号の形で指定してください: {item!r}")
    d = load_tokens()
    _, e = find(d, args.key)
    # 🚨 失効した行でも**取り消しは通す**。失効行は再発行のときの引き継ぎ元になるので、
    #    ここで拒否すると「誤って付けた済み」を訂正できず、次の発行で新しい行に乗り移る
    #    （2026-11-01 の Codex 指摘）。足すほうは引き続き拒否する。
    if e.get("revoked") and not args.undo:
        sys.exit(f"❌ {e.get('reporter_id')} は失効しています（配布を受けていないので手当ては要りません）。"
                 f"\n   取り違えでなければ、まず issue で発行し直してください"
                 f"\n   誤って付けた印を消すだけなら --undo は失効した行にも使えます")
    if not args.undo and state_of(e, now().strftime("%Y-%m-%d")) == "期限切":
        # 弾かない＝移行の話は鍵の期限とは別。ただし期限が切れていると取りに来られないので言う
        print(f"⚠️ {e.get('reporter_id')} のトークンは期限切れです（取りに来るには発行し直しが要ります）",
              file=sys.stderr)

    raw = e.get("migrations")
    bad_box = "migrations" in e and not isinstance(raw, dict)   # null も壊れた入れ物として扱う
    m = raw if isinstance(raw, dict) else {}
    who = f"{e.get('reporter_id')}（{cell(e.get('project'))}）"
    if args.undo:
        if bad_box:
            # 🚨 ここで「作り直します」と言って return すると、台帳は破損のままなのに
            #    直したように読める（2026-11-01 の Codex 指摘）。できないことをできないと言う。
            sys.exit(f"❌ {who} の印の記録そのものが読めない形です（項目ごとの取り消しはできません）。\n"
                     f"   正しい申告が分かっているなら記録し直してください（入れ物ごと作り直します）:\n"
                     f"      python3 bin/rule-reporter.py migrated {e.get('reporter_id')} "
                     f"--item {item} --on 済んだ日")
        rec = m.get(item)
        if rec is None:
            print(f"ℹ️ {who} に {item} の印はありません")
            return None
        if isinstance(rec, dict) and valid_day(rec.get("undone_at")):
            print(f"ℹ️ {who} の {item} はすでに取り消されています（{rec.get('undone_at')}）")
            return None
        # 🚨 消さずに「取り消した」印を残す＝消すと「一度も申告が来ていない」と見分けられない
        #    （失効を行の削除でなく印で残すのと同じ規律）。引き継ぎでもこの痕跡を持っていく。
        today = now().strftime("%Y-%m-%d")
        m[item] = {"at": (rec.get("at") if isinstance(rec, dict) else None),
                   "undone_at": today, "recorded_at": now().isoformat(timespec="seconds")}
        e["migrations"] = m
        ok = persist(d, "印の取り消し")
        print(f"✅ {who} の {item} の印を取り消しました（取消済みとして残ります）")
        return None if ok else 3
    if bad_box:                     # 🚨 中身は出さない（申告メモやトークンが入っていても流さない）
        print(f"⚠️ {e.get('reporter_id')} の印の記録が読めない形だったので作り直します"
              f"（{type(raw).__name__}・内容は表示しません）", file=sys.stderr)

    on = args.on or now().strftime("%Y-%m-%d")
    if not VALID_DATE.fullmatch(on):
        sys.exit(f"❌ --on は YYYY-MM-DD で指定してください: {on!r}")
    try:
        day = datetime.strptime(on, "%Y-%m-%d").date()
    except ValueError:
        sys.exit(f"❌ そんな日付はありません: {on!r}")
    if day > now().date():
        # 未来の日付は打ち間違い（2027 と打つ等）。入れてしまうと「済み」が先に立って気づけない
        sys.exit(f"❌ 未来の日付は受けつけません: {on}（今日は {now().strftime('%Y-%m-%d')}）")

    was = m.get(item)
    was_undone = isinstance(was, dict) and valid_day(was.get("undone_at"))
    m[item] = {"at": on, "recorded_at": now().isoformat(timespec="seconds"), "note": args.note or ""}
    e["migrations"] = m
    ok = persist(d, "手当ての記録")
    if was_undone:
        print(f"ℹ️ {who} の {item} は取り消されていました（{was.get('undone_at')}）→ {on} で記録し直しました")
    elif isinstance(was, dict) and valid_day(was.get("at")):
        print(f"ℹ️ {who} の {item} はすでに {was.get('at')} で記録済みでした → {on} に上書きしました")
    elif was is not None:
        # 読めない印の上書き＝「新しく済みにした」と同じ字で言うと、壊れていたことが残らない
        print(f"ℹ️ {who} の {item} には読めない印が入っていました → {on} で記録し直しました")
    else:
        print(f"✅ {who} の {item} を済み（{on}）にしました")
    if args.note:
        # 🚨 本文は出さない（トークンのような値を書かれたとき、端末とログに流してしまう）
        print("   申告のメモを表に記録しました（内容は表示しません・台帳にも出ません）")
    print("   ⚠️ この印は申告を書き写したものです（こちらで適用の成否は確かめられません）")
    return None if ok else 3


@table_lock_wrapped
def cmd_rebuild(_args):
    """台帳をトークン表から組み直す（表は読むだけ・1文字も変えない）。

    台帳は issue / revoke / migrated のついでに書き直される写しなので、**列や書き方を変えても
    次の発行まで古い形のまま残る**。手で直すのは禁止（表とズレる）ので、組み直す口を用意する。
    """
    d = load_tokens()
    write_ledger(d)
    print(f"✅ 台帳を組み直しました: {LEDGER}（{len(entries(d))}件）")


def cmd_list(args):
    d = load_tokens()
    rows = sorted(entries(d), key=lambda x: str(x[1].get("reporter_id", "")))
    if not rows:
        print("発行済みのルール通知トークンはありません")
        return
    today = now().strftime("%Y-%m-%d")
    fetched = []
    print(f"{'番号':<8} {'案件':<18} {'状態':<6} {'期限':<11} {'最終使用':<18} {'接続元':<16} 当日/通算")
    print("-" * 100)
    for _, e in rows:
        state = state_of(e, today)
        s = seen_of(cell(e.get("agent_id", ""))) or {}
        # cell() を通す＝表や状態ファイルに配列・辞書が入っていても幅指定で落ちない
        # （落ちると一覧そのものが出ず、ほかの案件の状態も見えなくなる）
        last = cell(s.get("last_seen"))[:16].replace("T", " ") or "—"
        print(f"{cell(e.get('reporter_id', '')):<8} {cell(e.get('project', '')):<18} {state:<6} "
              f"{cell(e.get('expires_at', '')):<11} {last:<18} {cell(s.get('last_ip')) or '—':<16} "
              f"{cell(s.get('today', 0))}/{cell(s.get('total', 0))}")
        if s.get("last_rules_version"):
            fetched.append((e, s))
    if fetched:
        # 「どの案件がいまどの版を持っているか」。取りに来た記録は API が同じ状態ファイルに
        # 残すので、別に配布台帳へ書き戻さなくても分かる（書き戻しは取りこぼす）。
        print()
        print("最後に取りに来たルールの版:")
        for e, s in fetched:
            when = cell(s.get("last_rules_at"))[:16].replace("T", " ")
            print(f"  {cell(e.get('reporter_id', '')):<8} {cell(e.get('project', '')):<18} "
                  f"{cell(s['last_rules_version'])}  ({when} / {cell(s.get('last_rules_action', ''))})")
    # 「1回だけの手当て」の済み具合。🚨 上の「最後に取りに来た版」とは別の話なので節を分ける
    # ＝取りに来た記録は**取得**までしか示さず、適用できたかは申告でしか分からない。
    # 🚨 対象は「失効していない案件」＝**期限切れも含める**。期限は鍵の話で、移行が済んだか
    #    どうかとは別の軸。除くと台帳（期限切も行が残る）と件数が食い違う。
    live = [e for _, e in rows if not e.get("revoked")]
    item = getattr(args, "item", None)
    if item and not VALID_ITEM.fullmatch(item):
        sys.exit(f"❌ --item は TB-019 のような番号の形で指定してください: {item!r}")
    if item:
        done, cancelled, broken, todo = [], [], [], []
        for e in live:
            ok, off, bad = read_migrations(e)
            # 🚨 判定の順は「破損 → 取消 → 済み」。読めない印が同居しているときに済みを先に
            #    決めると、**その読めない印がこの番号の取消だった可能性**を切り捨てて断定して
            #    しまう（box_unreadable の理屈は済みの有無と関係なく成り立つ）。
            if item in bad or box_unreadable(bad):
                broken.append(e)      # 印はあるが読めない＝未申告と混ぜない（直す対象）
            elif any(i == item for i, _ in ok):
                done.append(e)
            elif any(i == item for i, _ in off):
                cancelled.append(e)   # 申告を取り消した＝「一度も来ていない」と混ぜない
            else:
                todo.append(e)
        print()
        print(f"{item} の手当て: 済み {len(done)}件 / 未申告 {len(todo)}件"
              + (f" / 取消済み {len(cancelled)}件" if cancelled else "")
              + (f" / ⚠️記録破損 {len(broken)}件" if broken else "")
              + f"（失効していない {len(live)}件のうち）")
        for label, group in (("⚠️破損", broken), ("未申告", todo),
                             ("取消済", cancelled), ("済み", done)):
            for e in group:
                st = state_of(e, today)
                tail = ""
                if group is done:
                    tail = "  ({})".format(next(a for i, a in read_migrations(e)[0] if i == item))
                elif group is cancelled:
                    tail = "  (取消 {})".format(next(a for i, a in read_migrations(e)[1] if i == item))
                print(f"  {label}  {cell(e.get('reporter_id', '')):<8} {cell(e.get('project', ''))}"
                      f"{'（' + st + '）' if st != '有効' else ''}{tail}")
    elif live:
        # 🚨 1件も申告が無いときに節ごと消すと、移行を始めた直後（全件未申告）がいちばん見えない
        print()
        print("1回だけの手当て（案件側の手作業・申告で入る）:")
        for e in live:
            print(f"  {cell(e.get('reporter_id', '')):<8} {cell(e.get('project', '')):<18} "
                  f"{migrations_text(e)}")
    print()
    print("※ 「手当て」の印は案件からの申告で入れる。🚨 上の「取りに来た版」は**取得**の記録で、")
    print("   適用できたことの証拠にはならない（TB-019 は取得のあとで落ちる）:")
    print("   python3 bin/rule-reporter.py migrated RR-NNN --item TB-019")
    print("   未済だけ数える:  python3 bin/rule-reporter.py list --item TB-019")
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
    p.add_argument("--carry-from", metavar="RR-NNN",
                   help="手当ての記録をこの番号の行から引き継ぐ（識別子を変えた再発行のとき。"
                        "同じ識別子なら指定しなくても自動で引き継ぐ）")
    p.set_defaults(func=cmd_issue)

    p = sub.add_parser("revoke", help="失効させる（行は消さず理由を残す）")
    p.add_argument("key", help="RR-NNN / 案件名 / agent_id")
    p.add_argument("--reason", required=True, help="失効理由（台帳に残る）")
    p.set_defaults(func=cmd_revoke)

    p = sub.add_parser("migrated", help="案件側で1回だけ要る手作業が済んだことを記録する（申告の写し）")
    p.add_argument("key", help="RR-NNN / 案件名 / agent_id")
    p.add_argument("--item", default="TB-019", help="手当ての番号（既定 TB-019）")
    p.add_argument("--on", help="済んだ日（YYYY-MM-DD・既定は今日）。未来の日付は受けつけない")
    p.add_argument("--note", help="申告の内容（台帳には出さない・表に残す）")
    p.add_argument("--undo", action="store_true", help="印を取り消す（取り違えたとき）")
    p.set_defaults(func=cmd_migrated)

    p = sub.add_parser("rebuild", help="台帳をトークン表から組み直す（表は変えない）")
    p.set_defaults(func=cmd_rebuild)

    p = sub.add_parser("list", help="発行状況と最終使用を一覧する")
    p.add_argument("--item", help="この手当ての済み／未を数えて並べる（例: TB-019）")
    p.set_defaults(func=cmd_list)

    args = ap.parse_args(argv)
    # 3＝正（トークン表）には入ったが台帳を組み直せなかった（persist が申告済み）。
    # 0 と混ぜると、無人で回したときに食い違いが残ったことに気づけない。
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
