#!/usr/bin/env python3
"""経営会議（board）の決定台帳を読み、次に開いたときの「現在地」を機械で出す。

■ なぜ機械でやるか
  決定は「決めた瞬間」より「決めたあとどうなったか」で価値が決まる。ここを散文の約束
  （＝次回ちゃんと見ます）にすると必ず腐る。このリポジトリの事故はすべて
  **静かに壊れる**形だった（許可リスト片形欠けで配信5日停止／宛先を見ない蒸留 等）。
  だから台帳の状態は毎回ここで数え、見直し期日を過ぎた決定は exit 1 で鳴らす。

■ やること／やらないこと（judge と calc の分離＝todo-brief.py・pending-scan.py と同型）
  やる  … 台帳を読む・数える・見直し期日の超過を出す・ToDo の完了状態を照会する
  やらない… 決定の中身の判断、台帳の書き換え。それは board（LLM）と社長の仕事。

■ 使い方
  board-brief.py                     # 現在地（open・見直し超過・ToDo照会）
  board-brief.py --no-api            # hana-tools を叩かない（オフライン／テスト用）
  board-brief.py --date YYYY-MM-DD   # 基準日（テスト用）
  board-brief.py --file PATH         # 台帳の場所（テスト用）

■ exit
  0 = 見直し期日を過ぎた open が無い
  1 = 過ぎたものがある（board は冒頭で必ず扱う）
  2 = 台帳が読めない・壊れている（黙って0件にしない）
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.path.join(ROOT, "data", "board", "decisions.md")
API = os.path.join(ROOT, "bin", "hana-api.sh")
MEMBERS = os.path.join(ROOT, "config", "comms-members.json")

# 列の順序は台帳（data/board/decisions.md）の「列の意味」節と一対一。どちらかだけ直さない。
COLS = ["id", "decided", "text", "branch", "handoff", "review", "state"]
ID_RE = re.compile(r"^D-\d{3,}$")
# 節の見出しは完全一致で選ぶ（説明用の「## 決定一覧の書き方」等を拾わない）
HEAD_RE = re.compile(r"##\s+決定一覧\s*")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TODO_RE = re.compile(r"ToDo\s*#\s*(\d+)")
STATES = ("open", "done", "dropped")
SUPERSEDED_RE = re.compile(r"^superseded:\s*D-\d{3,}$")
JST = datetime.timezone(datetime.timedelta(hours=9))


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def parse_date(s, what):
    if not DATE_RE.match(s):
        die(f"{what} が日付の形ではありません: {s!r}（YYYY-MM-DD）")
    try:
        return datetime.date.fromisoformat(s)
    except ValueError:
        die(f"{what} が実在しない日付です: {s!r}")


def jst_date(v):
    """hana-tools が返す時刻を JST の日付に直す。

    ★先頭10文字で切ってはいけない★ API は JST 0時を UTC 表記で返すため、切ると
      1日前倒しになる（2026-08-25 に督促が全件1日早く鳴った実害・hana-api.sh の日付規約）。
    """
    if not v:
        return None
    try:
        t = datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        # ★タイムゾーン無しは JST とみなす★ bin/todo-brief.py と同じ規約に揃える。
        #   ここだけ UTC 扱いにすると、同じ API の同じ値を2つの道具が別の日として読む。
        t = t.replace(tzinfo=JST)
    return t.astimezone(JST).date()


def section(lines):
    """`## 決定一覧` の節だけを返す。

    ★節を絞るのは誤検知を消すため★ 台帳には「列の意味」など説明用の表も載っている。
      ファイル全体を走査すると、それらを毎回「読めなかった行7行」と鳴らし、
      **警報が常時点灯して意味を失う**（最初の実装で実際にそうなった）。
      見出しが無い場合は 0件と読まずに落とす（黙って空にしない）。
    """
    # ★部分一致で選ばない★「## 決定一覧の書き方」のような節が先にあると、
    #   そちらを拾って**本物の表を一度も読まずに 0件・正常終了**する（Codex 指摘・再現済み）。
    #   見つからない／複数ある、はどちらも黙って空にせず落とす。
    hits = [i for i, ln in enumerate(lines)
            if HEAD_RE.fullmatch(ln.strip())]
    if not hits:
        die("台帳に `## 決定一覧` の見出しがありません"
            "（節が無いまま0件と読むと、決定が消えたことに気づけません）")
    if len(hits) > 1:
        die("`## 決定一覧` の見出しが %d 個あります（%s 行目）＝どれが台帳か決められません"
            % (len(hits), "・".join(str(i + 1) for i in hits)))
    start = hits[0] + 1
    for j in range(start, len(lines)):
        if lines[j].strip().startswith("## "):
            return lines[start:j]
    return lines[start:]


def load(path):
    """台帳を読む。**表の行だけ**を決定として扱い、読めなかった行は数えて返す。

    取りこぼしを黙らないのは triage の教訓（列位置の決め打ちで 12件中1件しか取れず、
    それでも平然と件数を報告できた＝警報が鳴らないのと同じ壊れ方）。
    """
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        die(f"台帳を読めません: {path}（{e.__class__.__name__}: {e}）")

    rows, skipped, seen = [], 0, set()
    for ln in section(lines):
        s = ln.strip()
        if not s.startswith("|"):
            # ★黙って飛ばさない★ 先頭の | が欠けた決定行は表として読めないが、
            #   捨てると「決定が1件減った」ことに誰も気づけない（Codex 指摘・再現済み）。
            #   節の中の空行・コメント・引用・見出しだけが正当な非表行。
            if s and not s.startswith(("<!--", ">", "#")):
                skipped += 1
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        head = cells[0] if cells else ""
        if ID_RE.match(head):
            if len(cells) != len(COLS):
                die(f"{head} の列数が {len(cells)} です（{len(COLS)}列必要: {'/'.join(COLS)}）")
            if head in seen:
                die(f"決定ID {head} が台帳に重複しています")
            seen.add(head)
            rows.append(dict(zip(COLS, cells)))
            continue
        # 節の中の見出し行・区切り行は決定ではない。それ以外は「読めなかった行」として数える。
        if head == "ID" or not head or set(head) <= set("-: "):
            continue
        skipped += 1
    return rows, skipped


def enrich(rows, today):
    for r in rows:
        r["decided_d"] = parse_date(r["decided"], f"{r['id']} の決めた日")
        st = r["state"]
        if st not in STATES and not SUPERSEDED_RE.match(st):
            die(f"{r['id']} の状態が不正です: {st!r}"
                f"（{'/'.join(STATES)} または superseded:D-NNN）")
        r["is_open"] = st == "open"
        if r["is_open"]:
            r["review_d"] = parse_date(r["review"], f"{r['id']} の見直し")
            r["overdue"] = (today - r["review_d"]).days
        else:
            r["review_d"] = None
            r["overdue"] = None
        r["age"] = (today - r["decided_d"]).days
        m = TODO_RE.search(r["handoff"])
        r["todo_id"] = int(m.group(1)) if m else None
    return rows


def fetch_todos():
    """全担当ぶんの ToDo を取る（読み取りのみ）。戻り値 (dict|None, 失敗理由|None)。

    ★ここは todo-brief.py と違い「取れなくても止めない」★
      あちらは取得失敗を0件と読むと**二重起票**（書き込み事故）になるので落とす設計。
      こちらは社長が同席する対話の材料出しで、落ちて会議が止まる方が害が大きい。
      ただし **「照会に失敗した」と「照会できたが無い」を混ぜない**＝失敗は失敗と表示する
      （混ぜると「ToDoが消えています」と嘘の報告をする）。
    """
    try:
        with open(MEMBERS, encoding="utf-8") as f:
            m = (json.load(f) or {}).get("hana_user_ids")
    except Exception as e:
        return None, f"config/comms-members.json を読めません（{e.__class__.__name__}）"
    # ★形を決め打たない★ 辞書でなく配列で書かれていると .values() が AttributeError になり、
    #   Python が exit 1 で落ちる＝本ツールの「1＝見直し期日が来た決定あり」と区別できなくなる。
    if isinstance(m, dict):
        vals = list(m.values())
    elif isinstance(m, list):
        vals = m
    else:
        return None, "config/comms-members.json の hana_user_ids が辞書でも配列でもありません"
    uids = sorted({int(i) for v in vals
                   for i in (v if isinstance(v, list) else [v]) if str(i).isdigit()})
    if not uids:
        return None, "config/comms-members.json に hana_user_ids がありません"

    out = {}
    for uid in uids:
        # --status を渡さない＝完了ぶんも返る（完了を確認するのがここの目的）。
        cmd = ["bash", API, "todos", f"--assignee_user_id={uid}"]
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=120)
        except subprocess.TimeoutExpired:
            return None, f"hana-tools が応答しません（担当 {uid}・120秒）"
        if r.returncode != 0:
            return None, f"hana-tools の呼び出しに失敗（担当 {uid}・exit={r.returncode}）"
        try:
            d = json.loads(r.stdout)
        except Exception:
            return None, f"hana-tools の応答を読めません（担当 {uid}）＝認証・ネットワーク確認"
        if isinstance(d, dict):
            if d.get("success") is False:
                return None, f"hana-tools がエラーを返しました（担当 {uid}）"
            if "data" not in d:
                return None, f"hana-tools の応答に data がありません（担当 {uid}）"
            d = d["data"]
        if not isinstance(d, list):
            return None, f"hana-tools の応答が想定外の形です（担当 {uid}）"
        for i in d:
            if isinstance(i, dict) and i.get("id") is not None:
                out[int(i["id"])] = i
    if not out:
        # 全担当あわせて0件は「取れていない証拠」（todo-brief.py と同じ3段目の判定）。
        return None, "全担当あわせて ToDo が0件＝取得に失敗している可能性が高い"
    return out, None


def todo_line(r, todos, err, today):
    if r["todo_id"] is None:
        return None
    tid = r["todo_id"]
    if err is not None:
        return f"  {r['id']} → ToDo #{tid}  ⚠️ 照会できず（{err}）"
    t = todos.get(tid)
    if t is None:
        return f"  {r['id']} → ToDo #{tid}  ⚠️ ToDo が見つかりません（IDの誤りか削除）"
    done = jst_date(t.get("completed_at"))
    # ★食い違いは必ず名指しする★「回収は社長の申告に頼らない」＝台帳の状態を信じず、
    #   ToDo の実態と突き合わせて**両方向**のズレを出す（Codex 指摘 🔴＝open だけ見ていた）。
    if done:
        if r["is_open"]:
            return (f"  {r['id']} → ToDo #{tid}  ⚠️ **実行は完了（{done}）なのに台帳は open のまま**"
                    f"＝台帳を done にするか、次の一手を決める")
        return f"  {r['id']} → ToDo #{tid}  ✅ 完了（{done}）"
    due = jst_date(t.get("due_date"))
    over_txt = ""
    if due:
        over = (today - due).days
        over_txt = f"（期日 {due}・" + (f"超過{over}日" if over > 0 else
                                       ("本日期限" if over == 0 else f"あと{-over}日")) + "）"
    else:
        over_txt = "（期日なし）"
    if not r["is_open"]:
        return (f"  {r['id']} → ToDo #{tid}  ⚠️ **台帳は「{r['state']}」なのに実行は未完了**{over_txt}"
                f"＝決着の申告が実態と合っていない")
    return f"  {r['id']} → ToDo #{tid}  ⬜ 未完了{over_txt}"


def main():
    p = argparse.ArgumentParser(description="board 決定台帳の現在地を出す")
    p.add_argument("--file", default=LEDGER)
    p.add_argument("--date", help="基準日 YYYY-MM-DD（既定=今日）")
    p.add_argument("--no-api", action="store_true", help="hana-tools を叩かない")
    a = p.parse_args()

    today = parse_date(a.date, "--date") if a.date else datetime.date.today()
    rows, skipped = load(a.file)
    enrich(rows, today)

    opens = [r for r in rows if r["is_open"]]
    overdue = sorted([r for r in opens if r["overdue"] >= 0], key=lambda r: -r["overdue"])
    ahead = sorted([r for r in opens if r["overdue"] < 0], key=lambda r: r["review_d"])
    closed = [r for r in rows if not r["is_open"]]

    print(f"■ 決定台帳（{os.path.relpath(a.file, ROOT)}）  基準日 {today}")
    print(f"  全 {len(rows)} 件 ／ open {len(opens)}・決着 {len(closed)}"
          f"（done {sum(1 for r in closed if r['state'] == 'done')}"
          f"・dropped {sum(1 for r in closed if r['state'] == 'dropped')}"
          f"・superseded {sum(1 for r in closed if r['state'].startswith('superseded'))}）")
    if skipped:
        print(f"  ⚠️ 表の行として読めなかった行が {skipped} 行あります"
              f"（このツールは表の行だけを決定として扱う＝人が目で確認してください）")

    if overdue:
        print(f"\n■ 🔴 見直しの期日が来ている（{len(overdue)}件）＝今日この場で扱う")
        for r in overdue:
            d = "本日" if r["overdue"] == 0 else f"{r['overdue']}日超過"
            print(f"  {r['id']}  見直し {r['review']}（{d}）｜枝 {r['branch']}｜"
                  f"決定から{r['age']}日｜降ろし先 {r['handoff']}")
            print(f"        {r['text']}")
    if ahead:
        print(f"\n■ open・期日前（{len(ahead)}件）")
        for r in ahead:
            print(f"  {r['id']}  見直し {r['review']}（あと{-r['overdue']}日）｜枝 {r['branch']}"
                  f"｜降ろし先 {r['handoff']}")
            print(f"        {r['text']}")
    if not opens:
        print("\n  open の決定はありません。")

    todos, err = ({}, None) if a.no_api else fetch_todos()
    # ★全行を照会する★ open だけ見ると「done と書いたが実際は終わっていない」を永久に見逃す。
    lines = [ln for ln in (todo_line(r, todos or {}, err, today) for r in rows) if ln]
    if a.no_api:
        print("\n■ ToDo 照会：--no-api のため実行していません")
    elif lines:
        print("\n■ ToDo 照会（降ろし先が ToDo の決定すべて＝done も再確認する）")
        print("\n".join(lines))
    elif err is not None:
        print(f"\n■ ToDo 照会：⚠️ 照会できず（{err}）")

    return 1 if overdue else 0


if __name__ == "__main__":
    # ★想定外の例外で exit 1 にしない★ 1 は「見直し期日が来た決定がある」の意味なので、
    #   落ちたときに 1 を返すと**故障と正常な警告が区別できなくなる**（Codex 指摘）。
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as e:          # noqa: BLE001  区別できない終了コードを出さないための握り
        print(f"board-brief: 想定外のエラー（{e.__class__.__name__}: {e}）", file=sys.stderr)
        sys.exit(2)
