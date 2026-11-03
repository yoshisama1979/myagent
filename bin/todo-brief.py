#!/usr/bin/env python3
"""担当者ごとの「今日これを片付けてください」を作るための材料出しと、提案の記録・検証。

■ このツールがやること／やらないこと（2026-08-24 社長ご指示「マネージャーの役割」）
  やる  … 候補集め・超過日数などの事実の計算・提案の記録・消化率の測定・次回件数の決定
  やらない… **どれを選ぶかの判断**。それは呼び出し側（モード）の仕事。
  理由＝優先度は「売上に効くか」「相手を待たせているか」という判断であって計算ではない。
        一方で日数や件数は計算であり、LLM にやらせると静かに間違える（F-017 と同じ切り分け）。

■ 提案量は実行状況で決める（社長ご指示「多すぎず少なすぎず」）
  前回出した提案が片付いていれば増やし、捌けていなければ減らす。
  相手が詰まっているのに毎朝積み増すと、通知そのものが無視される。

■ 完了の記録漏れ（社長ご指示「終わったらTODO消してもらうのを忘れないように」）
  この仕組みは「完了が記録されていること」に全面的に依存する。記録されないと、
  **終わった仕事を毎朝突く**ことになり、いちばん早く信用を失う。
  そこで、提案したのに動きが無いものは `--stale` で「終わっていませんか」と聞く材料を出す。

使い方:
  todo-brief.py candidates [--assignee N] [--limit M]   # 候補＋事実（選定はしない）
  todo-brief.py outside [--assignee N]                   # 「外に約束があるか」で区分（社内の積み残しは件数だけ）
  todo-brief.py record --assignee N --ids 1,2,3          # 今日提案した ID を記録
  todo-brief.py review --assignee N                      # 前回の消化率と次回の推奨件数
  todo-brief.py stale --assignee N                       # 提案済みで動きが無いもの（完了漏れの疑い）
  todo-brief.py undated [--assignee N] [--top M]          # 期限が空×作業日が空か過去（台帳🔴を上に）
"""
import argparse
import datetime
import unicodedata
import re
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(ROOT, "data", "todo-manager", "state.json")
API = os.path.join(ROOT, "bin", "hana-api.sh")

# ★件数は主役ではない（2026-08-25 社長ご指摘で設計変更）★
#   当初は「1〜5件」で絞っていたが、社長より
#   「その日のうちにやらないことが多ければ、それらを全て提案してもらうべき。
#     急いでないものを全部出しているとキリがない、という意味で、単純な件数で本当にいいのか」
#   ＝**問題は量ではなく、今日出す理由があるかどうか**。
#   よって「理由で絞り、件数は結果」に変えた。期限が今日のものが8件あれば8件出す。
#   理由のあるものが0件なら「今日は急ぎなし」と伝える。
#
# 「今日出す理由」＝ 期限が今日/明日・期限超過・相手を待たせている・止まると他が止まる。
# このうち機械で判定できるのは日付だけ。残り（相手を待たせている等）は台帳の状態や本文から
# モード側が判断する＝ここでは**日付の理由だけを機械的に付け**、材料として渡す。
DUE_SOON_DAYS = 1        # 期限が今日・明日なら「今日出す理由」がある

# 起票を見送った理由の区分。**自由文にしない**＝固有名詞を状態ファイル（git追跡下）に残さない。
# どの用件かは C-NNN で台帳（git外）を引けば分かるので、ここには「型」だけを持たせる。
HOLD_REASONS = {
    "no-work":      "案件がHANAツールに無い",
    "work-ambiguous": "案件の候補が絞れない",
    "work-spans":   "複数の案件にまたがる",
    "assignee-unclear": "担当が不明・複数",
    "duplicate-suspect": "既存ToDoと重複の疑い",
    "not-in-room":  "本人がそのルームに参加していない",
    # 以下2つは todo-post.py が実際に出す区分（2026-09-03 追加）。
    # 区分が無いと --add が弾かれ、見送りが確認列に載らない＝社長に上がらない。
    "no-fields":    "台帳の行に案件・期日の欄が無い（v1.1 以前の書式）",
    "due-needs-human": "期限が逆算・強度＝日付は人が決める",
    # 2026-09-04 社長ご指示「案件については、私の方に追加を依頼してほしい」。
    # 案件が無い用件は work 199 へ入れて起票はするが、**案件を作るお願い自体が
    # ToDo 本文に埋もれて社長に届かない**ので、確認列に立てて上がるようにする。
    "work-missing": "この用件の案件が HANAツールに無い＝案件の作成をお願いします",
    # 2026-11-03 Codex 指摘＝起票の応答で作業日が空だったとき、警告を画面に出すだけだと
    #   comms の無人サイクル（2時間おき）はログに流して終了コード0で進むため、**宿題が残らない**。
    #   自動で入れ直すとToDoの二重作成の危険があるので、確認列に積んで人に渡す。
    "work-date-not-set": "作業日が保存されなかった（API が受けていない）＝手で入れてください",
    "other":        "その他（社長に口頭で確認）",
}

# 件数の上限は**保険**として残す（主役ではない）。理由のあるものが極端に多い日に、
# 捌けない相手へ積み増さないための歯止め。0にすると督促が途切れるので下限は1。
CAP_MIN, CAP_MAX, CAP_START = 1, 12, 8
# 提案してからこの日数が過ぎても未完了なら「終わっていませんか」と聞く材料にする
STALE_DAYS = 3

# ── 「次の作業日」の欄（2026-10-07 社長ご承認・マネジメント依頼 M-20261007T105014）──
#  契機＝朝のブリーフが due_date しか読まないため、**数日かかる作業が期日の当日まで上がらない**。
#  #459（長谷さん退職手続き・期日 10/10）の中の雇用保険の届出が 10/5〜10/7 の朝に出ず、
#  社長がたまたま思い出された。社長「作業は1日で終わるものではないので、期日にいきなり言われても困る」。
#
#  ★欄の定義（社長）★ ここを混ぜると朝の起点がずれる：
#    next_work_date ＝ 実際にいつ作業する予定か  → **これを朝の起点にする**
#    start_date     ＝ 最終的にどれだけ時間をかけたかを確かめるための開始日
#                      → **着手の予定としては読まない**（実データでも値ありは1件だけ）
#    due_date       ＝ 相手との期日（従来どおり）
#
#  期日がこの日数以内なのに next_work_date が空＝「いつ着手するか」の案を出す対象。
WORK_DATE_SOON_DAYS = 7

# 「次の作業日」の区分で本文を並べる件数の上限。**件数は必ず全部返す**（count）。
#  なぜ上限を置くか＝実測 2026-10-08 で next_work_date の値ありが56件、その多くが過去日付。
#  古い値の棚卸しはマネジメントが社長と行う予定で、それが済むまで本文を全部並べると
#  既存の区分（外のお客様を待たせている行）が画面から押し出される＝本件の再発になる。
WORK_DATE_TOP = 10


def today():
    return datetime.date.fromisoformat(
        os.environ.get("TODO_BRIEF_TODAY") or datetime.date.today().isoformat())


JST = datetime.timezone(datetime.timedelta(hours=9))


def _date(s):
    """hana-tools の日付を **JST の日付** として読む。

    ★文字列の先頭10文字を切ってはいけない（2026-08-25 partner セッションの指摘で発覚）★
      hana-tools は日付を「JST の 0時」を UTC で表した形で返す。
        投げた値 due_date=2026-08-28  →  返る値 2026-08-27T15:00:00.000000Z
      先頭10文字を切ると **2026-08-27**＝1日前倒しになり、督促が全件1日早く鳴る。
      期限当日のものを「昨日が期限」と言い、前日のものを「今日が期限」と言う。
      タイムゾーンの無い素の日付（"2026-08-28"）はそのまま JST の日付として扱う。
    """
    v = str(s or "")
    if not v:
        return None
    try:
        if "T" in v:
            dt = datetime.datetime.fromisoformat(v.replace("Z", "+00:00"))
            if dt.tzinfo is None:                 # タイムゾーン無しは JST とみなす
                dt = dt.replace(tzinfo=JST)
            return dt.astimezone(JST).date()
        return datetime.date.fromisoformat(v[:10])
    except Exception:
        return None


def known_user_ids():
    """config から「誰の担当ぶんを見るか」を読む。

    ★これを持たないと全体が見えない（2026-08-24 実害）：hana-api.sh は担当が未指定のとき
      .env の既定ユーザー（社長）を assignee_user_id に自動で入れる。その結果を「全ToDo」と
      思い込み、①他の担当者の既存ToDoを見落として重複を作り ②「社長保有率100%」と誤報した。
      実際は 71%。**既定フィルタの存在を知らないと、必ず自分の担当ぶんだけを全体だと思う。**
    """
    try:
        with open(os.path.join(ROOT, "config", "comms-members.json"), encoding="utf-8") as f:
            m = (json.load(f) or {}).get("hana_user_ids") or {}
    except Exception:
        return []
    ids = []
    for v in m.values():
        ids.extend(v if isinstance(v, list) else [v])
    return sorted({int(i) for i in ids if str(i).isdigit()})


def fetch_all_todos(status=None):
    """**全担当ぶん**をまとめて取る。重複判定はこれを使う（担当を絞ると見落とす）。"""
    seen = {}
    uids = known_user_ids()
    if not uids:
        sys.exit("ERROR: config/comms-members.json の hana_user_ids が読めません"
                 "（誰の担当ぶんを見るか分からないまま重複判定はできません）")
    for uid in uids:
        cmd = ["bash", API, "todos", f"--assignee_user_id={uid}"]
        if status:
            cmd.append(f"--status={status}")
        seen.update({i.get("id"): i for i in _fetch_one(cmd, uid)})
    # ★3段目：全担当を合わせて0件は「取得に失敗した証拠」として扱う（2026-08-25 社長ご指摘）。
    #   社内に未完了ToDoが1件も無いことは実際には起こらない。文言や応答形式が変わっても
    #   この判定は生き残るので、文字列に依存する検査より長持ちする。
    #   ここを通すと、認証切れの日に「既存ToDoは0件＝重複なし」と判定して**全件を二重起票**する。
    if not seen:
        sys.exit("ERROR: 全担当を合わせてToDoが0件でした。社内にToDoが皆無ということは通常ありません"
                 "＝取得に失敗している可能性が高いため、ここで止めます（重複起票を防ぐため）")
    return list(seen.values())


def _fetch_one(cmd, uid):
    """1回ぶんの取得。**失敗を空リストに化けさせない**（2026-08-25 Codexレビューで実害を確認）。

    hana-tools は認証切れでも HTTP 的には成功し `{"success": false, "message": ...}` を返す。
    以前は `d.get("data") or []` としていたため、これを「ToDo 0件」と読み、
    重複チェックが `safe_to_create: true` を返していた＝**認証が切れた日に全件を二重起票する**。
    """
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        sys.exit(f"ERROR: hana-tools の応答がありません（担当 {uid}・120秒）")
    if r.returncode != 0:
        sys.exit(f"ERROR: hana-tools の呼び出しが失敗しました（担当 {uid}・exit={r.returncode}）")
    try:
        d = json.loads(r.stdout)
    except Exception:
        sys.exit(f"ERROR: hana-tools の応答を読めません（担当 {uid}）"
                 "＝認証・ネットワークを確認してください")
    if isinstance(d, dict):
        if d.get("success") is False:
            sys.exit(f"ERROR: hana-tools がエラーを返しました（担当 {uid}）: "
                     f"{str(d.get('message'))[:80]}")
        if "data" not in d:
            sys.exit(f"ERROR: hana-tools の応答に data がありません（担当 {uid}）"
                     "＝空として扱うと重複起票につながるため止めます")
        d = d["data"]
    if not isinstance(d, list):
        sys.exit(f"ERROR: hana-tools の応答が想定外の形です（担当 {uid}）")
    return d


def fetch_todos(all_=False, assignee=None):
    """hana-tools から ToDo を取る（読み取りのみ）。取れなければ非0で落とす＝黙って空にしない。

    ★担当は**必ず API に渡す**（2026-08-25 修正）：hana-api.sh は担当未指定のとき .env の
      既定ユーザー（社長）を自動で入れる。以前は「既定で取ってから手元で担当を絞る」形だったため、
      他人の担当ぶんは**構造上ゼロ件にしかならなかった**（実際 `--assignee 37` が常に0件だった）。
    """
    cmd = ["bash", API, "todos"]
    if assignee is not None:
        cmd.append(f"--assignee_user_id={assignee}")
    if not all_:
        cmd.append("--status=incomplete")
    return _fetch_one(cmd, assignee if assignee is not None else "既定")


def load_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            s = json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError:
        # 壊れた状態を黙って捨てると、提案履歴が消えて消化率が測れなくなる
        sys.exit(f"ERROR: 状態ファイルが壊れています（{STATE}）。退避してから作り直してください")
    return s if isinstance(s, dict) else {}


def save_state(s):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(s, f, ensure_ascii=False, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE)


def key(assignee):
    return str(assignee if assignee is not None else "self")


def mine(items, assignee):
    """取得済みの一覧から、その人の担当ぶんだけを残す（API 側で既に絞っている前提の念押し）。

    assignee 未指定＝既定ユーザー（社長）ぶん。API が返す時点で null（作成者が担当）も含まれる。
    """
    if assignee is None:
        return items
    return [i for i in items if str(i.get("assignee_user_id")) == str(assignee)]


def facts(i, ref):
    """1件ぶんの機械的な事実。ここに『重要そう』などの判断は入れない。

    `due_reason` だけは例外で、**日付から機械的に決まる「今日出す理由」**を付ける
    （期限切れ／今日・明日が期限）。日付以外の理由（相手を待たせている等）は
    台帳や本文を読まないと分からないので、モード側が足す。
    """
    due, upd = _date(i.get("due_date")), _date(i.get("updated_at"))
    nwd = _date(i.get("next_work_date"))
    overdue = (ref - due).days if due and due < ref else 0
    days_left = (due - ref).days if due and due >= ref else None
    if overdue:
        reason = "期限超過"
    elif days_left is not None and days_left <= DUE_SOON_DAYS:
        reason = "期限が今日・明日"
    else:
        reason = None
    return {
        "id": i.get("id"),
        "work_id": i.get("work_id"),
        "content": i.get("content") or "",
        "description": (i.get("description") or "")[:300],
        "due": str(due) if due else None,
        "overdue_days": overdue,
        "days_left": days_left,
        "stale_days": (ref - upd).days if upd else None,
        "due_reason": reason,          # 日付から決まる「今日出す理由」。無ければ None
        # ★「次の作業日」＝いつ作業する予定か（社長の欄の定義 2026-10-07）。朝の起点はこちら。
        #   日付は _date() で読む＝JST 補正（[:10] で切ると1日早く読む・2度実害）。
        "next_work_date": str(nwd) if nwd else None,
        "next_work_over_days": (ref - nwd).days if nwd and nwd < ref else 0,
    }


def _my_items(a):
    """この担当ぶんの未完了 ToDo（生データ）。**取り方をここ1箇所に集める。**

    ★`fetch_todos` は担当未指定だと .env の既定ユーザー（社長）ぶんしか返さない★
      その落とし穴（2026-08-24 実害＝他の担当者の ToDo を見落として重複を作り「社長保有率100%」と
      誤報した）を各サブコマンドが個別に踏まないよう、`mine()` との組み合わせを1箇所にする
      （2026-09-11 `outside` 追加で2箇所に増えたため抽出）。
    """
    return mine(fetch_todos(assignee=a.assignee), a.assignee)


def cmd_candidates(a):
    ref = today()
    rows = [facts(i, ref) for i in _my_items(a)]
    # 並べ替えは「見やすさ」のためであって優先度ではない（選ぶのは呼び出し側）
    rows.sort(key=lambda r: (-r["overdue_days"], -(r["stale_days"] or 0)))
    if a.limit:
        rows = rows[:a.limit]
    # 日付の理由があるものと無いものを分けて渡す。
    # ★件数で切らない：理由があるものは何件でも due_reason 側に入れる（社長ご指示）。
    #   理由が無いものも捨てずに渡す＝モードが本文から別の理由（相手待ち等）を見つけられるように。
    due_now = [r for r in rows if r["due_reason"]]
    print(json.dumps({
        "as_of": str(ref), "assignee": a.assignee, "count": len(rows),
        "with_due_reason": len(due_now),
        "cap_hint": _cap_for(a.assignee),
        "note": ("日付の理由があるものは件数で切っていません。"
                 "相手を待たせている等の理由は本文・台帳から判断して足してください。"
                 "cap_hint は『理由のあるものが多すぎる日』の保険であり、上限ではありません"),
        "candidates": rows}, ensure_ascii=False, indent=1))


def _cap_for(assignee):
    """保険としての件数目安。前回の消化率から決める（無ければ既定）。"""
    hist = load_state().get(key(assignee), {}).get("history", [])
    return hist[-1].get("cap", CAP_START) if hist else CAP_START


# ── 「外に約束があるか」で分ける（2026-09-11 社長ご指摘で新設・同日 Codex レビューで補強）──
#  背景＝`candidates` は超過日数だけで並べる。その結果、105日超の社内開発（VPN接続・管理画面の
#  機能追加・deploy-prod エイリアス）が上位を占め、**4日超の「よしだ歯科」がその下に沈んだ**。
#  社長ご指摘＝「なぜこれを日々の提案で出してくれなかったんですか」（2026-09-11）。
#  誤りは並べ替えの基準にあった＝**日数は「放置の長さ」であって「痛みの大きさ」ではない**。
#  外のお客様を待たせている行と、自社の積み残しを同じ列に並べれば、長いほうが必ず勝つ。
#  よって**日数の前に区分で分ける**。区分の判定は機械的な材料だけで行い、
#  「どれを今日やるか」は選ばない＝`candidates` と同じ規律（判断はモードの仕事）。
#
#  ★区分の順は「外への影響が確かな順」であって、実行順ではない★
#    上の区分のほうが「外に迷惑がかかっている証拠が強い」というだけ。今日どれに手をつけるかは
#    社長と Main が決める（金額・依存・相手の都合は、この列からは分からない）。

# 社長ご自身が日付つきで宣言された行（例: `2026-09-04 社長ご指示「…月曜日に作業します」`）。
# これが期限超過＝**ご本人の言葉が流れている**＝いちばん先にお見せする。
# 実データの語尾は ご指示／ご決定／ご説明／ご判断／指示／） と揺れるので語尾は縛らない。
# ただし **「社長に確認」「社長へ報告」は宣言ではない**ので、助詞の に／へ が続くものは外す
# （2026-09-11 Codex 指摘）。日付は `2026-09-04` と `2026/9/4` の両方を受ける。
PROMISE_RE = re.compile(r"20\d\d[-/]\d{1,2}[-/]\d{1,2}\s*社長(?![にへ])")

# 私（AI）から中身が見えない経路。ここから来たご依頼は **ToDo の期日だけが唯一の手がかり**で、
# 私が本文を読んで気づくことが原理的にできない（よしだ歯科＝LINE、C-184＝電話）。
# ⚠️ カタカナの「ライン」は入れない＝「撤退ライン」に当たる（2026-09-11 実データで誤検知を確認）。
#    その代わり「ライン」表記の LINE 依頼は落ちる＝取りこぼしは `unclassified-due` 側で拾う。
# ⚠️ ASCII の LINE は前後に英字が続かないときだけ＝`ONLINE` `deadline` `pipeline` に当たらない
#    （2026-09-11 Codex 指摘。当時の実データでの誤爆はゼロだったが、原理的に当たる）。
# ⚠️ 判定前に NFKC 正規化する＝全角の `ＬＩＮＥ` `Ｔｅａｍｓ` を取りこぼさない。
INVISIBLE_RE = re.compile(r"(?<![A-Za-z])LINE(?![A-Za-z])|電話|口頭|対面|Teams")

CLIENTS_CACHE = os.path.join(ROOT, "data", "clients-cache.json")

# 法人格。**前後どちらにも付く**（`株式会社はなさか` / `盛川株式会社`）。
# 実データには学校法人・社会福祉法人・医療法人社団・事業協同組合もある（2026-09-11 Codex 指摘）。
LEGAL_RE = re.compile(
    r"^(株式会社|有限会社|合同会社|合資会社|一般社団法人|公益社団法人|一般財団法人|学校法人"
    r"|社会福祉法人|医療法人社団|医療法人|宗教法人|特定非営利活動法人|事業協同組合)\s*"
    r"|\s*(株式会社|有限会社|合同会社|合資会社|事業協同組合)$")

# **自社はクライアントではない**。実キャッシュに `株式会社はなさか`（→`はなさか`）と `YCOM` が
# 入っており、放っておくと自社タスクが「お客様を待たせている」に化ける（2026-09-11 Codex 指摘）。
CLIENT_DENY = {"はなさか", "株式会社はなさか", "YCOM", "ycom", "y-com"}

# 区分は「外への影響が確かな順」。値は社長にそのままお見せする言葉にする。
OUTSIDE_TIERS = [
    ("promise-slipped",   "社長ご自身の期日つきの言葉が過ぎています"),
    ("invisible-channel", "私から見えない経路（LINE・電話等）＝期日だけが手がかりです"),
    ("client-facing",     "外のお客様を待たせています"),
    ("unclassified-due",  "★期日が来ているのに区分が付きませんでした＝見落としの隠れ場所・必ず目を通す"),
    ("internal",          "期日が来ていない／期日なし（件数だけ）"),
]


def _norm(s):
    """判定用に正規化する。全角英数・全角カナを畳んで、表記揺れで取りこぼさないようにする。"""
    return unicodedata.normalize("NFKC", s or "")


def client_names():
    """クライアント名（と通称）の一覧。**取れなくても落とさない**。

    ★取れなかったことは黙らない★ 一覧が空だと `client-facing` が丸ごと成立しなくなる。
      以前はそれでも正常終了しており、**「クライアント案件を全件見落とす」変異がテストを通った**
      （2026-09-11 Codex 指摘）。いまは一致しなかった期日つきの行が `unclassified-due` に
      **本文つきで**出るので隠れないが、原因が分かるよう警告も返す。

    ★短い通称の扱い★ 以前は4文字未満を一律に捨てていたが、実キャッシュには法人格を外すと
      4文字未満になる実在クライアントが13件あった（HRC・AUN・コア・創拓・シード・みずの・
      夢工房・未来舎 ほか）。**法人格が付いている＝会社名だと確定している**ものに限って、
      2文字以上の通称も採る。法人格の無い短い名前（例: 辻村）は採らない＝本文のどこにでも
      当たるため。取りこぼしても `unclassified-due` で見える（誤検知は消えないが、見落としは見える）。
    """
    try:
        with open(CLIENTS_CACHE, encoding="utf-8") as f:
            data = json.load(f) or {}
    except (OSError, ValueError):
        return []
    names = set()
    for c in data.get("clients") or []:
        raw = (c.get("client_name") or "").strip()
        if not raw:
            continue
        if len(raw) >= 4:
            names.add(raw)
        short = LEGAL_RE.sub("", raw).strip()
        if short != raw and len(short) >= 2:
            names.add(short)
    names -= CLIENT_DENY
    # 長い順＝正式名を優先して `client` に返す。同じ長さは名前順＝**実行ごとに結果を変えない**。
    return sorted(names, key=lambda n: (-len(n), n))


def outside_tier(row, raw, names):
    """1件を区分に割り振る。戻りは (区分, 当たったクライアント名 or None)。

    ★判定には `raw`（生データ）の全文を使う★ `facts()` の `description` は**表示用に300文字で
      切ってある**。切った文字列で判定すると、長い履歴の末尾に「LINEで依頼」「2026-09-04 社長…」が
      追記された件がそのまま沈む（2026-09-11 Codex 指摘・当時 113件中33件が300文字超）。
    """
    desc = _norm(raw.get("description"))
    text = _norm(raw.get("content")) + " " + desc
    if row.get("overdue_days") and PROMISE_RE.search(desc):
        return "promise-slipped", None
    if not row.get("due_reason"):
        # 期限がまだ先・期限なし＝今日の材料ではない。ここで拾うと毎日同じ顔ぶれが並び続ける。
        return "internal", None
    if INVISIBLE_RE.search(text):
        return "invisible-channel", None
    hit = next((n for n in names if n in text), None)
    if hit:
        return "client-facing", hit
    # ★期日は来ているのに区分が付かなかった＝**社内と同じ箱に入れない**★
    #   以前はここを `internal`（件数だけ）に落としていたため、社名の表記揺れ・通称・キャッシュ
    #   欠損のいずれでも、期限超過中の顧客案件が本文なしで消えていた（2026-09-11 Codex 指摘）。
    return "unclassified-due", None


# ★ここは既存の区分（OUTSIDE_TIERS）を1行も動かさない★
#   同じ行が tiers と work_dates の両方に出るのは**意図どおり**＝見る目的が違う。
#     tiers      ＝外への影響が確かな順（誰を待たせているか）
#     work_dates ＝着手の予定（いつ手をつける予定になっているか）
#   混ぜて1つの列にすると、片方の意味が必ず壊れる（2026-09-11 に日数と痛みを混ぜて踏んだ型）。
# 1区分＝1行に閉じる（名前・見出し・入る条件・並び順）。
# ★ここを「名前をキーにした3つの辞書」で持ってはいけない★＝条件だけ直して並び順を直し忘れる、
#   区分を1つ足してラベルだけ足す、が起きる。このリポジトリで最頻の壊れ方
#   （rules/testing.md の ads/ga4/gsc の行＝「同じ判定を3本に書いている」と同じ型）。
#   ⚠️ 「期日が7日以内」は**期限超過を含めない**（社長の依頼文のとおりに読む）。超過ぶんは
#      既存の区分（期限超過）で既に大きく鳴っており、ここに混ぜると同じ行が二重に並ぶだけ。
#      ただし件数は cmd_outside の overdue_without_work_date で返す
#      ＝「超過していて着手日も無い」は最も重いので、数が消えないようにする。
WORK_DATE_BLOCKS = [
    ("work-today", "今日が次の作業日です",
     lambda r, ref: r["next_work_date"] == str(ref),
     lambda r: (-r["overdue_days"], r["id"])),
    ("work-slipped", "次の作業日を過ぎて未完了です",
     lambda r, ref: bool(r["next_work_over_days"]),
     lambda r: (-r["next_work_over_days"], r["id"])),
    ("work-undated", "期日が近いのに次の作業日が空です＝着手日を決める対象",
     lambda r, ref: (not r["next_work_date"] and r["days_left"] is not None
                     and r["days_left"] <= WORK_DATE_SOON_DAYS),
     lambda r: (r["days_left"], r["id"])),
]


def work_date_view(rows, ref, top):
    """「次の作業日」から見た3区分。件数は必ず全部返し、本文だけ top 件に絞る。"""
    out = []
    for kind, label, belongs, order in WORK_DATE_BLOCKS:
        hit = sorted((r for r in rows if belongs(r, ref)), key=order)
        out.append({"kind": kind, "label": label, "count": len(hit),
                    "shown": len(hit[:top]), "items": hit[:top]})
    return out, len([r for r in rows if not r["next_work_date"] and r["overdue_days"]])


def cmd_outside(a):
    ref = today()
    names = client_names()
    items = _my_items(a)
    groups = {k: [] for k, _ in OUTSIDE_TIERS}
    for i in items:
        r = facts(i, ref)
        tier, hit = outside_tier(r, i, names)
        r["client"] = hit
        groups[tier].append(r)
    for g in groups.values():
        g.sort(key=lambda r: (-r["overdue_days"], -(r["stale_days"] or 0)))
    warnings = []
    if not names:
        warnings.append("クライアント一覧が読めません（data/clients-cache.json）"
                        "＝お客様の案件は unclassified-due に落ちます。中身は返るので隠れません")
    # 社内の積み残しは**件数だけ**にする＝ここを並べると外の行が必ず埋もれる（本件の再発）。
    # ★除外の正は pop の1箇所★ 取り出した残りをそのまま並べる＝「pop する」と「一覧から外す」の
    #   条件が二重にならない（片方だけ直すと内部の行が社長の列に混ざる／逆に外の行が消える）。
    internal = groups.pop("internal")
    shown = [{"tier": k, "label": v, "count": len(groups[k]), "items": groups[k]}
             for k, v in OUTSIDE_TIERS if k in groups]
    # 「次の作業日」の区分は**全件（internal に落ちたものも含む）**から数える。
    # ★tiers の箱から数えてはいけない★＝「期日が来ていない／期日なし」は internal に落ちるので、
    #   そこを除くと「今日が次の作業日だが期日はまだ先」という行が丸ごと消える＝本件の目的そのもの
    #   （数日かかる作業を期日の前に上げる）が達成できない。
    all_rows = [r for t in shown for r in t["items"]] + internal
    work_blocks, overdue_undated = work_date_view(all_rows, ref, a.work_date_top)
    print(json.dumps({
        "as_of": str(ref), "assignee": a.assignee, "count": len(items),
        "client_aliases_loaded": len(names),
        "warnings": warnings,
        "note": ("区分は『外への影響が確かな順』であって実行順ではありません"
                 "（どれを今日やるかは選びません＝判断はモードの仕事）。"
                 "社内の積み残しは件数だけ返します＝並べると外の行が埋もれます。"
                 "unclassified-due は『期日が来ているのに区分が付かなかった』もの＝見落としの隠れ場所です"),
        "tiers": shown,
        "internal_count": len(internal),
        "internal_ids": [r["id"] for r in internal],
        # ── 「次の作業日」から見た区分（2026-10-07 社長ご承認・足すだけ＝上の tiers は不変）──
        "work_dates": {
            "soon_days": WORK_DATE_SOON_DAYS,
            "top": a.work_date_top,
            "note": ("next_work_date＝いつ作業する予定か（朝の起点）。start_date は"
                     "『どれだけ時間をかけたか』用なので着手の予定として読みません。"
                     "上の tiers とは別の箱です＝同じ行が両方に出ます（tiers＝外への影響／"
                     "こちら＝着手の予定）。count は全件・items は top 件だけ。"
                     "work-undated は期限超過を含みません＝超過ぶんは"
                     "overdue_without_work_date の件数で返します"),
            "blocks": work_blocks,
            "overdue_without_work_date": overdue_undated,
        },
        # 保存則の検算用＝どの行も必ずどこか1つの箱に入っている（テストで固定している）
        "accounted": sum(t["count"] for t in shown) + len(internal),
    }, ensure_ascii=False, indent=1))


# ── 「期限なし × 作業日なし」の見落とし（2026-11-02 マネジメント依頼・社長ご承認済み）──
#  契機＝発注済みの案件（#578／#589）が優先の一覧から落ちた。`outside` は **due_date のある行しか
#  区分しない**ため、期限が空の行は `internal`（件数だけ）に落ちて本文が1行も出ない。
#  実測 2026-11-03（社長ぶん 未完了238件）＝期限が空 152件／そのうち作業日が空か過去 **140件**
#  （空 94・過去 46）。台帳の C-NNN と突き合わせて 🔴 は 62件。
#
#  ★ここは「🔴 で絞る」のではなく「🔴 を上に置く」★
#    ご依頼の字面は「🔴」だが、実測するときっかけの #578 には `[C-NNN]` のタグが無い
#    （人が作った ToDo）。🔴 だけに絞ると**きっかけの行そのものが落ちる**＝本件の再発。
#    よって 140件すべてを返し、印で並べ替えるだけにする。件数は必ず全件返す。
#  ★「発注・着手の約束らしい行」を本文から推測しない★
#    代わりに**台帳が自分で付けた 💰 の印**（お金が動く用件）を読む。ToDo の文面から
#    「発注済みらしさ」を当てるのは推測なので、やらない（ご依頼「判定できないものを
#    推測で上げない」）。印が無い行は印が無いまま、下の箱に件数つきで出す。
LEDGER = os.path.join(ROOT, "data", "comms", "chatwork", "ledger.md")

# 台帳の行＝`C-NNN | 状態 | ルーム | 経緯 | 残＝… | 件名: …` のパイプ区切り1行。
# ★状態は「行の2番目の欄」から読む・節の見出しから読まない★
#   実データでは「🔴 の節に 🟢 の行がある」（状態を変えた直後・移動の途中）。
#   節で判定すると、閉じた用件を 🔴 として社長の列に積む。
LEDGER_ROW_RE = re.compile(r"^\s*(C-\d{3,})\s*\|\s*([^|]*)\|")
TODO_TAG_RE = re.compile(r"\[(C-\d{3,})\]")

# 本文を並べる上限。★件数（count）は必ず全件返す★＝一覧の「他に N 件あり」に使う。
UNDATED_TOP = 10


def ledger_states(path=None):
    """台帳（git外）から C-NNN ごとの印を読む。戻り＝({C-NNN: {red, money}}, 警告 or None)。

    ★読めないことがある★ 台帳は git 追跡外なので、環境によっては存在しない。
      そのときは**空で返して警告を立てる**＝並べ替えができないだけで、行は1件も隠さない
      （隠すと「台帳が無い環境では見落としが見えない」という別の穴になる）。
    """
    try:
        with open(path or LEDGER, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return {}, ("台帳が読めません（data/comms/chatwork/ledger.md）"
                    "＝🔴・💰 での並べ替えができません。行は全件返します")
    st = {}
    for line in lines:
        m = LEDGER_ROW_RE.match(line)
        if not m:
            continue
        tag, state = m.group(1), m.group(2)
        # ★最初に出た行を正とする★ 台帳は新しい順。同じ C-NNN が過去の節に残っていても
        #   上（新しい）を採る＝「解決済みなのに 🔴 と言う」を防ぐ。
        if tag not in st:
            st[tag] = {"red": "🔴" in state, "money": "💰" in line}
    return st, None


# 1箱＝1行（名前・見出し・入る条件）。**上から順に最初に当たった箱に入る**＝1行は必ず1箱。
# ⚠️ 箱を足すときは順番も一緒に考える（上が重い）。並び順を別の場所に持たせない。
UNDATED_BLOCKS = [
    ("red-money", "台帳🔴＋💰＝お金が動く用件（台帳が付けた印。本文からの推測ではありません）",
     lambda r: r["ledger"] == "red" and r["ledger_money"]),
    ("red", "台帳🔴＝未解決のまま台帳に残っています",
     lambda r: r["ledger"] == "red"),
    ("tag-not-in-ledger", "★タグはあるのに台帳で見つかりません（台帳が読めない／archive へ移った等）＝印で絞れないので目を通す",
     lambda r: r["ledger"] == "unknown-tag"),
    ("other-tagged", "台帳にはあるが🔴ではない（🟢・👥・📌）",
     lambda r: r["ledger"] == "other"),
    ("untagged", "★台帳に紐づきません（人が作った ToDo など）＝印では絞れないので必ず目を通す",
     lambda r: r["ledger"] is None),
]


def _undated_order(r):
    """作業日を過ぎたものを先（過ぎた日数の大きい順）→ 次に作業日が空（最終更新が古い順）。

    ★日付は facts() が JST に直した値だけを見る★（`[:10]` で切ると1日早く読む＝2度実害）。
    """
    return (0 if r["next_work_over_days"] else 1,
            -r["next_work_over_days"], -(r["stale_days"] or 0), r["id"] or 0)


def undated_rows(items, ref, st):
    """期限が空 × 作業日が空か過去 の行だけを返す（台帳の印を付けて）。

    ★タグは生データから拾う★ `facts()` の `description` は表示用に300文字で切ってあるので、
      切った文字列で探すと長い経過の末尾に付いたタグを落とす（2026-09-11 と同じ型）。
    """
    out = []
    for i in items:
        r = facts(i, ref)
        if r["due"]:
            continue                      # 期限があるものは既存の区分（tiers）が鳴らす
        if r["next_work_date"] and not r["next_work_over_days"]:
            continue                      # 今日・これからの作業日が入っている＝予定済み
        raw = (i.get("content") or "") + " " + (i.get("description") or "")
        tags = list(dict.fromkeys(TODO_TAG_RE.findall(raw)))
        hits = [st[t] for t in tags if t in st]
        if not tags:
            state = None
        elif not hits:
            state = "unknown-tag"
        elif any(h["red"] for h in hits):
            state = "red"
        else:
            state = "other"
        r["ledger_tags"] = tags
        r["ledger"] = state
        # ★🔴 と 💰 は**同じ行**に付いていることを要求する（2026-11-03 Codex 指摘）★
        #   1件の ToDo に複数の C-NNN が付くことがある。別々の行の 🔴 と 💰 を足すと
        #   「🔴＋💰＝お金が動く用件」という見出しが実態と食い違う（誤報の向きを作る）。
        r["ledger_money"] = any(h["red"] and h["money"] for h in hits)
        out.append(r)
    return out


def cmd_undated(a):
    ref = today()
    st, warn = ledger_states()
    rows = undated_rows(_my_items(a), ref, st)
    # ★1行は必ず1箱＝上から順に最初に当たった箱へ入れる★
    #   各箱の条件を全行に当てる書き方（箱ごとに filter）だと `red-money` の行が `red` にも
    #   入り、件数が二重に増える（2026-11-03 実装中に保存則の検算で検出＝42件が二重）。
    #   「他に N 件あり」に使う数字なので、二重計上は社長の判断材料を直接壊す。
    picked = {kind: [] for kind, _, _ in UNDATED_BLOCKS}
    for r in rows:
        for kind, _label, belongs in UNDATED_BLOCKS:
            if belongs(r):
                picked[kind].append(r)
                break
    blocks = []
    for kind, label, _belongs in UNDATED_BLOCKS:
        hit = sorted(picked[kind], key=_undated_order)
        blocks.append({"kind": kind, "label": label, "count": len(hit),
                       "shown": len(hit[:a.top]), "items": hit[:a.top]})
    print(json.dumps({
        "as_of": str(ref), "assignee": a.assignee,
        "target_count": len(rows),
        "top": a.top,
        "warnings": [w for w in [warn] if w],
        "note": ("期限（due_date）が空で、かつ次の作業日が空か過ぎている未完了 ToDo。"
                 "`outside` は期限のある行しか区分しないため、ここは本文が1行も出ない死角でした。"
                 "★🔴 で絞っていません＝台帳のタグが無い行（人が作った ToDo）も必ず返します。"
                 "並び順は『台帳が付けた印』だけで決めています（本文から発注済みらしさを推測しません）。"
                 "count は全件・items は top 件だけ。どれをやるかは選びません＝判断はモードの仕事"),
        "ledger": {"rows": len(st), "red": sum(1 for v in st.values() if v["red"])},
        "work_date": {
            "empty": sum(1 for r in rows if not r["next_work_date"]),
            "past": sum(1 for r in rows if r["next_work_over_days"]),
        },
        "blocks": blocks,
        # 保存則の検算用＝どの行も必ずどこか1つの箱に入っている（テストで固定）
        "accounted": sum(b["count"] for b in blocks),
    }, ensure_ascii=False, indent=1))


def cmd_record(a):
    ids = [int(x) for x in a.ids.split(",") if x.strip()]
    if not ids:
        sys.exit("ERROR: --ids に提案した ToDo の ID を渡してください")
    s = load_state()
    e = s.setdefault(key(a.assignee), {"history": []})
    e["history"] = [h for h in e["history"] if h.get("date") != str(today())]
    e["history"].append({"date": str(today()), "proposed": ids})
    e["history"] = e["history"][-60:]      # 状態ファイルを有界に保つ
    save_state(s)
    print(f"記録しました: {len(ids)}件（{today()}）")


def cmd_review(a):
    """前回の提案がどれだけ片付いたかを測り、**保険としての件数目安**を決める。

    ★これは上限ではない（2026-08-25 社長ご指摘で設計変更）★
      「今日出す理由があるもの」は、この値を超えていても出す。
      ここで決めるのは「理由のあるものが極端に多い日に、捌けない相手へ積み増さない」ための歯止め。
    """
    s = load_state()
    hist = s.get(key(a.assignee), {}).get("history", [])
    if not hist:
        print(json.dumps({"first_time": True, "next_cap": CAP_START,
                          "reminder": "保険であって上限ではありません"},
                         ensure_ascii=False, indent=1))
        return
    last = hist[-1]
    # 完了判定は全担当ぶんで見る（提案した相手以外へ付け替えられている可能性もあるため）
    done_ids = {i["id"] for i in fetch_all_todos() if i.get("completed_at")}
    proposed = last["proposed"]
    done = [i for i in proposed if i in done_ids]
    rate = len(done) / len(proposed) if proposed else 0.0
    # ★基準は「前回いくつ出したか」ではなく「前回の保険値」。
    #   以前は前回の提案数をそのまま基準にしていたため、13件出した翌日は13件が基準になり、
    #   設計上の上限がまったく効いていなかった（2026-08-25 Codexレビューで発覚・実データが反例）。
    prev_cap = last.get("cap", CAP_START)
    if rate >= 1.0:
        cap = min(prev_cap + 2, CAP_MAX)
    elif rate >= 0.5:
        cap = prev_cap
    else:
        cap = max(prev_cap - 2, CAP_MIN)
    print(json.dumps({
        "last_date": last["date"], "proposed": len(proposed), "completed": len(done),
        "rate": round(rate, 2), "prev_cap": prev_cap, "next_cap": cap,
        "note": ("前回は全部片付いています＝保険をゆるめる" if rate >= 1.0 else
                 "前回は半分以上片付いています＝据え置き" if rate >= 0.5 else
                 "前回は捌けていません＝保険を締める（積み増さない）"),
        "reminder": ("これは上限ではなく保険です。今日出す理由があるものは"
                     "この値を超えていても出してください（社長ご指示）"),
    }, ensure_ascii=False, indent=1))


def cmd_stale(a):
    """提案したのに動きが無いもの＝『もう終わっていませんか』と聞く材料。

    完了の記録漏れは、この仕組みが最初に壊れる場所（終わった仕事を毎朝突くことになる）。

    ★2026-08-25 Codexレビューで3つの穴を修正★
      ① **再提案で時計が戻らなかった**：同じIDを10日前と昨日に提案した場合、昨日ぶんは
         「3日未満」で飛ばされ、10日前の履歴から拾われて「10日動いていない」と催促していた。
         → **その ID を最後に提案した日**を基準にする。
      ② **担当を移された未完了ToDoが誰からも催促されなかった**：元担当のAPI検索から消え、
         新担当の履歴には無いため両方から漏れる。→ **全担当ぶんから探す**。
      ③ **「動きが無い」ことを確かめていなかった**：ToDo の updated_at を見ておらず、
         昨日更新されていても毎朝出していた。→ 更新があったものは聞かない。
    """
    ref = today()
    s = load_state()
    hist = s.get(key(a.assignee), {}).get("history", [])
    # 全担当ぶんから引く（担当が付け替えられても見失わない）
    all_todos = {i["id"]: i for i in fetch_all_todos()}
    # その ID を「最後に」提案した日
    last_proposed = {}
    for h in hist:
        d = _date(h.get("date"))
        if not d:
            continue
        for tid in h.get("proposed", []):
            if tid not in last_proposed or d > last_proposed[tid]:
                last_proposed[tid] = d
    out = []
    for tid, when in sorted(last_proposed.items(), key=lambda kv: kv[1]):
        t = all_todos.get(tid)
        if t is None or t.get("completed_at"):
            continue                                   # 完了・削除は聞かない
        if (ref - when).days < STALE_DAYS:
            continue                                   # 提案したばかりは急かさない
        upd = _date(t.get("updated_at"))
        if upd and upd >= when:
            continue                                   # 提案後に動きがある＝進んでいる
        out.append({"id": tid, "proposed_on": str(when),
                    "days_since": (ref - when).days,
                    "last_updated": str(upd) if upd else None,
                    "assignee": t.get("assignee_user_id"),
                    "content": t.get("content") or ""})
    print(json.dumps({"as_of": str(ref), "stale_days": STALE_DAYS,
                      "count": len(out), "items": out}, ensure_ascii=False, indent=1))


OTHER_TAG = re.compile(r"\[C-\d{3,}\]")


def cmd_check(a):
    """起票してよいかを調べる。**同じ用件が既にあれば起票しない**（迷ったら起票せず確認列へ）。

    ★タグ照合だけでは足りない（2026-08-24 実害）：既存の id=229 は台帳タグを持っていなかったため
      [C-007] の照合をすり抜け、同じ用件を二重に起票した。人が作ったToDoにタグは付いていない。
      そこで語の重なりも材料として出し、**最終判断は呼び出し側（モード）に委ねる**。
    """
    print(json.dumps(judge(fetch_all_todos(), (a.tag or "").strip(), a.title or ""),
                     ensure_ascii=False, indent=1))


def judge(todos, tag, title):
    """重複判定の本体。`check`（1件）と `check-batch`（複数件）が共有する唯一の実装。"""
    # ★角括弧つきで照合する：`C-01` が既存の `[C-010]` に部分一致すると、
    #   無関係な用件の起票を止めてしまう（業務が止まる側の誤検知・2026-08-25 Codexレビュー）。
    tagpat = re.compile(r"\[" + re.escape(tag) + r"\]") if tag else None
    exact = [{"id": t["id"], "content": t.get("content") or "",
              "completed": bool(t.get("completed_at")),
              "assignee": t.get("assignee_user_id")}
             for t in todos if tagpat and tagpat.search(t.get("content") or "")]
    words = [w for w in re.split(r"[\s\[\]（）()・、。／/]+", title) if len(w) >= 4]
    similar = []
    for t in todos:
        c = t.get("content") or ""
        if tagpat and tagpat.search(c):
            continue
        # ★別の台帳タグ [C-XXX] が付いた ToDo は、**定義上べつの台帳行**なので似ていても重複ではない。
        #   語の重なりは「人が作った（タグの無い）ToDo」を拾うための手段であって、
        #   機械が作ったもの同士を突き合わせるためではない。
        #   これを外さないと、**同じ客先の兄弟を作った直後に、次の行が永久に起票できなくなる**
        #   （2026-09-04 実害＝24件を一度に作った回で2件が落ち、部分失敗のあとは次回以降も落ち続ける）。
        if OTHER_TAG.search(c):
            continue
        # 説明欄にだけ詳細があるToDoも拾う（人が作ったものは件名が短いことが多い）
        body = c + " " + (t.get("description") or "")
        hit = [w for w in words if w in body]
        if hit:
            similar.append({"id": t["id"], "content": c, "completed": bool(t.get("completed_at")),
                            "assignee": t.get("assignee_user_id"), "matched": hit})
    return {"tag": tag, "scanned": len(todos),
            "scanned_assignees": known_user_ids(),
            "caveat": ("照合したのは config に登録された担当のぶんだけです。"
                       "登録漏れの担当が持つToDoは見えていません"),
            "exact": exact, "similar": similar,
            "safe_to_create": not exact and not similar}


def cmd_check_batch(a):
    """複数行ぶんの重複判定を **ToDo 全件取得1回** で済ませる。

    ★`check` を行ごとに呼ぶと、1行につき1回ずつ全件を取り直す（対象54行なら54回）。
      遅いだけでなく、**行ごとに違うスナップショットで判定する**ことになり、
      同じ実行の中で判定基準がずれる（2026-09-04 Codexレビュー指摘）。
      判定そのものは `cmd_check` と同じ関数（`judge`）を通す＝**重複の定義を2箇所に持たない**。

    入力＝stdin に `[{"tag": "C-001", "title": "..."}, ...]`／出力＝tag をキーにした判定の辞書。
    """
    try:
        items = json.loads(sys.stdin.read() or "[]")
    except Exception:
        sys.exit("ERROR: check-batch の入力（JSON）を読めません")
    todos = fetch_all_todos()
    print(json.dumps({t.get("tag", ""): judge(todos, t.get("tag", ""), t.get("title", ""))
                      for t in items}, ensure_ascii=False, indent=1))


def cmd_hold(a):
    """起票しなかったものと理由を積む（社長に確認する列）。朝に無理やりToDo化しないための置き場。"""
    s = load_state()
    h = s.setdefault("_hold", {})
    if a.add:
        if not a.reason:
            sys.exit("ERROR: --reason に「なぜ起票しなかったか」が要ります（理由の無い保留は溜まるだけ）")
        # ★理由は決められた区分から選ぶ（自由文を禁じる・2026-08-25 Codexレビュー）。
        #   自由文だと固有名詞（クライアント名・案件名）がそのまま書かれ、**git 追跡下の
        #   state.json に漏れる**（実際にテスト自身が固有名詞を書き込んでいた）。
        #   どの用件かは C-NNN で台帳（git外）を引けば分かるので、ここには「型」だけを持たせる。
        if a.reason not in HOLD_REASONS:
            sys.exit("ERROR: --reason は次から選んでください（固有名詞を状態ファイルに残さないため）:\n  "
                     + "\n  ".join(f"{k} … {v}" for k, v in HOLD_REASONS.items()))
        # ★ since は既存を保つ。ここを毎回 today() で上書きすると、2時間おきの自動同期で
        #   滞留日数が永久に 0 日になり、「10日放置」が見えなくなる（積む意味が消える）。
        prev = h.get(a.add) or {}
        h[a.add] = {"reason": a.reason, "since": prev.get("since") or str(today())}
        save_state(s)
        print(f"確認列に積みました: {a.add}")
    elif a.resolve:
        if h.pop(a.resolve, None) is None:
            sys.exit(f"ERROR: {a.resolve} は確認列にありません")
        save_state(s)
        print(f"確認列から外しました: {a.resolve}")
    else:
        ref = today()
        items = [{"tag": k, **v, "days": (ref - _date(v["since"])).days if _date(v["since"]) else None}
                 for k, v in sorted(h.items())]
        print(json.dumps({"count": len(items), "items": items}, ensure_ascii=False, indent=1))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("candidates", "outside", "undated", "record", "review", "stale",
                 "check", "check-batch", "hold"):
        q = sub.add_parser(name)
        q.add_argument("--assignee", type=int, default=None)
        if name == "candidates":
            q.add_argument("--limit", type=int, default=0)
        if name == "outside":
            q.add_argument("--work-date-top", type=int, default=WORK_DATE_TOP,
                           dest="work_date_top")
        if name == "undated":
            q.add_argument("--top", type=int, default=UNDATED_TOP)
        if name == "record":
            q.add_argument("--ids", required=True)
        if name == "check":
            q.add_argument("--tag", default="")
            q.add_argument("--title", default="")
        if name == "hold":
            q.add_argument("--add"); q.add_argument("--reason"); q.add_argument("--resolve")
    a = p.parse_args()
    {"candidates": cmd_candidates, "outside": cmd_outside, "undated": cmd_undated,
     "record": cmd_record, "review": cmd_review,
     "stale": cmd_stale, "check": cmd_check, "check-batch": cmd_check_batch,
     "hold": cmd_hold}[a.cmd](a)


if __name__ == "__main__":
    main()
