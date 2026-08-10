#!/usr/bin/env bash
# Chatwork 取得（bin/chatwork-fetch.py）の回帰テスト。
#
# 契機＝2026-08-10 rules/testing.md の空白地帯🔴（2h cron 常駐・テストゼロ）。
# ここで固定するのは「カーソル管理」＝壊れ方が最も静かな部分：
#   ・カーソルが進みすぎる → メッセージを永久に取りこぼす（誰も気づかない）
#   ・カーソルが戻る       → 同じメッセージを重複保存（台帳が二重起票）
#   ・失敗したルームのカーソルが進む → そのルームの新着が消える
# API には一切出ない（get() を偽物に差し替えて cmd_poll を丸ごと回す）。
#
# 触ったら必ず流すこと：bash bin/test-chatwork-fetch.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/chatwork-fetch.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import fcntl, importlib.util, json, sys, tempfile, time
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("cw", proj / "bin/chatwork-fetch.py")
cw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cw)

P = N = 0
def ok(m):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

# 本番のファイルに触れない（testing.md §6-1）
T = Path(tempfile.mkdtemp())
cw.ROOT = T          # 表示用 relative_to(ROOT) と .env 参照の両方をテスト内に閉じる
cw.DATA = T
cw.STATE = T / "state.json"
cw.LOCK = T / ".poll.lock"
cw.RAW = T / "raw"
for p in (cw.STATE, cw.LOCK, cw.RAW):
    if not str(p).startswith(str(T)):
        print(f"❌ テストの書き先が一時ディレクトリの外: {p}", file=sys.stderr); sys.exit(2)
time.sleep = lambda *_: None          # レート制限マージンの sleep を無効化（テストを速く）

# ---- 偽 API：ROOMS / MSGS を書き換えて cmd_poll を丸ごと回す ----
ROOMS, MSGS, FAIL_ROOMS = [], {}, set()
CALLS = []
def fake_get(path, tok):
    CALLS.append(path)
    if path == "/rooms":
        return ROOMS
    rid = int(path.split("/")[2])
    if rid in FAIL_ROOMS:
        raise RuntimeError("api down")
    return MSGS.get(rid, [])
cw.get = fake_get

def room(rid, lut, typ="group"):
    return {"room_id": rid, "name": f"部屋{rid}", "type": typ, "last_update_time": lut}

def msg(mid, t, body="本文", aid=111, name="山田"):
    return {"message_id": str(mid), "send_time": t,
            "account": {"account_id": aid, "name": name}, "body": body}

def poll():
    cw.cmd_poll("dummy-token")

def state():
    return json.loads(cw.STATE.read_text())

def raw_records():
    out = []
    for f in sorted(cw.RAW.glob("*.jsonl")):
        for l in f.read_text(encoding="utf-8").splitlines():
            if l.strip():
                out.append(json.loads(l))
    return out

NOW = int(time.time())

print("=== 初回＝基準点だけ置く（forward-only・過去を取らない）===")
ROOMS[:] = [room(1, NOW)]
MSGS[1] = [msg(10, NOW - 100)]
poll()
st = state()
(ok if "baseline" in st and st["rooms"] == {} else ng)(f"初回は基準点のみ（{sorted(st)}）")
(ok if not list(cw.RAW.glob('*.jsonl')) else ng)("初回はメッセージを保存しない")
(ok if CALLS == [] else ng)(f"初回は API を1回も呼ばない（{CALLS}）")

print("\n=== 新着の取得とカーソル前進 ===")
base = st["baseline"]
old_t, new_t = base - 50, base + 50
ROOMS[:] = [room(1, new_t)]
MSGS[1] = [msg(10, old_t), msg(11, new_t), msg(12, new_t + 1)]
poll()
recs = raw_records()
(ok if len(recs) == 2 and {r["message_id"] for r in recs} == {"11", "12"} else ng)(
    f"基準点より古いメッセージは取らない・新しい2件だけ保存（{[r['message_id'] for r in recs]}）")
(ok if recs and recs[0]["from_account_id"] == 111 and recs[0]["room_name"] == "部屋1" else ng)(
    "レコードにボール判定へ要る欄（from_account_id・room_name）が揃う")
cur = state()["rooms"]["1"]
(ok if cur["mid"] == "12" and cur["lut"] == new_t else ng)(f"カーソルが最新へ前進（mid={cur['mid']}）")

print("\n=== 冪等性（同じ新着で二重保存しない）===")
ROOMS[:] = [room(1, new_t + 10)]        # lut だけ進んだが中身は同じ
poll()
(ok if len(raw_records()) == 2 else ng)(f"mid カーソルで重複を弾く（{len(raw_records())}件のまま）")

print("\n=== message_id は数値で比較（文字列比較だと '9'>'10' で取りこぼす）===")
cw.STATE.write_text(json.dumps({"baseline": base, "last_poll": base,
                                "rooms": {"1": {"lut": base, "mid": "9"}}}))
ROOMS[:] = [room(1, new_t)]
MSGS[1] = [msg(9, old_t), msg(10, new_t)]
for f in cw.RAW.glob("*.jsonl"): f.unlink()
poll()
(ok if [r["message_id"] for r in raw_records()] == ["10"] else ng)(
    f"mid '9' の次に '10' を取れる（{[r['message_id'] for r in raw_records()]}）")

print("\n=== 失敗したルームのカーソルは進めない（次回自動再取得）===")
cw.STATE.write_text(json.dumps({"baseline": base, "last_poll": base, "rooms": {}}))
for f in cw.RAW.glob("*.jsonl"): f.unlink()
ROOMS[:] = [room(1, new_t), room(2, new_t)]
MSGS[1] = [msg(21, new_t)]
MSGS[2] = [msg(31, new_t)]
FAIL_ROOMS.add(2)
poll()
st = state()
(ok if "1" in st["rooms"] and "2" not in st["rooms"] else ng)(
    f"失敗ルームだけカーソル未前進（前進={sorted(st['rooms'])}）")
(ok if [r["message_id"] for r in raw_records()] == ["21"] else ng)(
    "片方が落ちても、もう片方は取得できる（全滅させない）")
FAIL_ROOMS.clear()
poll()   # 復旧後の再実行
(ok if {r["message_id"] for r in raw_records()} == {"21", "31"} and "2" in state()["rooms"]
 else ng)("復旧したら失敗ルームの分を自動で拾う（取りこぼし無し）")

print("\n=== 100件到達＝取りこぼしの可能性を黙らせない ===")
cw.STATE.write_text(json.dumps({"baseline": base, "last_poll": base, "rooms": {}}))
ROOMS[:] = [room(1, new_t)]
MSGS[1] = [msg(100 + i, new_t) for i in range(100)]
import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    poll()
(ok if "取りこぼしの可能性" in buf.getvalue() else ng)(
    "API 上限100件に張り付いたら警告を出す（静かに欠けさせない）")

print("\n=== ルーム数上限＝溢れた分のカーソルを進めない ===")
cw.STATE.write_text(json.dumps({"baseline": base, "last_poll": base, "rooms": {}}))
old_cap = cw.MAX_ROOMS_PER_POLL
cw.MAX_ROOMS_PER_POLL = 1
ROOMS[:] = [room(1, new_t), room(2, new_t + 1)]
MSGS[1] = [msg(41, new_t)]
MSGS[2] = [msg(51, new_t)]
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    poll()
st = state()
(ok if len(st["rooms"]) == 1 and "ルーム数上限" in buf.getvalue() else ng)(
    f"上限で {len(st['rooms'])}ルームだけ処理し、残りは未前進＋申告（次回に持ち越し）")
cw.MAX_ROOMS_PER_POLL = old_cap

print("\n=== マイチャットは取らない ===")
cw.STATE.write_text(json.dumps({"baseline": base, "last_poll": base, "rooms": {}}))
for f in cw.RAW.glob("*.jsonl"): f.unlink()
ROOMS[:] = [room(1, new_t, typ="my")]
MSGS[1] = [msg(61, new_t)]
poll()
(ok if raw_records() == [] else ng)("type=my（自分用メモ）はポーリング対象外")

print("\n=== v1→v2 の state 移行（取りこぼし・重複なし）===")
cw.STATE.write_text(json.dumps({"last_poll": base}))     # 旧形式＝グローバルカーソルのみ
ROOMS[:] = [room(1, new_t)]
MSGS[1] = [msg(71, old_t), msg(72, new_t)]
for f in cw.RAW.glob("*.jsonl"): f.unlink()
poll()
st = state()
(ok if st.get("baseline") == base else ng)(f"旧 last_poll が baseline に引き継がれる（{st.get('baseline')}）")
(ok if [r["message_id"] for r in raw_records()] == ["72"] else ng)(
    "移行直後も「旧カーソル以前は取らない・以後は取る」が保たれる")

print("\n=== 壊れた state で黙って初期化しない ===")
cw.STATE.write_text("{壊れたJSON")
try:
    cw.load_state(); ng("壊れた state で停止する")
except SystemExit as e:
    (ok if e.code else ng)("壊れた state は非0で停止（勝手に基準点を作り直して取りこぼしを隠さない）")
cw.STATE.write_text(json.dumps({"rooms": {}}))           # dict だが last_poll が無い
try:
    cw.load_state(); ng("欠損 state で停止する")
except SystemExit as e:
    (ok if e.code else ng)("必須キー欠損も非0で停止")

print("\n=== 排他（poll の二重起動）===")
cw.STATE.write_text(json.dumps({"baseline": base, "last_poll": base, "rooms": {}}))
lk = open(cw.LOCK, "w")
fcntl.flock(lk, fcntl.LOCK_EX)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    poll()
(ok if "スキップ" in buf.getvalue() else ng)("ロック中の後発は即終了（state を取り合わない）")
fcntl.flock(lk, fcntl.LOCK_UN); lk.close()

print("\n=== state の書き込みが壊れない（atomic）===")
st = state()
(ok if isinstance(st, dict) and "last_poll" in st else ng)("一連の poll 後も state は正しい JSON")
(ok if not cw.STATE.with_suffix(".json.tmp").exists() else ng)("一時ファイルが残っていない")

print("\n=== 表示用のタグ除去 ===")
got = cw.strip_cw_tags("[To:123]山田さん[qt][qtmeta aid=1]引用[/qt] 本文 [info]枠[/info]")
(ok if "本文" in got and "[" not in got else ng)(f"Chatwork 記法を落とす（{got!r}）")

print("\n=== 読み取り専用（送信・既読化のコードを持たない）===")
src = (proj / "bin/chatwork-fetch.py").read_text(encoding="utf-8")
import re as _re
posts = _re.findall(r'(data=|method="(POST|PUT|DELETE)")', src)
(ok if not posts else ng)(f"POST/PUT/DELETE を発行しない（{posts or 'なし'}）")
(ok if "/messages/read" not in src else ng)("既読化 API を呼ばない")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
