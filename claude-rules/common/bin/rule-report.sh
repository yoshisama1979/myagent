#!/usr/bin/env bash
#
# bin/rule-report.sh ── ルールの問題を、はなさかのルール開発側へ「一方向で」通知する。
#
#   bash bin/rule-report.sh --subject "件名" "本文..."
#   bash bin/rule-report.sh --subject "件名" < 本文ファイル
#
# このルールファイル群（CLAUDE.md・rules/ 等）は、はなさか側の共通テンプレート
# claude-rules/ から配布されたもの。使っていて「実態とずれている／危険／抜けている」と
# 気づいたら、ここから直接知らせられる。
#
# 【mailbox とは別物】
#   解析エージェントとやり取りする bin/mailbox.sh とは、目的も鍵も別。こちらは
#   **投函しかできない**（受信箱は無い・他の宛先へは送れない・返事は返らない）。
#   .env のキーも別（RULE_REPORT_URL / RULE_REPORT_TOKEN）。mailbox が配線されていない
#   案件でも、この2キーさえあれば通知だけは届く。
#
# 【まず記録が一次】
#   気づきはその都度 documents/rule-improvements.md に RI-NNN で記録する。そのうち
#   「このプロジェクト固有でなく、テンプレート全体に還元すべき」と判断したものだけを
#   ここから送る（本文の書き方＝「指示書」形式は rule-improvements.md 冒頭の節が正）。
#
# 【送れなかったら捏造しない】
#   サーバが ok:false を返したら**送れていない**。rule-improvements.md に残したまま、
#   社長に「ルール通知の受け口を有効にしてほしい」と伝える（「送ったつもり」にしない）。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
VERSION_FILE="$ROOT_DIR/.claude/rules-version"

die() { echo "エラー: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
使い方:
  bash bin/rule-report.sh --subject "[<ファイル名>] 要旨" "本文"
  bash bin/rule-report.sh --subject "[<ファイル名>] 要旨" < body.txt

本文は「指示書」形式で書く（対象／現場で何が起きたか／変更案／なぜ）。
クライアント名・実パス・ブランド色・秘密情報は書かない（匿名化する）。
USAGE
  exit 2
}

subject=""
body=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subject) [ $# -ge 2 ] || usage; subject="$2"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; body="$*"; break ;;
    -*) die "不明なオプション: $1" ;;
    *)  body="$*"; break ;;
  esac
done
[ -n "$subject" ] || usage
# 本文が引数に無ければ標準入力から読む（パイプでなければ待たない）
if [ -z "$body" ] && [ ! -t 0 ]; then body="$(cat)"; fi
[ -n "$body" ] || die "本文が空です（引数か標準入力で渡してください）"

command -v curl >/dev/null 2>&1 || die "curl が見つかりません"
# Python は JSON の生成と応答の判定に使う。Windows の Git Bash には python3 が無く python しか
# 無いことがあるので両方見る（python2 だと落ちるので 3 系かを確認する）。
# ⚠️ この検出と下の read_env() は bin/rules-update.sh にも同じものがある（直すときは両方・TB-012）。
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 7) else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
# 3.7 以上を要求する＝下の PY_LF（stdout.reconfigure）が 3.7 から（rules-update.sh と同じ）。
[ -n "$PY" ] || die "Python 3.7 以上（python3 または python）が見つかりません（JSON生成に使用）。python --version で版を確かめてください"
# Windows の Python は標準出力の \n を \r\n にする。ここでは出力を `$(…)` で受けるだけなので Git Bash では
# 実害が出ないが、\r を落とさない bash だと送信の成否の判定を読み違える。bin/rules-update.sh と同じ前置きを通す（TB-012）。
PY_LF='import sys
if hasattr(sys.stdout, "reconfigure"): sys.stdout.reconfigure(newline="\n")
'
[ -f "$ENV_FILE" ] || die ".env が見つかりません（${ENV_FILE}）"

# ここから下はトークンを扱う。bash -x（xtrace）が有効だと展開がそのままログに出るので、
# 読み込みと curl 設定の書き出しが終わるまで切る（argv 対策とは別の漏れ口）。
XTRACE_WAS_ON=""
case "$-" in *x*) XTRACE_WAS_ON="yes"; set +x ;; esac

# .env から必要な2キーだけ抜く（全体を source しない＝他の変数を実行環境に持ち込まない）。
# Windows で書かれた .env（CRLF）・`export` 付き・`=` の周りの空白・引用符に耐える。
read_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" \
    | head -1 | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
URL="$(read_env RULE_REPORT_URL)"
TOKEN="$(read_env RULE_REPORT_TOKEN)"
if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
  die "RULE_REPORT_URL / RULE_REPORT_TOKEN が .env にありません。
   このテンプレを配った社長に「ルール通知のトークンをこの案件に発行してほしい」と伝えてください。
   それまでは気づきを documents/rule-improvements.md に残しておけば取りこぼしません。"
fi
URL="${URL%/}"

# 使用中のテンプレ版。受け取った側が「その版以降で直っているか」を機械で引けるようにする。
# 版は配布時に刻まれる＝現場が書く必要はない。
if [ -f "$VERSION_FILE" ]; then
  VERSION="$(head -1 "$VERSION_FILE" | tr -d '\r\n')"
else
  VERSION="unknown"
  echo "警告: $VERSION_FILE が無いため版が不明のまま送ります。" >&2
  echo "      受け取り側で「もう直っている件か」を判定できないので、社長に配布し直しを依頼してください。" >&2
fi
# 版の頭は配布プロファイル名（website / websystem / site / system / full …）。
# 🚨 **許可リストを現場に持たせない。** 持たせると、プロファイルを足した日に配った先だけ
# 古い一覧を握り、報告が黙って別のスレッドへ落ちる。代わりに**形**で判定する：
# 英小文字・数字・ハイフンだけ／32文字以内／先頭はハイフン以外。外れたら `rules` に寄せる
# （版が無いときの `unknown` もここで `rules` になる＝従来どおり）。
TEMPLATE="${VERSION%%@*}"
case "$TEMPLATE" in
  "" | unknown | -* | *[!a-z0-9-]* ) TEMPLATE="rules" ;;
  * ) [ "${#TEMPLATE}" -le 32 ] || TEMPLATE="rules" ;;
esac

json="$(RR_SUBJECT="[$VERSION] $subject" RR_BODY="$body" RR_THREAD="${TEMPLATE}-kaizen" "$PY" -c "$PY_LF"'
import os, json
print(json.dumps({
    "to": "rule-kaizen",
    "type": "request",
    "thread": os.environ["RR_THREAD"],
    "subject": os.environ["RR_SUBJECT"],
    "body": os.environ["RR_BODY"],
}, ensure_ascii=False))')"

# トークンは --config 経由で渡す。-H "Authorization: Bearer xxx" だと curl の argv に乗り、
# ps / /proc から同じマシンの他ユーザーに見える。
cfg="$(umask 077; mktemp)" || die "一時ファイル作成に失敗"
trap 'rm -f "$cfg"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$cfg"
if [ -n "$XTRACE_WAS_ON" ]; then set -x; fi     # ここから先はトークンを展開しないので戻してよい

resp="$(printf '%s' "$json" | curl -sS --max-time 15 --config "$cfg" \
        -X POST -H "Content-Type: application/json" --data-binary @- "${URL}/?action=send")" || \
  die "送信に失敗しました（ネットワーク）。rule-improvements.md に残して社長に伝えてください。"

ok="$(RR_RESP="$resp" "$PY" -c "$PY_LF"'
import os, json, sys
try:
    d = json.loads(os.environ["RR_RESP"])
except json.JSONDecodeError:
    print("parse_error"); sys.exit()
print("ok" if d.get("ok") else (d.get("error") or "unknown_error"))')"

if [ "$ok" = "ok" ]; then
  echo "✅ 送信しました（版: ${VERSION}）"
  echo "   documents/rule-improvements.md の該当 RI-NNN を「送信済み」にしてください。"
  exit 0
fi

echo "❌ 送れていません（サーバの応答: ${ok}）" >&2
case "$ok" in
  token_revoked|token_expired)
    echo "   この案件のルール通知トークンが失効／期限切れです。社長に再発行を依頼してください。" >&2 ;;
  unknown_recipient|recipient_not_allowed)
    echo "   受け口が未整備です。社長に「ルール通知の受け口を有効にしてほしい」と伝えてください。" >&2 ;;
  daily_quota_exceeded)
    echo "   今日の送信上限に達しました。明日送るか、まとめて1通にしてください。" >&2 ;;
esac
echo "   気づきは documents/rule-improvements.md に残したままにしてください（送ったことにしない）。" >&2
exit 1
