#!/usr/bin/env bash
# メール取り込み（bin/gmail-fetch.py）の回帰テスト。
#
# 契機＝2026-08-10 rules/testing.md 新設時の空白地帯🔴1位（2h cron 常駐・本文欠落事故の前歴あり・
# OAuth 経路以外も一度も自動テストされていなかった）。ここで固定するのは過去に実際に起きた事故：
#   ・文字コード誤判定で 28通中3通・2,562字が � で黙って消えた（→ 候補採点方式）
#   ・b"\x80\x80\x80\x80" が utf-16 で「肀肀」score1.00 の成功扱いになった（→ utf-16 をフォールバックから除外）
#   ・引用で10,000字を使い切り本文が消えた（→ 抽出してから上限をかける順序）
#   ・修復の書き戻しが別のメールを潰しうる（→ message_id の本人確認）
# ネットワークには一切出ない（OAuth・API 呼び出しはテストしない＝疎通は `gmail-fetch.py auth` が担当）。
#
# 触ったら必ず流すこと：bash bin/test-gmail-fetch.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/gmail-fetch.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import base64, importlib.util, json, sys, tempfile
from pathlib import Path

proj = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("gf", proj / "bin/gmail-fetch.py")
gf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gf)

P = N = 0
def ok(m):
    global P; P += 1; print(f"  ✅ {m}")
def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d: print(f"      → {d}")

# 本番のファイルに触れない（testing.md §6-1）
T = Path(tempfile.mkdtemp())
gf.DATA = T
gf.SENDERS_FILE = T / "senders.md"
gf.PENDING_FILE = T / "pending.json"
gf.STATE_FILE = T / "state.json"
gf.LOCK_FILE = T / ".poll.lock"
gf.RAW_DIR = T / "raw"; gf.RAW_DIR.mkdir()
for p in (gf.SENDERS_FILE, gf.PENDING_FILE, gf.STATE_FILE, gf.LOCK_FILE, gf.RAW_DIR):
    if not str(p).startswith(str(T)):
        print(f"❌ テストの書き先が一時ディレクトリの外: {p}", file=sys.stderr); sys.exit(2)

b64u = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")

print("=== 送信者の振り分け（許可していない相手の本文は取得しない＝ここが門番）===")

gf.SENDERS_FILE.write_text("""# コメント
## 許可（本文を取得し蒸留対象にする）
@example.co.jp        # ドメイン許可
taro@other.com
special@blocked.jp    # 無視ドメインの中の1人だけ許可
## 無視（承認待ちにも出さない）
@blocked.jp
spam@example.co.jp    # 許可ドメインの中の1人だけ無視
""", encoding="utf-8")
lists = gf.parse_senders()

for addr, want, why in [
    ("hanako@example.co.jp", "allow",  "ドメイン許可が効く"),
    ("taro@other.com",       "allow",  "完全一致の許可が効く"),
    ("dm@blocked.jp",        "ignore", "無視ドメインが効く"),
    ("SPAM@EXAMPLE.CO.JP",   "ignore", "完全一致の無視はドメイン許可より優先（大文字でも）"),
    ("special@blocked.jp",   "allow",  "完全一致の許可は無視ドメインより優先"),
    ("unknown@nowhere.jp",   "pending","どのリストにも無ければ承認待ち"),
]:
    got = gf.classify(addr, lists)
    (ok if got == want else ng)(f"{why}（{got}）")

gf.SENDERS_FILE.write_text("taro@nosec.com\n## 許可\n", encoding="utf-8")
lists = gf.parse_senders()
(ok if gf.classify("taro@nosec.com", lists) == "pending" else ng)(
    "セクション見出しより前の行は無効（許可に化けない）")

print("\n=== 文字コード判定（過去の実事故を固定）===")

txt, used, failed = gf._decode_bytes("こんにちは。打ち合わせの件です。".encode("utf-8"), "utf-8")
(ok if not failed and "こんにちは" in txt else ng)(f"普通の UTF-8 が通る（{used}）")

txt, used, failed = gf._decode_bytes(b"\xef\xbb\xbf" + "本文".encode("utf-8"), "")
(ok if not failed and txt == "本文" and used == "utf-8-sig" else ng)(f"UTF-8 BOM を自己識別（{used}）")

raw = "会議は明日の10時からです。".encode("iso-2022-jp")
txt, used, failed = gf._decode_bytes(raw, "")
(ok if not failed and used == "iso-2022-jp" and "明日" in txt else ng)(
    f"ISO-2022-JP をエスケープで自己識別（{used}）＝UTF-8として“成功”させない")

raw = "お世話になっております。見積書を添付いたします。".encode("euc-jp")
txt, used, failed = gf._decode_bytes(raw, "")
(ok if "見積書" in txt and not failed else ng)(
    f"EUC-JP を日本語らしさで正しく選ぶ（{used}）＝cp932 で化けたまま通さない")

txt, used, failed = gf._decode_bytes(b"\x80\x80\x80\x80", "")
(ok if failed else ng)(f"壊れたバイト列は失敗として記録（{used}）＝utf-16で「肀肀」に化けない")

# ※ b"\xb1\xb2"（偶数長）は EUC-JP の正当な漢字1文字として読めるため「低品質」にならないのが正
#   （曖昧なバイト列を日本語らしい方に読むのは設計どおり）。ゲートの回帰には
#   EUC-JP として成立しない奇数長の半角カナ列を使う＝cp932 で「ｱｱｱ」（低品質）しか候補が残らない。
raw = b"\xb1\xb1\xb1"
txt, used, failed = gf._decode_bytes(raw, "")
(ok if failed and "低品質" in used else ng)(
    f"短くても低品質は疑う（{used}）＝len>=8 ゲートの回帰")

txt, used, failed = gf._decode_bytes(b"hello, this is ascii.", "cp932")
(ok if not failed and used == "cp932" else ng)(f"僅差なら宣言された文字コードを尊重（{used}）")

txt, used, failed = gf._decode_bytes(b"", "")
(ok if txt == "" else ng)("空バイトで落ちない")

(ok if "utf-16" not in [c.lower() for c in gf.FALLBACK_CHARSETS] else ng)(
    "フォールバック候補に utf-16 が入っていない（Codex🔴3 の恒久化）")

print("\n=== charset ヘッダの読み取り ===")
part = {"headers": [{"name": "Content-Type", "value": 'text/plain; charset = "Shift_JIS"'}]}
(ok if gf._part_charset(part) == "Shift_JIS" else ng)("= の前後に空白・引用符があっても読める")
(ok if gf._part_charset({"headers": []}) == "utf-8" else ng)("無宣言は utf-8 とみなす")

print("\n=== 本文抽出（text/plain 優先・添付を本文と誤認しない）===")

def part_of(mime, text, **kw):
    d = {"mimeType": mime, "body": {"data": b64u(text.encode("utf-8"))}}
    d.update(kw); return d

payload = {"mimeType": "multipart/alternative", "parts": [
    part_of("text/html", "<p>HTML版</p>"),
    part_of("text/plain", "プレーン版"),
]}
got = gf.extract_body(payload)
(ok if got == "プレーン版" else ng)(f"plain と html があれば plain（{got!r}）")

payload = {"mimeType": "multipart/mixed", "parts": [
    part_of("text/html", "<style>p{color:red}</style><p>本文&amp;A</p><script>alert(1)</script>"),
]}
got = gf.extract_body(payload)
(ok if "本文&A" in got and "alert" not in got and "color" not in got else ng)(
    f"html のみ＝script/style を落としタグ除去・実体参照を戻す（{got!r}）")

payload = {"mimeType": "multipart/mixed", "parts": [
    part_of("text/plain", "これは添付の中身", filename="memo.txt"),
    part_of("text/plain", "これが本文"),
]}
got = gf.extract_body(payload)
(ok if got == "これが本文" else ng)(f"filename 付き text/plain（添付）を本文にしない（{got!r}）")

# 本文パートが別取得（attachmentId）のケース＝Codex🔴6 の回帰
payload = {"mimeType": "text/plain", "body": {"attachmentId": "ATT1"}}
got = gf.extract_body(payload, fetch_part=lambda aid: b64u("別取得の本文".encode("utf-8")))
(ok if got == "別取得の本文" else ng)(f"body.data 無し＋attachmentId は取りに行く（{got!r}）")

def boom(aid):
    raise RuntimeError("network down")
got = gf.extract_body({"mimeType": "text/plain", "body": {"attachmentId": "A"}}, fetch_part=boom)
(ok if got == "" and any("attachment-fetch-error" in i["charset"] for i in gf.DECODE_FAILURES)
 else ng)("別取得の失敗は空を返しつつ記録に残す（黙って成功扱いしない）")

got = gf.extract_body({"mimeType": "text/plain", "body": {}})
(ok if got == "" else ng)("data も attachmentId も無ければ空（落ちない）")

print("\n=== 上限の順序（引用が長くても本文を失わない）===")

t = "x" * (gf.BODY_MAX + 500)
capped = gf.cap_body(t)
(ok if capped.endswith("…(以降省略)") and len(capped) < len(t) else ng)("上限超は印つきで切る")
(ok if gf.cap_body("短い") == "短い" else ng)("上限内は不変")

# 引用が BODY_MAX を超えるメール：body は切られるが body_new（今回分）は生き残る
quote = "> 引用の行です\n" * 1200            # 約16,000字の引用
body = "承知しました。明日伺います。\n\n2026年1月1日(月) 10:00 山田 <a@b.example> さんは書きました:\n" + quote
rec = gf.with_stripped({"message_id": "m1"}, body)
(ok if rec["body"].endswith("…(以降省略)") else ng)("原本 body は上限で切られる")
(ok if "承知しました" in rec["body_new"] and len(rec["body_new"]) < 200 else ng)(
    f"body_new は引用を落とした今回分だけ（{len(rec['body_new'])}字）＝「引用が上限を食い潰して本文が消える」の再発防止")
(ok if rec["strip_method"] and rec["strip_method"] != "none" else ng)(
    f"strip_method が判定を持つ（{rec['strip_method']}）")

print("\n=== デコード失敗の記録（黙って壊さない）===")
rec = gf.with_decode_note({"a": 1}, [])
(ok if "decode_status" not in rec else ng)("問題なしなら欄を増やさない")
rec = gf.with_decode_note({"a": 1}, [{"charset": "replace(試行: utf-8)", "b64": "QUJD"}])
(ok if rec.get("decode_status") == "failed" and rec.get("raw_body_base64") == "QUJD" else ng)(
    "失敗時は decode_status と原バイトが残る（後から復元できる）")

print("\n=== 書き戻し（修復が別のメールを潰さない）===")

raw_f = gf.RAW_DIR / "2026-01.jsonl"
rows = [{"message_id": f"m{i}", "body": f"本文{i}"} for i in range(3)]
raw_f.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")

n = gf.rewrite_rows({(raw_f, 1): {"message_id": "m1", "body": "修復済み"}})
lines = [json.loads(l) for l in raw_f.read_text(encoding="utf-8").splitlines()]
(ok if n == 1 and lines[1]["body"] == "修復済み" else ng)(f"ID が一致すれば書き戻す（written={n}）")
(ok if lines[0]["body"] == "本文0" and lines[2]["body"] == "本文2" else ng)("他の行は無傷")

n = gf.rewrite_rows({(raw_f, 2): {"message_id": "違うID", "body": "乗っ取り"}})
lines = [json.loads(l) for l in raw_f.read_text(encoding="utf-8").splitlines()]
(ok if n == 0 and lines[2]["body"] == "本文2" else ng)(
    f"message_id が食い違う行は書かない（written={n}）＝行がずれても別のメールを潰さない")

n = gf.rewrite_rows({(raw_f, 99): {"message_id": "m0", "body": "x"}})
(ok if n == 0 else ng)(f"行番号が範囲外ならファイルごと中止（written={n}）＝poll の追記と競合しても消さない")

print("\n=== 読み取り専用（送信・削除・既読化のコードを持たない）===")
src = (proj / "bin/gmail-fetch.py").read_text(encoding="utf-8")
bad = [w for w in (".send(", "messages().delete", "messages().trash", "messages().modify",
                   "gmail.send", "gmail.modify") if w in src]
(ok if not bad else ng)(f"書き込み系 API を呼んでいない（{bad or 'なし'}）")
(ok if 'SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]' in src else ng)(
    "スコープは gmail.readonly のみ")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
