#!/usr/bin/env bash
# 判断待ちの棚卸し（bin/pending-scan.py）の回帰テスト。
#
# 契機＝2026-08-27 社長ご指示「仕分けをするためのエージェントを作って」。
# ここで固定するのは、作っている最中に実際に踏んだ穴：
#   ・状態の列位置を「2列目」と決め打ったら yoshida が 12件中1件・rally が 11件中0件しか
#     取れず、**それでも「35件」と平然と報告できてしまった**（黙って少なく数える＝最悪の壊れ方）
#   ・台帳には取引先名・案件の実体が入る＝状態ファイルに本文を写すと漏れる面が増える
#   ・所有者が閉じた項目を「まだ open」と言い続けない／閉じ切れていない項目を gone のままにしない
# ネットワークには出ない。本番の data/ にも site/ にも書かない。
#
# 触ったら必ず流すこと：bash bin/test-pending-scan.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/pending-scan.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import importlib.util, io, json, sys, tempfile
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("ps", proj / "bin/pending-scan.py")
ps = importlib.util.module_from_spec(spec); spec.loader.exec_module(ps)

P = N = 0
def ok(m, d=""):        # d は無視（`(ok if c else ng)(m, 詳細)` の書き方を安全にするため）
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

# 本番のツリーには一切書かない（testing.md §6-1）
T = Path(tempfile.mkdtemp())
ps.PROJ = T
ps.STATE_DIR = T / "state"
ps.STATE_FILE = ps.STATE_DIR / "state.json"
ps.LOCK_FILE = ps.STATE_DIR / ".scan.lock"
for p in (ps.STATE_DIR, ps.STATE_FILE, ps.LOCK_FILE):
    if not str(p).startswith(str(T)):
        print(f"❌ テストの書き先が一時ディレクトリの外: {p}", file=sys.stderr); sys.exit(2)

# 架空の取引先名（実名を git 追跡ファイルへ出さない）
CLIENT = "ゼータ商事様"

print("=== 印の列位置に依存しない（2026-08-27 の実害＝12件中1件しか取れなかった）===")
html = """<table>
<tr><th>R</th><th>内容</th><th>状態</th><th>備考</th></tr>
<tr><td>R-Y31</td><td>%s の記事名の表記</td><td>🔔 要回答</td><td>-</td></tr>
<tr><td>R-R29</td><td>配管修理</td><td>🟡</td><td>🔔 要回答（社長）</td></tr>
<tr><td>🔔 要回答</td><td>この列は凡例です</td><td>-</td><td>-</td></tr>
<tr><td>凡例</td><td>🔔 は要回答の印です（例: R-999 を参照）</td><td>-</td><td>-</td></tr>
<tr><td>R-J12</td><td>終わったもの</td><td>✅ 完了</td><td>-</td></tr>
<tr><td>R-F02</td><td>解錠済み</td><td>✅ AI即応（🔔→✅）</td><td>-</td></tr>
<tr><td>R-F09</td><td>まだ待ち</td><td>🔔 要回答（前は✅だった）</td><td>-</td></tr>
</table>""" % CLIENT
f = T / "board.html"; f.write_text(html, encoding="utf-8")
got = ps.extract(f, "html_table")
ids = sorted(g["id"] for g in got)
(ok if ids == ["R-F09", "R-R29", "R-Y31"] else ng)(f"3列目でも4列目でも印を拾う（{ids}）")
# ★台帳は「🔔→✅」と解錠の履歴を同じセルに残す。印だけを見ると解決済みを判断待ちに数える
#   （実測 2026-08-27＝R-F02 は 08-21 に解決していた）。過少計上と同じく、水増しも社長を誤らせる。
(ok if "R-F02" not in ids else ng)(f"★「🔔→✅」＝解錠済みの履歴を判断待ちに数えない（{ids}）")
(ok if "R-F09" in ids else ng)("本文に✅の語があっても、状態が🔔なら判断待ちのまま残す")
(ok if "R-J12" not in ids else ng)("印の無い行（完了）は項目にしない")
(ok if not any(g["id"].startswith("🔔") for g in got) else ng)(
    "先頭セルに ID が無い凡例行を項目にしない")
# ★掲示板は本文セルの中で他の ID を引用する（「R-999 を参照」）。
#   行全体から ID を拾うと、その引用が独立した項目に化けて件数が水増しされる。
(ok if "R-999" not in ids else ng)(
    f"★本文セルの中で引用された ID を項目に化けさせない（{ids}）")
st = next((g["status"] for g in got if g["id"] == "R-R29"), "")
(ok if "🔔" in st else ng)(f"状態として拾うのは印のあるセル（列位置が違っても）（{st[:20]}）")

md = "\n".join([
    "| R | 状態 | 内容 |",
    "|---|---|---|",
    f"| R-014c | 🔔要回答 | {CLIENT} の件 |",
    "| R-036 | ✅クローズ済 | - |",
    "| 評価軸 | 高得点 | 凡例の行 |",
])
(T / "led.md").write_text(md, encoding="utf-8")
g2 = ps.extract(T / "led.md", "md_table")
ids2 = sorted(x["id"] for x in g2)
(ok if ids2 == ["R-014c"] else ng)(f"Markdown 表でも同じ判定（{ids2}）")

print("\n=== 取りこぼしを黙らせない（silent cap を作らない）===")
src = [("t", f, "html_table"), ("t", T / "led.md", "md_table")]
ps.sources = lambda: src
gap = ps.coverage_gap()
(ok if gap else ng)("表の行にならない印が残っていれば必ず報告する")
tot_left = sum(m - g for _, _, m, g in gap)
(ok if tot_left >= 1 else ng)(f"取りこぼし件数を数えている（残り {tot_left}）")

print("\n=== 状態ファイルに本文を持たない（取引先名を写さない）===")
ps.cmd_scan(quiet=True)
raw = ps.STATE_FILE.read_text(encoding="utf-8")
(ok if CLIENT not in raw else ng)("★台帳の本文（取引先名）が状態ファイルに写っていない")
recs = json.loads(raw)["items"]
extra = {k for r in recs.values() for k in r} - {
    "lane", "id", "src", "line", "first_seen", "last_seen", "status",
    "asked_at", "decided_at", "decision", "note_ref", "gone_at"}
(ok if not extra else ng)(f"状態に持つのは ID・置き場・日付だけ（余分なキー {extra or 'なし'}）")

print("\n=== 閉じたものを追い続けない／閉じ切れていないものを見失わない ===")
before = len(recs)
(ok if before == 4 else ng)(f"2ソースから4件を集める（{before}）")
# 行ごと消す＝所有モードが閉じてアーカイブへ移した状態。
# （ID を書き換えるだけでは R-Y31 が部分一致で残る＝テストとして無効になる。実際に踏んだ）
f.write_text("\n".join(l for l in html.split("\n") if "R-Y31" not in l), encoding="utf-8")
ps.cmd_scan(quiet=True)
recs = json.loads(ps.STATE_FILE.read_text(encoding="utf-8"))["items"]
(ok if recs["t|R-Y31"]["status"] == "gone" else ng)(
    f"ソースから消えたら gone（{recs['t|R-Y31']['status']}）＝所有モードが閉じたと見なす")
f.write_text(html, encoding="utf-8")
ps.cmd_scan(quiet=True)
recs = json.loads(ps.STATE_FILE.read_text(encoding="utf-8"))["items"]
(ok if recs["t|R-Y31"]["status"] == "open" else ng)(
    "★また現れたら open に戻す（閉じ切れていない項目を gone のまま見失わない）")
(ok if "gone_at" not in recs["t|R-Y31"] else ng)("open に戻したら gone の日付を消す")

print("\n=== 決定の記録 ===")
ps.cmd_decide("t|R-Y31", "president", "from-president.md へ記載")
recs = json.loads(ps.STATE_FILE.read_text(encoding="utf-8"))["items"]
(ok if recs["t|R-Y31"]["decision"] == "president" else ng)("決定の種別を記録する")
bad = 0
try:
    ps.cmd_decide("t|R-Y31", "適当な種別", None)
except SystemExit:
    bad = 1
(ok if bad else ng)("★決定の種別は決め打ちの3種類だけ（自由記述を許すと分類が崩れる）")
bad = 0
try:
    ps.cmd_decide("t|R-Y31", "president", "あ" * 200)
except SystemExit:
    bad = 1
(ok if bad else ng)("★note に本文を写せない（状態ファイルへの内容流出を止める）")
bad = 0
try:
    ps.cmd_decide("t|存在しない", "president", None)
except SystemExit:
    bad = 1
(ok if bad else ng)("無いキーには決定を書けない")

print("\n=== 壊れた状態を勝手に初期化しない ===")
ps.STATE_FILE.write_text("{壊れている", encoding="utf-8")
bad = 0
try:
    ps.load_state()
except SystemExit:
    bad = 1
(ok if bad else ng)("★壊れた state.json は非0終了（黙って作り直すと決定の履歴が消える）")
ps.STATE_FILE.write_text('{"v":1,"items":[]}', encoding="utf-8")
bad = 0
try:
    ps.load_state()
except SystemExit:
    bad = 1
(ok if bad else ng)("items が辞書でなければ止まる")

print("\n=== 在庫上限（2026-08-27 社長決定＝15件・新規起票だけ止める）===")
# 社長のお言葉＝「一定数貯まれば止める…上がった問題を対応仕分けできたら、その分新しく回していく」。
# AI は作る側の速度で走り、社長は捌く側の速度でしか走れない＝上限が無ければ差は必ず開く。
import io as _io2
def wip_rc(items):
    """items = {キー: 状態} を state.json に流し込んで wip の終了コードを取る"""
    st = {"v": 1, "items": {k: {"lane": "L", "id": k, "src": "x", "line": 1,
                                "first_seen": "2026-08-27", "last_seen": "2026-08-27",
                                "status": v} for k, v in items.items()}}
    ps.STATE_FILE.write_text(json.dumps(st, ensure_ascii=False), encoding="utf-8")
    ps.sources = lambda: []          # 走査で上書きさせない
    ps.cmd_scan = lambda quiet=True: ps.load_state()
    import contextlib
    with contextlib.redirect_stdout(_io2.StringIO()):
        return ps.cmd_wip("L")

_scan_backup, _src_backup = ps.cmd_scan, ps.sources
L = ps.WIP_LIMIT
(ok if L == 15 else ng)(f"上限は社長が決めた15件（{L}）")
(ok if wip_rc({f"k{i}": "open" for i in range(L - 1)}) == 0 else ng)(
    f"上限の1件手前では止めない（{L-1}件）")
(ok if wip_rc({f"k{i}": "open" for i in range(L)}) == 1 else ng)(
    f"★上限ちょうどで止める（{L}件）＝「以上」で判定（境界で1件すり抜けない）")
(ok if wip_rc({f"k{i}": "asked" for i in range(L)}) == 1 else ng)(
    "★社長に提示済み（asked）も在庫に数える＝提示しただけで枠が空くと上限が意味を失う")
(ok if wip_rc({f"k{i}": "decided" for i in range(L)}) == 0 else ng)(
    "★決定済みは在庫に数えない（社長の手を離れた＝所有モードの作業）")
(ok if wip_rc({f"k{i}": "gone" for i in range(L)}) == 0 else ng)(
    "閉じた項目は在庫に数えない")
ps.cmd_scan, ps.sources = _scan_backup, _src_backup

src_txt2 = (proj / "bin/pending-scan.py").read_text(encoding="utf-8")
(ok if "分析" in src_txt2.split("WIP_LIMIT")[0][-600:] else ng)(
    "★止めるのは新規起票だけで分析は止めない、と根拠が実装に書いてある"
    "（2026-07 の社長ご指示と両立させるため）")

print("\n=== 門番の視野（O-057・2026-09-01 社長承認）===")
# 契機＝門番が「✅ 8/15 起票可」と言えてしまうが、実際には表の行しか数えていない。
# 数えた分だけの安全は安全ではない＝「数の外」を判定と同じ画面に必ず出す。
_scan_backup2, _src_backup2 = ps.cmd_scan, ps.sources
blind_md = T / "coverage.md"
blind_md.write_text(
    "| ID | 状態 |\n|---|---|\n| R-B01 | 🔔 要回答 |\n\n"
    "- 🔔 箇条書きに埋まった印（表の行ではない）\n"
    "地の文にも 🔔 が1つ。\n", encoding="utf-8")
ps.sources = lambda: [("L", blind_md, "md_table")]
ps.cmd_scan = _scan_backup2
import contextlib as _ctx
_buf = _io2.StringIO()
with _ctx.redirect_stdout(_buf):
    _rc = ps.cmd_wip()
_out = _buf.getvalue()
(ok if "数の外 2件" in _out else ng)(
    "★数えた1件の横に「数の外2件」を出す（表の行だけを数えている事実を判定と同じ行に出す）", _out)
(ok if "起票可" in _out and "証拠にはなりません" in _out else ng)(
    "★「✅ 起票可」に「在庫が少ない証拠にはならない」と明記する（見かけの安全を作らない）", _out)
(ok if _rc == 0 else ng)("見える化を足しても止める/止めないの判定は変えない（挙動不変）", str(_rc))
# 死角しかないレーンを一覧から黙って落とさない
blind_only = T / "narr.md"
blind_only.write_text("- 🔔 表の外だけにある印\n", encoding="utf-8")
ps.sources = lambda: [("Z", blind_only, "md_table")]
_buf = _io2.StringIO()
with _ctx.redirect_stdout(_buf):
    ps.cmd_wip()
(ok if "Z:" in _buf.getvalue() else ng)(
    "★数えた件数が0でも死角のあるレーンは行に出す（黙って一覧から消さない）", _buf.getvalue())

# 死角の数え方＝行単位・解決済みは除く（2026-09-02 Codexレビュー 🔴2件の再発防止）
dup_md = T / "dup.md"
dup_md.write_text(
    "| ID | 状態 |\n|---|---|\n| R-D01 | 🔔 要回答 |\n\n"
    "- 🔔 ひとつの行に 🔔 が2個ある（項目としては1件）\n"
    "- 🔔→✅ 解決済みの履歴表記（在庫ではない）\n", encoding="utf-8")
ps.sources = lambda: [("D", dup_md, "md_table")]
_buf = _io2.StringIO()
with _ctx.redirect_stdout(_buf):
    ps.cmd_wip()
_o = _buf.getvalue()
(ok if "数の外 1件" in _o else ng)(
    "★死角は行単位で数える＝1行に🔔が2個でも1件（印の出現回数で数えると水増しになる）", _o)
(ok if "数の外 2件" not in _o else ng)(
    "★解決済みの「🔔→✅」を在庫に数えない（extract は除外するのに marks に残っていた）", _o)

# 地の文（NARRATIVE）も判断待ちだけを数える＝全ID数を混ぜない
narr_html = T / "board.html"
narr_html.write_text(
    "<p>O-001 は解決済みの過去記録。O-002 も昔の話。</p>\n"
    "<p>🔔 O-003 だけが判断待ち。</p>\n", encoding="utf-8")
_nar_backup = ps.NARRATIVE
ps.NARRATIVE = [("brd", narr_html, __import__("re").compile(r"O-\d{3}"))]
_got = ps.narrative_counts()
(ok if _got and _got[0][2] == 1 else ng)(
    "★地の文は🔔のある行のIDだけ数える（全ID数を『数の外』に足すと単位が混ざる）", str(_got))
ps.NARRATIVE = _nar_backup

ps.cmd_scan, ps.sources = _scan_backup2, _src_backup2

print("\n=== 他モードの台帳を横から書き換えない（所有者が閉じる）===")
src_txt = (proj / "bin/pending-scan.py").read_text(encoding="utf-8")
bad = [w for w in ("write_text(", ".unlink(", "os.remove", "shutil.")
       if w in src_txt.split("def save_state")[0] + src_txt.split("def cmd_verify")[-1]]
(ok if "from-president" in src_txt else ng)("回答の返し先が from-president.md だと明記されている")
w = [ln for ln in src_txt.split("\n") if "write_text" in ln and "STATE" not in ln and "tmp" not in ln]
(ok if not w else ng)(f"状態ファイル以外へ書き込まない（{w[:1] or 'なし'}）")

print("\n=== skill-kaizen（🔔 を使わない置き場・2026-09-12 追加）===")
K = T / "data/hp-improve"; K.mkdir(parents=True, exist_ok=True)
(K / "skill-kaizen.md").write_text(
    "# 台帳\n\n"
    "### K-001 — あ\n本文だけ（採否なし）\n\n"
    "### K-002 — い\nステータス: ✅反映済み(2026-01-01)\n\n"
    "### K-003 — う\nステータス: ❌却下\n\n"
    "### K-partner-702（partner Cycle 178）え\n本文だけ\n\n"
    "### 📦 退避分の索引\nK-900 K-901 は archive へ\n\n"
    "### K-001 — あ（同じ番号が再び使われている）\n本文だけ\n",
    encoding="utf-8")
got = ps.extract(K / "skill-kaizen.md", "kaizen_entry")
ids = [g["id"] for g in got]
(ok if ids == ["K-001", "K-partner-702", "K-001"] else ng)(
    "採否が付いていない見出しだけを拾う（反映済み・却下は除く）", ids)
(ok if "K-partner-702" in ids else ng)("接頭辞つきの ID（K-partner-702）も拾える")
(ok if not any(i.startswith("K-9") for i in ids) else ng)(
    "見出しでない行の中の ID（索引に並ぶ K-900 等）は項目にしない", ids)
(ok if all("本文" not in g["head"] for g in got) else ng)("本文を head に持ち込まない（§6 秘密の扱い）")

print("\n=== 同じ ID が複数の項目に使われていたら黙って寄せない ===")
_src3 = ps.sources
ps.sources = lambda: [("skill-kaizen", K / "skill-kaizen.md", "kaizen_entry")]
dup = ps.duplicate_ids()
(ok if dup and dup[0][2] == 3 and dup[0][3] == 2 and dup[0][4] == 1 else ng)(
    "項目3 / 異なるID2 / 重複1種 を申告する", dup)
(K / "skill-kaizen.md").write_text("### K-010 — か\n本文\n", encoding="utf-8")
(ok if not ps.duplicate_ids() else ng)("重複が無ければ何も言わない（鳴りっぱなしにしない）")
ps.sources = _src3

print("\n=== 収集対象に skill-kaizen が入っている ===")
src_txt2 = (proj / "bin/pending-scan.py").read_text(encoding="utf-8")
(ok if "skill-kaizen" in src_txt2.split("def sources")[1].split("def ")[0] else ng)(
    "sources() が skill-kaizen を含む")
(ok if "duplicate_ids" in src_txt2.split("def cmd_stats")[1] else ng)(
    "stats が重複IDを報告する（呼ばれない検査を作らない）")

print("\n=== overseer の 🔔ボックス（2026-09-13 追加・地の文から項目へ）===")
O = T / "site/overseer"; O.mkdir(parents=True, exist_ok=True)
def board(items, mark="🔔 社長の判断・対応待ち", tail='</div>'):
    lis = "\n".join(f"<li>{x}</li>" for x in items)
    return (f'<html><body><!-- ===== {mark}（未処理だけ） ===== -->\n'
            f'<div class="border-2"><h2>{mark}</h2><ul>\n{lis}\n</ul>{tail}\n'
            f'<div class="cycle"><h2>サイクルログ</h2><ul><li>O-999 これは別の節</li></ul></div>'
            '</body></html>')
(O / "index.html").write_text(board([
    "🔴 <strong>O-081</strong>（便が27日滞留／ご判断は…）：O-056 と同じ系統です",
    "🟡 <strong>O-082</strong>（レーンが止まっています）",
    "🔵 O-067 の実測更新（新規番号は起こしません）：…",
    "🔵 O-067 の実測更新（同じ番号の再掲）：…",
    "先頭に番号が無い項目です（人が読む）",
]), encoding="utf-8")
ps.PARSE_WARN.clear()
got = ps.extract(O / "index.html", "overseer_box")
ids = [g["id"] for g in got]
(ok if ids == ["O-081", "O-082", "O-067"] else ng)(
    "先頭の O番号を主題として拾い、本文中の参照（O-056）は拾わない", ids)
(ok if "O-999" not in ids else ng)("🔔ボックスの外（サイクルログ）を混ぜない", ids)
(ok if len(ids) == len(set(ids)) else ng)("同じ番号の再掲（実測更新）は1件にする", ids)
(ok if any("先頭に O番号が無い項目が 1 件" in w for w in ps.PARSE_WARN) else ng)(
    "先頭に番号が無い項目を黙って捨てず申告する", ps.PARSE_WARN)

ps.PARSE_WARN.clear()
(O / "index.html").write_text(board(["🔴 O-001（あ）", "🔴 O-002（い）"], mark="別の見出し"), encoding="utf-8")
(ok if ps.extract(O / "index.html", "overseer_box") == [] and ps.PARSE_WARN else ng)(
    "ボックスが見つからないときは 0件と読まずに申告する", ps.PARSE_WARN)

ps.PARSE_WARN.clear()
# ★入れ子の div があっても最後の項目まで届く（最初の </div> で切ると静かに少なく数える）
nested = ('<html><body><!-- ===== 🔔 社長の判断・対応待ち（未処理だけ） ===== -->\n'
          '<div class="box"><h2>🔔 社長の判断・対応待ち</h2><ul>\n'
          '<li>🔴 O-001（あ）<div class="note">補足</div></li>\n'
          '<li>🔴 O-002（い）</li>\n<li>🔴 O-003（う）</li>\n</ul></div></body></html>')
(O / "index.html").write_text(nested, encoding="utf-8")
got2 = [g["id"] for g in ps.extract(O / "index.html", "overseer_box")]
(ok if got2 == ["O-001", "O-002", "O-003"] else ng)(
    "項目の中に <div> があっても最後まで読む（深さで閉じる）", got2)

print("\n=== 収集対象に overseer が入り、NARRATIVE から外れている ===")
src3 = (proj / "bin/pending-scan.py").read_text(encoding="utf-8")
(ok if "overseer_box" in src3.split("def sources")[1].split("def ")[0] else ng)(
    "sources() が overseer を含む")
(ok if "PARSE_WARN" in src3.split("def cmd_stats")[1] else ng)(
    "stats が読み切れなかった置き場を報告する（呼ばれない検査を作らない）")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
