#!/usr/bin/env python3
"""Chatwork の生ログから「誰から誰へ」を機械的に取り出す（読み取り専用）。

契機＝2026-08-07 社長ご指摘：
    「グループチャットだと私宛てではないものが入ってしまっている。周りの動きを知るために
      対象外とする必要はないが、少なくとも誰から誰宛てのメッセージかを把握してまとめてほしい」

現状＝生ログの body には Chatwork の宛先記法がそのまま入っているのに、蒸留（comms モード）は
タグごと捨てて読んでいたため、**宛先の情報が使われていなかった**。
実測（2026-08-07）＝全 581 件中 [To:] 56 件・[rp aid=] 267 件＝**51% が明示的な宛先を持つ**。
既存台帳も 41 行中 22 行が他の方宛を指し、うち 9 行が🔴「社長ボール」のままだった。

判断を AI の目視に委ねず、ここで機械的に確定させる（[[feedback_writeback-to-source-of-truth]] と同じ考え方）。

## 黙って落とさない（2026-08-07 Codexレビュー反映）
無人ループに組み込む道具なので、**入力が壊れていても黙って進まない**ことを最優先にした：
  ・壊れた JSON 行 … ファイル名と行番号を出す（見えないまま捨てない）
  ・rooms.md の不備 … 未知の見出し・重複 room_id・形式違反を出す（除外は業務データを落とす設定）
  ・除外ルーム    … 出力から消さず「除外」節に分けて出す（規律「本当の用件が混ざっていたらメモへ」を実行可能にする）
  ・引用の閉じ忘れ … 宛先を取り違える恐れがあるので印をつける

出力は stdout のみ。**ファイルに書き出すのは roster.json（data/comms 配下＝git外）だけ。**

使い方：
    python3 bin/comms-who.py                 # 台帳の「蒸留済み(cw)」以降の新着を一覧
    python3 bin/comms-who.py --since "2026-08-01 00:00:00"
    python3 bin/comms-who.py --all
    python3 bin/comms-who.py --stats         # 件数だけ（固有名詞を出さない＝ログに残してよい）
    python3 bin/comms-who.py --rooms         # ルーム別の内訳と rooms.md の設定漏れ
    python3 bin/comms-who.py --audit         # 既存台帳の洗い直し（不整合が残れば非0で終わる）
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import tempfile
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "comms" / "chatwork"
RAW = DATA / "raw"
LEDGER = DATA / "ledger.md"
ROSTER = DATA / "roster.json"
ROOMS = DATA / "rooms.md"          # ルームの役割と除外（社長が編集・AIは読むだけ）

# 社長の Chatwork account_id。正本は config/comms-members.json（下の load_members）。
# ここの値は設定が読めなかったときの保険＝**判定を止めないための既定**（不備は MEMBER_PROBLEMS で申告する）。
ME = 757779
# 古い生ログ（35件）は from_account_id を保存していない時代のもの＝**その場合に限り**表示名で本人判定する。
# ID があるのに名前で判定すると、同姓同名の別アカウントを社長扱いしてしまう（Codex🟡）。
ME_NAME = "松田 祥宗"

# 社長・社内メンバーの Chatwork account_id は **git管理の設定ファイル**が正（Codex🔴・2026-08-21）。
# コードに直書きすると、社員が増えたときに直し忘れて「その方宛＝社外の反応待ち(🟢)」に静かに化ける
# ＝2026-08-21 に実際に起きた事故（長谷さん宛140件のうち台帳12行が🟢に埋もれた）の再発経路そのもの。
# 名前は持たない（表示名の正本は roster.json＝git外）。
MEMBERS = Path(__file__).resolve().parent.parent / "config" / "comms-members.json"


def load_members() -> tuple[int, set[int], list[str]]:
    """設定ファイルから (社長ID, 社内メンバーID集合, 不備の一覧) を返す。

    **黙って既定値に倒れない**＝不備はそのまま返し、--audit / --strict で失敗させる。
    社外扱いへの取り違えは静かに起きるので、気づけないまま回るほうが危ない。
    """
    probs: list[str] = []
    if not MEMBERS.exists():
        return 0, set(), [f"{MEMBERS} がありません＝社内・社長の判定ができません"]
    try:
        raw = json.loads(MEMBERS.read_text(encoding="utf-8"))
    except Exception as e:
        return 0, set(), [f"{MEMBERS.name} を JSON として読めません（{e}）"]
    pres = raw.get("president_id")
    if not isinstance(pres, int):
        probs.append("president_id が整数で入っていません")
        pres = 0
    ids = raw.get("internal_account_ids")
    internal: set[int] = set()
    if not isinstance(ids, list) or not ids:
        probs.append("internal_account_ids が空か配列ではありません＝社内宛が社外宛に化けます")
    else:
        for v in ids:
            if isinstance(v, int):
                internal.add(v)
            else:
                probs.append(f"internal_account_ids に整数でない値: {v!r}")
    if pres and pres in internal:
        probs.append("president_id が internal_account_ids に混ざっています（社長は 🔴・社内は 👥＝別扱い）")
    return pres, internal, probs


_PRES, INTERNAL, MEMBER_PROBLEMS = load_members()
if _PRES:
    ME = _PRES

# rooms.md の見出しは「見出し語」の完全一致で判定する。
# 部分一致（"除外" in 見出し）だと "## 除外しない" まで除外扱いになる（Codex🔴）ので、
# 括弧・空白より前の語だけを取り出して突き合わせる（"## 除外（蒸留しない）" → "除外"）。
HEAD_EXCLUDE = "除外"
HEAD_INCLUDE = "蒸留する"
HEAD_WORD = re.compile(r"^#{2,}\s*([^\s（(]+)")

# 引用ブロックの中の [To:] は「宛先」ではない（過去の引用が混ざる）＝先に落とす
QUOTE = re.compile(r"\[qt\].*?\[/qt\]", re.S)
QTMETA = re.compile(r"\[qtmeta[^\]]*\]")
# [To:12345] 長谷 優里奈さん  ／ [rp aid=12345 to=...] 長谷 優里奈さん
TO_TAG = re.compile(r"\[To:(\d+)\]\s*([^\[\n]{0,24})")
RP_TAG = re.compile(r"\[rp\s+aid=(\d+)[^\]]*\]\s*([^\[\n]{0,24})")
TOALL = re.compile(r"\[toall\]")
DELETED = re.compile(r"\[deleted[\]:]")
ANY_TAG = re.compile(r"\[/?[a-zA-Z]+[^\]]*\]")


def _name_after(tag_text: str) -> str:
    """タグ直後に Chatwork が入れる表示名を拾う（「さん」まで）。無ければ空。"""
    m = re.match(r"\s*(.{1,20}?)さん", tag_text)
    return m.group(1).strip() if m else ""


def load_raw() -> tuple[list[dict], list[str]]:
    """生ログを読む。壊れた行は捨てるが、**どのファイルの何行目かを必ず返す**。"""
    recs, problems = [], []
    for f in sorted(RAW.glob("*.jsonl")):
        for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            line = line.strip()
            if not line:
                continue
            try:
                recs.append(json.loads(line))
            except json.JSONDecodeError as e:
                problems.append(f"{f.name}:{n} JSONとして読めません（{e.msg}）")
    recs.sort(key=lambda r: r.get("sent", ""))
    return recs, problems


def build_roster(recs: list[dict]) -> dict[str, str]:
    """account_id → 表示名。API を増やさずに名前を引けるようにする。

    recs は送信時刻の昇順なので、**送信者名は後勝ち＝常に最新の観測名**になる。
    宛先タグ由来の名前は「その ID を送信者として一度も見ていない場合」の補完にだけ使う
    （新旧が混ざると、同じ人が場面によって別名で出る・Codex🟡）。
    """
    roster: dict[str, str] = {}
    from_tags: dict[str, str] = {}
    for r in recs:
        aid, name = r.get("from_account_id"), (r.get("from") or "").strip()
        if aid and name:
            roster[str(aid)] = name          # 後勝ち＝最新
        body = QUOTE.sub(" ", r.get("body", ""))
        for pat in (TO_TAG, RP_TAG):
            for a, tail in pat.findall(body):
                nm = _name_after(tail)
                if nm:
                    from_tags[a] = nm        # こちらも後勝ち
    for a, nm in from_tags.items():
        roster.setdefault(a, nm)
    return roster


def addressees(body: str) -> tuple[list[str], bool, bool, bool]:
    """(宛先account_idの一覧, 全員宛か, 返信か, 引用が閉じていないか)。引用の中は数えない。"""
    broken = body.count("[qt]") != body.count("[/qt]")
    b = QTMETA.sub(" ", QUOTE.sub(" ", body))
    to_ids = [a for a, _ in TO_TAG.findall(b)]
    rp_ids = [a for a, _ in RP_TAG.findall(b)]
    seen, ordered = set(), []
    for a in to_ids + rp_ids:
        if a not in seen:
            seen.add(a); ordered.append(a)
    return ordered, bool(TOALL.search(b)), bool(rp_ids), broken


def load_rooms() -> tuple[dict[str, dict], list[str]]:
    """rooms.md を読む → ({room_id: {...}}, 不備の一覧)。

    senders.md と同じ規律＝**社長が編集し、AI は読むだけ**。
    ファイルが無ければ空を返す（＝全ルーム蒸留対象＝従来どおり動く）。
    """
    if not ROOMS.exists():
        return {}, []
    out: dict[str, dict] = {}
    problems: list[str] = []
    section = None
    for n, line in enumerate(ROOMS.read_text(encoding="utf-8-sig").splitlines(), 1):
        s = line.strip()
        if s.startswith("##"):
            hm = HEAD_WORD.match(s)
            word = hm.group(1) if hm else ""
            if word == HEAD_EXCLUDE:
                section = "exclude"
            elif word == HEAD_INCLUDE:
                section = "include"
            else:
                section = None
                problems.append(f"{n}行目: 知らない見出し「{s}」＝この下の行は無視されます"
                                f"（使えるのは『## {HEAD_EXCLUDE}…』『## {HEAD_INCLUDE}…』）")
            continue
        if not s or s.startswith("#"):
            continue
        if section is None:
            problems.append(f"{n}行目: 見出しの外にルーム行があります＝無視されます「{s[:30]}」")
            continue
        body, _, note = s.partition("#")
        parts = body.split()
        if not parts or not parts[0].isdigit():
            problems.append(f"{n}行目: room_id で始まっていません＝無視されます「{s[:30]}」")
            continue
        rid = parts[0]
        if rid in out:
            problems.append(f"{n}行目: room_id {rid} が重複しています（後の行で上書きされます）")
        if len(parts) < 2:
            problems.append(f"{n}行目: room_id {rid} に役割ラベルがありません")
        out[rid] = {"role": parts[1] if len(parts) > 1 else "",
                    "excluded": section == "exclude", "note": note.strip()}
    return out, problems


def room_members(recs: list[dict]) -> dict[str, dict[str, str]]:
    """ルームごとの「これまでに発言した人」＝{room_id: {account_id or 名前: 表示名}}。"""
    people: dict[str, dict[str, str]] = defaultdict(dict)
    for r in recs:
        rid = str(r.get("room_id"))
        aid = r.get("from_account_id")
        name = (r.get("from") or "").strip()
        key = str(aid) if aid else name
        if key:
            people[rid][key] = name or key
    return people


def _is_me(rec: dict) -> bool:
    """社長ご自身の発信か。ID があるときは ID だけで判定する（同姓同名の誤爆を防ぐ）。"""
    aid = rec.get("from_account_id")
    if aid:
        return str(aid) == str(ME)
    return (rec.get("from") or "").strip() == ME_NAME


def annotate(recs: list[dict], roster: dict[str, str], members: dict[str, dict[str, str]],
             rooms: dict[str, dict] | None = None) -> list[dict]:
    rooms = rooms or {}
    out = []
    for r in recs:
        meta = rooms.get(str(r.get("room_id")), {})
        ids, toall, is_rp, qbroken = addressees(r.get("body", ""))
        rid = str(r.get("room_id"))
        mem = members.get(rid, {})
        solo = len(mem) <= 2
        from_me = _is_me(r)

        if toall:
            to_disp, to_me = ["全員"], True
        elif ids:
            to_disp = [roster.get(a, f"ID:{a}") for a in ids]
            to_me = str(ME) in ids
        elif from_me:
            # 社長ご自身の発信に宛先タグが無い場合。「社長→社長」と出さない（Codex🔴）。
            others = [nm for k, nm in mem.items() if k != str(ME) and nm != ME_NAME]
            if solo and len(others) == 1:
                to_disp, to_me = [others[0]], False
            else:
                to_disp, to_me = ["（宛先指定なし・ルーム全体）"], False
        else:
            # 宛先タグ無し＝社長宛として扱う（2026-08-07 社長ご決定）。
            # 1対1ルームは Chatwork の仕様上そもそも To が付かないため、ここで倒し切る。
            to_disp = ["（宛先指定なし＝社長宛" + ("・1対1" if solo else "・グループ") + "）"]
            to_me = True

        out.append({**r, "to_ids": ids, "to_names": to_disp, "to_me": to_me and not from_me,
                    "from_me": from_me, "is_reply": is_rp, "toall": toall, "solo_room": solo,
                    "quote_broken": qbroken, "deleted": bool(DELETED.search(r.get("body", ""))),
                    "role": meta.get("role", ""), "excluded": bool(meta.get("excluded")),
                    "known_room": bool(meta)})
    return out


def plain(body: str, n: int = 70) -> str:
    t = re.sub(r"\s+", " ", ANY_TAG.sub(" ", QUOTE.sub(" ", body))).strip()
    return t[:n] + ("…" if len(t) > n else "")


def cursor_from_ledger() -> str | None:
    if not LEDGER.exists():
        return None
    m = re.search(r"蒸留済み\(cw\):\s*([0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]{8})",
                  LEDGER.read_text(encoding="utf-8"))
    return m.group(1).replace(" ", "T") if m else None


def atomic_write_secret(path: Path, text: str) -> None:
    """0600 で作ってから中身を書く（通常権限で作って後から chmod する隙を作らない・Codex🟡）。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".json")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def warn_problems(raw_problems: list[str], room_problems: list[str]) -> None:
    """入力の不備は、必ず stdout と stderr の両方に出す（片方しか見ない相手に届かせる）。"""
    for title, probs in (("生ログ", raw_problems), ("rooms.md", room_problems)):
        if not probs:
            continue
        head = f"⚠️ {title} に不備が {len(probs)} 件あります＝黙って無視していません"
        print(head)
        print(head, file=sys.stderr)
        for p in probs[:20]:
            print(f"    - {p}")
            print(f"    - {p}", file=sys.stderr)
        if len(probs) > 20:
            print(f"    …ほか {len(probs) - 20} 件")


LEDGER_ROW = re.compile(r"^\s*(C-\d{3})\s*\|")
ANCHOR = re.compile(r"cw:\s*(\d+)-(\d+)")


def audit(items: list[dict]) -> int:
    """台帳の各行が指しているメッセージの宛先を照合し、直すべき行だけを出す。

    v0.7 以前の台帳は宛先を見ずに作られている＝🔴（社長ボール）に他の方宛が混ざる。
    蒸留は新着しか読まないので、放っておくと古い誤りが残り続ける＝ここで1回洗い直す。

    照合できない行が残っていたら **非0で終わる**（「監査済み」と記録して未監査行を固定化しない）。
    **直す行が1件でも残っていれば非0**（2026-08-21・Codex🟡）＝v0.9 の移行が終わったことを機械で言える。
    設定ファイル（config/comms-members.json）に不備があるときも非0＝社内宛が社外扱いのまま通らないように。
    """
    if not LEDGER.exists():
        print("台帳がありません", file=sys.stderr)
        return 1
    if MEMBER_PROBLEMS:
        # 社内・社長の判定ができないまま監査を通すと、社内宛が静かに社外扱いのまま残る。
        print(f"⚠️ {MEMBERS.name} に不備＝社内/社長の判定ができません", file=sys.stderr)
        for pr in MEMBER_PROBLEMS:
            print(f"    - {pr}", file=sys.stderr)
        return 1
    # room_id と message_id の**両方**で引く（message_id だけだと別ルームの同番に当たりうる）
    by_key = {(str(i.get("room_id")), str(i.get("message_id"))): i for i in items}
    rows = [l for l in LEDGER.read_text(encoding="utf-8").splitlines() if LEDGER_ROW.match(l)]

    tally, fix, broken_anchor = Counter(), [], []
    for line in rows:
        cid = LEDGER_ROW.match(line).group(1)
        # 状態は「2列目」を見る。先頭N文字から絵文字を探すと、ルーム名に絵文字が入った行を取り違える（Codex🟡）。
        cells = line.split("|")
        cell = cells[1].strip() if len(cells) > 1 else ""
        state = next((s for s in ("🔴", "👥", "🟢", "📌", "✅") if s in cell), "?")
        m = ANCHOR.search(line)
        if not m:
            # cw: アンカーが無い行。メール専用行（gm:）は Chatwork の監査対象外＝正常。
            # それ以外は raw 蓄積前の古い行＝照合しようがないので、申告はするが失敗にはしない
            # （失敗にすると監査が永久に通らず「監査済み」を記録できなくなる）。
            tally["メール行（Chatwork監査の対象外）" if "gm:" in line
                  else "cw:アンカー無し（raw蓄積前・照合不能）"] += 1
            continue
        it = by_key.get((m.group(1), m.group(2)))
        if not it:
            # アンカーはあるのに raw に無い＝張り替えミスか取得漏れ＝本当の異常
            tally["⚠️ アンカーが raw に見つからない"] += 1
            broken_anchor.append(f"{cid}（cw: {m.group(1)}-{m.group(2)} が raw に無い）")
            continue
        def flag(how: str) -> None:
            """この行に『こう直す』を1件立てる。差出人・宛先の取り出し方を1箇所にする。"""
            fix.append((cid, it.get("from", "?"), "、".join(it["to_names"]), how))

        if it["excluded"]:
            tally["除外ルームを指している"] += 1
            flag("除外ルーム＝起票対象外。残す理由を書くか取り下げる")
        elif it["to_me"]:
            tally["社長宛（そのままでよい）"] += 1
            if state == "👥":
                # 社長宛を 👥 に落とすと最重要のボールが把握用の枠に埋もれる（社長ご指示＝最重要は社長宛）。
                flag("👥 を 🔴 へ（社長宛＝最重要）")
        elif it["to_ids"]:
            internal = any(int(i) in INTERNAL for i in it["to_ids"])
            tally["社内の方宛（👥）" if internal else "他の方宛"] += 1
            if internal:
                # v0.9＝社内の方宛は「はなさか側のボール」。🟢 に落とすと督促対象から外れて落ちる。
                # ⚠️ 📌（確定記録）と ✅（完了）は**ボールではない**＝資産・履歴なので触らない。
                if state in ("🔴", "🟢"):
                    flag(f"{state} を 👥 社内ボールへ（v0.9・はなさか側のボール）")
            elif state == "🔴":
                flag("🔴 を外し ※社長宛でない（周辺情報）を付す")
        else:
            tally["社長ご自身の発信を指している"] += 1

    print(f"台帳の C-NNN 行: {len(rows)}")
    for k, v in tally.items():
        print(f"  {v:3d}  {k}")
    print(f"\n🔧 直す行: {len(fix)} 件")
    for cid, frm, to, how in fix:
        print(f"  {cid}\t〔{frm}→{to}〕\t{how}")
    if not fix:
        print("  （なし）")
    if broken_anchor:
        print(f"\n⚠️ アンカーが raw に見つからない行 {len(broken_anchor)} 件＝**監査未完**。"
              f"最新メッセージへ張り替えるか `cw: -` と明示してください")
        for u in broken_anchor:
            print(f"    - {u}")
        return 1
    print("\n✅ Chatwork アンカーを持つ行はすべて照合できました")
    if fix:
        # 直す行が残っている間は非0＝「監査が通った」を移行完了の意味で使えるようにする（Codex🟡）。
        print(f"⚠️ 直す行が {len(fix)} 件残っています＝台帳を直してからもう一度流してください")
        return 1
    return 0


def show_rooms(items: list[dict], rooms: dict[str, dict]) -> int:
    """ルーム一覧＋rooms.md の設定状況。設定漏れ（役割未設定・未登録）を見つけるための点検用。"""
    agg: dict[str, dict] = {}
    for i in items:
        rid = str(i.get("room_id"))
        d = agg.setdefault(rid, {"n": 0, "name": "", "me": 0, "other": 0, "last": ""})
        d["n"] += 1
        d["name"] = i.get("room_name") or d["name"]
        d["me"] += 1 if i["to_me"] else 0
        d["other"] += 1 if (not i["to_me"] and not i["from_me"]) else 0
        d["last"] = max(d["last"], i.get("sent", ""))

    print(f"ルーム {len(agg)} 件 ／ rooms.md 登録 {len(rooms)} 件")
    print(f'{"room_id":>10} {"件数":>5} {"★社長宛":>7} {"・他の方":>7}  最終更新    役割      ルーム名')
    for rid, d in sorted(agg.items(), key=lambda x: -x[1]["n"]):
        m = rooms.get(rid)
        role = ("【除外】" + m["role"]) if m and m["excluded"] else (m["role"] if m else "⚠️未登録")
        print(f'{rid:>10} {d["n"]:5d} {d["me"]:7d} {d["other"]:7d}  {d["last"][:10]}  {role:<9} {d["name"][:36]}')

    missing = [r for r in agg if r not in rooms]
    stale = [r for r in rooms if r not in agg]
    if missing:
        print(f"\n⚠️ rooms.md に無いルーム {len(missing)} 件＝役割不明のまま蒸留されます: {', '.join(missing)}")
    if stale:
        print(f"\nℹ️ rooms.md にあるが生ログに出ていないルーム {len(stale)} 件（消さなくてよい）: {', '.join(stale)}")
    if not missing:
        print("\n✅ すべてのルームが rooms.md に登録済みです")
    return 0


def _line(i: dict) -> str:
    mark = "▶" if i["from_me"] else ("★" if i["to_me"] else "・")
    rp = "↩" if i["is_reply"] else " "
    flags = ("⚠引用未閉" if i["quote_broken"] else "") + ("🗑削除済" if i["deleted"] else "")
    room = f'[{i["role"]}] ' if i["role"] else "[役割未設定] "
    return (f'{mark}{rp} {i.get("sent","")}\t{room}{(i.get("room_name") or "")[:22]}\t'
            f'{i.get("from","?")} → {"、".join(i["to_names"])}\t{flags}{plain(i.get("body",""))}')


def main() -> int:
    ap = argparse.ArgumentParser(description="Chatwork 生ログの『誰から誰へ』を出す（読み取り専用）")
    ap.add_argument("--since", help="この日時より新しいものだけ（例 '2026-08-01 00:00:00'）")
    ap.add_argument("--all", action="store_true", help="全期間")
    ap.add_argument("--stats", action="store_true", help="件数だけ（固有名詞を出さない）")
    ap.add_argument("--json", action="store_true", help="JSONL で出す")
    ap.add_argument("--audit", action="store_true",
                    help="既存の台帳 C-NNN 行を洗い直す（**直す行またはアンカー切れが残れば非0**＝「監査が通った」を移行完了の意味で使える）")
    ap.add_argument("--rooms", action="store_true",
                    help="ルーム一覧と役割・除外の設定状況を出す（rooms.md の点検用）")
    ap.add_argument("--strict", action="store_true",
                    help="入力に不備があれば非0で終わる（既定は申告して続行＝蒸留を止めない）")
    a = ap.parse_args()

    recs, raw_problems = load_raw()
    if not recs:
        print("生ログがありません", file=sys.stderr)
        return 1
    roster = build_roster(recs)
    atomic_write_secret(ROSTER, json.dumps(roster, ensure_ascii=False, indent=1))

    rooms, room_problems = load_rooms()
    items = annotate(recs, roster, room_members(recs), rooms)

    warn_problems(raw_problems, room_problems)

    def rc_of(rc: int = 0) -> int:
        """終了コードの決め方は1箇所に置く（--strict の扱いを片方だけ直す事故を防ぐ）。"""
        return rc or (1 if (a.strict and (raw_problems or room_problems)) else 0)

    if a.rooms:
        return rc_of(show_rooms(items, rooms))
    if a.audit:
        return rc_of(audit(items))

    if not a.all:
        since = (a.since or cursor_from_ledger() or "").replace(" ", "T")
        if since:
            items = [i for i in items if i.get("sent", "") > since]

    # 除外は**落とさず**別枠にする＝規律「除外の中に本当の用件が混ざっていたらメモへ」を実行可能にする
    live = [i for i in items if not i["excluded"]]
    skipped = [i for i in items if i["excluded"]]

    if a.stats:
        inbound = [i for i in live if i["to_me"]]
        noto = [i for i in inbound if not i["to_ids"] and not i["toall"]]
        print(f"対象 {len(live)} 件 ／ 名簿 {len(roster)} 名")
        print(f"  ★ 社長宛（相手 → 社長）        : {len(inbound)} 件")
        print(f"    ├ 明示的に社長へ（To/rp/全員）: {len(inbound) - len(noto)} 件")
        print(f"    └ 宛先タグなし＝社長宛        : {len(noto)} 件"
              f"（1対1 {sum(1 for i in noto if i['solo_room'])} ／ グループ {sum(1 for i in noto if not i['solo_room'])}）")
        others = [i for i in live if not i["to_me"] and not i["from_me"]]
        inside = [i for i in others if any(int(x) in INTERNAL for x in (i.get("to_ids") or []))]
        print(f"  ・ 他の方宛（周辺情報として読む）: {len(others)} 件")
        print(f"    ├ 社内の方宛（👥 社内ボール候補）  : {len(inside)} 件")
        print(f"    └ 社外の方宛                      : {len(others) - len(inside)} 件")
        print(f"  ▶ 社長ご自身の発信（相手ボール）: {sum(1 for i in live if i['from_me'])} 件")
        print(f"  🗑 削除済みの発言（用件にしない）: {sum(1 for i in live if i['deleted'])} 件")
        print(f"  ⚠️ 引用が閉じていない（要確認）  : {sum(1 for i in live if i['quote_broken'])} 件")
        print(f"  ⏸ 除外ルーム（起票しない・目視） : {len(skipped)} 件")
        unknown = {str(i.get("room_id")) for i in live if not i["known_room"]}
        if unknown:
            print(f"  ⚠️ rooms.md に無いルームが {len(unknown)} 件＝役割不明のまま蒸留します"
                  f"（`--rooms` で確認して rooms.md に足してください）")
        return rc_of()

    if a.json:
        for i in items:
            print(json.dumps(i, ensure_ascii=False))
        return rc_of()

    print(f"# {len(live)} 件（★＝社長宛／▶＝社長ご自身の発信／・＝他の方宛）  名簿 {len(roster)} 名")
    print("# 時刻\t[役割] ルーム\t差出人 → 宛先\t本文（タグ除去・先頭70字）")
    for i in live:
        print(_line(i))

    if skipped:
        print(f"\n## 除外ルーム {len(skipped)} 件（C-NNN は起票しない。"
              f"**本当の用件が混ざっていたら握り潰さず台帳「メモ」節へ**）")
        for i in skipped:
            print(_line(i))

    return rc_of()


if __name__ == "__main__":
    sys.exit(main())
