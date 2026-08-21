#!/usr/bin/env bash
# 宛先判定（bin/comms-who.py）の回帰テスト。
#
# 契機＝2026-08-07 Codexレビュー🟡「新規パーサの自動テストがありません」。
# この判定を誤ると「社長宛の用件を静かに取りこぼす」か「他の方への依頼を社長ボールに化けさせる」
# のどちらかが起きる＝無人ループの中でいちばん静かに壊れる場所なので、境界を固定する。
#
# 触ったら必ず流すこと：bash bin/test-comms-who.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/comms-who.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import importlib.util, json, os, sys, tempfile
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("cw", proj / "bin/comms-who.py")
cw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cw)

P = N = 0
def ok(m):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

T = Path(tempfile.mkdtemp())
cw.DATA = T
cw.RAW = T / "raw"; cw.RAW.mkdir()
cw.ROOMS = T / "rooms.md"
cw.ROSTER = T / "roster.json"
cw.LEDGER = T / "ledger.md"
for p in (cw.RAW, cw.ROOMS, cw.ROSTER, cw.LEDGER):
    if not str(p).startswith(str(T)):
        print(f"❌ テストの書き先が一時ディレクトリの外: {p}", file=sys.stderr); sys.exit(2)

ME = cw.ME          # 757779
HASE = "10868354"   # 他の方

print("=== 宛先の取り出し（誰宛かを取り違えない）===")

def addr(b): return cw.addressees(b)

r = addr(f"[To:{ME}]社長さん お願いします")
(ok if r[0] == [str(ME)] else ng)(f"素の [To:] を拾う（{r[0]}）")

r = addr(f"[rp aid={HASE} to=123-456]長谷さん 承知しました")
(ok if r[0] == [HASE] and r[2] else ng)(f"返信 [rp aid=] を宛先として拾い、返信と判る（{r[0]} rp={r[2]}）")

r = addr(f"[qt][qtmeta aid=999 time=1][To:{ME}]社長さん 過去の依頼[/qt]了解です")
(ok if r[0] == [] else ng)(f"引用の中の [To:] は宛先にしない（{r[0]}）")

r = addr(f"[To:{ME}]社長さん [To:{HASE}]長谷さん 両名へ")
(ok if r[0] == [str(ME), HASE] else ng)(f"複数宛先を順に拾う（{r[0]}）")

r = addr(f"[To:{ME}]社長さん [To:{ME}]社長さん 重複")
(ok if r[0] == [str(ME)] else ng)(f"同じ宛先の重複は1つにまとめる（{r[0]}）")

r = addr("[toall]皆さんへ")
(ok if r[1] and r[0] == [] else ng)(f"[toall] を全員宛として判る（toall={r[1]}）")

r = addr(f"[qt][To:{ME}]社長さん 閉じ忘れ")
(ok if r[3] else ng)(f"引用の閉じ忘れに印がつく（broken={r[3]}）")

r = addr("宛先タグのない発言です")
(ok if r[0] == [] and not r[1] else ng)("タグが無ければ宛先は空")

print("\n=== 誰宛か・誰からか（ボールの向き）===")

def mk(mid, rid, aid, name, body, sent="2026-08-07T10:00:00"):
    return {"room_id": int(rid), "room_name": f"room{rid}", "message_id": str(mid),
            "from": name, "from_account_id": int(aid) if aid else None,
            "sent": sent, "body": body}

def run(recs, rooms=None):
    roster = cw.build_roster(recs)
    return cw.annotate(recs, roster, cw.room_members(recs), rooms or {})

# グループ（3人以上）で他の方宛
recs = [mk(1, 9, HASE, "長谷", f"[To:{ME}]社長さん 確認願います"),
        mk(2, 9, "111", "山本", f"[To:{HASE}]長谷さん 修正お願いします"),
        mk(3, 9, ME, "松田 祥宗", "承知しました")]
it = run(recs)
(ok if it[0]["to_me"] else ng)("明示的に社長宛→社長宛")
(ok if not it[1]["to_me"] else ng)("明示的に他の方宛→社長宛にしない（🔴に化けさせない）")
(ok if it[2]["from_me"] and not it[2]["to_me"] else ng)("社長ご自身の発信は社長宛にしない")

# 社長発信＋タグ無し＝「社長→社長」と出さない（Codex🔴）
(ok if "社長宛" not in "".join(it[2]["to_names"]) else ng)(
    f"社長発信の宛先表示が自己宛にならない（{it[2]['to_names']}）")

# 1対1ルーム＝Toが付かない。相手からの発言は社長宛（社長ご決定）
recs = [mk(1, 5, "222", "奥野", "サーバー更新しました"),
        mk(2, 5, ME, "松田 祥宗", "ありがとうございます")]
it = run(recs)
(ok if it[0]["to_me"] else ng)("1対1でタグ無し＝相手からの発言は社長宛")
(ok if it[1]["to_names"] == ["奥野"] else ng)(f"1対1で社長が出した発言の宛先は相手の名前（{it[1]['to_names']}）")

# グループでタグ無し＝社長宛に倒す（社長ご決定 2026-08-07）
recs = [mk(1, 7, HASE, "長谷", "おはようございます"),
        mk(2, 7, "111", "山本", "よろしくお願いします"),
        mk(3, 7, ME, "松田 祥宗", "はい")]
it = run(recs)
(ok if it[0]["to_me"] else ng)("グループでタグ無しも社長宛に倒す")
(ok if it[2]["to_names"] == ["（宛先指定なし・ルーム全体）"] else ng)(
    f"社長発信でグループなら『ルーム全体』（{it[2]['to_names']}）")

print("\n=== 本人判定（同姓同名で誤爆しない）===")
recs = [mk(1, 5, "999", "松田 祥宗", "別アカウントの同姓同名"),
        mk(2, 5, None, "松田 祥宗", "IDが無い古い行")]
it = run(recs)
(ok if not it[0]["from_me"] else ng)("IDがあるなら名前が同じでも社長扱いしない")
(ok if it[1]["from_me"] else ng)("IDが無い古い行は表示名で社長と判る")

print("\n=== 名簿（改名したら新しい名前を出す）===")
recs = [mk(1, 5, HASE, "旧姓", "むかしの発言", sent="2026-01-01T00:00:00"),
        mk(2, 5, HASE, "新姓", "いまの発言", sent="2026-08-01T00:00:00")]
roster = cw.build_roster(recs)
(ok if roster[HASE] == "新姓" else ng)(f"送信者名は最新が勝つ（{roster.get(HASE)}）")

recs = [mk(1, 5, "111", "山本", f"[To:{HASE}]長谷さん お願いします")]
roster = cw.build_roster(recs)
(ok if roster.get(HASE) == "長谷" else ng)(f"送信者として未観測なら宛先タグの名前で補う（{roster.get(HASE)}）")

print("\n=== rooms.md（除外は業務データを落とす設定＝壊れ方を黙殺しない）===")

def rooms(text):
    cw.ROOMS.write_text(text, encoding="utf-8")
    return cw.load_rooms()

d, pr = rooms("## 除外（蒸留しない）\n123  通知bot  # メモ\n\n## 蒸留する（役割つき）\n456  客先\n")
(ok if d["123"]["excluded"] and not d["456"]["excluded"] else ng)("除外／蒸留するを見出しで振り分ける")
(ok if d["456"]["role"] == "客先" else ng)("役割ラベルを読む")
(ok if not pr else ng)(f"正常なファイルでは不備を出さない（{pr}）")

d, pr = rooms("## 除外しない\n123  客先\n")
(ok if not d.get("123", {}).get("excluded") and pr else ng)(
    f"『## 除外しない』を除外扱いしない＋警告を出す（excluded={d.get('123',{}).get('excluded')} 警告={len(pr)}）")

d, pr = rooms("## 除外（蒸留しない）\n123 通知bot\n## 蒸留する\n123 客先\n")
(ok if any("重複" in p for p in pr) else ng)(f"room_id の重複を申告する（{pr}）")

d, pr = rooms("## 蒸留する\nこれはIDではない\n")
(ok if any("room_id で始まっていません" in p for p in pr) else ng)(f"形式違反行を申告する（{pr}）")

d, pr = rooms("## 蒸留する\n123\n")
(ok if any("役割ラベルがありません" in p for p in pr) else ng)(f"役割ラベル欠落を申告する（{pr}）")

d, pr = rooms("999 客先\n## 蒸留する\n123 客先\n")
(ok if any("見出しの外" in p for p in pr) and "999" not in d else ng)(f"見出しの外の行を申告して無視する（{pr}）")

d, pr = rooms("﻿## 除外（蒸留しない）\n123 通知bot\n")
(ok if d.get("123", {}).get("excluded") else ng)("BOM 付きでも先頭の見出しを読める")

print("\n=== 生ログが壊れていても黙って捨てない ===")
(cw.RAW / "2026-08.jsonl").write_text(
    json.dumps(mk(1, 5, HASE, "長谷", "正常"), ensure_ascii=False) + "\n"
    + "{壊れたJSON\n"
    + json.dumps(mk(2, 5, HASE, "長谷", "正常2"), ensure_ascii=False) + "\n",
    encoding="utf-8")
recs, probs = cw.load_raw()
(ok if len(recs) == 2 else ng)(f"壊れた行を飛ばして残りは読む（{len(recs)}件）")
(ok if len(probs) == 1 and "2026-08.jsonl:2" in probs[0] else ng)(
    f"壊れた行のファイル名と行番号を申告する（{probs}）")

print("\n=== 除外ルームは消さずに分けて出す ===")
recs = [mk(1, 123, HASE, "長谷", "除外ルームの発言"), mk(2, 456, HASE, "長谷", "通常ルーム")]
rooms_map, _ = rooms("## 除外（蒸留しない）\n123 通知bot\n## 蒸留する\n456 客先\n")
it = run(recs, rooms_map)
(ok if it[0]["excluded"] and not it[1]["excluded"] else ng)("除外フラグが立つ")
(ok if len(it) == 2 else ng)("除外しても annotate の結果から消えない（別枠で出せる）")

print("\n=== 権限 ===")
cw.atomic_write_secret(cw.ROSTER, "{}")
mode = oct(os.stat(cw.ROSTER).st_mode & 0o777)
(ok if mode == "0o600" else ng)(f"roster.json は 0600（{mode}）")

print("\n=== 読み取り専用（Chatwork へ書きに行っていない）===")
src = (proj / "bin/comms-who.py").read_text(encoding="utf-8")
bad = [w for w in ("requests.post", "urlopen", "api.chatwork.com", "X-ChatWorkToken") if w in src]
(ok if not bad else ng)(f"通信・書き込みのコードを持たない（{bad or 'なし'}）")

# --- v0.9: 社内の方宛は 👥 社内ボール（audit の助言） -----------------------
# Red の再現＝2026-08-21。監査は社内宛(長谷さん)の 🔴/🟢 を「※社長宛でない（周辺情報）」と助言していた。
# それに従うと、はなさか側のボールが督促対象から外れて静かに落ちる。
def _audit_advice(state, to_id):
    """1行だけの台帳を作って audit を流し、その行への助言を返す（無ければ ''）。"""
    import io, contextlib
    (T / "ledger.md").write_text(
        f"C-999 | {state} | 💬 ルーム〔A→B〕 | 用件 | 次 | 最終: 08/21 | cw: 11-22 |\n",
        encoding="utf-8")
    cw.LEDGER = T / "ledger.md"
    items = [{"room_id": 11, "message_id": 22, "excluded": False, "to_me": False,
              "to_ids": [to_id], "to_names": ["宛先"], "from": "差出人"}]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cw.audit(items)
    for line in buf.getvalue().splitlines():
        if line.strip().startswith("C-999"):
            return line
    return ""

HASE = next(iter(cw.INTERNAL), None)    # 社内メンバー（ID のみ・名前は持たない）
if HASE is None:                        # INTERNAL が空＝社内宛が社外宛に化ける＝ここで止めずに落とす
    ng("INTERNAL が空＝社内宛の判定ができない"); HASE = -1
OUTSIDE = 999999999                     # 社内リストに無い＝社外

for st in ("🔴", "🟢"):
    a = _audit_advice(st, HASE)
    m = f"audit: 社内宛の {st} は 👥 社内ボールへ誘導する"
    ok(m) if "👥" in a else ng(m, a or "助言が出ていない")

a = _audit_advice("👥", HASE)
ok("audit: 既に 👥 の社内宛は直す対象にしない") if a == "" else ng("audit: 既に 👥 の社内宛は直す対象にしない", a)

for st in ("📌", "✅"):
    a = _audit_advice(st, HASE)
    m = f"audit: {st} はボールではない＝👥 に変えない"
    ok(m) if a == "" else ng(m, a)

a = _audit_advice("🔴", OUTSIDE)
m = "audit: 社外宛の 🔴 は従来どおり周辺情報へ"
ok(m) if "周辺情報" in a else ng(m, a or "助言が出ていない")

a = _audit_advice("🟢", OUTSIDE)
m = "audit: 社外宛の 🟢 はそのまま（相手の反応待ち）"
ok(m) if a == "" else ng(m, a)

def _audit_advice_to_me(state):
    """社長宛のメッセージを指す1行に対する助言を返す。"""
    import io, contextlib
    (T / "ledger.md").write_text(
        f"C-998 | {state} | 💬 ルーム〔A→社長〕 | 用件 | 次 | 最終: 08/21 | cw: 33-44 |\n", encoding="utf-8")
    cw.LEDGER = T / "ledger.md"
    items = [{"room_id": 33, "message_id": 44, "excluded": False, "to_me": True,
              "to_ids": [cw.ME], "to_names": ["社長"], "from": "差出人"}]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cw.audit(items)
    for line in buf.getvalue().splitlines():
        if line.strip().startswith("C-998"):
            return line
    return ""

a = _audit_advice_to_me("👥")
m = "audit: 社長宛を 👥 にしている行は 🔴 へ戻す（最重要は社長宛）"
ok(m) if "🔴" in a else ng(m, a or "助言が出ていない")

a = _audit_advice_to_me("🔴")
m = "audit: 社長宛の 🔴 はそのまま"
ok(m) if a == "" else ng(m, a)

# --- v0.9(Codexレビュー反映): 設定ファイル・終了コード・状態の取り違え ---------
import json as _json

def _members(obj):
    """設定ファイルを差し替えて load_members() を呼ぶ（本物の config は触らない）。"""
    f = T / "members.json"
    f.write_text(_json.dumps(obj), encoding="utf-8")
    orig = cw.MEMBERS
    cw.MEMBERS = f
    try:
        return cw.load_members()
    finally:
        cw.MEMBERS = orig

pres, ids, probs = _members({"president_id": 1, "internal_account_ids": [2, 3]})
m = "設定: 正しい設定は社長ID・社内IDを読めて不備なし"
ok(m) if (pres == 1 and ids == {2, 3} and not probs) else ng(m, f"{pres} {ids} {probs}")

for bad, label in (({"president_id": 1, "internal_account_ids": []}, "社内IDが空"),
                   ({"president_id": 1}, "社内IDが無い"),
                   ({"internal_account_ids": [2]}, "社長IDが無い"),
                   ({"president_id": 1, "internal_account_ids": [1, 2]}, "社長IDが社内IDに混入")):
    _, _, probs = _members(bad)
    m = f"設定: {label} は不備として申告する"
    ok(m) if probs else ng(m, "不備なしと判定された")

orig = cw.MEMBERS
cw.MEMBERS = T / "does-not-exist.json"
_, _, probs = cw.load_members()
cw.MEMBERS = orig
m = "設定: ファイルが無いときは不備として申告する（黙って既定に倒れない）"
ok(m) if probs else ng(m, "不備なしと判定された")

# 終了コード＝「監査が通った」を移行完了の意味で使えるか
import io, contextlib
def _audit_rc(ledger_line, items):
    (T / "ledger.md").write_text(ledger_line, encoding="utf-8")
    cw.LEDGER = T / "ledger.md"
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return cw.audit(items)

dirty = [{"room_id": 11, "message_id": 22, "excluded": False, "to_me": False,
          "to_ids": [HASE], "to_names": ["宛先"], "from": "差出人"}]
rc = _audit_rc("C-999 | 🟢 | 💬 ルーム〔A→B〕 | 用件 | 次 | 最終: 08/21 | cw: 11-22 |\n", dirty)
m = "audit: 直す行が残っている間は非0"
ok(m) if rc != 0 else ng(m, f"rc={rc}")

rc = _audit_rc("C-999 | 👥 | 💬 ルーム〔A→B〕 | 用件 | 次 | 最終: 08/21 | cw: 11-22 |\n", dirty)
m = "audit: 直す行がゼロなら0（移行完了と言える）"
ok(m) if rc == 0 else ng(m, f"rc={rc}")

# 状態はルーム名の絵文字に引きずられない
a = _audit_advice("🟢", HASE)
m0 = "audit: 状態は2列目から取る（ルーム名の絵文字に釣られない）"
(T / "ledger.md").write_text(
    "C-997 | 👥 | 💬 🔴🟢混じりのルーム名〔A→B〕 | 用件 | 次 | 最終: 08/21 | cw: 11-22 |\n", encoding="utf-8")
cw.LEDGER = T / "ledger.md"
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    cw.audit(dirty)
hit = [l for l in buf.getvalue().splitlines() if l.strip().startswith("C-997")]
ok(m0) if not hit else ng(m0, hit[0])

m = "INTERNAL は空でなく、社長自身を含まない"
ok(m) if (cw.INTERNAL and cw.ME not in cw.INTERNAL) else ng(m, f"ME={cw.ME}")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
