#!/usr/bin/env python3
# hp-diff.py — HP分析ループ用・スナップショット差分ツール（T-009）
#
# 目的：gsc-fetch.py / ga4-fetch.py が出した「2時点の JSON スナップショット」を突き合わせ、
#       before→after（順位・CTR・クリック・CV件数）と「新規/消滅した行」を表で出す。
#       効果検証（施策“前” baseline と施策“後”の比較）を毎サイクル1コマンドで行うための定石ツール。
#       ＝「欲しいデータは回り道でなく1コマンドに」（coverage.md §9 #1）。
#
# 安全（automation.md 準拠）：**読み取り専用**＝ローカルの JSON 2ファイルを読んで stdout に出すだけ。
#   ネットワーク・外部送信・ファイル書き込み・破壊的操作はしない。BigQuery も叩かない（取得は gsc/ga4-fetch の役目）。
#
# 使い方：
#   python3 bin/hp-diff.py <旧JSON> <新JSON> [--section auto|queries|pages|events|cv]
#                          [--match <部分文字列>] [--sort <metric>] [--top N] [--json]
#   例（料金クエリの順位が動いたか）：
#     python3 bin/hp-diff.py cycles/ycom/baseline-20260619-queries.json cycles/ycom/20260621-queries.json \
#             --section queries --match 料金
#   例（受け皿ページのCTR before/after）：
#     python3 bin/hp-diff.py cycles/ycom/baseline-20260619-pages.json cycles/ycom/20260621-pages.json --section pages
#
# 対応スナップショット（キー＝突き合わせる結合キー／metrics＝数値指標）：
#   GSC queries : key=query        metrics=clicks, impressions, ctr, avg_position
#   GSC pages   : key=url          metrics=clicks, impressions, ctr, avg_position
#   GA4 events  : key=event_name   metrics=c, users
#   GA4 cv      : key=month|event_name  metrics=c, users
#
# 注意：avg_position は「小さいほど良い（上位）」。本ツールは Δ の符号に加え ▲改善/▼悪化 を指標の向きで判定して表示する。

import argparse
import json
import sys

# section → (リストが入っている JSON キー, 結合キーのフィールド)
SECTIONS = {
    "queries": ("queries", ["query"]),
    "pages":   ("pages",   ["url"]),
    "events":  ("events",  ["event_name"]),
    "cv":      ("cv",      ["month", "event_name"]),
}
# 「小さいほど良い」指標（Δの向き判定用）
LOWER_IS_BETTER = {"avg_position"}
# 表示時の指標の優先順（これ以外は後ろに付ける）
METRIC_ORDER = ["clicks", "impressions", "ctr", "avg_position", "c", "users"]


def die(msg):
    print(f"hp-diff: {msg}", file=sys.stderr)
    sys.exit(2)


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        die(f"ファイルが見つかりません: {path}")
    except json.JSONDecodeError as e:
        die(f"JSON として読めません: {path}（{e}）")


def detect_section(old, new):
    """両ファイルに共通して存在する既知のリストキーを1つだけ見つける。"""
    found = [s for s, (lk, _) in SECTIONS.items()
             if isinstance(old.get(lk), list) and isinstance(new.get(lk), list)]
    if not found:
        die("既知のセクション（queries/pages/events/cv）が両ファイルに見つかりません。--section で指定してください")
    if len(found) > 1:
        die(f"複数セクションが該当します（{', '.join(found)}）。--section で1つ指定してください")
    return found[0]


def rows_of(doc, section):
    list_key, key_fields = SECTIONS[section]
    rows = doc.get(list_key)
    if not isinstance(rows, list):
        die(f"セクション '{section}'（キー {list_key}）がこのファイルにありません")
    return rows, key_fields


def join_key(row, key_fields):
    return " | ".join(str(row.get(k, "")) for k in key_fields)


def check_rows(rows, key_fields, label):
    """結合キーの欠落・重複を検出（無人運用での取り違え・後勝ち上書き事故を防ぐ）。"""
    seen = set()
    for i, r in enumerate(rows):
        if not isinstance(r, dict):
            die(f"{label}: 行{i} が dict ではありません")
        for k in key_fields:
            if k not in r:
                die(f"{label}: 行{i} に結合キー '{k}' がありません（スナップショットの種類を確認）")
        kk = join_key(r, key_fields)
        if kk in seen:
            die(f"{label}: 結合キーが重複しています '{kk}'（集計条件・section 指定を確認）")
        seen.add(kk)


def numeric_metrics(rows, key_fields):
    """行に含まれる数値フィールド（結合キー以外）を優先順で返す。"""
    seen = set()
    for r in rows:
        for k, v in r.items():
            if k in key_fields:
                continue
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                seen.add(k)
    ordered = [m for m in METRIC_ORDER if m in seen]
    ordered += sorted(m for m in seen if m not in METRIC_ORDER)
    return ordered


def fmt(metric, v):
    if v is None:
        return "-"
    if metric == "ctr":
        return f"{v*100:.2f}%"
    if metric == "avg_position":
        return f"{v:.1f}"
    if isinstance(v, float):
        return f"{v:.2f}".rstrip("0").rstrip(".")
    return str(v)


def fmt_delta(metric, old_v, new_v):
    if old_v is None or new_v is None:
        return ""
    d = new_v - old_v
    if abs(d) < 1e-9:
        return "±0"
    if metric == "ctr":
        body = f"{'+' if d>0 else ''}{d*100:.2f}pt"
    elif metric == "avg_position":
        body = f"{'+' if d>0 else ''}{d:.1f}"
    else:
        body = f"{'+' if d>0 else ''}{d:.2f}".rstrip("0").rstrip(".")
    better = (d < 0) if metric in LOWER_IS_BETTER else (d > 0)
    arrow = "▲" if better else "▼"
    return f"{body}{arrow}"


def main():
    p = argparse.ArgumentParser(description="HP分析 スナップショット差分（読み取り専用・before→after）")
    p.add_argument("old", help="施策“前”の JSON（baseline）")
    p.add_argument("new", help="施策“後”の JSON")
    p.add_argument("--section", default="auto", choices=["auto", *SECTIONS])
    p.add_argument("--match", default=None, help="結合キーにこの部分文字列を含む行だけ対象（例: 料金）")
    p.add_argument("--sort", default=None, help="この指標の変化量(絶対値)で並べる（既定: 主指標）")
    p.add_argument("--only", default=None, choices=["better", "worse"], help="主指標が改善/悪化した行だけ表示")
    p.add_argument("--top", type=int, default=30, help="変化のある行の表示上限（既定30・1以上）")
    p.add_argument("--json", dest="as_json", action="store_true", help="機械可読JSONで出力")
    a = p.parse_args()
    if a.top < 1:
        die("--top は 1 以上を指定してください")

    old, new = load(a.old), load(a.new)
    if not isinstance(old, dict) or not isinstance(new, dict):
        die("スナップショットJSONはトップレベルが dict である必要があります（gsc/ga4-fetch --json の出力）")
    section = detect_section(old, new) if a.section == "auto" else a.section

    old_rows, key_fields = rows_of(old, section)
    new_rows, _ = rows_of(new, section)
    check_rows(old_rows, key_fields, f"旧({a.old})")
    check_rows(new_rows, key_fields, f"新({a.new})")
    metrics = numeric_metrics(old_rows + new_rows, key_fields) or []
    primary = a.sort or (metrics[0] if metrics else None)
    if a.sort and a.sort not in metrics:
        die(f"--sort の指標 '{a.sort}' がデータにありません（候補: {', '.join(metrics)}）")

    def index(rows):
        d = {}
        for r in rows:
            k = join_key(r, key_fields)
            if a.match and a.match not in k:
                continue
            d[k] = r
        return d

    oi, ni = index(old_rows), index(new_rows)
    keys_old, keys_new = set(oi), set(ni)
    both = keys_old & keys_new
    added = keys_new - keys_old      # 新規（新スナップにだけ）
    dropped = keys_old - keys_new    # 消滅（旧スナップにだけ）

    changed = []
    for k in both:
        deltas = {}
        for m in metrics:
            ov, nv = oi[k].get(m), ni[k].get(m)
            deltas[m] = (ov, nv, (nv - ov) if (isinstance(ov, (int, float)) and isinstance(nv, (int, float))) else None)
        mag = abs(deltas.get(primary, (None, None, None))[2] or 0) if primary else 0
        changed.append((k, deltas, mag))
    changed.sort(key=lambda t: -t[2])

    # --only: 主指標が改善/悪化した行だけに絞る（avg_position は小さいほど改善）
    if a.only and primary:
        def improved(d):
            dv = d.get(primary, (None, None, None))[2]
            if not dv:
                return None
            return (dv < 0) if primary in LOWER_IS_BETTER else (dv > 0)
        want = (a.only == "better")
        changed = [(k, d, m) for (k, d, m) in changed if improved(d) is want]

    meta = {
        "section": section, "key_fields": key_fields, "metrics": metrics,
        "old": {kk: old.get(kk) for kk in ("start", "end", "dataset", "table") if kk in old},
        "new": {kk: new.get(kk) for kk in ("start", "end", "dataset", "table") if kk in new},
        "counts": {"matched": len(both), "added": len(added), "dropped": len(dropped)},
        "match_filter": a.match,
    }

    if a.as_json:
        out = {
            "meta": meta,
            "changed": [{"key": k, "metrics": {m: {"old": d[m][0], "new": d[m][1], "delta": d[m][2]} for m in metrics}}
                        for k, d, _ in changed[:a.top]],
            "added": [{"key": k, **{m: ni[k].get(m) for m in metrics}} for k in sorted(added)],
            "dropped": [{"key": k, **{m: oi[k].get(m) for m in metrics}} for k in sorted(dropped)],
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return

    # 人間向けテキスト
    span_o = f"{meta['old'].get('start','?')}〜{meta['old'].get('end','?')}"
    span_n = f"{meta['new'].get('start','?')}〜{meta['new'].get('end','?')}"
    print(f"# HP-diff [{section}]  旧:{span_o}  →  新:{span_n}"
          + (f"  (match='{a.match}')" if a.match else ""))
    print(f"  突き合わせ {len(both)} 件 / 新規 {len(added)} / 消滅 {len(dropped)}  ｜ 主指標={primary}  ▲改善 ▼悪化\n")

    if changed:
        print(f"## 変化（主指標の変化量 上位 {min(a.top,len(changed))}）")
        for k, d, _ in changed[:a.top]:
            cells = []
            for m in metrics:
                ov, nv, _dd = d[m]
                cells.append(f"{m} {fmt(m,ov)}→{fmt(m,nv)} {fmt_delta(m,ov,nv)}".rstrip())
            print(f"  • {k}")
            print(f"      {'  |  '.join(cells)}")
    if added:
        print(f"\n## 📈 新規に出現（{len(added)} 件・上位 {min(a.top,len(added))}）")
        for k in sorted(added, key=lambda kk: -(ni[kk].get(primary, 0) or 0))[:a.top]:
            print(f"  • {k}  " + "  ".join(f"{m}={fmt(m,ni[k].get(m))}" for m in metrics))
    if dropped:
        print(f"\n## 📉 消滅（{len(dropped)} 件・上位 {min(a.top,len(dropped))}）")
        for k in sorted(dropped, key=lambda kk: -(oi[kk].get(primary, 0) or 0))[:a.top]:
            print(f"  • {k}  " + "  ".join(f"{m}={fmt(m,oi[k].get(m))}" for m in metrics))


if __name__ == "__main__":
    main()
