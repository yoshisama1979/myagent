#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Gmail 差分取得（comms パイプライン・フェーズ1）

設計（2026-07-28 社長合意・オプトイン方式）:
- senders.md の許可リスト該当だけ本文を取得して raw へ保存（蒸留対象）。
- 未承認の送信者は本文を取得すらしない＝メタデータ（アドレス・表示名・件数・日時）
  だけを pending.json に記録し「承認待ち一覧」として社長が選べるようにする。
- 無視リスト該当は承認待ちにも出さない（記録を残さない）。
- forward-only: 初回実行時刻を baseline とし、それ以前のメールは扱わない（Chatworkと同合意）。
- スコープは gmail.readonly のみ＝送信・削除・既読化は権限レベルで不可能。
- ボール判定（🔴自分/🟢相手）のため送信済み（自分の返信）も取得対象。
- 認証は2方式対応（2026-07-28 Workspace未使用と判明しOAuthに切替）:
  ① OAuthリフレッシュトークン（通常Gmail用・現行）: `login` で1回だけブラウザ同意→
     data/secrets/gmail-token-<addr>.json に保存。同意画面が「本番環境」ならトークンは失効しない
     （テストモードだと7日で切れるので不可）。パスワード変更時のみ再 login が必要。
  ② サービスアカウント＋ドメイン全体の委任（Workspace移行時用に残置）: .env GMAIL_SA_JSON。
- 堅牢化は chatwork-fetch.py と同型:
  アカウント単位カーソル（失敗アカウントはカーソル未前進＝次回自動再取得）・flock 排他・
  atomic な state/pending 書き込み・破損 state は勝手に初期化せず非0終了。
- raw/pending/senders は data/comms/gmail/ 配下（.gitignore 済み・機械ガードの許可範囲内）。

使い方:
  gmail-fetch.py login    # 初回のみ: ブラウザ同意→エラーページのURL貼り付けでトークン保存
  gmail-fetch.py login-code '<URL>'  # login の貼り付けを引数で渡す版（対話入力できない端末用）
  gmail-fetch.py auth     # 疎通確認（getProfile のみ・メールは読まない）
  gmail-fetch.py poll     # 差分取得（cron 用）
  gmail-fetch.py pending  # 承認待ちアドレス一覧を表示（手動確認用）
"""
import base64
import fcntl
import json
import os
import re
import sys
import time
from email.header import decode_header, make_header
from email.utils import getaddresses, parseaddr
from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent
DATA = PROJ / "data" / "comms" / "gmail"
RAW_DIR = DATA / "raw"
STATE_FILE = DATA / "state.json"
SENDERS_FILE = DATA / "senders.md"
PENDING_FILE = DATA / "pending.json"
LOCK_FILE = DATA / ".poll.lock"
ENV_FILE = PROJ / ".env"

SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]
BODY_MAX = 10000          # 蒸留に十分な長さで打ち切り（長文の引用連鎖対策）
LIST_HARD_CAP = 1000      # 1アカウント1回の処理上限（古い側から処理＝残りは次回に持ち越し）
LIST_PAGE_MAX = 200       # ID列挙の暴走ガード（200ページ=2万件超えは異常＝カーソル未前進で停止）
RECENT_WINDOW_MS = 2000   # after: クエリが秒精度のための境界重複をIDで除外する窓

SENDERS_TEMPLATE = """# Gmail 送信者リスト（社長が編集してよいファイル）
#
# 書式: 1行1エントリ。
#   @example.co.jp    → ドメイン一致（その会社の全員）
#   taro@example.com  → アドレス完全一致
# 行内の # 以降はコメント。完全一致はドメイン指定より優先
# （例: ドメイン許可の中の newsletter@ だけ個別に無視、が可能）。
# セクション見出し（## の行）は変更しないこと。

## 許可（本文を取得し蒸留対象にする）

## 無視（承認待ち一覧にも出さない）
"""


def env_value(key: str) -> str:
    """最初に一致した行の値を返す（hana-api.sh と同じ規約・秘密値はログに出さない）"""
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


def die(msg: str, code: int = 1):
    print(f"⚠️ gmail-fetch: {msg}", file=sys.stderr)
    sys.exit(code)


def atomic_write(path: Path, text: str):
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def atomic_write_secret(path: Path, text: str):
    """秘密ファイル用：一時ファイルの作成時点から 0600（umask 0002 環境で
    書き込み中・replace直後にグループ可読になる穴を塞ぐ）"""
    tmp = path.with_suffix(path.suffix + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def load_state():
    """無い→None（初回）。壊れている→勝手に初期化せず非0終了（黙ってbaselineを進めない）"""
    if not STATE_FILE.is_file():
        return None
    try:
        st = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        assert isinstance(st.get("baseline"), int) and isinstance(st.get("accounts"), dict)
        return st
    except Exception:
        die(f"state.json が破損。手当てするまで実行しない: {STATE_FILE}")


def load_pending():
    if not PENDING_FILE.is_file():
        return {}
    try:
        p = json.loads(PENDING_FILE.read_text(encoding="utf-8"))
    except ValueError:
        die(f"pending.json が破損: {PENDING_FILE}")
    if not isinstance(p, dict):
        # 黙って {} にすると次回保存で承認待ちの蓄積を消してしまう
        die(f"pending.json が想定外の型: {PENDING_FILE}")
    return p


def parse_senders():
    """senders.md → (allow_exact, allow_dom, ign_exact, ign_dom)。無ければ雛形を作る"""
    if not SENDERS_FILE.is_file():
        atomic_write(SENDERS_FILE, SENDERS_TEMPLATE)
    allow_e, allow_d, ign_e, ign_d = set(), set(), set(), set()
    sec = None
    for line in SENDERS_FILE.read_text(encoding="utf-8").splitlines():
        ls = line.strip()
        if ls.startswith("##"):
            if "許可" in ls:
                sec = "allow"
            elif "無視" in ls:
                sec = "ignore"
            continue
        if ls.startswith("#") or not ls or sec is None:
            continue
        tok = ls.split("#", 1)[0].strip().split()
        tok = tok[0].lower() if tok else ""
        if tok.startswith("@") and len(tok) > 1:
            (allow_d if sec == "allow" else ign_d).add(tok[1:])
        elif "@" in tok:
            (allow_e if sec == "allow" else ign_e).add(tok)
    return allow_e, allow_d, ign_e, ign_d


def classify(addr: str, lists) -> str:
    allow_e, allow_d, ign_e, ign_d = lists
    a = addr.lower()
    d = a.split("@")[-1]
    if a in ign_e:
        return "ignore"
    if a in allow_e:
        return "allow"
    if d in ign_d:
        return "ignore"
    if d in allow_d:
        return "allow"
    return "pending"


def hdec(s: str) -> str:
    """RFC2047（=?UTF-8?B?...?=）ヘッダのデコード"""
    try:
        return str(make_header(decode_header(s)))
    except Exception:
        return s


def _part_charset(part) -> str:
    for h in part.get("headers") or []:
        if h.get("name", "").lower() == "content-type":
            # `charset = Shift_JIS` のように = の前後に空白がある正当な表記も通す
            m = re.search(r'charset\s*=\s*"?([\w\-]+)', h.get("value", ""), re.I)
            if m:
                return m.group(1)
    return "utf-8"


def _is_attachment(part) -> bool:
    if part.get("filename"):
        return True
    for h in part.get("headers") or []:
        if h.get("name", "").lower() == "content-disposition" \
                and h.get("value", "").lower().startswith("attachment"):
            return True
    return False


def _decode_part(part) -> str:
    data = (part.get("body") or {}).get("data")
    if not data:
        return ""
    raw = base64.urlsafe_b64decode(data + "===")
    try:
        return raw.decode(_part_charset(part), errors="replace")
    except LookupError:
        return raw.decode("utf-8", errors="replace")


def extract_body(payload) -> str:
    """text/plain 優先・無ければ text/html をタグ除去。添付は見ない"""
    import html as html_mod
    plain = html = None
    stack = [payload]
    while stack:
        p = stack.pop(0)
        mt = p.get("mimeType", "")
        if mt.startswith("multipart/"):
            stack = (p.get("parts") or []) + stack
            continue
        if _is_attachment(p):
            # text/plain の添付ファイルを本文と誤認して取り込まない（「添付は見ない」の徹底）
            continue
        if not (p.get("body") or {}).get("data"):
            continue
        if mt == "text/plain" and plain is None:
            plain = p
        elif mt == "text/html" and html is None:
            html = p
    part = plain or html
    if part is None:
        return ""
    txt = _decode_part(part)
    if plain is None:
        txt = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", txt, flags=re.S | re.I)
        txt = re.sub(r"<[^>]+>", " ", txt)
        txt = html_mod.unescape(txt)
        txt = re.sub(r"[ \t　]+", " ", txt)
    txt = re.sub(r"\n{3,}", "\n\n", txt).strip()
    if len(txt) > BODY_MAX:
        txt = txt[:BODY_MAX] + "\n…(以降省略)"
    return txt


SECRETS_DIR = PROJ / "data" / "secrets"


def _resolve(rel: str) -> Path:
    p = Path(rel)
    return p if p.is_absolute() else PROJ / p


def token_path(account: str) -> Path:
    return SECRETS_DIR / f"gmail-token-{account}.json"


def build_creds(account: str):
    """①サービスアカウント（GMAIL_SA_JSON があり service_account 型なら優先）
    ②OAuthリフレッシュトークン（login コマンドで保存したもの）"""
    sa_rel = env_value("GMAIL_SA_JSON")
    if sa_rel and _resolve(sa_rel).is_file():
        from google.oauth2 import service_account
        return service_account.Credentials.from_service_account_file(
            str(_resolve(sa_rel)), scopes=SCOPES).with_subject(account)
    tp = token_path(account)
    if not tp.is_file():
        # die() だとアカウント単位の失敗隔離（片方だけ未login等）が壊れるため例外で返す
        raise RuntimeError(f"{account} のトークンが無い。先に実行: python3 bin/gmail-fetch.py login")
    try:
        d = json.loads(tp.read_text(encoding="utf-8"))
        from google.oauth2.credentials import Credentials
        return Credentials(
            None, refresh_token=d["refresh_token"], token_uri=d["token_uri"],
            client_id=d["client_id"], client_secret=d["client_secret"], scopes=SCOPES)
    except (KeyError, ValueError):
        raise RuntimeError(f"トークンファイルが不正: {tp}（login をやり直す）")


def gmail_service(account: str):
    from googleapiclient.discovery import build
    return build("gmail", "v1", credentials=build_creds(account), cache_discovery=False)


def get_accounts():
    raw = env_value("GMAIL_ACCOUNTS")
    if not raw:
        die("GMAIL_ACCOUNTS が未設定（.env に取得対象アカウントを登録する）")
    return [a.strip().lower() for a in raw.split(",") if a.strip()]


def get_self_addrs():
    """自分側とみなすアドレス集合＝アカウント本体＋送信エイリアス（.env GMAIL_SELF_ADDRS）。
    1つのGmailに複数ドメインのエイリアスが載る構成（send-as）で、自分発・自分宛てを
    相手（counterpart）として誤検出しないために使う"""
    raw = env_value("GMAIL_SELF_ADDRS")
    extra = [a.strip().lower() for a in raw.split(",") if a.strip()] if raw else []
    return set(get_accounts()) | set(extra)


REDIRECT_URI = "http://localhost:8765/"


def _oauth_client_cfg():
    client_rel = env_value("GMAIL_OAUTH_CLIENT") or "data/secrets/gmail-oauth-client.json"
    client_file = _resolve(client_rel)
    if not client_file.is_file():
        die(f"OAuthクライアントJSONが見つからない: {client_file}\n"
            "  （GCPコンソールで作成した『デスクトップアプリ』型のJSONをこのパスに置く）")
    try:
        return json.loads(client_file.read_text(encoding="utf-8"))["installed"]
    except (KeyError, ValueError):
        die("OAuthクライアントJSONの形式が想定外（\"installed\" 型のみ対応）")


def _auth_url(cfg) -> str:
    from urllib.parse import urlencode
    return "https://accounts.google.com/o/oauth2/v2/auth?" + urlencode({
        "client_id": cfg["client_id"], "redirect_uri": REDIRECT_URI,
        "response_type": "code", "scope": " ".join(SCOPES),
        "access_type": "offline", "prompt": "consent"})


def _extract_code(pasted: str) -> str:
    """貼り付けられた『リダイレクト先URL全体』または code 単体から認可コードを取り出す"""
    from urllib.parse import parse_qs, unquote, urlparse
    s = pasted.strip().strip('"').strip("'")
    if "://" in s or s.startswith("localhost"):
        qs = parse_qs(urlparse(s).query)
        code = qs.get("code", [""])[0]
        if not code:
            die("貼り付けたURLに code= が見つからない。アドレスバーのURL全体をコピーする")
        return code
    if not s:
        die("何も入力されていない。login からやり直す")
    return unquote(s)


def _finish_login(cfg, code: str):
    """認可コード→リフレッシュトークン交換・実アカウント確定・保存"""
    from urllib.parse import urlencode
    from urllib.request import Request, urlopen
    body = urlencode({
        "code": code, "client_id": cfg["client_id"],
        "client_secret": cfg["client_secret"], "redirect_uri": REDIRECT_URI,
        "grant_type": "authorization_code"}).encode()
    try:
        with urlopen(Request("https://oauth2.googleapis.com/token", data=body), timeout=30) as r:
            tok = json.loads(r.read().decode())
    except Exception as e:
        die(f"トークン交換に失敗: {type(e).__name__}。"
            "コードの有効期限（約10分・1回きり）切れの可能性＝login からやり直す")
    if not tok.get("refresh_token"):
        die("refresh_token が返らなかった。login からやり直す")

    # どのアカウントで同意されたかを getProfile で確定してから保存する
    from google.oauth2.credentials import Credentials
    from googleapiclient.discovery import build
    creds = Credentials(tok["access_token"], scopes=SCOPES)
    email = build("gmail", "v1", credentials=creds, cache_discovery=False) \
        .users().getProfile(userId="me").execute()["emailAddress"].lower()

    SECRETS_DIR.mkdir(parents=True, exist_ok=True)
    atomic_write_secret(token_path(email), json.dumps({
        "client_id": cfg["client_id"], "client_secret": cfg["client_secret"],
        "refresh_token": tok["refresh_token"],
        "token_uri": "https://oauth2.googleapis.com/token"}, ensure_ascii=False))
    print(f"OK: {email} のトークンを保存しました")
    if email not in get_accounts():
        print(f"⚠️ {email} は GMAIL_ACCOUNTS（{', '.join(get_accounts())}）に含まれていません。"
              "対象に加えるなら .env の GMAIL_ACCOUNTS を更新してください")


def cmd_login():
    """ブラウザ同意→エラーページのURL貼り付け、の2手方式。
    リダイレクト先(localhost)はどこにも繋がらず『このサイトにアクセスできません』と出るのが正常＝
    その時点でアドレスバーに認可コードが載っているのでURLごとコピーして貼り付けてもらう。
    ポート転送・受けサーバ不要＝ヘッドレスVPSで確実に動く"""
    cfg = _oauth_client_cfg()
    print("① 次のURLをブラウザで開き、取得したいGmailアカウントでログイン・許可してください。")
    print("   （『確認されていないアプリ』警告は「詳細」→続行。アカウントごとに login を1回ずつ）\n")
    print(_auth_url(cfg) + "\n")
    print("② 許可後に『このサイトにアクセスできません』と出ます。それで正常です。")
    print("   その画面の【アドレスバーのURL全体】（localhost:8765/?code=... ）をコピーして、")
    print("   ここに貼り付けて Enter してください。\n")
    try:
        pasted = input("URL貼り付け> ")
    except EOFError:
        print("\n（この端末では入力できないため）コピーしたURLを引数にして次を実行してください:")
        print("  python3 bin/gmail-fetch.py login-code 'ここにURLを貼る'")
        return
    _finish_login(cfg, _extract_code(pasted))


def cmd_login_code(arg: str):
    if not arg:
        die("使い方: gmail-fetch.py login-code '<リダイレクト先URL全体 または code>'")
    _finish_login(_oauth_client_cfg(), _extract_code(arg))


def cmd_auth():
    ok = 0
    accounts = get_accounts()
    for acct in accounts:
        try:
            prof = gmail_service(acct).users().getProfile(userId="me").execute()
            print(f"OK  {acct} (総メッセージ {prof.get('messagesTotal', '?')} 件)")
            ok += 1
        except Exception as e:
            print(f"NG  {acct} — {type(e).__name__}: トークン失効・スコープ不一致の可能性（login をやり直す）")
            print(f"    詳細: {str(e)[:200]}")
    print(f"auth: {ok}/{len(accounts)} アカウント疎通")
    sys.exit(0 if ok == len(accounts) else 1)


def _headers_map(meta):
    return {h["name"].lower(): h["value"] for h in meta.get("payload", {}).get("headers", [])}


def _poll_account(svc, acct: str, cur: dict, lists, pending: dict, self_addrs=None):
    """1アカウント分の差分処理。成功時に (新cursor辞書, rawレコード群, pending更新, counts) を返す。
    例外はそのまま上げる＝呼び出し側がカーソル未前進のまま次回へ回す"""
    counts = {"new": 0, "saved": 0, "pending": 0, "ignored": 0}
    recent = set(cur.get("recent_ids", []))
    cursor_ms = cur["cursor_ms"]

    # ID列挙は全ページ取得（1ページ=1コール100件）。異常量だけ LIST_PAGE_MAX で止め、
    # その場合は例外＝カーソル未前進で停止（取りこぼしを黙って確定させない）
    ids = []
    req = svc.users().messages().list(userId="me", q=f"after:{cursor_ms // 1000}", maxResults=100)
    pages = 0
    while req is not None:
        resp = req.execute()
        ids += [m["id"] for m in resp.get("messages", [])]
        pages += 1
        if pages >= LIST_PAGE_MAX:
            raise RuntimeError(f"新着一覧が {LIST_PAGE_MAX * 100} 件超え＝異常量")
        req = svc.users().messages().list_next(req, resp)

    # 一覧は新しい順で返るため【古い側から】上限件数まで処理する。
    # カーソルは処理済みの最大時刻で止まるので、未処理の新しい側は次回 poll の after: に必ず入る
    # （新しい側から処理してカーソルを進めると、切り捨てた古い側が永久欠落する）
    ids.reverse()
    overflow = max(0, len(ids) - LIST_HARD_CAP)
    if overflow:
        ids = ids[:LIST_HARD_CAP]

    recs, new_cursor = [], cursor_ms
    seen_pairs = []  # (message_id, internalDate) — 秒精度境界の重複除外窓の材料
    pend_local = {}
    for mid in ids:
        if mid in recent:
            continue
        meta = svc.users().messages().get(
            userId="me", id=mid, format="metadata",
            metadataHeaders=["From", "To", "Cc", "Subject", "Date",
                             "Authentication-Results"]).execute()
        labels = set(meta.get("labelIds") or [])
        if labels & {"DRAFT", "CHAT"}:
            continue
        internal = int(meta.get("internalDate", 0))
        if internal < cursor_ms - RECENT_WINDOW_MS:
            continue
        seen_pairs.append((mid, internal))
        if internal > new_cursor:
            new_cursor = internal
        h = _headers_map(meta)
        from_name, from_addr = parseaddr(h.get("from", ""))
        from_addr = from_addr.lower()
        to_pairs = [(hdec(n), a.lower()) for n, a in
                    getaddresses([h.get("to", ""), h.get("cc", "")]) if a]
        selfs = self_addrs or {acct}
        outgoing = "SENT" in labels or from_addr in selfs
        if outgoing:
            counterparts = [(n, a) for n, a in to_pairs if a not in selfs]
        else:
            counterparts = [(hdec(from_name), from_addr)] if from_addr and from_addr not in selfs else []
        if not counterparts:
            continue

        counts["new"] += 1
        verdicts = [(n, a, classify(a, lists)) for n, a in counterparts]
        ts = internal // 1000
        for n, a, v in verdicts:
            if v == "pending":
                p = pend_local.get(a) or dict(pending.get(a) or
                                              {"name": "", "count": 0, "first": ts, "in": 0, "out": 0})
                p["count"] += 1
                p["last"] = ts
                p["out" if outgoing else "in"] += 1
                if not p["name"] and n:
                    p["name"] = n
                pend_local[a] = p
        if any(v == "allow" for _, _, v in verdicts):
            full = svc.users().messages().get(userId="me", id=mid, format="full").execute()
            # From は偽装可能な非認証ヘッダ＝受信時は SPF/DKIM 判定を記録し蒸留側の警戒材料にする
            auth_res = h.get("authentication-results", "").lower()
            if outgoing:
                auth = "self"
            elif "spf=pass" in auth_res or "dkim=pass" in auth_res:
                auth = "pass"
            else:
                auth = "fail" if auth_res else "unknown"
            recs.append({
                "ts": ts,
                "account": acct,
                "dir": "out" if outgoing else "in",
                "from": from_addr,
                "from_name": hdec(from_name),
                # 無視リストのアドレスは宛先欄にも残さない（「記録を残さない」の一貫性）
                "to": [a for _, a in to_pairs
                       if a in selfs or classify(a, lists) != "ignore"],
                "subject": hdec(h.get("subject", "")),
                "body": extract_body(full.get("payload", {})),
                "thread_id": meta.get("threadId", ""),
                "message_id": mid,
                "auth": auth,
                "link": f"https://mail.google.com/mail/#all/{mid}",
            })
            counts["saved"] += 1
        elif all(v == "ignore" for _, _, v in verdicts):
            counts["ignored"] += 1
        else:
            counts["pending"] += 1

    # 重複除外窓＝新カーソル近傍のIDだけを追加保持（処理順の末尾ではなく時刻基準。
    # 300件超を処理したとき境界側のIDが窓から落ちて二重取得になるのを防ぐ）
    near = [m for m, ts_ms in seen_pairs if ts_ms >= new_cursor - RECENT_WINDOW_MS]
    recent_ids = (list(cur.get("recent_ids", [])) + near)[-300:]
    new_cur = {"cursor_ms": new_cursor, "recent_ids": recent_ids}
    if overflow:
        print(f"⚠️ 1回の処理上限 {LIST_HARD_CAP} 件到達。残り {overflow} 件（新しい側）は次回pollで取得")
    return new_cur, recs, pend_local, counts


def cmd_poll():
    lockf = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("gmail poll: 前回実行が継続中のためスキップ")
        return

    st = load_state()
    if st is None:
        st = {"v": 1, "baseline": int(time.time()), "accounts": {}}
        atomic_write(STATE_FILE, json.dumps(st, ensure_ascii=False))
        print(f"gmail poll: 初回＝baseline を現在時刻に設定（forward-only）")
    pending = load_pending()
    lists = parse_senders()
    # 社長が senders.md で許可/無視へ振り分けたアドレスは承認待ちから除去
    resolved = [a for a in list(pending) if classify(a, lists) != "pending"]
    if resolved:
        for a in resolved:
            del pending[a]
        atomic_write(PENDING_FILE, json.dumps(pending, ensure_ascii=False, indent=1))
        print(f"pending整理: 振り分け済み {len(resolved)} 件を承認待ちから除去")
    accounts = get_accounts()

    totals = {"new": 0, "saved": 0, "pending": 0, "ignored": 0}
    ok_accts = 0
    for acct in accounts:
        cur = dict(st["accounts"].get(acct) or {"cursor_ms": st["baseline"] * 1000, "recent_ids": []})
        try:
            svc = gmail_service(acct)
            new_cur, recs, pend_local, counts = _poll_account(
                svc, acct, cur, lists, pending, get_self_addrs())
        except Exception as e:
            print(f"⚠️ {acct}: 取得失敗（{type(e).__name__}: {str(e)[:120]}）＝カーソル未前進・次回自動再取得")
            continue
        # 成功したアカウントだけ反映。保存順序は raw → pending → state（カーソル）の固定。
        # state を先に進めて途中で落ちると、その間の raw/pending が「再取得されないのに
        # 保存もされていない」永久欠損になるため、カーソル前進は必ず最後
        if recs:
            RAW_DIR.mkdir(parents=True, exist_ok=True)
            by_month = {}
            for r in recs:
                m = time.strftime("%Y-%m", time.localtime(r["ts"]))
                by_month.setdefault(m, []).append(r)
            for m, rs in by_month.items():
                with open(RAW_DIR / f"{m}.jsonl", "a", encoding="utf-8") as f:
                    for r in rs:
                        f.write(json.dumps(r, ensure_ascii=False) + "\n")
                    f.flush()
                    os.fsync(f.fileno())
        pending.update(pend_local)
        atomic_write(PENDING_FILE, json.dumps(pending, ensure_ascii=False, indent=1))
        st["accounts"][acct] = new_cur
        atomic_write(STATE_FILE, json.dumps(st, ensure_ascii=False))
        for k in totals:
            totals[k] += counts[k]
        ok_accts += 1

    print(f"gmail poll done: acct_ok={ok_accts}/{len(accounts)} "
          f"new={totals['new']} saved={totals['saved']} "
          f"pending={totals['pending']} ignored={totals['ignored']} "
          f"承認待ちアドレス累計={len(pending)}")
    if ok_accts < len(accounts):
        sys.exit(1)


def cmd_pending():
    pending = load_pending()
    if not pending:
        print("承認待ちアドレスはありません")
        return
    rows = sorted(pending.items(), key=lambda kv: kv[1].get("last", 0), reverse=True)
    print(f"承認待ち {len(rows)} 件（senders.md の許可/無視に振り分けてください）")
    print(f"{'アドレス':<40} {'表示名':<20} {'件数':>4} {'受/送':>7} 最終")
    for addr, p in rows:
        last = time.strftime("%m/%d %H:%M", time.localtime(p.get("last", 0)))
        print(f"{addr:<40} {p.get('name', ''):<20} {p.get('count', 0):>4} "
              f"{p.get('in', 0):>3}/{p.get('out', 0):<3} {last}")


def main():
    DATA.mkdir(parents=True, exist_ok=True)
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "login":
        cmd_login()
    elif cmd == "login-code":
        cmd_login_code(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "auth":
        cmd_auth()
    elif cmd == "poll":
        cmd_poll()
    elif cmd == "pending":
        cmd_pending()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
