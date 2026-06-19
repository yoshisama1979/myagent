#!/usr/bin/env bash
#
# mailbox.sh ── 拠点横断メールボックス API のクライアント
#
# 各拠点のマシンに置き、Tailscale 経由で VPS の /tools/mailbox/ を叩く。
# .env から MAILBOX_URL / MAILBOX_TOKEN を「必要キーだけ」抽出して使う（automation.md §2）。
# トークンは画面・ログに出さない。
#
# 【有効】
#   bin/mailbox.sh inbox [<agent>]
#       自分宛の未読(new/)を取得。<agent> は admin のみ他人指定可。
#
#   bin/mailbox.sh send --to <agent> --subject "件名" [options] [本文...]
#       メッセージを投函。本文は引数末尾 or 標準入力（パイプ）から。
#       options:
#         --type request|report|ack|fyi   既定 request
#         --thread <id>                    会話の束ね
#         --needs-approval                 外部送信/本番改変/書き込みを促す → hold/(社長承認待ち)
#       例: echo "本文" | bin/mailbox.sh send --to yoshida-dev --subject "依頼" --thread t1
#
#   bin/mailbox.sh local-send --from <agent> --to <agent> --subject "件名" [options] [本文...]
#       同一マシン(VPS)内の内部調整を HTTP 不経由で new/ へ直接投函（json安全・atomic・一意id）。
#       from を自己申告できる（同一マシン例外）。needs_approval は常に false。
#       外部送信/本番改変/書込を促すものは使わず、通常の send（+--needs-approval）を使うこと。
#       options: --type request|report|ack|fyi（既定 request）/ --thread <id>
#
#   bin/mailbox.sh done <id>
#       自分宛の new/<id> を処理済み(cur/)へ移動。本文は編集しない。
#
# 【スライス3以降・現在サーバが 501】
#   bin/mailbox.sh approve <id>      社長(admin)だけ hold/ → new/
#
# 規約・書式は .claude/rules/mailbox.md を参照。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

die() { echo "エラー: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl が見つかりません"
command -v python3 >/dev/null 2>&1 || die "python3 が見つかりません（送信のJSON生成に使用）"
[ -f "$ENV_FILE" ] || die ".env が見つかりません（$ENV_FILE）。.env.example を参照"

# .env から必要キーだけ抽出（全体を source しない）
MAILBOX_URL="$(grep -E '^MAILBOX_URL=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
MAILBOX_TOKEN="$(grep -E '^MAILBOX_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
[ -n "$MAILBOX_URL" ]   || die "MAILBOX_URL が .env に未設定です"
[ -n "$MAILBOX_TOKEN" ] || die "MAILBOX_TOKEN が .env に未設定です"
MAILBOX_URL="${MAILBOX_URL%/}"  # 末尾スラッシュを正規化

# curl 共通：トークンは --config 経由で渡す。
# -H "Authorization: Bearer xxx" だとトークンが curl の argv に乗り、ps / /proc から他ユーザーに見える。
# umask 077 + mktemp の一時 config（owner only）に書き、curl に読ませてから消す。
auth_curl() {
  local cfg rc=0
  cfg="$(umask 077; mktemp)" || die "一時ファイル作成に失敗"
  printf 'header = "Authorization: Bearer %s"\n' "$MAILBOX_TOKEN" > "$cfg"
  curl -sS --max-time 15 --config "$cfg" "$@" || rc=$?
  rm -f "$cfg"
  return $rc
}

cmd="${1:-}"; shift || true

case "$cmd" in
  inbox)
    to="${1:-}"
    url="${MAILBOX_URL}/?action=inbox"
    [ -n "$to" ] && url="${url}&to=${to}"
    auth_curl "$url"; echo
    ;;

  send)
    to="" subject="" type="request" thread="" needs_approval="false"
    body_args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --to)             to="${2:-}"; shift 2 ;;
        --subject)        subject="${2:-}"; shift 2 ;;
        --type)           type="${2:-}"; shift 2 ;;
        --thread)         thread="${2:-}"; shift 2 ;;
        --needs-approval) needs_approval="true"; shift ;;
        --) shift; body_args+=("$@"); break ;;
        *)  body_args+=("$1"); shift ;;
      esac
    done
    [ -n "$to" ] || die "--to <agent> は必須です"

    # 本文：引数末尾があればそれ、無ければ標準入力（パイプ）から
    if [ ${#body_args[@]} -gt 0 ]; then
      body="${body_args[*]}"
    elif [ ! -t 0 ]; then
      body="$(cat)"
    else
      body=""
    fi
    [ -n "$subject" ] || [ -n "$body" ] || die "件名(--subject)か本文のどちらかは必要です"

    # JSON 生成は python3（環境変数経由＝クォート/日本語崩れ・インジェクション防止）
    json="$(MB_TO="$to" MB_SUBJECT="$subject" MB_TYPE="$type" MB_THREAD="$thread" \
            MB_BODY="$body" MB_NA="$needs_approval" python3 -c '
import os, json
print(json.dumps({
    "to": os.environ["MB_TO"],
    "subject": os.environ["MB_SUBJECT"],
    "type": os.environ["MB_TYPE"],
    "thread": os.environ["MB_THREAD"],
    "body": os.environ["MB_BODY"],
    "needs_approval": os.environ["MB_NA"] == "true",
}, ensure_ascii=False))')"

    printf '%s' "$json" | auth_curl -X POST -H "Content-Type: application/json" \
      --data-binary @- "${MAILBOX_URL}/?action=send"; echo
    ;;

  local-send)
    # 同一マシン(VPS常駐)内の内部調整専用：HTTP を経由せず data/mailbox/new/ へ直接投函。
    # mailbox.sh(HTTP)の from はトークン由来＝1マシン1トークンで「相手の名」を名乗れないため、
    # 同居モード間の転送は from を自己申告でローカル投函する（規約 mailbox.md 同一マシン例外）。
    # needs_approval は常に false（外部送信/本番改変/書込を促すものはこの近道を使わず HTTP send + hold/ へ）。
    from="" to="" subject="" type="request" thread=""
    body_args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --from)    from="${2:-}"; shift 2 ;;
        --to)      to="${2:-}"; shift 2 ;;
        --subject) subject="${2:-}"; shift 2 ;;
        --type)    type="${2:-}"; shift 2 ;;
        --thread)  thread="${2:-}"; shift 2 ;;
        --) shift; body_args+=("$@"); break ;;
        *)  body_args+=("$1"); shift ;;
      esac
    done
    [ -n "$from" ] || die "local-send: --from <agent> は必須です"
    [ -n "$to" ]   || die "local-send: --to <agent> は必須です"
    if [ ${#body_args[@]} -gt 0 ]; then
      body="${body_args[*]}"
    elif [ ! -t 0 ]; then
      body="$(cat)"
    else
      body=""
    fi
    [ -n "$subject" ] || [ -n "$body" ] || die "件名(--subject)か本文のどちらかは必要です"
    newdir="$ROOT_DIR/data/mailbox/new"
    [ -d "$newdir" ] || die "mailbox の new/ がありません（$newdir）"
    # 一意id・JSON安全生成・atomic 書き込み（tmp に書いて os.replace）を python3 で。
    # tmp は .json 以外の接尾辞にして、書き込み途中を dispatcher(find -name '*.json') に拾わせない。
    MB_FROM="$from" MB_TO="$to" MB_SUBJECT="$subject" MB_TYPE="$type" \
    MB_THREAD="$thread" MB_BODY="$body" MB_NEWDIR="$newdir" python3 -c '
import os, json, datetime, uuid, tempfile
jst = datetime.timezone(datetime.timedelta(hours=9))
now = datetime.datetime.now(jst)
mid = "M-%s-%s-%s" % (now.strftime("%Y%m%dT%H%M%S"), os.environ["MB_FROM"], uuid.uuid4().hex[:6])
msg = {
    "id": mid,
    "thread": os.environ["MB_THREAD"],
    "from": os.environ["MB_FROM"],
    "to": os.environ["MB_TO"],
    "type": os.environ["MB_TYPE"],
    "needs_approval": False,
    "ts": now.isoformat(),
    "subject": os.environ["MB_SUBJECT"],
    "body": os.environ["MB_BODY"],
}
newdir = os.environ["MB_NEWDIR"]
fd, tmp = tempfile.mkstemp(dir=newdir, suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(msg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, os.path.join(newdir, mid + ".json"))
except BaseException:
    try: os.unlink(tmp)
    except OSError: pass
    raise
print(mid)'
    ;;

  done)
    id="${1:-}"
    [ -n "$id" ] || die "done <id> の id は必須です"
    auth_curl -X POST "${MAILBOX_URL}/?action=done&id=${id}"; echo
    ;;

  approve)
    echo "（approve はスライス3以降。現在サーバは 501 を返します）" >&2
    exit 2
    ;;

  ""|-h|--help|help)
    sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 1
    ;;
  *)
    die "不明なコマンド: $cmd（help を参照）"
    ;;
esac
