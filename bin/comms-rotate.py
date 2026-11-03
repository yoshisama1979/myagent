#!/usr/bin/env python3
"""Chatwork・メール整理台帳（`data/comms/chatwork/ledger.md`）の退避を**機械で**行う。

■ なぜツールにするか（2026-11-02 マネジメント依頼 fe0221・社長ご承認済み）
  社長が整理板（`site/comms/index.html`）を「めちゃくちゃ長い」とお感じになっている。
  実測 2026-11-03＝台帳 803KB（器の上限 70KB の 11.5倍）・掲示板 978KB。
  退避の規律は `rules/modes/comms.md` にあるが、**毎サイクル LLM が目で判定している**ため
  追いついていない（蒸留メモは1サイクルに2本ずつしか動いておらず、新しい分が同じ速さで増える）。
  **判定できるものは機械に移し、判断が要るものだけ人に残す**（この repo の分け方）。

■ このツールが動かすもの（＝機械で判定できるものだけ）
  ① 🔴 行のうち「紐づく ToDo が1件以上あって**全部完了**」かつ「**完了後に行が動いていない**」もの
  ② 蒸留メモ（`> ※` で始まる行）のうち、新しい方 N 本（既定10本）を残した残り

■ このツールが**触らないもの**（判断が要る＝人／LLM の仕事）
  - 🟢 相手ボール … 退避の条件が「残作業ゼロ・期限なし・督促不要・案件の芽でない」＝判断
    （`rules/modes/comms.md` v0.8）。機械で当てると案件の芽を消す。
  - 👥 社内ボール … 残作業がある状態そのもの（v0.9 で退避対象外）
  - 📌 確定記録 … 資産として本体に残す
  - ✅ 完了 … 毎サイクルの手順で動いている
  - 掲示板（`site/comms/index.html`）… 台帳から再生成するビュー。次の comms サイクルが作り直す

■ 守っていること
  - **消さない・原文無改変**（`rules/ledger-discipline.md` §3）。移すのは行の**バイト列そのまま**。
  - 順序は **①archive へ追記 → ②入ったか確認 → ③本体から削除**（§4）。
    途中で落ちても最悪「二重存在」で済む＝欠損しない。
  - **固有名詞を画面に出さない**（`rules/modes/comms.md` の出力規律）。出すのは C-NNN・日付・バイト数だけ。
  - **ToDo 完了＝閉じてよい、と推測しない**（マネジメントのご指摘）。
    ToDo が無い行は「証拠が無い」として動かさない。完了より後に行が動いていれば動かさない
    （＝先方の新しい問いが同じ行に積まれている形）。
  - 台帳は comms の無人サイクル（2時間おき 6-22時の :10）が書く。**読んだ後に変わっていたら中止する**
    （楽観ロック＝書く直前に大きさとハッシュを再確認）。自分同士の多重起動は flock で防ぐ。

■ 実行は有人（マネジメント窓口）。cron には載せない。
  `plan` は読むだけ。`apply` が実際に動かす。どちらも何度流しても同じ結果になる（冪等）。

使い方:
  comms-rotate.py plan  [--keep-memo N]   # 候補と削減見込みを出すだけ（書き込まない）
  comms-rotate.py apply [--keep-memo N]   # ①追記→②確認→③削除
"""
import argparse
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.path.join(ROOT, "data", "comms", "chatwork", "ledger.md")
ARCHIVE = os.path.join(ROOT, "data", "comms", "chatwork", "archive.md")
LOCK = os.path.join(ROOT, "data", "comms", "chatwork", ".rotate.lock")
# ★台帳・archive を書くもう一方＝comms の無人サイクル。agent-tick.sh がこの錠で多重起動を防ぐ。
#   **同じ錠を取る**ことで「読んでから書くまでの間に無人サイクルが書く」競合を塞ぐ
#   （2026-11-03 Codex 指摘＝楽観ロックだけでは確認と置換が不可分でない）。
TICK_LOCK = os.path.join(ROOT, "data", "overseer", ".tick.lock")
JST = datetime.timezone(datetime.timedelta(hours=9))
# ToDo の取得と日付の読み方は **todo-brief.py を正とする**（定義を2箇所に持たない）。
# ★ここを自前で書くと、JST 補正（UTC 15:00Z＝翌日0時）や「0件は取得失敗」の柵を写し損じる。
BRIEF = os.path.join(ROOT, "bin", "todo-brief.py")

# 台帳の行＝`C-NNN | 状態 | …`。状態は**行の2番目の欄**から読む（節の見出しから読まない
# ＝実データでは「🔴 の節に 🟢 の行」がある）。
ROW_RE = re.compile(r"^\s*(C-\d{3,})\s*\|\s*([^|]*)\|")
LAST_RE = re.compile(r"最終:\s*(\d{1,2})/(\d{1,2})")
TAG_RE = re.compile(r"\[(C-\d{3,})\]")
# 蒸留メモ＝引用で始まる1行。1サイクル1本ずつ積まれる。
MEMO_RE = re.compile(r"^>\s*※")

# 残す蒸留メモの本数。**0 にはしない**＝直近の経緯が台帳から消えると、次のサイクルが
# 「前回なにを直したか」を読めなくなる（判定の訂正履歴として使われている）。
KEEP_MEMO = 10


def today():
    """基準日＝**JST の今日**。ホストの TZ に依存させない（2026-11-03 Codex 指摘）。

    UTC のホストでは JST の 0:00〜8:59 が前日になり、`最終: MM/DD` の年の補完が狂って
    **当日の行を前年と読む**＝誤って退避する経路になる。テストからは環境変数で固定する。
    """
    return datetime.date.fromisoformat(
        os.environ.get("COMMS_ROTATE_TODAY") or datetime.datetime.now(JST).date().isoformat())


def _brief():
    """todo-brief.py を読み込んで使う（ToDo 取得・日付の読み方を借りる）。"""
    spec = importlib.util.spec_from_file_location("todo_brief", BRIEF)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def read_rows(text):
    """台帳を「行」に分けて、C-NNN 行と蒸留メモ行に印を付ける。原文は一切変えない。"""
    rows = []
    for i, line in enumerate(text.split("\n")):
        m = ROW_RE.match(line)
        rows.append({
            "i": i, "text": line,
            "tag": m.group(1) if m else None,
            "state": m.group(2) if m else None,
            "memo": bool(MEMO_RE.match(line)),
        })
    return rows


def last_touched(line, ref):
    """`最終: MM/DD` を**直近1年以内の日付**として読む。読めなければ None。

    ★年を補う★ 台帳は年を書かない。今年で読んで未来になるなら前年とみなす
    （年末年始に「12/28」を翌年と読んで『まだ動いている』を見落とさないため）。
    """
    m = LAST_RE.search(line)
    if not m:
        return None
    mo, da = int(m.group(1)), int(m.group(2))
    for y in (ref.year, ref.year - 1):
        try:
            d = datetime.date(y, mo, da)
        except ValueError:
            continue
        if d <= ref:
            return d
    return None


def todos_by_tag(tb):
    """C-NNN → その番号の ToDo（**全担当ぶん**・完了も含む全件）。

    ★`fetch_todos(all_=True, assignee=None)` を使ってはいけない★（2026-11-03 Codex 指摘）
      hana-api.sh は担当未指定のとき .env の既定ユーザー（社長）を自動で入れる＝**社長ぶんしか返らない**。
      実測＝既定担当 554件／全担当 632件。同じ C-NNN に「社長ぶんは完了・別の担当ぶんは未完了」が
      あると、**生きている 🔴 行を『全部完了』と誤判定して退避する**（この道具で一番やってはいけない事故）。
      全担当を見る関数は `fetch_all_todos()`（担当ごとに API へ投げ、0件なら取得失敗として落ちる）。
    """
    out = {}
    for t in tb.fetch_all_todos():
        text = (t.get("content") or "") + " " + (t.get("description") or "")
        for tag in set(TAG_RE.findall(text)):
            out.setdefault(tag, []).append(t)
    return out


# 候補から外した理由。**自由文にしない**＝件数で数えられるようにし、固有名詞を出さない。
SKIPS = [
    ("no-todo",        "紐づく ToDo が無い（完了の証拠が無い）"),
    ("todo-open",      "未完了の ToDo がある"),
    ("completed-unreadable", "完了日が読めない"),
    ("last-unreadable", "行の `最終:` が読めない"),
    ("touched-after",  "ToDo の完了より後に行が動いている（先方の新しい問いが積まれている形）"),
]


def judge_red(rows, by_tag, tb, ref):
    """🔴 行を「退避してよい／残す」に分ける。戻り＝(候補, 理由ごとの件数)。

    ★ここが本件の急所★ 「ToDo が完了＝閉じてよい」と**推測しない**
    （2026-11-02 マネジメントのご指摘）。証拠が無い・完了後に動いている行は残す（安全側）。
    """
    picked, why = [], {k: 0 for k, _ in SKIPS}
    for r in rows:
        if not r["tag"] or not r["state"] or "🔴" not in r["state"]:
            continue
        ts = by_tag.get(r["tag"]) or []
        if not ts:
            why["no-todo"] += 1
            continue
        if any(not t.get("completed_at") for t in ts):
            why["todo-open"] += 1
            continue
        done = [d for d in (tb._date(t.get("completed_at")) for t in ts) if d]
        # ★1件でも完了日が読めなければ残す★（2026-07 Codex 指摘）
        #   読めた分だけで判定すると、読めなかった ToDo が**行の更新より後に**完了していた場合に
        #   「完了後に動いていない」の証明が成り立たない＝証拠が欠けたまま退避する。
        if len(done) != len(ts):
            why["completed-unreadable"] += 1
            continue
        last = last_touched(r["text"], ref)
        if last is None:
            why["last-unreadable"] += 1
            continue
        if last > max(done):
            why["touched-after"] += 1
            continue
        picked.append({"i": r["i"], "tag": r["tag"], "text": r["text"],
                       "bytes": len(r["text"].encode()),
                       "row_last": str(last), "todo_done": str(max(done)),
                       "todos": len(ts)})
    return picked, why


def pick_memos(rows, keep):
    """蒸留メモのうち、**新しい方 keep 本を残して**残りを候補にする。

    ★新しい順に積まれている前提に頼らない★ 行の中の日付ではなく**並び**で切ると、
      並べ替えが起きた日に古い方を残してしまう。台帳は新しいものを上に書く規約なので
      「上から keep 本を残す」で切る＝規約と同じ向きで、並びが崩れても欠損はしない
      （残す本数が増えるだけ）。
    """
    memos = [r for r in rows if r["memo"]]
    return [{"i": r["i"], "text": r["text"], "bytes": len(r["text"].encode())}
            for r in memos[keep:]]


def fingerprint(path):
    """読んだときの中身を覚えておくための印（大きさ＋中身のハッシュ）。"""
    with open(path, "rb") as f:
        b = f.read()
    return {"bytes": len(b), "sha": hashlib.sha256(b).hexdigest()[:16]}


def batch_text(stamp, red, memos, keep_memo):
    """archive へ足す1まとまり。**行は原文のまま**で、見出しだけ足す。"""
    out = [""]
    out.append(f"## {stamp}（comms-rotate.py・機械判定による退避）")
    out.append("")
    if red:
        out.append(f"### 🔴→退避（ToDo が全部完了・完了後に動いていない）＝{len(red)}件")
        out.append("")
        out.append("> 判定＝`bin/comms-rotate.py`（紐づく ToDo が1件以上あり全完了／行の `最終:` が"
                   "最後の完了日以前）。**原文無改変・消さずに移動**。")
        out.append("")
        for r in red:
            out.append(r["text"])
        out.append("")
    if memos:
        # ★定数ではなく**その実行で実際に残した本数**を書く★（2026-11-03 Codex 指摘）
        #   `--keep-memo 2` で流したのに「10本残した」と記録が残ると、監査が狂う。
        out.append(f"### 🧹 蒸留メモの退避（新しい{keep_memo}本を台帳に残した残り）＝{len(memos)}行")
        out.append("")
        for m in memos:
            out.append(m["text"])
        out.append("")
    return "\n".join(out)


def cmd_plan(a, do_apply=False):
    tb = _brief()
    ref = today()
    before = fingerprint(LEDGER)
    text = open(LEDGER, encoding="utf-8").read()
    rows = read_rows(text)
    by_tag = todos_by_tag(tb)
    red, why = judge_red(rows, by_tag, tb, ref)
    memos = pick_memos(rows, a.keep_memo)
    moved_bytes = sum(r["bytes"] for r in red) + sum(m["bytes"] for m in memos)
    report = {
        "mode": "apply" if do_apply else "plan",
        "as_of": str(ref),
        "ledger": {"bytes": before["bytes"], "limit": 70 * 1024,
                   "over": round(before["bytes"] / (70 * 1024), 1)},
        "red": {"count": len(red),
                "bytes": sum(r["bytes"] for r in red),
                "items": [{k: r[k] for k in ("tag", "row_last", "todo_done", "todos", "bytes")}
                          for r in red]},
        "memo": {"keep": a.keep_memo, "count": len(memos),
                 "bytes": sum(m["bytes"] for m in memos)},
        "kept_back": [{"kind": k, "why": w, "count": why[k]} for k, w in SKIPS],
        "estimate": {"moved_bytes": moved_bytes,
                     "ledger_after": before["bytes"] - moved_bytes},
        "note": ("🟢・👥・📌・✅ は触りません（退避の条件に判断が入るため＝人／LLM の仕事）。"
                 "掲示板は台帳から再生成するビューなので、次の comms サイクルが作り直します。"
                 "固有名詞は出しません＝どの用件かは C-NNN で台帳を引いてください"),
    }
    if not do_apply:
        print(json.dumps(report, ensure_ascii=False, indent=1))
        return 0
    if not red and not memos:
        report["applied"] = {"skipped": "動かすものがありません"}
        print(json.dumps(report, ensure_ascii=False, indent=1))
        return 0

    stamp = datetime.datetime.now(JST).strftime("%Y-%m-%d %H:%M")

    # ★①archive へ追記★（まだ本体からは消さない）
    #   ⚠️ **すでに archive にある行は足さない**（2026-11-03 Codex 指摘）。
    #      途中で中止したあとの再実行で、同じ行を2度 archive へ入れてしまうため
    #      （「二重存在で済む」は本体と archive の間の話で、archive の中の二重は別の問題）。
    #      行はバイト一致で突き合わせる＝経緯まで含んだ1行なので実質一意。
    arc_before = open(ARCHIVE, encoding="utf-8").read()
    red_new = [r for r in red if r["text"] not in arc_before]
    memo_new = [m for m in memos if m["text"] not in arc_before]
    already = (len(red) - len(red_new)) + (len(memos) - len(memo_new))
    at = len(arc_before.encode())
    if red_new or memo_new:
        batch = batch_text(stamp, red_new, memo_new, a.keep_memo)
        with open(ARCHIVE, "a", encoding="utf-8") as f:
            f.write(batch if batch.endswith("\n") else batch + "\n")
            f.flush()
            os.fsync(f.fileno())

    # ★②入ったか確認★
    #   新しく足した行は**今回足した範囲**の中にあることを確かめる（2026-11-03 Codex 指摘）。
    #   ファイル全体で探すと、昔の同一行が見つかって「今回の追記が成功した」と誤って通る。
    #   もとからあった行（再実行ぶん）は全体で存在を確かめる＝すでに保存されている証明になる。
    arc_all = open(ARCHIVE, encoding="utf-8").read()
    tail = arc_all.encode()[at:].decode("utf-8", "ignore")
    missing = [r["tag"] for r in red_new if r["text"] not in tail]
    missing += [f"memo#{m['i']}" for m in memo_new if m["text"] not in tail]
    missing += [r["tag"] for r in red if r["text"] not in arc_all]
    missing += [f"memo#{m['i']}" for m in memos if m["text"] not in arc_all]
    if missing:
        sys.exit("ERROR: archive に入っていない行があります（本体は触っていません）: "
                 + ", ".join(sorted(set(missing))[:5]))

    # ★③本体から削除★ その前に「読んだときと同じ中身か」を確かめる。
    #   錠（TICK_LOCK）で無人サイクルは止めているが、**人が手で編集した場合**は錠を取らないので
    #   この確認は残す（二重の備え）。
    now = fingerprint(LEDGER)
    if now != before:
        sys.exit("ERROR: 台帳が読み込み後に変わりました（誰かが手で編集した可能性）。"
                 "archive への追記は済んでいます＝二重存在の状態です。"
                 "もう一度 apply を流してください（すでに archive にある行は2度足しません）")
    drop = {r["i"] for r in red} | {m["i"] for m in memos}
    kept = [r["text"] for r in rows if r["i"] not in drop]
    tmp = LEDGER + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(kept))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, LEDGER)
    report["applied"] = {"archive_batch": stamp,
                         "red_moved": len(red), "memo_moved": len(memos),
                         "already_in_archive": already,
                         "ledger_bytes": fingerprint(LEDGER)["bytes"]}
    print(json.dumps(report, ensure_ascii=False, indent=1))
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "apply"):
        q = sub.add_parser(name)
        q.add_argument("--keep-memo", type=int, default=KEEP_MEMO, dest="keep_memo")
    a = p.parse_args()
    if a.keep_memo < 1:
        sys.exit("ERROR: --keep-memo は1以上にしてください"
                 "（直近の訂正履歴が台帳から消えると、次のサイクルが前回の判断を読めません）")
    for path in (LEDGER, ARCHIVE):
        if not os.path.exists(path):
            sys.exit(f"ERROR: {os.path.basename(path)} がありません: {path}")
    # 自分同士の多重起動を防ぐ（2つ流すと同じ行を2度 archive へ入れる）
    lk = open(LOCK, "w")
    try:
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("ERROR: もう1つ comms-rotate が動いています（終わってから流してください）")
    # ★もう一方の書き手（comms の無人サイクル）と**同じ錠**を取る（2026-11-03 Codex 指摘）★
    #   楽観ロックだけでは「確認してから置換するまで」が不可分でないため、確認の後に
    #   無人サイクルが書いた分を置換で消せる。agent-tick.sh が使う錠を取れば、
    #   走っている間は無人サイクルが入らない（逆に走っていたらこちらが降りる）。
    #   ⚠️ `plan` は読むだけなので錠は要らない＝サイクル中でも現況は見られるようにする。
    if a.cmd == "apply":
        try:
            tk = open(TICK_LOCK, "a")
        except OSError as e:
            sys.exit(f"ERROR: 無人サイクルの錠を開けません（{TICK_LOCK}）: {e}")
        try:
            fcntl.flock(tk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            sys.exit("ERROR: 無人サイクル（comms 等）が動いています＝台帳を書いている最中です。"
                     "終わってから流してください（偶数時の :10 前後は避ける）")
    return cmd_plan(a, do_apply=(a.cmd == "apply"))


if __name__ == "__main__":
    sys.exit(main())
