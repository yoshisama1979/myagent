#!/usr/bin/env python3
"""メール本文から「今回書かれた部分」だけを抜き出す（引用・署名の除去）— 共有ライブラリ。

返信が続くと過去のやり取りが全部ぶら下がり、蒸留に渡す量が本文の何倍にもなる。
署名欄などの目印を相手に付けてもらう必要はない＝引用は必ず「そのスレッドの過去分の再掲」であり、
送信側のメーラーが既に構造（引用ヘッダ・行頭 >）を残しているため、こちらだけで切り出せる。

方針（上から順に試す）:
  1. インライン返信の検知 → 引用ヘッダでは切らない（引用の中に回答を書く習慣があり、
     素朴に消すと回答そのものが消える。冗長さより欠落の方が害が大きい）。
     ただし自社署名の区切り（┛）があればそこで切る＝相手の回答は必ず署名より上に来るため安全。
  2. 引用の開始位置で切る（日本語ヘッダ / On..wrote / Original Message / 行頭 > の連続 / From:ブロック）
  3. それでも切れなければ、同スレッドの過去メッセージとの行差分で引く
  4. 署名は「同じ送信者の複数通の末尾に共通して現れるブロック」を学習して落とす（目印に依存しない）

原本は書き換えない。抽出結果は呼び出し側が別フィールドに持つこと。
利用者＝bin/gmail-fetch.py（取り込み時）／bin/mail-strip.py（検証・レポート）。
ファイル名にハイフンが使えない（import できない）ため _ 始まりの別ファイルにしてある。
"""

import re
import unicodedata
from collections import defaultdict

# --- 引用の開始を示す行 --------------------------------------------------
# ★正規表現は「本文にも出てくる形」を避けて厳しめにする（Codex🔴2）。緩いと本文を引用と誤認して
#   その行から下を全部捨てる＝相手の依頼が丸ごと消える。実際に以下が消えることを再現した：
#     「2026年8月3日(月) 対応事項：」で始まる箇条書き → 0字
#     本文中の「From: 営業部への確認内容」以降 → 全部消える
QUOTE_HEADERS = [
    # 2026年7月31日(金) 10:00 名前 <addr@example.com>:
    # メールアドレスか山括弧を必須にする＝日付で始まる見出し行と区別できる唯一の手がかり。
    # 落ちる形（アドレスを書かないメーラー）は下の「行頭 > の連続」で拾えるので取りこぼさない。
    re.compile(r"^\s*\d{4}[年/-]\d{1,2}[月/-]\d{1,2}日?[\s(（].*[<＜@].*[:：]\s*$"),
    re.compile(r"^\s*On\s.+\swrote:\s*$", re.I),
    re.compile(r"^\s*-{2,}\s*(Original Message|元のメッセージ|Forwarded message|転送されたメッセージ)\s*-{2,}", re.I),
    re.compile(r"^\s*_{10,}\s*$"),          # Outlook の区切り線
]

# Outlook 形式のヘッダ集合。`From:` 1行だけを引用開始とみなすと本文の「From: 営業部への確認内容」で
# 誤爆するので、近接する数行に3種類以上そろったときだけ引用の始まりとする。
OUTLOOK_FIELDS = [
    re.compile(r"^\s*(差出人|送信者|From)\s*[:：]", re.I),
    re.compile(r"^\s*(送信日時|送信|日時|Sent|Date)\s*[:：]", re.I),
    re.compile(r"^\s*(宛先|To|CC)\s*[:：]", re.I),
    re.compile(r"^\s*(件名|Subject)\s*[:：]", re.I),
]
OUTLOOK_WINDOW = 6
OUTLOOK_MIN_FIELDS = 3


def find_outlook_header(lines):
    """Outlook 形式の引用ヘッダ集合が始まる行番号（無ければ None）"""
    for i, ln in enumerate(lines):
        if not OUTLOOK_FIELDS[0].match(ln):
            continue
        kinds = set()
        for j in range(i, min(i + OUTLOOK_WINDOW, len(lines))):
            for k, pat in enumerate(OUTLOOK_FIELDS):
                if pat.match(lines[j]):
                    kinds.add(k)
        if len(kinds) >= OUTLOOK_MIN_FIELDS:
            return i
    return None

QUOTE_LINE = re.compile(r"^\s*[>＞]")

# 自社（はなさか）の署名の区切り線。社長ご指定 2026-07-31＝「署名以外に使うことは考えにくい」。
# 引用された形（行頭 > つき）でも拾えるようにしておく。
# ★これは目印として使うが、目印が無いと切れないわけではない（上の QUOTE_HEADERS で18/28通は切れる）。
#   あくまで「より早い位置で切れる候補」を1つ増やすもの＝候補は最小値を採るので、切る位置が後退することはない。
OWN_SIGNATURE_MARK = re.compile(r"^\s*[>＞\s]*┛{4,}\s*$")
# 署名・フッタでよく出る行（インライン返信の判定から除外する＝これは「回答」ではない）
NOISE_LINE = re.compile(
    r"^\s*(-{2,}\s*$|={3,}|_{3,}|\*{3,}|TEL|FAX|Tel|E-?mail|https?://|〒|株式会社|有限会社)"
)


def _norm(s: str) -> str:
    """比較用の正規化（全角半角・空白の揺れで差分が取れなくなるのを防ぐ）"""
    s = unicodedata.normalize("NFKC", s)
    return re.sub(r"\s+", "", s)


def find_quote_start(lines):
    """ここから下は不要（引用または自社署名）という行番号を返す。見つからなければ None。

    候補を集めて最小値を採る＝どの手がかりが先に来ても、いちばん早い位置で切れる。
    """
    cands = []
    for i, ln in enumerate(lines):
        if any(p.match(ln) for p in QUOTE_HEADERS):
            cands.append(i)
            break
    ol = find_outlook_header(lines)
    if ol is not None:
        cands.append(ol)
    # 自社署名の区切り線（実測：社長の送信メール10通でこれが引用ヘッダより前に来る＝署名も落ちる）
    for i, ln in enumerate(lines):
        if OWN_SIGNATURE_MARK.match(ln):
            cands.append(i)
            break
    # 行頭 > が2行以上続く塊の先頭
    run = 0
    for i, ln in enumerate(lines):
        if QUOTE_LINE.match(ln):
            run += 1
            if run >= 2:
                cands.append(i - run + 1)
                break
        elif ln.strip():
            run = 0
    return min(cands) if cands else None


def looks_inline(lines, start):
    """引用の中に地の文が挟まっている＝インライン返信か。

    「引用開始より後ろにある地の文」を数えるだけでは足りない。行頭 > を使わない
    （Outlook 形式などの）全文引用は本文そのものが地の文に見えるため、引用を丸ごと
    インライン返信と誤認して1文字も切れなくなる。実測28通のうち3通がこれだった。
    判定は「最初の引用行と最後の引用行の【あいだ】に地の文があるか」に限る。
    """
    quoted = [i for i, ln in enumerate(lines[start:], start) if QUOTE_LINE.match(ln)]
    if len(quoted) < 2:
        return False             # > が無い＝この方法では見分けられない。切る側に倒す
    lo, hi = quoted[0], quoted[-1]
    body_lines = 0
    for i in range(lo + 1, hi):
        ln = lines[i]
        s = ln.strip()
        if not s or QUOTE_LINE.match(ln) or NOISE_LINE.match(ln):
            continue
        if any(p.match(ln) for p in QUOTE_HEADERS):
            continue
        if len(s) >= 8:          # 短い相槌や区切りは数えない
            body_lines += 1
    return body_lines >= 2


def diff_against(lines, parents):
    """過去メッセージに出てきた行を落とす（引用ヘッダで切れなかったとき用）"""
    seen = set()
    for p in parents:
        for ln in p.splitlines():
            n = _norm(ln)
            if len(n) >= 10:     # 短い定型句（よろしくお願いします 等）は消さない
                seen.add(n)
    kept = [ln for ln in lines if _norm(ln) not in seen]
    return kept


def learn_signatures(messages, min_lines=2, min_msgs=2):
    """同じ送信者の複数通で末尾に共通して現れるブロックを署名とみなす（目印に依存しない）"""
    by_sender = defaultdict(list)
    for m in messages:
        by_sender[m.get("from", "")].append((m.get("body") or "").splitlines())
    sigs = {}
    for sender, docs in by_sender.items():
        if len(docs) < min_msgs:
            continue
        ref = docs[0]
        best = 0
        for other in docs[1:]:
            k = 0
            while k < min(len(ref), len(other)) and _norm(ref[-1 - k]) == _norm(other[-1 - k]):
                k += 1
            best = max(best, k)
        if best >= min_lines:
            sigs[sender] = [_norm(x) for x in ref[-best:] if _norm(x)]
    return sigs


def strip_signature(lines, sig):
    if not sig:
        return lines, False
    norm = [_norm(x) for x in lines]
    for cut in range(len(lines) - 1, max(len(lines) - len(sig) - 6, -1), -1):
        tail = [x for x in norm[cut:] if x]
        if tail and tail == sig[-len(tail):]:
            return lines[:cut], True
    return lines, False


def is_substantive(ln):
    """「地の文」＝引用でも署名でもヘッダでもない、意味のある行か"""
    s = ln.strip()
    return (
        len(s) >= 8
        and not QUOTE_LINE.match(ln)
        and not NOISE_LINE.match(ln)
        and not OWN_SIGNATURE_MARK.match(ln)
        and not any(p.match(ln) for p in QUOTE_HEADERS)
        and not any(p.match(ln) for p in OUTLOOK_FIELDS)
    )


def strip_quotes(body, parents=None, signature=None):
    """本文から今回書かれた部分だけを返す。

    返り値: dict(text, method, inline, suspect, kept_ratio)
      method = header-cut / inline-sig-cut / inline-kept / bottom-post / thread-diff / none / suspect-empty
    """
    lines = (body or "").splitlines()
    start = find_quote_start(lines)
    inline = bool(start is not None and looks_inline(lines, start))
    # 自社署名の区切りは、インライン返信でも切ってよい（社長のご指摘 2026-07-31）。
    # 理由＝相手が引用の中に回答を書くのは「こちらの質問のすぐ下」＝必ず署名より上になる。
    # 実測でも該当5通すべて、┛ より下にあるのは署名ブロックだけ（12行が全通で同一）だった。
    # 当初はインラインと判定した時点で一切切らない実装にしていたため、明らかに落とせる署名まで
    # 丸ごと残り、残量の76%を占めていた＝守りすぎて役に立たない状態だった。
    own_sig = next((i for i, ln in enumerate(lines) if OWN_SIGNATURE_MARK.match(ln)), None)

    # 残す行を「番号の集合」で組み立てる。単純に「引用開始より上」を採ると、引用が先で返信が後ろに
    # 書かれる形（ボトムポスト）で本文が丸ごと消える（Codex🔴1・実際に0字になることを再現）。
    keep = set()
    if inline and own_sig is not None:
        keep |= set(range(own_sig))               # 相手の回答は自社署名より上にある
        method = "inline-sig-cut"
    elif inline:
        keep |= set(range(len(lines)))
        method = "inline-kept"
    elif start is not None:
        keep |= set(range(start))
        method = "header-cut"
    elif parents:
        kept, method = diff_against(lines, parents), "thread-diff"
        return _finish(kept, lines, body, method, inline)
    else:
        keep |= set(range(len(lines)))
        method = "none"

    # 引用の【後ろ】に地の文があれば、それも今回書かれた分として残す（ボトムポスト対応）。
    quoted = [i for i, ln in enumerate(lines) if QUOTE_LINE.match(ln)]
    if quoted:
        tail_from = quoted[-1] + 1
        tail = lines[tail_from:]
        ts = next((i for i, ln in enumerate(tail) if OWN_SIGNATURE_MARK.match(ln)), len(tail))
        tail = tail[:ts]
        if any(is_substantive(ln) for ln in tail):
            keep |= set(range(tail_from, tail_from + len(tail)))
            if method == "header-cut" and not any(is_substantive(lines[i]) for i in range(start)):
                method = "bottom-post"            # 上に地の文が無い＝純粋なボトムポスト

    kept = [lines[i] for i in sorted(keep)]
    if method not in ("inline-kept", "inline-sig-cut"):
        kept, _ = strip_signature(kept, signature)
    return _finish(kept, lines, body, method, inline)


def _finish(kept, lines, body, method, inline):
    """末尾の空行を落として仕上げる。空になったら切らずに全部返す（安全弁）。

    ★削減率は「切りすぎ」を検出できない指標＝切るほど数字は良くなる（Codex）。
      本文が残らなかったときは黙って捨てず、原文をそのまま返して suspect を立てる。
      冗長になるだけで済むが、消えると相手の依頼そのものが失われる。
    """
    while kept and not kept[-1].strip():
        kept.pop()
    text = "\n".join(kept).strip()
    suspect = False
    if not any(is_substantive(ln) for ln in kept) and any(is_substantive(ln) for ln in lines):
        text = (body or "").strip()
        method, suspect = "suspect-empty", True
    ratio = len(text) / len(body) if body else 1.0
    return {"text": text, "method": method, "inline": inline, "suspect": suspect, "kept_ratio": ratio}
