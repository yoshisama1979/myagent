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
  1. 状態が 👥（はなさか側にボールがある）
  2. 担当が確定（不明・複数は除く）
  3. 既存 ToDo と重複しない（todo-brief.py check ＝全担当ぶんと照合）
  4. 案件が一意（`案件: 不明` はマイエージェントへ入れ、案件作成を促す文面を添える）
  5. 期日は `根拠: 明示` のときだけ入れる（逆算・強度は人の確認が要る＝入れずに確認列へ）
  ※ 3の「本人がそのルームに参加しているか」は comms が台帳を書く時点で担保する

使い方:
  todo-post.py plan            # 何を起票するか見せるだけ（書き込まない）
  todo-post.py post            # 実際に起票する
  todo-post.py post --dry-run  # plan と同じ
"""
import argparse
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
FALLBACK_NOTE = (
    "\n\n【この用件の案件が HANAツールにありません】\n"
    "HANAツールは案件マスターです。該当する案件を作成し、この ToDo を移してください。\n"
    "作成が難しい場合は社長にご相談ください。")


def field(line, name):
    """`名前: 値` を1つ取り出す。列区切り（|）までを値とみなす。"""
    m = re.search(re.escape(name) + r":\s*([^|]*)", line)
    return m.group(1).strip() if m else ""


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
        if "👥" not in line:
            continue                                  # 社内ボール以外は対象外（静かに飛ばす）
        who = field(line, "担当")
        uid = staff_user_id(who)
        if who in ("", "不明", "複数") or uid is None:
            hold.append((tag, "assignee-unclear")); continue
        work = field(line, "案件")
        if not work:
            # 台帳がまだ v1.1 の書式（案件:／期日:／根拠:）になっていない行。
            # **推測で埋めない**＝欄が無いことと「不明」は違う。前者は comms の書き漏れ。
            hold.append((tag, "no-fields")); continue
        if work == "不明":
            work_id, fallback = FALLBACK_WORK_ID, True
        elif work.isdigit():
            work_id, fallback = int(work), False
        else:
            hold.append((tag, "work-ambiguous")); continue
        due_raw, basis = field(line, "期日"), field(line, "根拠")
        # ★期日は「明示」のときだけ入れる。逆算・強度は AI が日付を確定しない（v1.1）
        if basis == "明示" and re.match(r"^\d{4}-\d{2}-\d{2}$", due_raw):
            due = due_raw
        else:
            due = None
            if basis in ("逆算", "強度"):
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


def check_duplicate(item):
    """既存 ToDo と重ならないか。**判定は todo-brief.py に任せる**＝重複の定義を2箇所に持たない。"""
    r = subprocess.run(
        [sys.executable, BRIEF, "check", "--tag", item["tag"],
         "--title", item["content"].split("[")[0].strip()],
        capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        # 取得に失敗しているのに「重複なし」と読むと全件を二重起票する（2026-08-25 の実害）
        sys.exit(f"ERROR: 重複チェックに失敗しました（{item['tag']}）: "
                 f"{(r.stderr or r.stdout).strip()[:160]}")
    try:
        return json.loads(r.stdout)
    except Exception:
        sys.exit(f"ERROR: 重複チェックの結果を読めません（{item['tag']}）")


def cmd_plan(a, do_post=False):
    todo, hold = plan_rows()
    made, skipped = [], list(hold)
    for it in todo:
        d = check_duplicate(it)
        if not d.get("safe_to_create"):
            ids = [x["id"] for x in d.get("exact", []) + d.get("similar", [])]
            skipped.append((it["tag"], f"duplicate-suspect(既存 {ids[:3]})"))
            continue
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
    print(json.dumps({"mode": "post" if do_post else "plan",
                      "created" if do_post else "would_create": made,
                      "skipped": [{"tag": t, "reason": r} for t, r in skipped]},
                     ensure_ascii=False, indent=1))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    q = sub.add_parser("post"); q.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    cmd_plan(a, do_post=(a.cmd == "post" and not a.dry_run))


if __name__ == "__main__":
    main()
