#!/usr/bin/env bash
# bin/office-forest-fetch.py の build_payload（純関数）の回帰テスト。ネットワーク不要。
# 対象＝高さ/灯り/開花の判定が正しく出ること・部分故障の持ち越し・未接続サイトの表現。
set -u
cd "$(dirname "$0")/.."
python3 - <<'EOF'
import sys, os
sys.path.insert(0, "bin")
import importlib.util
spec = importlib.util.spec_from_file_location("otf", "bin/office-forest-fetch.py")
otf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(otf)

fails = []
def check(name, cond):
    print(("OK  " if cond else "NG  ") + name)
    if not cond:
        fails.append(name)

TODAY = "2026-08-10"

# --- 1. 通常系：7日合計・最新日・bloom ---------------------------------------
gsc = {"ycom": [(f"2026-08-0{d}", 10) for d in range(1, 9)],      # 8/1〜8/8 各10クリック
       "yoshida": [("2026-08-07", 3), ("2026-08-08", 5)],
       "fujisaka": [], "yokohawaii": [("2026-08-06", 0)]}
cv = {"ycom": [("2026-08-07", 0), ("2026-08-08", 2)],             # 最新日にCV → 咲く
      "yoshida": [("2026-08-04", 1)]}                             # 4日前のCV → 咲かない
p = otf.build_payload(None, TODAY, gsc, cv)["sites"]
check("7日合計＝最新日から7日ぶんだけ（8/2〜8/8=70）", p["ycom"]["clicks7d"] == 70)
check("最新日のクリック", p["ycom"]["clicks_latest"] == 10 and p["ycom"]["latest_date"] == "2026-08-08")
check("最新日にCV → bloom", p["ycom"]["bloom"] is True and p["ycom"]["cv_recent"] == 2)
check("古いCV(4日前) → 咲かない", p["yoshida"]["bloom"] is False)
check("GSC行が空でも connected", p["fujisaka"]["connected"] is True and p["fujisaka"]["clicks7d"] == 0)
check("未接続サイトは connected=False", p["rally"]["connected"] is False and p["konjaku"]["connected"] is False)
check("CVフィード無しは has_cv_feed=False", p["fujisaka"]["has_cv_feed"] is False)

# --- 2. bloom＝最新2日のどちらかにCV（前日CVでも咲く） -------------------------
cv2 = {"ycom": [("2026-08-07", 1), ("2026-08-08", 0)]}
p2 = otf.build_payload(None, TODAY, gsc, cv2)["sites"]
check("前日CV・最新日0 → 咲く", p2["ycom"]["bloom"] is True)

# --- 3. エクスポート遅延が3日超なら咲かせない ---------------------------------
cv3 = {"ycom": [("2026-08-05", 3), ("2026-08-06", 3)]}            # 4日遅れのデータ
p3 = otf.build_payload(None, TODAY, cv_by_site=cv3, gsc_by_site=gsc)["sites"]
check("3日超の遅延データでは咲かない", p3["ycom"]["bloom"] is False)

# --- 4. 部分故障：GSC失敗サイトは前回値を持ち越す -----------------------------
prev = {"sites": {"yoshida": {"label": "よしだ歯科", "connected": True, "clicks7d": 42,
                              "clicks_latest": 6, "latest_date": "2026-08-05",
                              "fetched_date": "2026-08-07", "has_cv_feed": True,
                              "bloom": False, "cv_recent": 0}}}
gsc4 = dict(gsc); gsc4["yoshida"] = None
p4 = otf.build_payload(prev, TODAY, gsc4, cv)["sites"]
check("失敗サイトは前回値を持ち越し（fetched_dateが古いまま）",
      p4["yoshida"]["clicks7d"] == 42 and p4["yoshida"]["fetched_date"] == "2026-08-07")
check("失敗サイトに前回値も無ければ未接続扱い",
      otf.build_payload(None, TODAY, gsc4, cv)["sites"]["yoshida"]["connected"] is False)

# --- 5. CVだけ失敗：前回のCV行を持ち越して判定 --------------------------------
prev5 = {"sites": {"ycom": {"connected": True, "cv_rows": [["2026-08-08", 1]]}}}
cv5 = {"ycom": None}
p5 = otf.build_payload(prev5, TODAY, gsc, cv5)["sites"]
check("CVだけ失敗 → 前回のCV行で bloom 判定", p5["ycom"]["bloom"] is True)

# --- 6. 壊れた prev で例外にならない（Codex🔴 2026-08-11）----------------------
#     cron は毎朝これを踏む可能性がある＝どの型崩れでも「壊れた部分だけ捨てて」続行する
gsc6 = dict(gsc); gsc6["yoshida"] = None; cv6 = {"ycom": None}
broken_prevs = [
    ("ルートが配列", [1, 2, 3]),
    ("sites が配列", {"sites": ["a", "b"]}),
    ("サイト値が文字列", {"sites": {"yoshida": "garbage", "ycom": "x"}}),
    ("cv_rows が不正形式", {"sites": {"ycom": {"connected": True,
                                               "cv_rows": [["not-a-date", 1], "x", [None], ["2026-08-08", "2"]]}}}),
    ("connected が文字列", {"sites": {"yoshida": {"connected": "true", "clicks7d": "many"}}}),
]
for name, bp in broken_prevs:
    try:
        r = otf.build_payload(bp, TODAY, gsc6, cv6)["sites"]
        ok = isinstance(r, dict)
    except Exception as e:
        ok = False
        print(f"    例外: {type(e).__name__}: {e}")
    check(f"壊れた prev（{name}）でも例外にならない", ok)
# 型崩れ cv_rows のうち正しい1行（8/8, n=2）だけが拾われて bloom する
r6 = otf.build_payload(broken_prevs[3][1], TODAY, gsc6, cv6)["sites"]
check("cv_rows の正しい行だけ拾って判定（'2'→2 で bloom）", r6["ycom"]["bloom"] is True and r6["ycom"]["cv_recent"] == 2)
# connected が "true"（文字列）の持ち越しは信用しない＝未接続扱い
check("connected が文字列の持ち越しは未接続扱い", r6.get("yoshida", {}).get("connected") is False or
      otf.build_payload(broken_prevs[4][1], TODAY, gsc6, cv6)["sites"]["yoshida"]["connected"] is False)

print()
if fails:
    print(f"❌ {len(fails)} 件失敗"); sys.exit(1)
print("✅ 全テスト通過")
EOF
