#!/usr/bin/env bash
# メール本文の抽出（bin/_mail_strip.py）と文字コード判定（bin/gmail-fetch.py）の回帰テスト。
#
# 契機＝2026-08-03 Codex レビュー。実データ32通での検証（削減92%・切りすぎ0通）は
# 「そのとき届いていたメールの分布」に対する確認でしかなく、境界条件を保証していなかった。
# 実際、ボトムポスト・本文中の From:・日付で始まる見出しは本文が丸ごと消えていた。
# 削減率は切りすぎを検出できない指標（切るほど数字が良くなる）ため、ここで形を固定する。
#
# 触ったら必ず流すこと：bash bin/test-mail-strip.sh
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$PROJ/bin/_mail_strip.py" ] || { echo "❌ 起動位置がおかしい: $PROJ" >&2; exit 2; }

python3 - "$PROJ" <<'PYEOF'
import sys, importlib.util
from pathlib import Path

proj = Path(sys.argv[1])
sys.path.insert(0, str(proj / "bin"))
from _mail_strip import strip_quotes                      # noqa: E402
spec = importlib.util.spec_from_file_location("gf", proj / "bin/gmail-fetch.py")
gf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gf)

P = N = 0


def ok(m):
    global P; P += 1; print(f"  ✅ {m}")


def ng(m, d=""):
    global N; N += 1; print(f"  ❌ {m}")
    if d:
        print(f"      → {d}")


def keeps(name, body, must_have, must_not=()):
    """抽出結果に must_have が残り、must_not が消えていること"""
    r = strip_quotes(body)
    miss = [s for s in must_have if s not in r["text"]]
    left = [s for s in must_not if s in r["text"]]
    if miss:
        ng(name, f"消えてはいけない語が消えた: {miss} / 判定={r['method']} 結果={r['text'][:60]!r}")
    elif left:
        ng(name, f"落とすべき語が残った: {left} / 判定={r['method']}")
    else:
        ok(f"{name}（{r['method']}）")


print("=== 本文が消えない（切りすぎ防止）===")

keeps("ボトムポスト＝引用が先・返信が後ろ",
      "> 過去の質問1\n> 過去の質問2\n\n承知しました。明日対応いたします。",
      ["承知しました。明日対応いたします。"], ["過去の質問1"])

# 引用が1行しかない場合は切断の手がかりとして弱いため、あえて何も落とさない（冗長 ＞ 欠落）。
# ここで検証したいのは「前後どちらの地の文も生き残ること」＝引用が残るのは許容する。
keeps("引用の前後どちらにも地の文がある（1行引用は落とさない）",
      "お世話になります。\n\n> ご質問の件\n\n以上、よろしくお願いいたします。",
      ["お世話になります。", "以上、よろしくお願いいたします。"])

keeps("本文中の From: では切らない",
      "ご確認ください。\n\nFrom: 営業部への確認内容\n・見積の再提出をお願いします\n・納期は8月末を希望します",
      ["見積の再提出をお願いします", "納期は8月末を希望します"])

keeps("日付で始まる見出しでは切らない",
      "2026年8月3日(月) 対応事項：\n・サーバー再起動をお願いします\n・DBバックアップ確認をお願いします",
      ["サーバー再起動をお願いします", "DBバックアップ確認をお願いします"])

keeps("インライン返信は回答を残す",
      "> 納期はいつですか\n8月末を予定しています\n> 金額は\n50万円です。ご検討ください。",
      ["8月末を予定しています", "50万円です。ご検討ください。"])

r = strip_quotes("> 引用だけ\n> 引用だけ")
ok("引用しかない本文でも例外にならない") if isinstance(r["text"], str) else ng("引用のみ")

print("\n=== 引用と署名は落ちる ===")

keeps("トップポスト＝引用ヘッダで切る",
      "8月5日で問題ありません。\n\n2026年8月3日(月) 10:00 相手 <x@example.com>:\n> 打ち合わせの日程ですが\n> いかがでしょうか",
      ["8月5日で問題ありません。"], ["打ち合わせの日程ですが"])

keeps("Outlook形式＝ヘッダ集合が揃えば切る",
      "承知しました。対応いたします。\n\n差出人: 山田太郎\n送信日時: 2026年8月3日 10:00\n宛先: 松田様\n件名: 見積の件\n\nお世話になっております。",
      ["承知しました。対応いたします。"], ["お世話になっております。"])

keeps("自社署名（┛）から下は落とす",
      "了解いたしました。\n\n┛┛┛┛┛┛┛┛┛┛┛┛\n株式会社はなさか\nTEL 000-0000-0000",
      ["了解いたしました。"], ["TEL 000-0000-0000"])

keeps("インライン返信でも自社署名は落とす",
      "> ご確認ください\n確認しました。問題ありません。\n> よろしくお願いします\n┛┛┛┛┛┛┛┛┛┛┛┛\n株式会社はなさか",
      ["確認しました。問題ありません。"], ["株式会社はなさか"])

print("\n=== 安全弁 ===")
r = strip_quotes("2026年8月3日(月) 10:00 相手 <x@example.com>:\n> 引用\n> 引用")
ok("全部が引用なら空でもよい（地の文が無い）") if not r["suspect"] else ng("誤って suspect")

print("\n=== 文字コードの判定 ===")
S = "お世話になっております。株式会社はなさかの吉田です。"
for cs, decl in [("iso-2022-jp", ""), ("cp932", "x-sjis"), ("euc-jp", "utf-8"),
                 ("utf-8", "utf-8"), ("cp932", "shift_jis"), ("utf-8", "")]:
    t, used, failed = gf._decode_bytes(S.encode(cs), decl)
    (ok if t == S and not failed else ng)(f"{cs} 実体／{decl or '宣言なし'} → {used}")

t, used, failed = gf._decode_bytes(b"\x80\x80\x80\x80", "")
(ok if failed else ng)(f"文章に見えないバイト列は失敗として記録する（{used}）")

t, used, failed = gf._decode_bytes("あ".encode("utf-8-sig"), "")
(ok if t == "あ" else ng)(f"UTF-8 BOM を取り除く（{used} → {t!r}）")

t, used, failed = gf._decode_bytes("あいう".encode("utf-16"), "")
(ok if t == "あいう" else ng)(f"BOM 付き UTF-16 は読める（{used}）")

# ★BOM 無しの UTF-16 を推測に使うと、壊れたバイト列を「漢字」に化けさせる（Codex🔴3）
t, used, failed = gf._decode_bytes(b"\x80\x80\x80\x80", "")
(ok if "肀" not in t else ng)("BOM 無しで utf-16 を推測しない（壊れたバイトを漢字にしない）")

print("\n=== 本文パートが別取得（attachmentId）でも取りこぼさない ===")
import base64                                              # noqa: E402

BODY = "お世話になっております。ご確認をお願いいたします。"
enc = base64.urlsafe_b64encode(BODY.encode()).decode()
payload_att = {"mimeType": "text/plain",
               "headers": [{"name": "Content-Type", "value": "text/plain; charset=UTF-8"}],
               "body": {"attachmentId": "ATT1", "size": len(BODY.encode())}}

t = gf.extract_body(payload_att, lambda aid: enc if aid == "ATT1" else "")
(ok if t == BODY else ng)(f"attachmentId の本文を取りに行く（{t[:20]!r}）")

t = gf.extract_body(payload_att)                            # 取得関数を渡さない＝従来動作
(ok if t == "" else ng)("取得関数が無ければ空（従来どおり・例外にしない）")


def boom(_):
    raise RuntimeError("network")


t = gf.extract_body(payload_att, boom)
(ok if t == "" and gf.DECODE_FAILURES else ng)("取得に失敗したら記録が残る（黙って空にしない）")

# 添付ファイルは従来どおり本文にしない
payload_file = {"mimeType": "text/plain", "filename": "note.txt",
                "body": {"attachmentId": "ATT1", "size": 10}}
(ok if gf.extract_body(payload_file, lambda a: enc) == "" else ng)("添付ファイルは本文にしない")

print("\n=== デコード失敗時に原バイトを残す ===")
gf.DECODE_FAILURES.clear()
bad = {"mimeType": "text/plain",
       "headers": [{"name": "Content-Type", "value": "text/plain; charset=UTF-8"}],
       "body": {"data": base64.urlsafe_b64encode(b"\x80\x80\x80\x80").decode()}}
gf.extract_body(bad)
rec = gf.with_decode_note({"id": "x"}, list(gf.DECODE_FAILURES))
(ok if rec.get("decode_status") == "failed" else ng)("疑わしい本文に decode_status が付く")
(ok if rec.get("raw_body_base64") else ng)("原バイトが base64 で残る（Gmail が消えても復元できる）")
(ok if "decode_status" not in gf.with_decode_note({"id": "y"}, []) else ng)(
    "問題が無ければ余計な欄を足さない")

print(f"\n合計: 合格 {P} ／ 不合格 {N}")
sys.exit(1 if N else 0)
PYEOF
