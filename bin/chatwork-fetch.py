#!/usr/bin/env python3
"""Chatwork 取得ツール（読み取り専用・GET のみ）

「これから」の会話・タスクを差分で貯める。過去の遡り取得はしない（社長合意 2026-07-27）。
保存先は data/comms/chatwork/（.gitignore 済み＝クライアント名を含むため git 外）。

使い方:
  python3 bin/chatwork-fetch.py rooms          # ルーム一覧の要約を表示（保存なし）
  python3 bin/chatwork-fetch.py tasks          # 自分の未完了タスク全ルーム横断で取得・保存
  python3 bin/chatwork-fetch.py poll           # 前回以降の新着メッセージを差分取得・保存
                                               # （初回は基準点を記録するだけで何も取得しない）

仕組み（2026-07-28 Codexレビュー反映＝ルーム単位カーソル方式）:
  - state.json v2: {"baseline", "last_poll", "rooms": {"<room_id>": {"lut", "mid"}}}
      lut = 処理済み last_update_time ／ mid = 取り込み済み最終 message_id
  - カーソルは**成功したルームだけ**前進する。取得失敗・上限超過で今回読めなかった
    ルームはカーソルが動かない＝次回 poll が自動で再取得する（取りこぼさない）
  - 新着判定は message_id の数値比較（秒境界の欠落・重複追記なし）。カーソル未保持の
    ルーム（初回・新規参加）だけ send_time > baseline で forward-only に入る
  - poll 全体を flock で排他（cron の2hおき実行と /comms モード内の実行が重なっても安全）
  - state の書き込みは一時ファイル→fsync→os.replace（強制終了でも壊れない）
  - state.json が壊れていたら**勝手に初期化せず**非0終了で毎回申告（無言の基準点リセットで
    取りこぼしを隠さない。poll 停滞・state 破損は system-health.py が監視）
  - Chatwork API はルームごと最新100件までしか返さない＝2hおき運用（6-22時 cron）なら実用上
    足りるが、100件全て新着のときは取りこぼしの可能性を⚠️で自己申告する
  - 書き込み系エンドポイントは一切呼ばない
"""
import fcntl
import json
import os
import re
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "comms" / "chatwork"
STATE = DATA / "state.json"
LOCK = DATA / ".poll.lock"
RAW = DATA / "raw"
API = "https://api.chatwork.com/v2"
MAX_ROOMS_PER_POLL = 60  # レート制限 300req/5min の安全マージン


def token() -> str:
    for line in (ROOT / ".env").read_text().splitlines():
        if line.startswith("CHATWORK_API_TOKEN="):
            return line.split("=", 1)[1].strip()
    sys.exit("CHATWORK_API_TOKEN が .env にありません")


def get(path: str, tok: str):
    req = urllib.request.Request(API + path, headers={"x-chatworktoken": tok})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
        return json.loads(body) if body else []


def load_state() -> dict:
    """state を読む。壊れていたら勝手に初期化せず非0終了（毎回 poll.log に残る＝無言でリセットしない）"""
    if not STATE.exists():
        return {}
    try:
        st = json.loads(STATE.read_text())
        if not isinstance(st, dict) or "last_poll" not in st:
            raise ValueError("last_poll がない")
        return st
    except Exception as e:
        sys.exit(f"⚠️ state.json が壊れています（{type(e).__name__}: {e}）。"
                 "勝手に基準点を作り直すと取りこぼしを隠すため停止します。"
                 "中身を確認して修復するか、forward-only で仕切り直すなら手動で削除してください。")


def save_state(state: dict) -> None:
    """一時ファイル→fsync→os.replace の atomic 書き込み（強制終了でも壊れた state を残さない）"""
    DATA.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".json.tmp")
    with tmp.open("w") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE)


def cmd_rooms(tok: str) -> None:
    rooms = get("/rooms", tok)
    print(f"総ルーム数: {len(rooms)}")
    active = [r for r in rooms if r["unread_num"] or r["mytask_num"]]
    for r in sorted(active, key=lambda x: -x["last_update_time"]):
        print(f"  [{r['room_id']}] {r['name'][:40]}  未読:{r['unread_num']} 自タスク:{r['mytask_num']}")


def strip_cw_tags(body: str) -> str:
    """Chatwork記法（[qt][qtmeta ...][To:...]等）を落として本文だけにする（表示用）"""
    body = re.sub(r"\[/?[a-zA-Z]+[^\]]*\]", " ", body)
    return re.sub(r"\s+", " ", body).strip()


def cmd_tasks(tok: str) -> None:
    tasks = get("/my/tasks?status=open", tok)
    DATA.mkdir(parents=True, exist_ok=True)
    out = {
        "fetched_at": datetime.now().isoformat(timespec="seconds"),
        "count": len(tasks),
        "tasks": tasks,
    }
    (DATA / "tasks-latest.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(f"未完了タスク {len(tasks)} 件 → data/comms/chatwork/tasks-latest.json")
    for t in sorted(tasks, key=lambda x: x.get("limit_time") or 0):
        limit = t.get("limit_time") or 0
        due = datetime.fromtimestamp(limit).strftime("%Y/%m/%d") if limit else "期限なし"
        room = t["room"]["name"][:24]
        body = strip_cw_tags(t["body"])[:50]
        print(f"  [{due}] {room} | {body}")


def cmd_poll(tok: str) -> None:
    DATA.mkdir(parents=True, exist_ok=True)
    # 排他：cron と /comms モード内の実行が重なったら後発は即終了（重複追記・state巻き戻り防止）
    lock_f = LOCK.open("w")
    try:
        fcntl.flock(lock_f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"[{datetime.now():%Y-%m-%d %H:%M}] 別の poll が実行中＝スキップ")
        return

    state = load_state()
    now = int(time.time())

    if not state:
        # 初回＝基準点を置くだけ。過去は取らない（forward-only）
        save_state({"baseline": now, "last_poll": now, "rooms": {}})
        print("初回実行: 基準点を記録しました。次回以降ここからの新着を取得します。")
        return

    # v1（グローバルカーソルのみ）→ v2 移行。baseline=旧last_poll なので取りこぼし・重複なし
    if "baseline" not in state:
        state = {"baseline": state["last_poll"], "last_poll": state["last_poll"], "rooms": {}}
    baseline = state["baseline"]
    cursors = state.setdefault("rooms", {})
    last = state["last_poll"]

    rooms = get("/rooms", tok)
    cand = [r for r in rooms if r["type"] != "my"
            and r["last_update_time"] > cursors.get(str(r["room_id"]), {}).get("lut", baseline)]
    cand.sort(key=lambda x: -x["last_update_time"])
    skipped = cand[MAX_ROOMS_PER_POLL:]
    targets = cand[:MAX_ROOMS_PER_POLL]

    RAW.mkdir(parents=True, exist_ok=True)
    outfile = RAW / f"{datetime.now():%Y-%m}.jsonl"
    saved = 0
    over_100 = []
    failed = []
    with outfile.open("a") as f:
        for r in targets:
            rid = str(r["room_id"])
            try:
                msgs = get(f"/rooms/{r['room_id']}/messages?force=1", tok)
            except Exception as e:
                # カーソル据え置き＝次回 poll が自動で再取得する
                failed.append(f"[{rid}] {r['name'][:30]}: {type(e).__name__}")
                continue
            cur = cursors.get(rid, {})
            if cur.get("mid"):
                fresh = [m for m in msgs if int(m["message_id"]) > int(cur["mid"])]
            else:
                fresh = [m for m in msgs if m["send_time"] > baseline]
            if len(fresh) == len(msgs) == 100:
                over_100.append(r["name"][:30])
            for m in fresh:
                rec = {
                    "room_id": r["room_id"],
                    "room_name": r["name"],
                    "message_id": m["message_id"],
                    "from": m["account"]["name"],
                    "from_account_id": m["account"]["account_id"],  # ボール判定はIDが正（757779=社長）
                    "send_time": m["send_time"],
                    "sent": datetime.fromtimestamp(m["send_time"]).isoformat(timespec="seconds"),
                    "body": m["body"],
                }
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                saved += 1
            # 成功したルームだけカーソル前進
            new_cur = {"lut": r["last_update_time"]}
            max_mid = max((int(m["message_id"]) for m in msgs), default=0)
            if max_mid:
                new_cur["mid"] = str(max_mid)
            elif cur.get("mid"):
                new_cur["mid"] = cur["mid"]
            cursors[rid] = new_cur
            time.sleep(0.3)  # レート制限マージン

    state["last_poll"] = now
    save_state(state)
    hours = (now - last) / 3600
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    print(f"[{stamp}] 前回から {hours:.1f}h / 更新ルーム {len(targets)} / 新着 {saved} 件 → {outfile.relative_to(ROOT)}")
    if over_100:
        print(f"  ⚠️ 100件超で取りこぼしの可能性: {', '.join(over_100)}")
    if failed:
        print(f"  ⚠️ 取得失敗 {len(failed)} ルーム（カーソル未前進＝次回自動再取得）: {'; '.join(failed)}")
    if skipped:
        print(f"  ⚠️ ルーム数上限で {len(skipped)} ルーム未取得（カーソル未前進＝次回自動再取得）")


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    tok = token()
    if cmd == "rooms":
        cmd_rooms(tok)
    elif cmd == "tasks":
        cmd_tasks(tok)
    elif cmd == "poll":
        cmd_poll(tok)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
