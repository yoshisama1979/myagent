#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Googleカレンダー取得（読み取り専用・無人セッション用）

なぜ必要か（2026-08-03）:
  claude.ai の Googleカレンダーコネクタは対話セッションでは使えるが、**cron のヘッドレス実行からは
  見えない**（実測で確認：ローカルの mcpServers に無く、アカウント側で解決されるため）。
  朝礼は無人で動くので、そこから予定を見るには別途こちらで取りに行く必要がある。

設計（gmail-fetch.py と同型・社長合意 2026-08-03）:
- スコープは calendar.readonly のみ＝**作成・変更・削除は権限レベルで不可能**。
- 読むカレンダーは calendars.md の許可リストだけ（オプトイン）。指定外は**取得すらしない**＝
  私生活のカレンダー（ファミリー・日記メモ等）に触れない。senders.md と同じ考え方。
  ★ただし正直に書いておく：これは**このスクリプトの中の約束**であって、権限そのものではない。
    トークンは社長アカウントが見られる全カレンダーを読める権限を持っている（calendar.readonly は
    「許可リスト内だけ」という意味ではない）。権限レベルで縛るには、朝礼専用の Google アカウントを
    作って対象1本だけを共有する構成が要る（2026-08-03 時点では未実施＝社長判断待ち）。
    そのため許可リストの解析は「曖昧なら落とす」設計にしてある（下の load_calendars）。
  ★`list` は許可リストを作るための下見コマンドで、**全カレンダーの名前とIDを列挙する**。
    設定が済んだら使わない（無人実行の経路では呼ばれない）。
- 取得先は data/comms/calendar/（.gitignore 済み）。予定の中身は git に入れない。
- 認証は gmail-fetch と同じ「ブラウザ同意→URL貼り付け」方式（ヘッドレスVPSで確実に動く）。
  トークンは gmail とは別ファイルに分ける＝スコープが違うため、片方の再認証が他方を壊さない。

使い方:
  calendar-fetch.py login              # 初回のみ: ブラウザ同意→URL貼り付けでトークン保存
  calendar-fetch.py login-code '<URL>' # 貼り付けを引数で渡す版
  calendar-fetch.py list               # 見えているカレンダー一覧（許可リスト作成用）
  calendar-fetch.py fetch [日数]       # 許可カレンダーの予定を取得して保存（既定 7日先まで）
  calendar-fetch.py show               # 保存済みから「今日・明日」を表示（朝礼が使う形）
"""
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent
DATA = PROJ / "data" / "comms" / "calendar"
SECRETS_DIR = PROJ / "data" / "secrets"
CAL_LIST = DATA / "calendars.md"
OUT_FILE = DATA / "events.json"
STATUS_FILE = DATA / "fetch-status.json"   # 直近の取得が失敗したときだけ置く
ENV_FILE = PROJ / ".env"

SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]
REDIRECT_URI = "http://localhost:8765/"
JST = timezone(timedelta(hours=9))
DEFAULT_DAYS = 7

# ★実際のカレンダーIDはここに書かない（このファイルは git に載る）。
#   雛形は例示だけにして、実値は data/comms/calendar/calendars.md（git 管理外）に置く。
#   senders.md（Gmail の許可リスト）と同じ扱い。
CAL_TEMPLATE = """# 読むカレンダー（社長が編集してよいファイル）
#
# 1行1カレンダー。`カレンダーID  # 表示名` の形式。行頭 # はコメント。
# ここに書いたものだけ取得する（書いていないカレンダーは取得すらしない）。
# ID は `python3 bin/calendar-fetch.py list` で確認できる。
#
# 例:
#   xxxxxxxx@group.calendar.google.com  # 仕事用カレンダー
"""


def die(msg: str, code: int = 1):
    print(f"⚠️ calendar-fetch: {msg}", file=sys.stderr)
    sys.exit(code)


def env_value(key: str) -> str:
    """.env から必要キーだけ抜く（gmail-fetch と同じ規約・秘密値はログに出さない）"""
    if not ENV_FILE.is_file():
        return ""
    for line in ENV_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip() != key:
            continue
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        return v
    return ""


def atomic_write(path: Path, text: str, secret: bool = False):
    """一時ファイル→置換で原子的に書く。

    ★予定の中身も社外に見せたくない情報（打ち合わせ相手・場所）なので、
      既定の umask 任せ（0644 になりうる）にせず 0600 を明示する。
    ★一時ファイル名は固定にしない＝同時実行やシンボリックリンクで踏まれないように。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600 if secret else 0o644)
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def token_path() -> Path:
    return SECRETS_DIR / "calendar-token.json"


def build_creds():
    tp = token_path()
    if not tp.is_file():
        die(f"トークンが無い。先に実行: python3 bin/calendar-fetch.py login（{tp}）")
    try:
        d = json.loads(tp.read_text(encoding="utf-8"))
        from google.oauth2.credentials import Credentials
        return Credentials(None, refresh_token=d["refresh_token"], token_uri=d["token_uri"],
                           client_id=d["client_id"], client_secret=d["client_secret"], scopes=SCOPES)
    except (KeyError, ValueError):
        die(f"トークンファイルが不正: {tp}（login をやり直す）")


def service():
    from googleapiclient.discovery import build
    return build("calendar", "v3", credentials=build_creds(), cache_discovery=False)


def api_call(fn):
    """API呼び出しの失敗を、社長が次に何をすればよいか分かる形に翻訳する。

    生のトレースバックを出すと「何が悪いのか・誰が直せるのか」が伝わらない。
    とくに accessNotConfigured（プロジェクトでAPIが未有効）は、こちら側では直せず
    GCPコンソールでの操作が要る＝そう言わないと社長が待ち続けることになる。
    """
    try:
        return fn()
    except Exception as e:
        msg = str(e)
        if "accessNotConfigured" in msg or "has not been used in project" in msg:
            import re as _re
            m = _re.search(r"project (\d+)", msg)
            proj = m.group(1) if m else "（不明）"
            die("Googleカレンダー API がこのプロジェクトで有効になっていません。\n"
                f"  GCPコンソールで有効化してください（プロジェクト {proj}）:\n"
                f"  https://console.cloud.google.com/apis/library/calendar-json.googleapis.com?project={proj}\n"
                "  有効化から数分待ってから、もう一度実行してください。\n"
                "  ※ Gmail API は同じプロジェクトで有効化済みですが、API ごとに個別の有効化が要ります。")
        if "insufficient" in msg.lower() or "invalid_scope" in msg or "insufficientPermissions" in msg:
            die("権限（スコープ）が足りません。login をやり直してください:\n"
                "  python3 bin/calendar-fetch.py login")
        if "invalid_grant" in msg:
            die("トークンが失効しています。login をやり直してください:\n"
                "  python3 bin/calendar-fetch.py login")
        die(f"API 呼び出しに失敗: {type(e).__name__}\n  {msg[:300]}")


# --- OAuth（gmail-fetch.py と同じ2手方式：ブラウザ同意 → URL貼り付け）------------
def _oauth_client_cfg():
    rel = env_value("GMAIL_OAUTH_CLIENT") or "data/secrets/gmail-oauth-client.json"
    p = Path(rel)
    p = p if p.is_absolute() else PROJ / p
    if not p.is_file():
        die(f"OAuthクライアントJSONが見つからない: {p}")
    try:
        return json.loads(p.read_text(encoding="utf-8"))["installed"]
    except (KeyError, ValueError):
        die('OAuthクライアントJSONの形式が想定外（"installed" 型のみ対応）')


def _auth_url(cfg) -> str:
    from urllib.parse import urlencode
    return "https://accounts.google.com/o/oauth2/v2/auth?" + urlencode({
        "client_id": cfg["client_id"], "redirect_uri": REDIRECT_URI,
        "response_type": "code", "scope": " ".join(SCOPES),
        "access_type": "offline", "prompt": "consent"})


def _extract_code(pasted: str) -> str:
    from urllib.parse import parse_qs, unquote, urlparse
    s = pasted.strip().strip('"').strip("'")
    if "://" in s or s.startswith("localhost"):
        code = parse_qs(urlparse(s).query).get("code", [""])[0]
        if not code:
            die("貼り付けたURLに code= が見つからない。アドレスバーのURL全体をコピーする")
        return code
    if not s:
        die("何も入力されていない。login からやり直す")
    return unquote(s)


def _finish_login(cfg, code: str):
    from urllib.parse import urlencode
    from urllib.request import Request, urlopen
    body = urlencode({"code": code, "client_id": cfg["client_id"],
                      "client_secret": cfg["client_secret"], "redirect_uri": REDIRECT_URI,
                      "grant_type": "authorization_code"}).encode()
    try:
        with urlopen(Request("https://oauth2.googleapis.com/token", data=body), timeout=30) as r:
            tok = json.loads(r.read().decode())
    except Exception as e:
        die(f"トークン交換に失敗: {type(e).__name__}。コードの有効期限（約10分・1回きり）切れの可能性")
    if not tok.get("refresh_token"):
        die("refresh_token が返らなかった。login からやり直す")
    atomic_write(token_path(), json.dumps({
        "client_id": cfg["client_id"], "client_secret": cfg["client_secret"],
        "refresh_token": tok["refresh_token"],
        "token_uri": "https://oauth2.googleapis.com/token"}, ensure_ascii=False), secret=True)
    print(f"OK: トークンを保存しました（{token_path()}・0600）")
    print("次: python3 bin/calendar-fetch.py list  でカレンダー一覧を確認")


def cmd_login():
    cfg = _oauth_client_cfg()
    print("① 次のURLをブラウザで開き、カレンダーを見たいGoogleアカウントで許可してください。\n")
    print(_auth_url(cfg) + "\n")
    print("② 許可後に『このサイトにアクセスできません』と出ます。それで正常です。")
    print("   その画面の【アドレスバーのURL全体】をコピーして貼り付けてください。\n")
    try:
        pasted = input("URL貼り付け> ")
    except EOFError:
        print("\n（この端末では入力できないため）次を実行してください:")
        print("  python3 bin/calendar-fetch.py login-code 'ここにURLを貼る'")
        return
    _finish_login(cfg, _extract_code(pasted))


def cmd_login_code(arg: str):
    if not arg:
        die("使い方: calendar-fetch.py login-code '<リダイレクト先URL全体 または code>'")
    _finish_login(_oauth_client_cfg(), _extract_code(arg))


# --- 許可リスト ------------------------------------------------------------
def load_calendars():
    """calendars.md → [(id, 表示名)]。無ければ雛形を作る。

    ★ここは「どのカレンダーに触れるか」を決める唯一の場所なので、曖昧な入力は通さず落とす。
      1件でもおかしければ API を呼ぶ前に異常終了する＝間違ったカレンダーに触りにいかない。
      実測で見つかった落とし穴（2026-08-03 Codexレビュー）：
        ・BOM付きで保存されると先頭行がコメントと認識されず、﻿ がIDとして API に送られる
        ・`#` でコメントを切ると `ja.japanese#holiday@group.v.calendar.google.com` のように
          **ID自体に # を含むカレンダー**（祝日等）が壊れる → 区切りは空白にする
        ・`primary` は「認証したアカウントの既定カレンダー」を指す特別な識別子＝
          許可リストに書いてしまうと私生活側を読みうる → 明示的に拒否する
    """
    if not CAL_LIST.is_file():
        atomic_write(CAL_LIST, CAL_TEMPLATE)
        print(f"許可リストの雛形を作りました: {CAL_LIST}")
    out, seen = [], {}
    # utf-8-sig＝BOM があれば取り除く（無ければ通常の utf-8 として読む）
    for no, line in enumerate(CAL_LIST.read_text(encoding="utf-8-sig").splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        # 区切りは最初の空白。以降はコメント（先頭の # は飾りとして落とす）
        parts = s.split(None, 1)
        cal_id = parts[0]
        comment = parts[1].lstrip("#").strip() if len(parts) > 1 else ""
        if cal_id.lower() == "primary":
            die(f"{CAL_LIST}:{no} `primary` は使えません＝認証アカウントの既定カレンダーを指すため、"
                "私生活のカレンダーを読む恐れがあります。実際のカレンダーIDを書いてください")
        if any(c.isspace() or ord(c) < 0x20 for c in cal_id) or "　" in cal_id:
            die(f"{CAL_LIST}:{no} カレンダーIDに空白・制御文字が含まれています: {cal_id!r}")
        if "@" not in cal_id:
            die(f"{CAL_LIST}:{no} カレンダーIDの形式が想定外（@ を含まない）: {cal_id!r}")
        if cal_id in seen:
            die(f"{CAL_LIST}:{no} カレンダーIDが重複しています（{seen[cal_id]}行目と同じ）: {cal_id}")
        seen[cal_id] = no
        out.append((cal_id, comment))
    return out


def cmd_list():
    """見えているカレンダーを全部出す（許可リストを作るための下見。予定は読まない）"""
    allowed = {c for c, _ in load_calendars()}
    items = api_call(lambda: service().calendarList().list(maxResults=250).execute()).get("items", [])
    print(f"見えているカレンダー {len(items)} 本（✅＝許可リストに入っている）\n")
    for it in sorted(items, key=lambda x: x.get("summary", "")):
        mark = "✅" if it["id"] in allowed else "  "
        print(f"{mark} {it.get('summary', '(名前なし)')}")
        print(f"     {it['id']}")


# --- 取得 ------------------------------------------------------------------
def cmd_fetch(days: int):
    cals = load_calendars()
    if not cals:
        die(f"許可リストが空: {CAL_LIST}（読むカレンダーを1行書く）")
    now = datetime.now(JST)
    lo = now.replace(hour=0, minute=0, second=0, microsecond=0)
    hi = lo + timedelta(days=days)
    svc = service()
    events, errs = [], []
    for cal_id, name in cals:
        try:
            token, pages = None, 0
            while True:
                # ★nextPageToken を辿る：maxResults で終わりではない（251件目以降が黙って消える）。
                #   singleEvents=True は繰り返しを1件ずつに展開するので、件数は簡単に増える。
                res = svc.events().list(
                    calendarId=cal_id, timeMin=lo.isoformat(), timeMax=hi.isoformat(),
                    singleEvents=True, orderBy="startTime", maxResults=250,
                    timeZone="Asia/Tokyo",   # 応答の既定はカレンダー毎の時間帯＝混在を防ぐため固定
                    pageToken=token).execute()
                for ev in res.get("items", []):
                    if ev.get("status") == "cancelled":
                        continue
                    st, en = ev.get("start", {}), ev.get("end", {})
                    s_val = st.get("dateTime") or st.get("date", "")
                    e_val = en.get("dateTime") or en.get("date", "")
                    if not s_val or not e_val:
                        # 開始/終了が読めない予定を黙って捨てると「予定なし」に化ける
                        raise RuntimeError(f"開始/終了が読めない予定: {ev.get('id', '?')}")
                    events.append({
                        "calendar": name or cal_id,
                        "calendar_id": cal_id,      # 表示名は取り違えうるのでIDも残す
                        "event_id": ev.get("id", ""),
                        "summary": ev.get("summary", "(件名なし)"),
                        "start": s_val, "end": e_val,
                        "all_day": "date" in st,
                        # transparency=transparent ＝「予定あり」にしない設定＝時間を専有しない
                        "busy": ev.get("transparency") != "transparent",
                        "location": ev.get("location", ""),
                    })
                token = res.get("nextPageToken")
                pages += 1
                if not token or pages >= 20:        # 20ページ=5000件で異常とみなす
                    break
        except Exception as e:
            # API 未有効など「全カレンダー共通で直らない」失敗は、1本目で止めて理由を出す
            if "accessNotConfigured" in str(e) or "has not been used in project" in str(e):
                api_call(lambda: (_ for _ in ()).throw(e))
            errs.append(f"{name or cal_id}: {type(e).__name__}: {str(e)[:120]}")

    # ★1本でも取れなかったら、前回の正常な結果を上書きしない（Codex🔴4）。
    #   部分的な結果を保存すると、朝礼には「予定が少ない／無い」ようにしか見えず、
    #   トークン失効・通信断が「予定なし」に化ける＝いちばん静かに壊れる経路。
    if errs:
        atomic_write(STATUS_FILE, json.dumps({
            "failed_at": now.isoformat(), "errors": errs}, ensure_ascii=False, indent=1))
        print(f"⚠️ {len(errs)} 本のカレンダーが取得できませんでした＝保存を中止します"
              f"（前回の結果はそのまま残しています）", file=sys.stderr)
        for e in errs:
            print(f"   - {e}", file=sys.stderr)
        sys.exit(1)

    events.sort(key=lambda e: (e["start"], e["summary"]))
    atomic_write(OUT_FILE, json.dumps({
        "fetched_at": now.isoformat(), "days": days,
        "window": [lo.isoformat(), hi.isoformat()],
        "calendars": [n or c for c, n in cals],
        "errors": [], "events": events}, ensure_ascii=False, indent=1), secret=True)
    STATUS_FILE.unlink(missing_ok=True)     # 直近が成功なら失敗記録は残さない
    print(f"取得 {len(events)} 件 / カレンダー {len(cals)} 本 / {lo:%m-%d}〜{hi:%m-%d} → {OUT_FILE}")


def _fmt(ev):
    if ev["all_day"]:
        return "終日"
    try:
        s = datetime.fromisoformat(ev["start"]).astimezone(JST)
        e = datetime.fromisoformat(ev["end"]).astimezone(JST)
        return f"{s:%H:%M}–{e:%H:%M}"
    except ValueError:
        return ev["start"][:16]


def _span(ev):
    """予定の期間を (開始, 終了) の datetime で返す。終日はその日の 00:00〜翌0:00。

    ★「開始日の文字列が一致するか」で当日判定してはいけない（Codex🔴6）。
      複数日にまたがる予定・深夜をまたぐ予定・UTC表記の予定を取りこぼす。
    """
    if ev["all_day"]:
        s = datetime.fromisoformat(ev["start"]).replace(tzinfo=JST)
        e = datetime.fromisoformat(ev["end"]).replace(tzinfo=JST)   # 終日の end は「翌日」
        return s, e
    return (datetime.fromisoformat(ev["start"]).astimezone(JST),
            datetime.fromisoformat(ev["end"]).astimezone(JST))


def cmd_show():
    """朝礼が読む形。保存済みから今日・明日だけを出す（通信しない）"""
    if not OUT_FILE.is_file():
        die(f"まだ取得していない: python3 bin/calendar-fetch.py fetch（{OUT_FILE}）")
    try:
        d = json.loads(OUT_FILE.read_text(encoding="utf-8"))
        events = d["events"]
        fetched = datetime.fromisoformat(d["fetched_at"]).astimezone(JST)
    except (ValueError, KeyError, TypeError) as e:
        die(f"予定ファイルが壊れています（{type(e).__name__}）＝取り直してください: {OUT_FILE}")

    # ★古さの判定はルール文でなくコードで強制する（Codex🔴8）。
    #   「AIが取得時刻を見て自分で気づく」に頼ると、いつか黙って古い予定で判断する。
    now = datetime.now(JST)
    stale = fetched.date() != now.date()
    if stale or d.get("errors"):
        print("🔴 予定は未取得です（この情報で予定の有無を判断しないでください）")
        print(f"   最後に取得できたのは {fetched:%Y-%m-%d %H:%M} です"
              + ("／取得エラーあり" if d.get("errors") else ""))
        if STATUS_FILE.is_file():
            try:
                st = json.loads(STATUS_FILE.read_text(encoding="utf-8"))
                for e in st.get("errors", [])[:3]:
                    print(f"   - {e}")
            except ValueError:
                pass
        print("   復旧: python3 bin/calendar-fetch.py fetch")
        sys.exit(1)

    today = now.date()
    for offset, label in ((0, "今日"), (1, "明日")):
        day = today + timedelta(days=offset)
        lo = datetime.combine(day, datetime.min.time(), tzinfo=JST)
        hi = lo + timedelta(days=1)
        rows = []
        for ev in events:
            try:
                s, e = _span(ev)
            except ValueError:
                continue
            if s < hi and e > lo:            # 半開区間で重なりを見る＝複数日の予定も拾う
                rows.append((s, ev, s < lo or e > hi))
        rows.sort(key=lambda r: r[0])
        print(f"■ {label}（{day}）")
        if not rows:
            print("   予定なし")
        for _, ev, spans in rows:
            mark = "" if ev["busy"] else "（空き扱い）"
            loc = f" @{ev['location']}" if ev["location"] else ""
            cont = "（前後の日にまたがる）" if spans and not ev["all_day"] else ""
            print(f"   {_fmt(ev):<12} {ev['summary']}{loc}{mark}{cont}")
    print(f"\n（取得: {fetched:%Y-%m-%d %H:%M} ／ 対象: {', '.join(d.get('calendars', []))}）")


def main():
    DATA.mkdir(parents=True, exist_ok=True)
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "login":
        cmd_login()
    elif cmd == "login-code":
        cmd_login_code(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "list":
        cmd_list()
    elif cmd == "fetch":
        try:
            days = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_DAYS
        except ValueError:
            die("日数は整数で指定する（例: fetch 7）")
        cmd_fetch(days)
    elif cmd == "show":
        cmd_show()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
