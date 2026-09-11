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
#   bin/mailbox.sh local-inbox [--as <agent>]
#       同一マシン(VPS)のスプールから自分宛の未読(new/)を直接読む（HTTP不経由）。
#       身元は無人なら MYAGENT_AGENT・有人なら --as。**サイト別の宛名（hp-loop-<site> 等）は
#       こちらを使う**＝HTTP の inbox はトークンが名乗る総称名でしか開けず、常に count:0 になる。
#
#   bin/mailbox.sh local-done <id> [--as <agent>]
#       同一マシンで new/<id> を cur/ へ移す（自分宛のみ・本文は編集しない）。
#
# 【スライス3以降・現在サーバが 501】
#   bin/mailbox.sh approve <id>      社長(admin)だけ hold/ → new/
#
# 規約・書式は rules/modes/mailbox.md を参照。

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
    from="" to="" subject="" type="request" thread="" type_set=""
    body_args=()
    while [ $# -gt 0 ]; do
      # ★同じフラグの2度目は即エラー（2026-08-19 Codexレビュー）：後勝ちにすると、
      #   呼び出し側のガードが最初の値を見て許可し、実行時は最後の値が使われる
      #   ＝`--from talk --to partner --from overseer --to yoshida-dev` で送信者と宛先を偽装できた。
      dup() { echo "local-send: $1 は1回だけ指定できます（重複指定は認めません）" >&2; exit 2; }
      case "$1" in
        --from)    [ -n "$from" ]    && dup --from;    from="${2:-}"; shift 2 ;;
        --to)      [ -n "$to" ]      && dup --to;      to="${2:-}"; shift 2 ;;
        --subject) [ -n "$subject" ] && dup --subject; subject="${2:-}"; shift 2 ;;
        --type)    [ -n "$type_set" ] && dup --type;   type="${2:-}"; type_set=1; shift 2 ;;
        --thread)  [ -n "$thread" ]  && dup --thread;  thread="${2:-}"; shift 2 ;;
        --) shift; body_args+=("$@"); break ;;
        *)  body_args+=("$1"); shift ;;
      esac
    done
    [ -n "$from" ] || die "local-send: --from <agent> は必須です"
    [ -n "$to" ]   || die "local-send: --to <agent> は必須です"
    # 早期拒否（多重防御の一段目）：from/to に識別子以外の文字が混ざっていたら弾く。
    # from はファイル名(mid)に入るため、ここを抜けないとパストラバーサル(../)の余地になる。
    case "$from" in *[!A-Za-z0-9_-]*) die "local-send: --from は英数字/_/- のみ" ;; esac
    case "$to"   in *[!A-Za-z0-9_-]*) die "local-send: --to は英数字/_/- のみ" ;; esac
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
    # セキュリティ：from/to を厳格検証（正規表現＋登録エージェント許可リスト・president不可＝人間の代弁禁止）、
    # 格納先が new/ 直下に収まることを realpath で保証（パストラバーサル/なりすまし対策）。
    # tmp は .json 以外の接尾辞にして、書き込み途中を dispatcher(find -name '*.json') に拾わせない。
    MB_FROM="$from" MB_TO="$to" MB_SUBJECT="$subject" MB_TYPE="$type" \
    MB_THREAD="$thread" MB_BODY="$body" MB_NEWDIR="$newdir" python3 -c '
import os, json, datetime, uuid, tempfile, re, sys
ID = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
# local-send を出せるのは VPS 常駐モードのみ。president(人間)は不可。受け手は実在エージェントのみ。
# 総称 hp-loop は複数サイト化で廃止：宛先は必ず hp-loop-<site>（消費する dispatch が存在する名のみ許可＝孤児化防止）。
# 各サイトループ hp-loop-<site> は「最新レポートを実装担当へ流す」ために送信者にもなる（同一VPS常駐＝local-send）。
# ブログ解析ループ blog-loop-<client> も同様（実装担当への配信＋fact質問の送信者）。VPS常駐＝local-send。
SENDERS    = {"overseer", "hanasaka-main",
              "hp-loop-ycom", "hp-loop-yoshida", "hp-loop-fujisaka", "hp-loop-yokohawaii",
              "hp-loop-rally", "hp-loop-konjaku", "hp-loop-shigatoyota",
              "blog-loop-ycom",
              # 相談役（軽い会話・2026-08-19）。深掘りが要る話を partner へ渡す唯一の経路。
              "talk"}
RECIPIENTS = {"overseer", "hanasaka-main", "web-hanasaka", "yoshida-dev", "fujisaka-dev", "yokohawaii-dev",
              "rally-dev", "konjaku-dev", "shigatoyota-dev",
              "hp-loop-ycom", "hp-loop-yoshida", "hp-loop-fujisaka", "hp-loop-yokohawaii",
              "hp-loop-rally", "hp-loop-konjaku", "hp-loop-shigatoyota",
              "blog-loop-ycom",
              # 経営パートナー（レポート）。talk からの申し送りを受ける。
              "partner"}
TYPES      = {"request", "report", "ack", "fyi"}
frm = os.environ["MB_FROM"]; to = os.environ["MB_TO"]; typ = os.environ["MB_TYPE"] or "request"
if not ID.match(frm) or frm not in SENDERS:
    sys.exit("local-send: 不正な --from（許可: %s）: %r" % (",".join(sorted(SENDERS)), frm))
# ★無人実行では「自分の名」しか名乗れない（2026-08-19 Codexレビュー）。
#   名簿を通るだけだと、外部入力に誘導されたモードが他モードを騙って内部指示を投函できる
#   （受け手はそれを正規の依頼として実行してしまう＝指示注入が横に伝播する経路）。
#   MYAGENT_AGENT は無人起動時にだけ渡る＝有人セッションの代筆・検証は従来どおり通す。
_me = os.environ.get("MYAGENT_AGENT", "")
if _me and frm != _me:
    sys.exit("local-send: 無人実行では --from は自分（%s）だけです: %r" % (_me, frm))
if not ID.match(to) or to not in RECIPIENTS:
    sys.exit("local-send: 不正な --to（許可: %s）: %r" % (",".join(sorted(RECIPIENTS)), to))
if typ not in TYPES:
    sys.exit("local-send: 不正な --type（許可: %s）: %r" % (",".join(sorted(TYPES)), typ))
jst = datetime.timezone(datetime.timedelta(hours=9))
now = datetime.datetime.now(jst)
mid = "M-%s-%s-%s" % (now.strftime("%Y%m%dT%H%M%S"), frm, uuid.uuid4().hex[:6])
newdir = os.environ["MB_NEWDIR"]
dest = os.path.join(newdir, mid + ".json")
# 多重防御：格納先が必ず new/ 直下であることを保証（id 検証を抜けても外へ出さない）
if os.path.dirname(os.path.realpath(dest)) != os.path.realpath(newdir):
    sys.exit("local-send: 不正な格納先")
msg = {
    "id": mid, "thread": os.environ["MB_THREAD"], "from": frm, "to": to,
    "type": typ, "needs_approval": False, "ts": now.isoformat(),
    "subject": os.environ["MB_SUBJECT"], "body": os.environ["MB_BODY"],
}
fd, tmp = tempfile.mkstemp(dir=newdir, suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(msg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, dest)
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

  local-inbox|local-done)
    # ── 同一VPS内の受信・消費（HTTP 不経由）。2026-09-11 社長ご指示で新設。
    # なぜ要るか：inbox/done は HTTP API で、身元は MAILBOX_TOKEN が決める。VPS のトークンは
    # 旧来の総称 "hp-loop" のままで、宛名がサイト別（hp-loop-<site>）へ移行した後は
    # **自分宛の便が1通も見えない**（inbox は常に count:0）。一方 dispatcher(agent-tick.sh) は
    # スプールを to: で直接数えて「新着あり」と判定するため、ペース外でも毎日起動し、
    # 起動しても消費できず noprogress を繰り返していた（ycom は 36.9 日・8件で実発生）。
    # 正＝dispatcher と同じ「スプールの to:」を agent 側も見る（正を1つにする）。
    as_agent=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --as) as_agent="${2:-}"; shift 2 ;;
        *) break ;;
      esac
    done
    mid="${1:-}"
    # 身元：無人起動では MYAGENT_AGENT が正で、--as で他人を名乗らせない（local-send と同じ規律）。
    me="${MYAGENT_AGENT:-}"
    if [ -n "$me" ] && [ -n "$as_agent" ] && [ "$as_agent" != "$me" ]; then
      die "$cmd: 無人実行では --as は自分（$me）だけです: $as_agent"
    fi
    [ -n "$me" ] || me="$as_agent"
    [ -n "$me" ] || die "$cmd: 名乗る相手が決まりません（無人なら MYAGENT_AGENT・有人なら --as <agent>）"
    case "$me" in *[!A-Za-z0-9_-]*) die "$cmd: エージェント名は英数字/_/- のみ" ;; esac
    [ "$cmd" = "local-done" ] && { [ -n "$mid" ] || die "local-done <id> の id は必須です"; }
    MB_CMD="$cmd" MB_ME="$me" MB_ID="$mid" MB_ROOT="$ROOT_DIR" python3 -c '
import os, json, re, sys, glob
ID   = re.compile(r"^M-[A-Za-z0-9_-]{1,120}$")
root = os.environ["MB_ROOT"]
me   = os.environ["MB_ME"]
newd = os.path.realpath(os.path.join(root, "data/mailbox/new"))
curd = os.path.realpath(os.path.join(root, "data/mailbox/cur"))
if not os.path.isdir(newd): sys.exit("mailbox の new/ がありません: %s" % newd)

def load(path):
    try:
        with open(path, encoding="utf-8") as f: return json.load(f)
    except Exception: return None

if os.environ["MB_CMD"] == "local-inbox":
    msgs, unreadable = [], 0
    for path in sorted(glob.glob(os.path.join(newd, "*.json"))):
        d = load(path)
        if d is None: unreadable += 1; continue      # 黙って落とさない（triage の教訓）
        if str(d.get("to", "")) == me: msgs.append(d)
    out = {"ok": True, "agent": me, "inbox_of": me, "source": "spool",
           "count": len(msgs), "messages": msgs}
    if unreadable: out["unreadable"] = unreadable
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(0)

mid = os.environ["MB_ID"]
if not ID.match(mid): sys.exit("local-done: 不正な id: %r" % mid)
src = os.path.join(newd, mid + ".json")
if os.path.realpath(os.path.dirname(src)) != newd: sys.exit("local-done: 不正な参照元")
if not os.path.exists(src): sys.exit("local-done: new/ に見つかりません: %s" % mid)
d = load(src)
if d is None: sys.exit("local-done: 壊れたメッセージです（人が見てください）: %s" % mid)
if str(d.get("to", "")) != me:
    # 他人宛を消費させない＝その相手の起動理由を横から消すことになる
    sys.exit("local-done: 自分(%s)宛ではありません（to=%s）: %s" % (me, d.get("to"), mid))
if not os.path.isdir(curd): os.makedirs(curd, exist_ok=True)
dest = os.path.join(curd, mid + ".json")
if os.path.realpath(os.path.dirname(dest)) != curd: sys.exit("local-done: 不正な格納先")
os.replace(src, dest)                                 # 本文は編集しない・履歴を消さない
print(json.dumps({"ok": True, "id": mid, "moved_to": "cur"}, ensure_ascii=False))'
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
