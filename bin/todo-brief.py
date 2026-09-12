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
    "other":        "その他（社長に口頭で確認）",
}

# 件数の上限は**保険**として残す（主役ではない）。理由のあるものが極端に多い日に、
# 捌けない相手へ積み増さないための歯止め。0にすると督促が途切れるので下限は1。
CAP_MIN, CAP_MAX, CAP_START = 1, 12, 8
# 提案してからこの日数が過ぎても未完了なら「終わっていませんか」と聞く材料にする
STALE_DAYS = 3


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
    }


def cmd_candidates(a):
    ref = today()
    rows = [facts(i, ref) for i in mine(fetch_todos(assignee=a.assignee), a.assignee)]
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


def cmd_outside(a):
    ref = today()
    names = client_names()
    items = mine(fetch_todos(assignee=a.assignee), a.assignee)
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
    internal = groups.pop("internal")
    shown = [{"tier": k, "label": v, "count": len(groups[k]), "items": groups[k]}
             for k, v in OUTSIDE_TIERS if k != "internal"]
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
        # 保存則の検算用＝どの行も必ずどこか1つの箱に入っている（テストで固定している）
        "accounted": sum(t["count"] for t in shown) + len(internal),
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
    for name in ("candidates", "outside", "record", "review", "stale", "check", "check-batch", "hold"):
        q = sub.add_parser(name)
        q.add_argument("--assignee", type=int, default=None)
        if name == "candidates":
            q.add_argument("--limit", type=int, default=0)
        if name == "record":
            q.add_argument("--ids", required=True)
        if name == "check":
            q.add_argument("--tag", default="")
            q.add_argument("--title", default="")
        if name == "hold":
            q.add_argument("--add"); q.add_argument("--reason"); q.add_argument("--resolve")
    a = p.parse_args()
    {"candidates": cmd_candidates, "outside": cmd_outside, "record": cmd_record, "review": cmd_review,
     "stale": cmd_stale, "check": cmd_check, "check-batch": cmd_check_batch,
     "hold": cmd_hold}[a.cmd](a)


if __name__ == "__main__":
    main()
