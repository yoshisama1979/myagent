#!/usr/bin/env bash
# test-all.sh — 全回帰スイートを流して合計項目数を機械で出す（O-041）。
#
# 契機＝2026-08-17。rules/testing.md §7 のベースラインを**人が手で数えていた**ため、
# 実際に誤記録が出た（test-hana-api は台帳 53 に対し実測 55／test-precommit-guard も同じズレ）。
# §6-5 は「末尾に『合計: 合格 N ／ 不合格 M』の1行（将来まとめ実行するときに機械で読める）」と
# 書式を定めているが、機械の担保が無かった＝§4 が禁じる「宣言だけのルール」。これがその担保。
#
# 3種類の書式に対応する（規定形に揃えるのが本筋だが、揃うまで数えられない方が困る）：
#   A: 合計: 合格 N ／ 不合格 M      … 規定形（大多数）
#   B: 全 N 件 合格                  … test-guard-unattended-edits
#   C: サマリ行なし                  … test-office-forest（"OK " 行を数える）
# ⚠️ ✅/❌ の行数で数えてはいけない：check-ssl・oom-guard は**ツール自身の出力に ✅ が混ざる**
#    （2026-08-17 に実際これで誤検知した）。必ずスイートの自己申告を使う。
#
# 使い方: bash bin/test-all.sh            # 一覧＋合計
#         bash bin/test-all.sh --quiet    # 合計だけ（台帳更新用）
set -u
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ" || exit 2
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1

total=0; failed=0; suites=0
for t in bin/test-*.sh bin/test-*.py; do
  [ -f "$t" ] || continue
  case "$t" in */test-all.sh) continue ;; esac          # 自分自身は数えない
  case "$t" in *.py) out="$(python3 "$t" 2>&1)" ;; *) out="$(bash "$t" 2>&1)" ;; esac
  rc=$?
  n="$(printf '%s' "$out" | grep -oP '(?<!不)合格 \K[0-9]+' | tail -1)"          # A
  [ -z "$n" ] && n="$(printf '%s' "$out" | grep -oP '全 \K[0-9]+(?= 件 合格)' | tail -1)"  # B
  [ -z "$n" ] && n="$(printf '%s' "$out" | grep -c '^OK ')"                      # C
  ng="$(printf '%s' "$out" | grep -oP '不合格 \K[0-9]+' | tail -1)"; ng="${ng:-0}"
  suites=$((suites+1)); total=$((total+n))
  if [ "$rc" -ne 0 ] || [ "$ng" -ne 0 ]; then
    failed=$((failed+1))
    printf '  ⛔ %-28s %4s項目  不合格 %s  rc=%s\n' "$(basename "$t")" "$n" "$ng" "$rc"
  elif [ "$QUIET" = 0 ]; then
    printf '  ✅ %-28s %4s項目\n' "$(basename "$t")" "$n"
  fi
done

echo "------------------------------------------------------"
printf 'ベースライン: %s項目 ／ %s スイート ／ 落ちたスイート %s 本\n' "$total" "$suites" "$failed"
[ "$failed" -eq 0 ] || exit 1
