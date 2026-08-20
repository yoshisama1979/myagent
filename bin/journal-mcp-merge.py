#!/usr/bin/env python3
"""journal-mcp-merge.py — MCP で取った仕訳 JSON を仕訳帳CSV（MF エクスポート互換）へ落とす。

F-017（社長決定 2026-08-18・案①）の中核。**LLM に算術と判定をさせない**ための決定的な部品：
ヘッドレス claude は「MCP の戻り値をそのまま書き出す」だけを担当し、
金額の税込計算・日付書式・並べ替え・削除検知・貸借検算はすべてここでやる。

■ 変換の対応表（2026-08-18 に FY2026 実データで一致を確認）
    1 branch = CSV 1 行。debitor が null なら借方列は空・creditor が null なら貸方列は空。
    金額 = value + tax_value（**税込**。MCP は本体と税額を分けて返すが CSV は税込1列）
    税区分 = tax_long_name（"課税仕入 8%"。tax_name は "課仕 8%" で CSV と違う）
    取引日 = transaction_date の "-" を "/" に（CSV は 2026/07/01 形式）
    並び順 = 取引日 昇順（MF のエクスポートもこの順。取引No 順ではない）

■ 入力（ヘッドレス claude が .staging/ へ書く2ファイル）
    index.jsonl   … 窓の中の全仕訳 {"n": 取引No, "u": update_time} 1行1件
    changed.json  … {"fy_total_count": N, "journals": [ getJournals の journal をそのまま ]}
                    journals は「手元に無い／update_time が変わった」ものだけ＝日々の転記量を小さく保つ

■ なぜ index と changed を分けるか
    窓（既定35日）を毎日まるごと転記させると LLM の書き写し量が数百KBになり、
    費用も誤りの確率も跳ね上がる。index（1件40バイト）で**在否と版**だけ取り、
    中身の転記は本当に変わったものに限る。MF 側で削除された仕訳は
    「窓の中にあるのに index に無い」で検知できる＝削除も追随できる。
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import sys
from pathlib import Path

COLS = [
    "取引No", "取引日",
    "借方勘定科目", "借方補助科目", "借方部門", "借方取引先", "借方税区分", "借方インボイス", "借方金額(円)",
    "貸方勘定科目", "貸方補助科目", "貸方部門", "貸方取引先", "貸方税区分", "貸方インボイス", "貸方金額(円)",
    "摘要", "タグ", "メモ",
]

# CSV の「インボイス」列が空になる invoice_kind。実データ（FY2026 全474行）はこの2種のみで
# 全行が空欄だった。未知の種別が来たら**黙って空にせず申告する**＝仕様の穴に気づけるように。
INVOICE_KIND_BLANK = {"INVOICE_KIND_NOT_TARGET", "INVOICE_KIND_QUALIFIED", "", None}

ENCODING = "cp932"          # MF のエクスポートに合わせる（PHP 側も cp932 を想定して読む）


# ---------------------------------------------------------------- 変換

def _side(part: dict | None) -> list[str]:
    """debitor / creditor の片側を CSV 6列（科目・補助・部門・取引先・税区分・インボイス）+金額 へ。"""
    if not part:
        return ["", "", "", "", "", "", ""]
    amount = int(part.get("value") or 0) + int(part.get("tax_value") or 0)
    return [
        part.get("account_name") or "",
        part.get("sub_account_name") or "",
        part.get("department_name") or "",
        part.get("trade_partner_name") or "",
        part.get("tax_long_name") or "",
        "",                       # インボイス列（下の warn で未知種別を申告する）
        str(amount),
    ]


def journal_rows(j: dict, warns: list[str] | None = None) -> list[list[str]]:
    """1 仕訳 → CSV 行（branch の数だけ）。順序は MCP の branches の順を保つ。"""
    no = str(j.get("number", ""))
    date = str(j.get("transaction_date") or "").replace("-", "/")
    tags = ",".join(str(t) for t in (j.get("tags") or []))
    memo = j.get("memo") or ""
    rows = []
    for b in j.get("branches") or []:
        dr, cr = b.get("debitor"), b.get("creditor")
        if warns is not None:
            for part in (dr, cr):
                kind = (part or {}).get("invoice_kind")
                if part and kind not in INVOICE_KIND_BLANK:
                    warns.append(f"取引No {no}: 未知の invoice_kind={kind}（インボイス列を空で出力）")
        d = _side(dr)
        c = _side(cr)
        # 片側が無い branch は金額も空欄（MF のエクスポートがそうなっている）
        if not dr:
            d[6] = ""
        if not cr:
            c[6] = ""
        rows.append([no, date] + d + c + [b.get("remark") or "", tags, memo])
    return rows


# ---------------------------------------------------------------- CSV 入出力

def read_csv(path: Path) -> list[list[str]]:
    """既存CSVを読む。無ければ空。ヘッダは捨てる（列は COLS 固定として検査済み前提）。"""
    if not path.is_file():
        return []
    raw = path.read_bytes()
    text = None
    for enc in (ENCODING, "utf-8-sig", "utf-8"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    if text is None:
        raise ValueError(f"文字コードを判定できません: {path}")
    rows = list(csv.reader(io.StringIO(text)))
    if not rows:
        return []
    if rows[0] != COLS:
        raise ValueError(f"既存CSVの列が想定と違います: {path}\n  期待: {COLS}\n  実際: {rows[0]}")
    return [r for r in rows[1:] if any(c.strip() for c in r)]


def write_csv(path: Path, rows: list[list[str]]) -> None:
    """原子的に置き換える。**同じディレクトリに書いてから rename**＝途中で落ちても半端なCSVを残さない。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\r\n", quoting=csv.QUOTE_ALL)
    w.writerow(COLS)
    w.writerows(rows)
    # cp932 で表せない文字（絵文字・一部の丸数字）で落とさない＝置換して申告のほうが実務的
    tmp.write_bytes(buf.getvalue().encode(ENCODING, errors="replace"))
    os.replace(tmp, path)


# ---------------------------------------------------------------- マージ

def merge(existing: list[list[str]], changed: dict[str, list[list[str]]],
          window: list[str], alive: set[str]) -> tuple[list[list[str]], dict]:
    """既存行に、窓の中の変更を反映する。

    existing … 既存CSVの行
    changed  … {取引No: 行リスト} ＝内容が変わった／新規の仕訳
    window   … 窓に入る取引日（"YYYY/MM/DD" の集合ではなく [開始, 終了] の2要素）
    alive    … 窓の中に**いま存在する**取引No（index.jsonl 由来）

    落とす行は2種類：
      ① 取引日が窓の中なのに alive に無い → MF 側で削除された
      ② changed に載っている取引No → 中身が変わったので丸ごと差し替える
    """
    lo, hi = window
    dropped_deleted, dropped_changed = set(), set()
    kept = []
    for r in existing:
        no, date = r[0], r[1]
        if no in changed:
            dropped_changed.add(no)
            continue
        if lo <= date <= hi and no not in alive:
            dropped_deleted.add(no)
            continue
        kept.append(r)

    for no in changed:
        kept.extend(changed[no])

    # 取引日 昇順（MF のエクスポート順）。同日内は 取引No 昇順で決定的に。
    kept.sort(key=lambda r: (r[1], int(r[0]) if r[0].isdigit() else 0))
    stats = {
        "deleted_in_mf": sorted(dropped_deleted, key=int),
        "replaced": sorted(dropped_changed, key=int),
        "added": sorted(set(changed) - dropped_changed, key=int),
    }
    return kept, stats


# ---------------------------------------------------------------- 検証

def validate(rows: list[list[str]], expect_total: int | None,
             prev_count: int, shrink_pct: float, shrink_min_rows: int = 10) -> list[str]:
    """書き出す前の検算。ここを通らないものは**前回のCSVを残して中止**する。"""
    problems = []
    if not rows:
        problems.append("行が0件です（取得に失敗した可能性）")
        return problems

    balance: dict[str, list[int]] = {}
    for i, r in enumerate(rows, start=2):
        if len(r) != len(COLS):
            problems.append(f"{i}行目: 列数が {len(r)}（期待 {len(COLS)}）")
            continue
        no, date = r[0], r[1]
        if not no.isdigit():
            problems.append(f"{i}行目: 取引No が数値でない（{no!r}）")
        if len(date) != 10 or date[4] != "/" or date[7] != "/":
            problems.append(f"{i}行目: 取引日の書式が YYYY/MM/DD でない（{date!r}）")
        # ⚠️ 検出しただけで先へ進んではいけない。桁区切り付き（"1,100"）を int() に渡すと
        #    ここで例外になり、下の貸借検算と「前回CSVを残しました」の案内まで届かない
        #    ＝利用者にはトレースバックだけが出る（2026-08-18 テストで検出）。
        amounts, bad = {}, False
        for col, idx in (("借方金額(円)", 8), ("貸方金額(円)", 15)):
            v = r[idx]
            if v != "" and not v.isdigit():
                problems.append(f"{i}行目: {col} が非負整数でない（{v!r}）")
                bad = True
            amounts[idx] = int(v) if v.isdigit() else 0
        if bad:
            continue
        b = balance.setdefault(no, [0, 0])
        b[0] += amounts[8]
        b[1] += amounts[15]

    for no, (dr, cr) in balance.items():
        if dr != cr:
            problems.append(f"取引No {no}: 貸借が一致しません（借方 {dr} / 貸方 {cr}）")

    # MF 側の全件数と突き合わせる＝窓の外で起きた増減に気づくための唯一の手掛かり
    if expect_total is not None and len(balance) != expect_total:
        problems.append(
            f"DRIFT: 手元の仕訳 {len(balance)} 件に対し MF は {expect_total} 件"
            "（窓の外で増減した可能性＝--full で作り直してください）")

    # 大量に減るのは事故のかたち。少数の削除は通し、地滑りだけ止める。
    # ⚠️ 割合だけで見てはいけない：行数が少ない年度始めは 1〜2 行の正当な削除でも
    #    5% を軽く超えてしまい、まともな取り込みが毎回止まる（2026-08-18 テストで検出）。
    #    「割合も超え、かつ実数でも shrink_min_rows 行以上減った」ときだけ止める。
    lost = prev_count - len(rows)
    if prev_count and lost >= shrink_min_rows and len(rows) < prev_count * (1 - shrink_pct / 100):
        problems.append(
            f"行数が {prev_count} → {len(rows)} へ {lost}行（{shrink_pct}%超）減りました（取得漏れの疑い）")
    return problems


# ---------------------------------------------------------------- 入力の読み込み

def load_staging(staging: Path) -> tuple[set[str], dict[str, list[list[str]]], int | None, list[str]]:
    """.staging/ の2ファイルを読む。壊れていたら例外でなく problems で返す（＝前回CSVを残せる）。"""
    warns: list[str] = []
    idx_file = staging / "index.jsonl"
    chg_file = staging / "changed.json"
    if not idx_file.is_file():
        raise FileNotFoundError(f"index.jsonl がありません: {idx_file}")
    if not chg_file.is_file():
        raise FileNotFoundError(f"changed.json がありません: {chg_file}")

    alive: set[str] = set()
    for ln, line in enumerate(idx_file.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError as e:
            raise ValueError(f"index.jsonl {ln}行目が JSON として壊れています: {e}") from None
        alive.add(str(o["n"]))

    chg = json.loads(chg_file.read_text(encoding="utf-8"))
    changed: dict[str, list[list[str]]] = {}
    for j in chg.get("journals") or []:
        rows = journal_rows(j, warns)
        if rows:
            changed[str(j.get("number"))] = rows
    total = chg.get("fy_total_count")
    return alive, changed, (int(total) if total is not None else None), warns


def load_index_updates(staging: Path) -> dict[str, str]:
    """index.jsonl を {取引No: update_time} に。次回の差分判定（サイドカー）に使う。"""
    out = {}
    for line in (staging / "index.jsonl").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            o = json.loads(line)
            out[str(o["n"])] = str(o.get("u") or "")
    return out


# ---------------------------------------------------------------- CLI

def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="MCP 仕訳 JSON → 仕訳帳CSV マージ")
    p.add_argument("--staging", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path, help="書き出す仕訳帳CSV")
    p.add_argument("--sidecar", type=Path, help="取引No→update_time の版管理ファイル")
    p.add_argument("--window-start", required=True, help="YYYY-MM-DD")
    p.add_argument("--window-end", required=True, help="YYYY-MM-DD")
    p.add_argument("--shrink-pct", type=float, default=5.0)
    p.add_argument("--shrink-min-rows", type=int, default=10)
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)

    window = [a.window_start.replace("-", "/"), a.window_end.replace("-", "/")]
    try:
        existing = read_csv(a.out)
        alive, changed, expect_total, warns = load_staging(a.staging)
    except (ValueError, FileNotFoundError, json.JSONDecodeError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    merged, stats = merge(existing, changed, window, alive)
    problems = validate(merged, expect_total, len(existing), a.shrink_pct, a.shrink_min_rows)

    for w in warns:
        print(f"WARN: {w}")
    # DRIFT だけは「書き出しは進めるが黙って成功にしない」＝古いデータで止まるより新しい方がまし
    fatal = [x for x in problems if not x.startswith("DRIFT:")]
    drift = [x for x in problems if x.startswith("DRIFT:")]

    if fatal:
        for x in fatal:
            print(f"ERROR: {x}", file=sys.stderr)
        print("→ 前回のCSVをそのまま残しました（書き換えていません）", file=sys.stderr)
        return 2

    if a.dry_run:
        print(f"(dry-run) 反映後 {len(merged)}行 / {len({r[0] for r in merged})}仕訳")
    else:
        write_csv(a.out, merged)
        if a.sidecar:
            a.sidecar.parent.mkdir(parents=True, exist_ok=True)
            side = {}
            if a.sidecar.is_file():
                side = json.loads(a.sidecar.read_text(encoding="utf-8"))
            for no in stats["deleted_in_mf"]:
                side.pop(no, None)
            side.update(load_index_updates(a.staging))
            a.sidecar.write_text(json.dumps(side, ensure_ascii=False, sort_keys=True), encoding="utf-8")

    print(f"OK: {len(merged)}行 / {len({r[0] for r in merged})}仕訳"
          f"（新規 {len(stats['added'])} / 差替 {len(stats['replaced'])} / MF削除 {len(stats['deleted_in_mf'])}）")
    for x in drift:
        print(f"WARN: {x}")
    return 3 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
