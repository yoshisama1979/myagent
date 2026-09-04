#!/usr/bin/env python3
"""会話台帳を読んで hana-tools へ ToDo を起票する（**LLM を使わない**）。

■ なぜ別のツールなのか（2026-08-25 社長ご承認・案B）
  会話を蒸留する comms モードは `bin/hana-api.sh` を実行できない。ガードが
  「外部送信・外部書き込みスクリプト」として物理的に拒否する。これは意図的な制限で、
  **外部から来た文章を読む役に、外部システムへ書く力を持たせない**ため
  （Chatwork 本文に「〇〇を登録して」と書かれていても従えないようにしてある）。

  そこで役割を2つに割る：
    comms（LLM）      … 用件を読んで **台帳に判断を書く**（担当・案件・期日・根拠）
    このツール（LLM無し）… 台帳の値を **そのまま** hana-tools へ渡す

  このツールは判断しない。台帳に書いていないことは補わない。**推測が入り込む余地を無くす**のが目的。

■ 起票の条件（rules/modes/comms.md v1.0/v1.1・すべて満たすときだけ）
  1. 状態が 👥（社内ボール）または 🔴（社長ボール）＝🟢・📌 は対象外
     （🔴 は 2026-09-04 社長ご指示で追加。それまでは永久に起票されなかった）
  2. 担当が確定（不明・複数は除く）
  3. 既存 ToDo と重複しない（todo-brief.py check ＝全担当ぶんと照合）
  4. 案件が一意（`案件: 不明` はマイエージェントへ入れ、案件作成を促す文面を添える）
  5. 期日は `根拠: 明示` のときだけ入れる（逆算・強度は人の確認が要る＝入れずに確認列へ）
  ※ 3の「本人がそのルームに参加しているか」は comms が台帳を書く時点で担保する

使い方:
  todo-post.py plan            # 何を起票するか見せるだけ（書き込まない）
  todo-post.py hold-sync       # 見送りを確認列へ積む（**書き込みはローカルの state.json だけ**）
  todo-post.py hold-sync --dry-run   # 積まずに差分だけ見せる
  todo-post.py post            # 実際に起票する（＋確認列も同期する）
  todo-post.py post --dry-run  # plan と同じ

■ 見送りを確認列へ積む（2026-09-03 追加）
  rules/modes/comms.md v1.0 は「起票しなかったものは理由つきで確認列（todo-brief.py hold）に積み、
  社長に確認してから起票する」と定めているが、**その処理が実装されていなかった**。
  見送りは実行時の出力に載るだけで、どこにも残らなかった。
  結果＝確認列は 8/25 の導入以来ずっと空（実測 0 件）で、**社長に「案件欄を埋めてください」と
  上がる場面が一度も発生しなかった**。台帳の 👥 18件のうち 16件が「案件欄が無い」だけの理由で
  10日間止まっていた（うち4件は同じルームで14日超の放置）。

  外部（hana-tools）への書き込みと、確認列（ローカルの state.json）への書き込みは
  **リスクが違う**ので、サブコマンドを分けてある。hold-sync は外部へ一切書かない。
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.path.join(ROOT, "data", "comms", "chatwork", "ledger.md")
API = os.path.join(ROOT, "bin", "hana-api.sh")
BRIEF = os.path.join(ROOT, "bin", "todo-brief.py")
CONFIG = os.path.join(ROOT, "config", "comms-members.json")

FALLBACK_WORK_ID = 199          # 株式会社はなさか > マイエージェント > エージェント開発
ROW = re.compile(r"^\s*(C-\d{3})\s*\|")
# 内部の見送り理由 → todo-brief.py の HOLD_REASONS（固定コード）への対応。
# ★確認列の state.json には**固定コードしか書かない**（固有名詞・ID を残さない。
#   どの用件かは C-NNN で台帳＝git 管理外を引けば分かる。2026-08-25 Codexレビュー）。
# 1つの行に複数の理由が付くことがある（例＝起票はできるが期日だけ人が要る）ので、
# **より重い理由を優先**する＝下の並び順が優先順位。
# 起票の対象にする状態。**状態列そのもの**を見る（行のどこかに絵文字があるか、ではない）。
# ★2026-09-04 社長ご指示で 🔴（社長ボール）を追加＝「社長のぶんも ToDo に起票する」。
#   それまでは 👥 だけが対象で、🔴 は**構造的に永久に起票されなかった**（小磯様 C-122 の件で発覚）。
#   あわせて判定を列に固定した理由＝注記に「※👥対象外」と書いた 🔴 の行が
#   `"👥" in line` をすり抜けて対象に混ざっていた（2026-09-03 実測＝C-039・C-125）。
FILE_STATES = ("👥", "🔴")

HOLD_PRIORITY = ["assignee-unclear", "no-fields", "work-ambiguous",
                 "duplicate-suspect", "work-missing", "due-needs-human"]


def hold_code(reason):
    """`duplicate-suspect(既存 [253])` のような装飾を落として固定コードにする。"""
    return reason.split("(")[0].strip()


FALLBACK_NOTE = (
    "\n\n【この用件の案件が HANAツールにありません】\n"
    "HANAツールは案件マスターです。該当する案件を作成し、この ToDo を移してください。\n"
    "作成が難しい場合は社長にご相談ください。")


# 台帳の装飾（強調・下線・コード）。comms は人が読む前提で書くので値に混ざる。
DECOR = re.compile(r"\*\*|</?u>|</?b>|`")
# 1つの欄の中で「値の終わり」を示すもの。`期日: 2026-08-31 ／ 根拠: 明示（…） ※注記` の
# ように、1つの `|` 区切りの中に別項目と注記が続く書き方が台帳の実際の形。
VALUE_END = re.compile(r"／|※|（|\(")
RE_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# 台帳が持つ欄の名前。**この列は欄の列か**を判定するために使う（本文の列と区別する）。
FIELDS = ("担当", "案件", "最終", "期日", "根拠", "cw", "gm")


def field(line, name):
    """`名前: 値` を1つ取り出す。

    ★**列（`|` 区切り）か、その中の `／` 区切りの「先頭」にあるものだけ**を欄とみなす。
      行のどこかを検索する実装だと、本文に引用された `…「案件: 999 で」…` や
      `…／ 担当: ○○ とのこと` を本物の欄より先に拾い、**別人へ起票する**
      （2026-09-04 Codexレビュー指摘。実データでの発生は0件だが、静かに間違う種類）。
      台帳の実際の形は `… | 担当: 長谷さん | 案件: 67 | … | 期日: X ／ 根拠: Y ※注記` で、
      欄は必ず区切りの直後に来る。
    """
    head = name + ":"
    for col in line.split("|"):
        segs = [x.strip() for x in col.split("／")]
        # ★`／` の中まで見てよいのは「その列自体が欄の列」のときだけ。
        #   本文の列に `…／ 担当: ○○ とのこと` と引用が入っていると、
        #   区切りの直後という条件だけでは本文を欄と読んでしまう（別人へ起票する）。
        if not segs or not any(segs[0].startswith(f + ":") for f in FIELDS):
            continue
        for seg in segs:
            if seg.startswith(head):
                return seg[len(head):].strip()
    return ""


def valid_date(v):
    """`YYYY-MM-DD` で、**暦として実在する日付**のときだけ返す。

    形だけ見る正規表現だと `2026-02-31` を通してしまい、そのまま API へ送る。
    """
    try:
        return str(datetime.date.fromisoformat(v)) if RE_DATE.match(v) else None
    except ValueError:
        return None


def field_value(line, name):
    """欄から**値だけ**を取り出す（装飾・続く別項目・注記を落とす）。

    ★v1.1 の仕様例は `| 案件: 131 | 期日: 2026-08-31 | 根拠: 明示 |` と素の値を並べていたが、
      実際に comms が書く台帳は `| 期日: **2026-08-31** ／ 根拠: 明示（**8月中**） ※注記`。
      素の値しか受け付けない実装だと **全行の期日と根拠が落ちる**（2026-09-03 実測＝👥22行の
      すべてで期日が None・明示の期日3件が期日なしで起票される寸前だった）。
      仕様の書式も台帳の書式も、どちらも読めるようにする＝台帳側を書き換えさせない。
    """
    v = DECOR.sub("", field(line, name))
    return VALUE_END.split(v)[0].strip()


def agent_user_id():
    """起票の名義。社長名義で作ると『社長が作ったToDo』として記録され、
    委任したのに社長の保有件数が増える（2026-08-24 社長ご指摘）。"""
    try:
        with open(CONFIG, encoding="utf-8") as f:
            uid = ((json.load(f) or {}).get("hana_user_ids") or {}).get("agent")
    except Exception:
        uid = None
    if not uid:
        sys.exit("ERROR: config/comms-members.json の hana_user_ids.agent が読めません"
                 "（誰の名義で起票するか不明のまま共有システムへ書き込みません）")
    return int(uid)


# 担当名 → user_id の対応。**氏名を含むので git 管理外に置く**（config は数値だけ持つ）
STAFF_MAP = os.path.join(ROOT, "data", "comms", "hana-users.json")


def staff_user_id(name):
    """担当名 → hana-tools の user_id。**対応が無ければ起票しない**（推測しない）。

    対応漏れは「その人の担当ぶんが静かに落ちる」形で効くので、
    見つからなかったことは呼び出し側で確認列に積む（黙って捨てない）。
    """
    try:
        with open(STAFF_MAP, encoding="utf-8") as f:
            m = (json.load(f) or {}).get("by_name") or {}
    except FileNotFoundError:
        sys.exit(f"ERROR: 担当の対応表がありません: {STAFF_MAP}"
                 "（誰に割り当てるか分からないまま共有システムへ書き込みません）")
    except Exception:
        sys.exit(f"ERROR: 担当の対応表を読めません: {STAFF_MAP}")
    v = m.get(name)
    return int(v) if isinstance(v, int) or (isinstance(v, str) and v.isdigit()) else None


def read_rows():
    if not os.path.exists(LEDGER):
        sys.exit(f"ERROR: 台帳がありません: {LEDGER}")
    with open(LEDGER, encoding="utf-8") as f:
        return [l for l in f if ROW.match(l)]


def clean(s):
    return re.sub(r"\s+", " ", re.sub(r"\*\*|<u>|</u>|`", "", s)).strip()


def plan_rows():
    """台帳から「起票してよい行」と「見送る行（理由つき）」を仕分ける。判断はしない＝台帳を読むだけ。"""
    agent = agent_user_id()
    todo, hold = [], []
    for line in read_rows():
        cols = [c.strip() for c in line.split("|")]
        tag = cols[0]
        if len(cols) < 2 or cols[1] not in FILE_STATES:
            continue                                  # 🟢（相手ボール）・📌（確定記録）は対象外
        who = field_value(line, "担当")
        uid = staff_user_id(who)
        if who in ("", "不明", "複数") or uid is None:
            hold.append((tag, "assignee-unclear")); continue
        work = field_value(line, "案件")
        if work == "対象外":
            # ★2026-09-04 社長ご指示。人事・労務・個人の稼働など「ToDo にしないと決めた行」。
            #   `不明`（＝案件が分からない）とは別物＝**決めた結果**なので確認列にも積まない。
            #   積むと「まだ決まっていない件」に紛れて、決めたことが永遠に消えない。
            continue
        if not work:
            # 台帳がまだ v1.1 の書式（案件:／期日:／根拠:）になっていない行。
            # **推測で埋めない**＝欄が無いことと「不明」は違う。前者は comms の書き漏れ。
            hold.append((tag, "no-fields")); continue
        if work == "不明":
            work_id, fallback = FALLBACK_WORK_ID, True
            # 起票はする（用件を落とさない）が、**案件の作成をお願いする行**として確認列にも立てる。
            # 本文に書くだけでは社長に届かない（2026-09-04 社長ご指示）。
            hold.append((tag, "work-missing"))
        elif work.isdigit():
            work_id, fallback = int(work), False
        else:
            hold.append((tag, "work-ambiguous")); continue
        due_raw, basis = field_value(line, "期日"), field_value(line, "根拠")
        # ★期日は「明示」のときだけ入れる。逆算・強度は AI が日付を確定しない（v1.1）
        due = None
        if basis == "明示":
            due = valid_date(due_raw)
            if due is None:
                # ★「明示」と書いてあるのに日付として読めない＝台帳の書き損じ。
                #   黙って期日なしで起票すると、**約束した期限が消えたまま督促に乗らない**
                #   （2026-09-04 Codexレビュー指摘）。起票はするが期日は人に決めてもらう。
                hold.append((tag, "due-needs-human(明示だが日付として読めない)"))
        elif basis in ("逆算", "強度"):
            # 日付は人が決める（v1.1）。起票自体は行い、期日だけ確認列へ回す
            hold.append((tag, f"due-needs-human({basis})"))
        title = clean(cols[3])[:44] if len(cols) > 3 else tag
        body = clean(cols[4])[:400] if len(cols) > 4 else ""
        todo.append({
            "tag": tag, "work_id": work_id, "fallback": fallback,
            "user_id": agent, "assignee_user_id": uid,
            "content": f"{title} [{tag}]",
            "description": f"Chatworkの会話から自動起票（{tag}）。\n{body}"
                           + (FALLBACK_NOTE if fallback else ""),
            "due_date": due,
        })
    return todo, hold


def check_duplicates(items):
    """全行ぶんの重複判定を **ToDo 全件取得1回** で済ませる（`todo-brief.py check-batch`）。

    ★行ごとに `check` を呼ぶと、1行につき1回ずつ全件を取り直す（対象54行なら54回）。
      遅いだけでなく **行ごとに違うスナップショットで判定する**ことになり、
      同じ実行の中で基準がずれる（2026-09-04 Codexレビュー指摘）。
      判定そのものは todo-brief 側の1つの関数に集約している＝定義を2箇所に持たない。
    """
    if not items:
        return {}
    payload = json.dumps([{"tag": it["tag"], "title": it["content"].split("[")[0].strip()}
                          for it in items], ensure_ascii=False)
    r = subprocess.run([sys.executable, BRIEF, "check-batch"], input=payload,
                       capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        # 取得に失敗しているのに「重複なし」と読むと全件を二重起票する（2026-08-25 の実害）
        sys.exit(f"ERROR: 重複チェックに失敗しました: {(r.stderr or r.stdout).strip()[:200]}")
    try:
        res = json.loads(r.stdout)
    except Exception:
        sys.exit("ERROR: 重複チェックの結果を読めません")
    missing = [it["tag"] for it in items if it["tag"] not in res]
    if missing:
        # 返ってこなかった行を「重複なし」と読むと、そこだけ黙って二重起票になる
        sys.exit(f"ERROR: 重複チェックの結果に含まれない行があります: {missing[:5]}")
    return res


def read_hold():
    """今の確認列を読む。判定は todo-brief.py に集約する（2箇所に持たない）。"""
    r = subprocess.run([sys.executable, BRIEF, "hold"],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        # 読めないまま「差分なし」と扱うと、積むべきものが静かに落ちる
        sys.exit(f"ERROR: 確認列を読めません: {(r.stderr or r.stdout).strip()[:160]}")
    try:
        return {x["tag"]: x for x in (json.loads(r.stdout).get("items") or [])}
    except Exception:
        sys.exit("ERROR: 確認列の結果を読めません")


def hold_plan(skipped):
    """見送りリスト → 確認列に対する差分（積む／理由が変わった／もう対象でない）。

    ★消す側は自動化しない。確認列には人が手で積んだものも入りうるので、
      機械が消すと社長の作業が黙って消える。ここでは `gone` として見せるだけにする。
    """
    now = {}
    for tag, reason in skipped:
        code = hold_code(reason)
        if code not in HOLD_PRIORITY:
            code = "other"                      # 知らない区分は捨てずに other で残す
        cur = now.get(tag)
        if cur is None or HOLD_PRIORITY.index(code) < HOLD_PRIORITY.index(cur):
            now[tag] = code
    cur = read_hold()
    add = [(t, c) for t, c in sorted(now.items())
           if t not in cur or cur[t].get("reason") != c]
    gone = sorted(t for t in cur if t not in now)
    return now, add, gone


def hold_apply(add):
    """確認列へ積む。**外部（hana-tools）には一切書かない**＝ローカルの state.json だけ。"""
    for tag, code in add:
        r = subprocess.run([sys.executable, BRIEF, "hold", "--add", tag, "--reason", code],
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            sys.exit(f"ERROR: 確認列に積めませんでした（{tag}／{code}）: "
                     f"{(r.stderr or r.stdout).strip()[:200]}")


def cmd_hold_sync(a):
    _, add, gone = hold_plan(plan_skipped())
    if not a.dry_run:
        hold_apply(add)
    print(json.dumps({"mode": "hold-sync" + (" (dry-run)" if a.dry_run else ""),
                      "added": [{"tag": t, "reason": c} for t, c in add],
                      "no_longer_held": gone,
                      "hold_total": len(read_hold())}, ensure_ascii=False, indent=1))


def split_by_duplicate(todo, hold):
    """起票してよい行と、見送る行（理由つき）に分ける。

    ★重複判定は「1件も作る前に」全件済ませる。作りながら調べると
      **同じ実行で自分が作った ToDo が、次の行の重複判定に当たる**
      （2026-09-04 実害＝24件を一度に作った回で C-131・C-132 が落ちた）。
      この順序にすると **plan と post の結果が一致する** という性質も同時に手に入る。
    確認列に積むときは `hold_code()` が `(既存 …)` を落とすので、
    **理由に id を添えたまま1つの実装を plan・post・hold-sync で共有できる**。
    """
    ready, skipped = [], list(hold)
    dup = check_duplicates(todo)
    for it in todo:
        d = dup[it["tag"]]
        if not d.get("safe_to_create"):
            ids = [x["id"] for x in d.get("exact", []) + d.get("similar", [])]
            skipped.append((it["tag"], f"duplicate-suspect(既存 {ids[:3]})"))
            continue
        ready.append(it)
    return ready, skipped


def plan_skipped():
    """起票されない行を（重複判定まで含めて）確定させる。post と同じ経路を通す。"""
    return split_by_duplicate(*plan_rows())[1]


def cmd_plan(a, do_post=False):
    ready, skipped = split_by_duplicate(*plan_rows())
    made = []
    for it in ready:
        if not do_post:
            made.append({**it, "would_create": True})
            continue
        payload = {k: v for k, v in it.items()
                   if k in ("work_id", "user_id", "assignee_user_id", "content",
                            "description", "due_date") and v is not None}
        r = subprocess.run(["bash", API, "create-todo", json.dumps(payload, ensure_ascii=False)],
                           capture_output=True, text=True, timeout=180)
        try:
            res = json.loads(r.stdout); t = res.get("data") or res
        except Exception:
            sys.exit(f"ERROR: 起票の応答を読めません（{it['tag']}）: {r.stdout[:160]}")
        if not res.get("success") or t.get("assignee_user_id") != it["assignee_user_id"]:
            sys.exit(f"ERROR: 起票に失敗、または担当が意図と違います（{it['tag']}）: {r.stdout[:200]}")
        made.append({"tag": it["tag"], "id": t.get("id"), "work_id": t.get("work_id"),
                     "assignee": t.get("assignee_user_id"), "due_date": t.get("due_date")})
    # ★見送りは必ず確認列へ回す。ここが無いと「出力に出して終わり」になり、
    #   社長に上がる場が一度も開かない（2026-09-03 に実際にそうなっていた）。
    _, add, gone = hold_plan(skipped)
    if do_post:
        hold_apply(add)
    print(json.dumps({"mode": "post" if do_post else "plan",
                      "created" if do_post else "would_create": made,
                      "skipped": [{"tag": t, "reason": r} for t, r in skipped],
                      "hold_added" if do_post else "hold_would_add":
                          [{"tag": t, "reason": c} for t, c in add],
                      "hold_no_longer_held": gone},
                     ensure_ascii=False, indent=1))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    q = sub.add_parser("post"); q.add_argument("--dry-run", action="store_true")
    h = sub.add_parser("hold-sync"); h.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    if a.cmd == "hold-sync":
        cmd_hold_sync(a)
    else:
        cmd_plan(a, do_post=(a.cmd == "post" and not a.dry_run))


if __name__ == "__main__":
    main()
