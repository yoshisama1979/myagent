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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _mail_strip  # noqa: E402  引用・署名の除去（検証ツール bin/mail-strip.py と同じ実装を共有）

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


# 日本語メールで実際に使われる文字コード。宣言が無い／間違っている／Python が知らない名前
# （x-sjis 等）のときに順に試す。ISO-2022-JP はエスケープシーケンスで自己識別でき、
# CP932 は Shift_JIS の上位互換（機種依存文字も読める）なので Shift_JIS より先に置く。
# ★utf-16 は入れない（Codex🔴3）：Python の utf-16 は BOM が無くてもネイティブエンディアンで
#   デコードできてしまうため、他が全滅した壊れたバイト列を「漢字らしい文字列」に化けさせる。
#   実測で b"\x80\x80\x80\x80" が「肀肀」になり、日本語らしさ 1.00 で成功扱いになった＝
#   errors="replace" で � にするより悪い（壊れたことに誰も気づけない）。
#   BOM がある場合と、宣言が明示的に utf-16 系の場合だけ下で個別に扱う。
FALLBACK_CHARSETS = ("utf-8", "iso-2022-jp", "cp932", "euc-jp")

# デコードできなかった／中身が文章に見えなかった本文の記録（poll の最後に鳴らすため）
DECODE_FAILURES = []
MIN_DECODE_SCORE = 0.5    # これ未満は「読めたつもり」を疑う（★提案既定値・本文は捨てない）
RAW_KEEP_MAX = 200_000    # デコード失敗時に原バイトを残す上限（★提案既定値・失敗回のみ）


def _jp_score(t: str) -> float:
    """日本語の文章としてもっともらしいか（0〜1）。

    「厳格にデコードできた＝正しい」ではない。実測で2通り外れた：
      ・ISO-2022-JP は全バイトが7bit なので UTF-8 として“成功”する（中身はエスケープ記号の羅列）
      ・EUC-JP はたまたま CP932 としても妥当なバイト列になり、化けたまま“成功”する
    そこで、デコードできた候補すべてを「日本語らしさ」で採点して選ぶ。
    """
    good = bad = 0
    for ch in t:
        o = ord(ch)
        if ch.isascii():
            good += 1 if (ch.isprintable() or ch in "\r\n\t") else 0
            bad += 0 if (ch.isprintable() or ch in "\r\n\t") else 1   # 制御文字＝化けの兆候
        elif 0x3000 <= o <= 0x30FF or 0x4E00 <= o <= 0x9FFF or 0xFF01 <= o <= 0xFF60:
            good += 1                      # 記号・かな・漢字・全角英数＝日本語の本文らしい
        elif 0xFF61 <= o <= 0xFF9F:
            bad += 1                       # 半角カタカナが大量＝化けの典型
        else:
            bad += 1                       # 私用領域・珍しい漢字など
    return good / (good + bad) if (good + bad) else 0.0


def _decode_bytes(raw: bytes, declared: str):
    """(本文, 使った文字コード, 失敗したか) を返す。

    ★errors="replace" を最初から使わない：読めないバイトを黙って � に置き換えて捨てるため、
      あとから復元できない。実際 07月の28通中3通・2,562文字がこれで失われていた
      （805字中705字が � など）。厳格にデコードできた候補を集め、日本語らしさで選ぶ。
      全滅したときだけ置換に落とすが、そのときは必ず記録して鳴らす（黙って壊さない）。
    """
    # ① 自己識別できるもの（BOM・エスケープシーケンス）を先に確定させる＝推測に頼らない
    for bom, enc in ((b"\xef\xbb\xbf", "utf-8-sig"), (b"\xff\xfe", "utf-16"), (b"\xfe\xff", "utf-16")):
        if raw.startswith(bom):
            try:
                return raw.decode(enc), enc, False
            except UnicodeDecodeError:
                break
    # ISO-2022-JP はエスケープシーケンスで自己識別できる＝他の候補より確実なので先に確定させる
    if b"\x1b$" in raw or b"\x1b(J" in raw:
        try:
            return raw.decode("iso-2022-jp"), "iso-2022-jp", False
        except UnicodeDecodeError:
            pass
    # ② 宣言が明示的に utf-16 系のときだけ試す（BOM 無しの推測には使わない＝上の注記の理由）
    if (declared or "").lower().replace("_", "-") in ("utf-16", "utf-16le", "utf-16be"):
        try:
            return raw.decode(declared), declared, False
        except (UnicodeDecodeError, LookupError):
            pass
    cands, tried = [], []
    for cs in [declared] + [c for c in FALLBACK_CHARSETS if c.lower() != (declared or "").lower()]:
        if not cs:
            continue
        tried.append(cs)
        try:
            txt = raw.decode(cs)                       # errors 既定＝strict
        except (UnicodeDecodeError, LookupError):
            continue
        # 宣言された文字コードは僅差なら優先する（送り主の申告を無闇に疑わない）
        cands.append((_jp_score(txt) + (0.02 if cs == declared else 0), txt, cs))
    if cands:
        score, txt, cs = max(cands, key=lambda x: x[0])
        # 厳格にデコードできても中身が文章に見えないことがある（例：b"\x80\x80\x80\x80" は cp932 で
        # 「通る」が中身は制御文字）。失敗として記録だけする＝本文は返すので情報は失わないが、
        # 「読めたつもり」で静かに通過させない（Codex🔴4）。日本語以外の本文も低得点になり得るため、
        # ここで本文を捨てたり置換したりはしない。
        if txt.strip() and score < MIN_DECODE_SCORE:
            return txt, f"{cs}(低品質 score={score:.2f})", True
        return txt, cs, False
    # ここに来たら本当に読めない。原本は Gmail 側に残っているので後から再取得できる
    return raw.decode("utf-8", errors="replace"), f"replace(試行: {'/'.join(tried)})", True


def _decode_part(part, fetch_part=None) -> str:
    b = part.get("body") or {}
    data = b.get("data")
    if not data and b.get("attachmentId") and fetch_part:
        try:
            data = fetch_part(b["attachmentId"])
        except Exception as e:
            DECODE_FAILURES.append({"charset": f"attachment-fetch-error({type(e).__name__})", "b64": ""})
            return ""
    if not data:
        return ""
    # パディングは固定 "===" ではなく長さから計算する（不正な長さを黙って通さない）
    raw = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))
    size = b.get("size")
    if isinstance(size, int) and size > 0 and abs(len(raw) - size) > 8:
        # Gmail が申告したサイズと合わない＝取得が欠けている可能性。捨てずに記録だけする
        DECODE_FAILURES.append({"charset": f"size-mismatch({len(raw)}≠{size})", "b64": ""})
    txt, used, failed = _decode_bytes(raw, _part_charset(part))
    if failed:
        # ★読めなかった原バイトを残す（Codex🔴5）：Gmail 側が消えた・認証が切れた場合に
        #   再取得できなくなるため、こちらにも復元の種を持っておく。失敗した回だけなので量は増えない。
        DECODE_FAILURES.append({"charset": used, "b64": base64.b64encode(raw[:RAW_KEEP_MAX]).decode()})
    return txt


def attachment_fetcher(svc, message_id):
    """本文パートが別取得になっていたとき、その中身（base64）を取りに行く関数を返す"""
    def fetch(attachment_id):
        return (svc.users().messages().attachments()
                .get(userId="me", messageId=message_id, id=attachment_id)
                .execute() or {}).get("data", "")
    return fetch


def with_decode_note(rec: dict, issues) -> dict:
    """デコードに問題があった回だけ、状態と原バイトを記録に足す。

    問題なしのときは何も足さない＝全件に余計な欄を増やさない。蒸留側は decode_status が
    あるかどうかだけ見れば「この本文は疑わしい」と分かる。
    """
    if not issues:
        return rec
    rec = dict(rec, decode_status="failed",
               decode_detail=" / ".join(i["charset"] for i in issues))
    b64 = next((i["b64"] for i in issues if i.get("b64")), "")
    if b64:
        rec["raw_body_base64"] = b64
    return rec


def with_stripped(rec: dict, body: str) -> dict:
    """本文を差し替えたレコードを返す（body / body_new / strip_method を必ず揃える）。

    body だけ直して body_new を置き去りにすると、修復したのに古い（化けた本文から作った）
    抽出結果が残る。3つを別々に組み立てる場所が増えるほど、その事故が起きやすくなる。
    """
    new_txt, method = strip_body(body)
    return dict(rec, body=cap_body(body), body_new=cap_body(new_txt), strip_method=method)


def strip_body(txt: str):
    """引用と自社署名を落とした「今回書かれた部分」を返す (本文, 判定)。

    返信が積み重なると引用が本文の何倍にもなる（実測32通で141,571字→11,361字＝92%が引用と署名）。
    蒸留に渡す量がそのまま無駄になるので取り込み時に落とす。
    ★原本（body）は消さない：抽出は必ずどこかで外れるので、後から作り直せる形にしておく。
    ★取り込み時は同スレッドの過去分も学習済み署名も手元に無いが、それ抜きでも 92.0% 落ちる
      （引用ヘッダと自社署名の区切りだけで足りる）ので、単体で完結させている。
    """
    try:
        r = _mail_strip.strip_quotes(txt)
        return r["text"], r["method"]
    except Exception as e:                     # 抽出の失敗で取り込み自体を止めない
        return txt, f"error({type(e).__name__})"


def extract_body(payload, fetch_part=None) -> str:
    """text/plain 優先・無ければ text/html をタグ除去。添付は見ない。

    ★body.data が無くても諦めない（Codex🔴6）：Gmail は本文パートのデータを別取得にすることがあり、
      その場合 data が空で attachmentId が入る。これは「添付ファイル」とは限らず本文でも起きるため、
      data が無いパートを一律に飛ばすと、エラーも出さずに空本文を保存してしまう（静かに壊れる）。
      fetch_part(attachment_id) -> base64文字列 を渡せば取りに行く（渡さなければ従来どおり）。
    """
    import html as html_mod
    DECODE_FAILURES.clear()          # この1通ぶんの失敗だけを呼び出し側へ渡す
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
        b = p.get("body") or {}
        if not b.get("data") and not b.get("attachmentId"):
            continue
        if mt == "text/plain" and plain is None:
            plain = p
        elif mt == "text/html" and html is None:
            html = p
    part = plain or html
    if part is None:
        return ""
    txt = _decode_part(part, fetch_part)
    if plain is None:
        txt = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", txt, flags=re.S | re.I)
        txt = re.sub(r"<[^>]+>", " ", txt)
        txt = html_mod.unescape(txt)
        txt = re.sub(r"[ \t　]+", " ", txt)
    txt = re.sub(r"\n{3,}", "\n\n", txt).strip()
    return txt


def cap_body(txt: str) -> str:
    """保存用に上限をかける。

    ★順序が大事：以前はここ（extract_body の中）で切ってから保存していたため、
      引用が長い返信では「引用で10,000字を使い切り、その先にある本文が消える」経路があった
      （実測で32通中6通が上限ちょうど＝10,008字で頭打ちになっていた）。
      いまは【抽出してから】上限をかけるので、抽出結果が切られることは実質なくなる。
    """
    if len(txt) > BODY_MAX:
        return txt[:BODY_MAX] + "\n…(以降省略)"
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
            # 抽出は【上限をかける前】の本文に対して行う（長い引用で本文が消えないように）
            body_txt = extract_body(full.get("payload", {}), attachment_fetcher(svc, mid))
            decode_issues = list(DECODE_FAILURES)
            body_new, strip_method = strip_body(body_txt)
            recs.append(with_decode_note({
                "ts": ts,
                "account": acct,
                "dir": "out" if outgoing else "in",
                "from": from_addr,
                "from_name": hdec(from_name),
                # 無視リストのアドレスは宛先欄にも残さない（「記録を残さない」の一貫性）
                "to": [a for _, a in to_pairs
                       if a in selfs or classify(a, lists) != "ignore"],
                "subject": hdec(h.get("subject", "")),
                # body＝原本（上限つき・従来どおり）／body_new＝引用と署名を落とした今回分。
                # 原本を残すのは、抽出が外れたとき後から作り直せるようにするため。
                "body": cap_body(body_txt),
                "body_new": cap_body(body_new),
                "strip_method": strip_method,
                "thread_id": meta.get("threadId", ""),
                "message_id": mid,
                "auth": auth,
                "link": f"https://mail.google.com/mail/#all/{mid}",
            }, decode_issues))
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


def cmd_repair(apply: bool):
    """保存済みで文字化けしている本文を、Gmail から取り直して修復する（読み取り専用API）。

    契機＝2026-07-31。errors="replace" が読めないバイトを黙って � に置き換えていたため、
    28通中3通・2,562文字がローカルで失われていた。原本は Gmail 側に残っており
    message_id も保存しているので取り直せる（失われたのはこちらのコピーだけ）。
    既定は下見のみ。--apply を付けたときだけ書き換える。
    """
    targets = []
    for p in sorted(RAW_DIR.glob("*.jsonl")):
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines()):
            if not line.strip():
                continue
            d = json.loads(line)
            n = (d.get("body") or "").count("�")
            if n:
                targets.append((p, i, d, n))
    if not targets:
        print("文字化けしている本文はありません")
        return
    print(f"文字化けを含む本文: {len(targets)} 件")
    fixed = {}
    for p, i, d, n in targets:
        acct, mid = d.get("account", ""), d.get("message_id", "")
        before = len(d.get("body") or "")
        try:
            svc = gmail_service(acct)
            full = svc.users().messages().get(userId="me", id=mid, format="full").execute()
            body = extract_body(full.get("payload", {}), attachment_fetcher(svc, mid))
        except Exception as e:                     # 認証切れ・削除済み等でも他の件を止めない
            print(f"  ❌ 取得失敗 {mid[:12]}… （{type(e).__name__}）")
            continue
        left = body.count("�")
        mark = "✅" if left == 0 else ("△" if left < n else "❌")
        print(f"  {mark} {mid[:12]}… {before:6d}字(�{n:4d}) → {len(body):6d}字(�{left:4d})")
        if left < n:
            # body だけ直すと body_new/strip_method が化けた本文から作った古い値のまま残る（Codex🔴8）
            fixed[(p, i)] = with_stripped(d, body)
    if not fixed:
        print("修復できたものはありません（原本側の文字コードが判別不能な可能性）")
        return
    if not apply:
        print(f"\n{len(fixed)} 件が修復可能です。書き換えるには --apply を付けて再実行してください（下見のみ・未書き換え）")
        return
    # 「書けた件数」を報告する＝競合で中止したのに「修復しました」と出すと嘘になる（Codex🔴7）
    n = rewrite_rows(fixed)
    print(f"\n{n} 件を修復しました" + ("" if n == len(fixed) else f"（{len(fixed) - n} 件は書き換えできず＝再実行してください）"))


def rewrite_rows(changed) -> int:
    """{(パス, 行番号): 新しいレコード} を raw/*.jsonl へ書き戻し、実際に書けた件数を返す。

    ★読み込み→書き戻しの間に cron の poll が追記すると、その1通が消える。poll は2時間おきに走り、
      修復は Gmail への往復で分単位かかるため現実的な窓がある。サイズと更新時刻を控えて、
      変わっていたら書かずに中止する（黙って上書きしない）。
    """
    written = 0
    for p in {k[0] for k in changed}:
        rows = {k: v for k, v in changed.items() if k[0] == p}
        # poll と同じロックを取ってから読み直す＝「確認したあとに追記される」窓を無くす（Codex🔴7）。
        # サイズと更新時刻の比較だけでは、確認後・置換前の追記を消してしまう（compare-and-swap ではない）。
        with open(LOCK_FILE, "a+") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            try:
                lines = p.read_text(encoding="utf-8").splitlines()
                stale = [i for (_, i) in rows if i >= len(lines)]
                if stale:
                    print(f"  ⚠️ {p.name} の行構成が変わっています＝書き換えを中止します（もう一度実行してください）")
                    continue
                for (_, i), d in rows.items():
                    # 行番号だけで上書きすると、間に行が入ったとき別のメールを潰す。ID で本人確認する
                    cur = json.loads(lines[i])
                    if cur.get("message_id") != d.get("message_id"):
                        print(f"  ⚠️ {p.name}:{i} の内容が入れ替わっています＝この行はスキップします")
                        continue
                    lines[i] = json.dumps(d, ensure_ascii=False)
                    written += 1
                tmp = p.with_suffix(p.suffix + f".tmp{os.getpid()}")   # 固定名だと同時実行で衝突する
                tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
                tmp.replace(p)
            finally:
                fcntl.flock(lk, fcntl.LOCK_UN)
    return written


def cmd_restrip(apply: bool):
    """保存済みの本文に body_new（引用・署名を落とした今回分）を付け直す。

    取り込み時の抽出を入れる前に保存された分を揃えるため。Gmail への通信は不要
    （手元の body から計算するだけ）＝原本を再取得する repair とは別物。
    """
    changed, o, k = {}, 0, 0
    for p in sorted(RAW_DIR.glob("*.jsonl")):
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines()):
            if not line.strip():
                continue
            d = json.loads(line)
            txt = d.get("body") or ""
            nd = with_stripped(d, txt)
            if (d.get("body_new"), d.get("strip_method")) == (nd["body_new"], nd["strip_method"]):
                continue
            o += len(txt)
            k += len(nd["body_new"])
            changed[(p, i)] = nd
    if not changed:
        print("付け直す対象はありません（すべて最新）")
        return
    print(f"対象 {len(changed)} 通: {o:,} 字 → {k:,} 字（削減 {100 - 100 * k / (o or 1):.1f}%）")
    if not apply:
        print("書き換えるには --apply を付けて再実行してください（下見のみ・未書き換え）")
        return
    n = rewrite_rows(changed)
    print(f"{n} 通に body_new を付けました" + ("" if n == len(changed) else f"（{len(changed) - n} 通は書き換えできず＝再実行してください）"))


def main():
    DATA.mkdir(parents=True, exist_ok=True)
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "repair":
        cmd_repair("--apply" in sys.argv)
        return
    if cmd == "restrip":
        cmd_restrip("--apply" in sys.argv)
        return
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
