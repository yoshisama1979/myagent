#!/usr/bin/env bash
#
# bin/deploy-ssh.sh - deploy committed files to a server over SSH.
#
# Rule (read it first): rules/modes/deploy-ssh.md
# Config:               .deploy/<target>.conf   (sample: .deploy/production.conf.sample)
#
#   bash bin/deploy-ssh.sh [-t TARGET] preflight        check tools / connection (read-only)
#   bash bin/deploy-ssh.sh [-t TARGET] preview          show what would change (read-only)
#   bash bin/deploy-ssh.sh [-t TARGET] apply TOKEN      deploy exactly what preview showed
#   bash bin/deploy-ssh.sh [-t TARGET] undo [TOKEN]     roll back the last deploy
#   bash bin/deploy-ssh.sh [-t TARGET] baseline [TOKEN] record the current server as the start point
#   bash bin/deploy-ssh.sh [-t TARGET] status           show last deploy, lock, log (read-only)
#   bash bin/deploy-ssh.sh [-t TARGET] unlock           remove a stale lock
#
# Commands without TOKEN never change the server. Commands with TOKEN (and unlock)
# change the server and must be typed by a person in a terminal.
#
# Exit codes: 0 = done / nothing to do
#             1 = usage, config or environment error (server unchanged)
#             2 = STOP: a safety check failed (server unchanged)
#             3 = FAILED while writing: production may be partly changed -> run undo
#
# Keep this file ASCII-only (some consoles break non-ASCII when pasted or shown).
#
set -euo pipefail

main() {
VERSION=1
export LC_ALL=C
TAB=$(printf '\t')
SSH_BIN=${DEPLOY_SSH_BIN:-ssh}

die()  { echo "ERROR: $*" >&2; exit 1; }
WRITING=0
stop() { if [ "$WRITING" = 1 ]; then fail "$*"; fi; echo "STOP: $*" >&2; exit 2; }
fail() { echo "FAILED: $*" >&2; echo "NEXT: production may be partly changed. Run: bash bin/deploy-ssh.sh${TOPT} undo" >&2; exit 3; }

# ---------------------------------------------------------------- arguments
TARGET=production
while [ $# -gt 0 ]; do
  case $1 in
    -t|--target) [ $# -ge 2 ] || die "-t needs a name"; TARGET=$2; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
CMD=${1:-}; ARG=${2:-}
[ -n "$CMD" ] || { sed -n '2,25p' "$0"; exit 1; }
[[ $TARGET =~ ^[A-Za-z0-9_-]+$ ]] || die "bad target name: $TARGET"
TOPT=""; [ "$TARGET" = production ] || TOPT=" -t $TARGET"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run this inside the project's git repository"
TOP=$(git rev-parse --show-toplevel)
cd "$TOP"
CONF=".deploy/$TARGET.conf"
GITDIR=$(git rev-parse --absolute-git-dir)
WORK="$GITDIR/deploy-ssh/$TARGET"
RUN="$WORK/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"

if command -v sha256sum >/dev/null 2>&1; then HASH="sha256sum"
elif command -v shasum >/dev/null 2>&1; then HASH="shasum -a 256"
else die "need sha256sum or shasum on this PC"; fi

need_tty() {
  if [ ! -t 0 ]; then
    stop "'$CMD' changes the server, so a person must type it in a terminal (not an AI agent, not a pipe)."
  fi
}

# ---------------------------------------------------------------- config
load_conf() {
  [ -f "$CONF" ] || stop "config not found: $CONF (copy .deploy/production.conf.sample and fill it in)"
  SSH_HOST=""; REMOTE_ROOT=""; STATE_DIR=""; SOURCE_DIR="."; BRANCH="main"; REMOTE="origin"; BACKUP_KEEP=10
  local line key val n=0 seen=" "
  : > "$RUN/conf-excludes"; : > "$RUN/check-urls"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1)); line=${line%$'\r'}
    case $line in ''|'#'*) continue ;; esac
    case $line in *=*) ;; *) stop "$CONF line $n: expected KEY=VALUE" ;; esac
    key=${line%%=*}; val=${line#*=}
    case $val in *CHANGE_ME*) stop "$CONF line $n: '$key' is not filled in" ;; esac
    case $key in
      SSH_HOST|REMOTE_ROOT|STATE_DIR|SOURCE_DIR|BRANCH|REMOTE|BACKUP_KEEP)
        case $seen in *" $key "*) stop "$CONF line $n: '$key' appears twice" ;; esac
        seen="$seen$key "; eval "$key=\$val" ;;
      EXCLUDE)   printf '%s\n' "$val" >> "$RUN/conf-excludes" ;;
      CHECK_URL) printf '%s\n' "$val" >> "$RUN/check-urls" ;;
      *) stop "$CONF line $n: unknown key '$key'" ;;
    esac
  done < "$CONF"
  [ -n "$SSH_HOST" ]    || stop "$CONF: SSH_HOST is empty"
  [ -n "$REMOTE_ROOT" ] || stop "$CONF: REMOTE_ROOT is empty"
  [ -n "$STATE_DIR" ]   || stop "$CONF: STATE_DIR is empty"
  [[ $SSH_HOST =~ ^[A-Za-z0-9._@-]+$ ]] || stop "$CONF: SSH_HOST must be a host name from ~/.ssh/config (letters, digits, . _ - @)"
  local p
  for p in REMOTE_ROOT STATE_DIR; do
    val=${!p}; val=${val%/}; eval "$p=\$val"
    [[ $val =~ ^/[A-Za-z0-9._/-]+$ ]] || stop "$CONF: $p must be an absolute path (letters, digits, . _ - /)"
    case "/$val/" in */../*|*/./*) stop "$CONF: $p must not contain . or .. parts" ;; esac
    [[ $val =~ ^/[^/]+/.+ ]] || stop "$CONF: $p is too close to / ($val)"
  done
  case "$STATE_DIR/" in "$REMOTE_ROOT"/*) stop "$CONF: STATE_DIR must be outside REMOTE_ROOT (it would be public)" ;; esac
  case "$REMOTE_ROOT/" in "$STATE_DIR"/*) stop "$CONF: REMOTE_ROOT must not be inside STATE_DIR" ;; esac
  SOURCE_DIR=${SOURCE_DIR%/}; SOURCE_DIR=${SOURCE_DIR#./}; [ -n "$SOURCE_DIR" ] || SOURCE_DIR="."
  [[ $SOURCE_DIR =~ ^[A-Za-z0-9._/-]+$ ]] || stop "$CONF: SOURCE_DIR has unsupported characters"
  case "/$SOURCE_DIR/" in /./) ;; */../*|*/./*) stop "$CONF: SOURCE_DIR must not contain . or .. parts" ;; esac
  case $SOURCE_DIR in /*) stop "$CONF: SOURCE_DIR must be relative to the repository root" ;; esac
  [[ $BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || stop "$CONF: bad BRANCH"
  [[ $REMOTE =~ ^[A-Za-z0-9._-]+$ ]] || stop "$CONF: bad REMOTE"
  [[ $BACKUP_KEEP =~ ^[0-9]+$ ]] && [ "$BACKUP_KEEP" -ge 1 ] && [ "$BACKUP_KEEP" -le 100 ] || stop "$CONF: BACKUP_KEEP must be 1-100"
  while IFS= read -r p; do
    case $p in /*) stop "$CONF: EXCLUDE '$p' must be relative to REMOTE_ROOT (no leading /)" ;; esac
    case $p in *"$TAB"*) stop "$CONF: EXCLUDE '$p' contains a tab" ;; esac
  done < "$RUN/conf-excludes"
  while IFS= read -r p; do
    [[ $p =~ ^https?://[^[:space:]\']+$ ]] || stop "$CONF: CHECK_URL '$p' must be an http(s) URL"
  done < "$RUN/check-urls"

  # Never deployed, never deleted, never compared (built in, cannot be turned off).
  {
    printf '%s\n' '.git*' '*/.git*'
    printf '%s\n' '.deploy' '.deploy/*' '.claude' '.claude/*' '.env' '.env.*' '*/.env' '*/.env.*' '*.md' '*.sh'
    cat "$RUN/conf-excludes"
  } > "$RUN/excludes"
  EXC_LIST=$(cat "$RUN/excludes")
  PRUNE_DIRS=""
  while IFS= read -r p; do
    case $p in
      */\*) local d=${p%/\*}
            if [[ $d =~ ^[A-Za-z0-9._-][A-Za-z0-9._/-]*$ ]]; then PRUNE_DIRS="$PRUNE_DIRS $d"; fi ;;
    esac
  done < "$RUN/excludes"
}

is_excluded() {
  local pat IFS=$'\n'
  set -f
  for pat in $EXC_LIST; do
    # shellcheck disable=SC2053
    if [[ $1 == $pat ]]; then set +f; return 0; fi
  done
  set +f
  return 1
}

# ---------------------------------------------------------------- helpers
q() { case $1 in *"'"*) die "internal: quote in argument" ;; esac; printf "'%s'" "$1"; }
rsh() { "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" "$1"; }
# Run an action of the remote helper (POSIX sh, sent on stdin).
rcall() {
  local a s=""
  for a in "$@"; do s="$s $(q "$a")"; done
  remote_lib | "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" "sh -s --$s"
}
safe_text() { printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._@:=+/-' | cut -c1-120; }
who_am_i() { local u; u=$(git config user.name 2>/dev/null || true); [ -n "$u" ] || u=${USER:-unknown}; safe_text "$u"; }
now_id() { date -u +%Y%m%dT%H%M%SZ; }

# "hash  ./path" lines -> "path<TAB>hash", sorted. Refuses names sha256sum had to escape.
to_tsv() {
  awk -v tab="$TAB" '
    substr($0,1,1)=="\\" { bad=1; next }
    { h=substr($0,1,64); p=substr($0,67); sub(/^\.\//,"",p)
      if (index(p,tab)) { bad=1; next }
      print p tab h }
    END { if (bad) exit 9 }' | sort -t "$TAB" -k1,1
}
filter_tsv() {
  local p h
  while IFS="$TAB" read -r p h; do
    is_excluded "$p" || printf '%s\t%s\n' "$p" "$h"
  done
}
local_manifest() { # dir -> tsv on stdout (filtered)
  ( cd "$1" && find . -type f -exec $HASH {} + ) | to_tsv | filter_tsv \
    || stop "a file name contains a newline, tab or backslash under $1 (not supported)"
}
only_in()  { comm -23 <(cut -f1 "$1") <(cut -f1 "$2"); }
changed()  { join -t "$TAB" "$1" "$2" | awk -F "$TAB" '$2!=$3 {print $1}'; }
nul() { tr '\n' '\0' < "$1"; }
count() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
token_of() { cat "$@" | $HASH | cut -c1-16; }

remote_manifest() { # -> $1 (filtered tsv); stops on server symlinks
  local raw="$RUN/remote.raw"
  rcall manifest "$REMOTE_ROOT" $PRUNE_DIRS > "$raw" || stop "could not read production files under $REMOTE_ROOT (permission or connection)"
  local l; : > "$RUN/remote.links"
  grep '^LINK ' "$raw" | sed 's/^LINK \.\///' | while IFS= read -r l; do is_excluded "$l" || printf '%s\n' "$l"; done > "$RUN/remote.links" || true
  if [ -s "$RUN/remote.links" ]; then
    sed 's/^/  /' "$RUN/remote.links" >&2
    stop "symbolic links on the server are not supported (add them to EXCLUDE if they are not yours to manage)"
  fi
  sed '/^LINK /d' "$raw" | to_tsv | filter_tsv > "$1" || stop "a production file name contains a newline, tab or backslash (not supported)"
}

fetch_remote_files() { # listfile destdir
  [ -s "$1" ] || return 0
  mkdir -p "$2"
  nul "$1" | rsh "cd $(q "$REMOTE_ROOT") && tar --null -T - -cf -" | tar -xf - -C "$2" \
    || stop "could not download server copies for comparison"
}

read_state() {
  DEPLOYED=""; LOCK=""; INPROGRESS=""; HAS_STATE=no; HAS_MANIFEST=no
  local out line
  out=$(rcall state "$REMOTE_ROOT" "$STATE_DIR") || stop "cannot connect to '$SSH_HOST' (check: ssh $SSH_HOST true)"
  while IFS= read -r line; do
    case $line in
      NOROOT) stop "REMOTE_ROOT does not exist on the server: $REMOTE_ROOT" ;;
      INSIDE) stop "STATE_DIR resolves inside REMOTE_ROOT on the server (it would be public)" ;;
      STATE=yes) HAS_STATE=yes ;;
      MANIFEST=yes) HAS_MANIFEST=yes ;;
      DEPLOYED=*) DEPLOYED=${line#DEPLOYED=}
                  [[ $DEPLOYED =~ ^[0-9a-f]{40}$ ]] || stop "the server's deploy record is broken (not a commit id). Ask for help; do not edit it by guess" ;;
      LOCK=*) LOCK=$(safe_text "${line#LOCK=}") ;;
      INPROGRESS=*) INPROGRESS=$(printf '%s' "${line#INPROGRESS=}" | tr -cd 'A-Za-z0-9:-')
                    [[ $INPROGRESS =~ ^(undo:)?[0-9TZ]+-[0-9a-f]+$ ]] || stop "the server's unfinished marker is broken: ask for help" ;;
    esac
  done <<< "$out"
}

# ---------------------------------------------------------------- git checks
check_git() {
  local br head up entry rel st dirty=""
  br=$(git symbolic-ref --short -q HEAD || true)
  [ "$br" = "$BRANCH" ] || stop "current branch is '${br:-detached HEAD}', expected '$BRANCH'"
  git ls-files --error-unmatch "$CONF" >/dev/null 2>&1 || stop "$CONF is not committed (commit it so everyone deploys with the same settings)"
  while IFS= read -r -d '' entry; do
    st=${entry:0:2}; rel=${entry:3}
    case $st in R*|C*) IFS= read -r -d '' _ || true ;; esac
    case $rel in .deploy/*) dirty="$dirty  $st $rel"$'\n'; continue ;; esac
    if [ "$SOURCE_DIR" != "." ]; then
      case $rel in "$SOURCE_DIR"/*) rel=${rel#"$SOURCE_DIR"/} ;; *) continue ;; esac
    fi
    is_excluded "$rel" || dirty="$dirty  $st $rel"$'\n'
  done < <(git status --porcelain -z --untracked-files=all)
  if [ -n "$dirty" ]; then printf '%s' "$dirty" | head -30 >&2
    stop "uncommitted or untracked files in the deploy area (commit them, or add to .gitignore / EXCLUDE)"; fi
  git fetch --quiet "$REMOTE" "$BRANCH" || stop "git fetch $REMOTE $BRANCH failed (network or permission)"
  head=$(git rev-parse HEAD)
  up=$(git rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH") || stop "$REMOTE/$BRANCH not found after fetch"
  if [ "$head" != "$up" ]; then
    if git merge-base --is-ancestor "$up" "$head"; then stop "local $BRANCH has commits not pushed yet. Push first: git push $REMOTE $BRANCH"
    elif git merge-base --is-ancestor "$head" "$up"; then stop "local $BRANCH is behind $REMOTE/$BRANCH (someone pushed). Update first: git pull --ff-only $REMOTE $BRANCH"
    else stop "local $BRANCH and $REMOTE/$BRANCH have diverged. Resolve (pull/rebase) before deploying"; fi
  fi
  HEAD_SHA=$head
  if [ "$SOURCE_DIR" = "." ]; then TREE=$HEAD_SHA; else
    git cat-file -e "$HEAD_SHA:$SOURCE_DIR" 2>/dev/null || stop "SOURCE_DIR '$SOURCE_DIR' does not exist in HEAD"
    TREE="$HEAD_SHA:$SOURCE_DIR"; fi
}

build_target() {
  mkdir -p "$RUN/target"
  git archive --format=tar "$TREE" | tar -xf - -C "$RUN/target" || die "git archive failed"
  local l links=""
  while IFS= read -r l; do l=${l#./}; is_excluded "$l" || links="$links  $l"$'\n'; done < <(cd "$RUN/target" && find . -type l)
  [ -z "$links" ] || { printf '%s' "$links" >&2; stop "symbolic links in the repository are not supported by this procedure"; }
  local_manifest "$RUN/target" > "$RUN/target.tsv"
}

show_list() { # tag file
  local p; while IFS= read -r p; do printf '  %s  %s\n' "$1" "$p"; done < "$2"
}

# ---------------------------------------------------------------- plan (preview / apply)
build_plan() { # $1 = 1 when we hold the lock ourselves
  load_conf; check_git; read_state
  [ "$HAS_STATE" = yes ] && [ -n "$DEPLOYED" ] && [ "$HAS_MANIFEST" = yes ] \
    || stop "no deploy record on the server yet. First time: run 'bash bin/deploy-ssh.sh${TOPT} baseline' (rule section 5)"
  [ -z "$INPROGRESS" ] || stop "a previous apply or undo did not finish ($INPROGRESS). Run 'bash bin/deploy-ssh.sh${TOPT} undo' first"
  if [ -n "$LOCK" ] && [ "${1:-0}" != 1 ]; then echo "WARNING: someone holds the deploy lock: $LOCK"; fi
  [[ $DEPLOYED =~ ^[0-9a-f]{40}$ ]] || stop "the server's deploy record is broken: '$DEPLOYED'"
  git cat-file -e "$DEPLOYED^{commit}" 2>/dev/null \
    || stop "the last deployed commit ${DEPLOYED:0:12} is not in your repository. It was deployed from a commit that was never pushed. Find who deployed it ('status') before going on"
  git merge-base --is-ancestor "$DEPLOYED" "$HEAD_SHA" \
    || stop "production has commit ${DEPLOYED:0:12}, which is not part of $BRANCH. Deploying would roll it back. Ask who deployed it ('status')"

  echo "== deploy-ssh preview  target=$TARGET  host=$SSH_HOST =="
  echo "server path   : $REMOTE_ROOT"
  echo "deploy commit : $(git log -1 --format='%h %s (%an)' "$HEAD_SHA")"
  echo "last deployed : $(git log -1 --format='%h %s (%an)' "$DEPLOYED")"
  if [ "$DEPLOYED" != "$HEAD_SHA" ]; then
    echo "commits since last deploy:"
    git log --format='  %h %ad %an: %s' --date=short "$DEPLOYED..$HEAD_SHA" -- ${SOURCE_DIR%.} | head -50
  fi

  rsh "cat $(q "$STATE_DIR/manifest")" > "$RUN/stored.raw" || stop "could not read the deploy record"
  filter_tsv < "$RUN/stored.raw" | sort -t "$TAB" -k1,1 > "$RUN/stored.tsv"
  remote_manifest "$RUN/prod.tsv"

  if ! cmp -s "$RUN/stored.tsv" "$RUN/prod.tsv"; then
    changed "$RUN/stored.tsv" "$RUN/prod.tsv" > "$RUN/drift.mod"
    only_in "$RUN/prod.tsv" "$RUN/stored.tsv" > "$RUN/drift.add"
    only_in "$RUN/stored.tsv" "$RUN/prod.tsv" > "$RUN/drift.del"
    echo
    echo "Production was changed after the last deploy (not by this tool):"
    show_list "changed on server" "$RUN/drift.mod"
    show_list "new on server    " "$RUN/drift.add"
    show_list "gone from server " "$RUN/drift.del"
    cat "$RUN/drift.mod" "$RUN/drift.add" > "$RUN/drift.fetch"
    fetch_remote_files "$RUN/drift.fetch" "$RUN/drift-server"
    echo "server copies : $RUN/drift-server/"
    echo "NEXT: the commits listed above are deployed changes only. Anything here was edited on the server"
    echo "      directly (CMS admin, FTP, another tool). Decide with the person responsible: rule section 6."
    stop "production drift detected - nothing was changed"
  fi

  build_target
  only_in "$RUN/target.tsv" "$RUN/prod.tsv" > "$RUN/added.lst"
  changed "$RUN/target.tsv" "$RUN/prod.tsv" > "$RUN/modified.lst"
  only_in "$RUN/prod.tsv" "$RUN/target.tsv" > "$RUN/deleted.lst"
  NA=$(count "$RUN/added.lst"); NM=$(count "$RUN/modified.lst"); ND=$(count "$RUN/deleted.lst")
  # A new file whose path is a folder on the server, or whose parent folder is a file on the server.
  cut -f1 "$RUN/prod.tsv" > "$RUN/prod.paths"
  awk -v pf="$RUN/prod.paths" 'BEGIN { while ((getline l < pf) > 0) { f[l]=1; n=l; while (sub(/\/[^\/]*$/,"",n)) d[n]=1 } }
    ($0 in d) { print "  folder on server : " $0; next }
    { n=$0; while (sub(/\/[^\/]*$/,"",n)) if (n in f) { print "  file on server   : " n " (needed as a folder for " $0 ")"; next } }' \
    "$RUN/added.lst" > "$RUN/conflicts"
  if [ -s "$RUN/conflicts" ]; then cat "$RUN/conflicts" >&2
    stop "a file and a folder with the same path (server vs commit). This procedure does not switch between them: change it by hand, then run baseline"; fi
  printf '%s\n' "v$VERSION" "$TARGET" "$HEAD_SHA" "$DEPLOYED" > "$RUN/token.head"
  TOKEN=$(token_of "$RUN/token.head" "$CONF" "$RUN/prod.tsv" "$RUN/target.tsv")
}

print_plan() {
  echo
  echo "changes: $NM modified, $NA added, $ND deleted"
  if [ $((NA+NM+ND)) -eq 0 ]; then echo "OK: production already matches $(git rev-parse --short "$HEAD_SHA"). Nothing to deploy."; return 0; fi
  cat "$RUN/modified.lst" "$RUN/deleted.lst" > "$RUN/old.fetch"
  fetch_remote_files "$RUN/old.fetch" "$RUN/old"
  mkdir -p "$RUN/old" "$RUN/new"
  cat "$RUN/modified.lst" "$RUN/added.lst" | tr '\n' '\0' | (cd "$RUN/target" && tar --null -T - -cf -) | tar -xf - -C "$RUN/new"
  local p note
  while IFS= read -r p; do
    note=""
    if cmp -s <(tr -d '\r' < "$RUN/old/$p") <(tr -d '\r' < "$RUN/new/$p"); then note="   <- LINE ENDINGS ONLY (CRLF/LF) - check .gitattributes"; fi
    printf '  M  %s%s\n' "$p" "$note"
  done < "$RUN/modified.lst"
  show_list "A" "$RUN/added.lst"
  show_list "D" "$RUN/deleted.lst"
  ( cd "$RUN" && git diff --no-index --no-color old new > "$RUN/changes.diff" 2>/dev/null ) || true
  echo
  echo "full diff     : $RUN/changes.diff ($(count "$RUN/changes.diff") lines)"
  head -n 200 "$RUN/changes.diff"
  [ "$(count "$RUN/changes.diff")" -le 200 ] || echo "... (diff truncated; read the file above)"
  echo
  [ "$ND" -eq 0 ] || echo "NOTE: $ND file(s) will be DELETED from production (they are no longer in the repository)."
  [ "$NA" -eq 0 ] || echo "NOTE: $NA NEW file(s) - check that each path is where you mean it to be."
  echo "TOKEN: $TOKEN"
  echo "NEXT: if this is what you intend, a person types in a terminal:"
  echo "  bash bin/deploy-ssh.sh${TOPT} apply $TOKEN"
}

cmd_preview() { build_plan 0; print_plan; }

# ---------------------------------------------------------------- lock
LOCK_HELD=0
take_lock() {
  local out
  out=$(rcall lock "$STATE_DIR" "$(who_am_i) $(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-') $(now_id) $CMD") || stop "could not reach the server to take the lock"
  case $out in
    LOCKED) LOCK_HELD=1; trap release_lock EXIT ;;
    BUSY*) stop "another deploy is running or was interrupted: ${out#BUSY }. Wait, or ask that person; 'unlock' only if you are sure it is dead" ;;
    *) stop "unexpected answer from server while locking: $out" ;;
  esac
}
release_lock() { if [ "$LOCK_HELD" = 1 ]; then rcall unlock "$STATE_DIR" >/dev/null 2>&1 || echo "WARNING: could not release the lock; run 'unlock'" >&2; LOCK_HELD=0; fi; }

check_urls() {
  [ -s "$RUN/check-urls" ] || return 0
  command -v curl >/dev/null 2>&1 || { echo "check URLs by hand (curl not found):"; sed 's/^/  /' "$RUN/check-urls"; return 0; }
  local u code
  echo "URL check (status only - also open them and check the change itself, rule section 8):"
  while IFS= read -r u; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$u" 2>/dev/null || echo "ERR")
    printf '  %s  %s\n' "$code" "$u"
  done < "$RUN/check-urls"
}

# ---------------------------------------------------------------- apply
cmd_apply() {
  [ -n "$ARG" ] || die "usage: apply TOKEN (run preview first)"
  need_tty
  load_conf
  take_lock
  build_plan 1
  [ "$TOKEN" = "$ARG" ] || stop "something changed since the preview (token is now $TOKEN). Run preview again and read it"
  if [ $((NA+NM+ND)) -eq 0 ]; then echo "OK: nothing to deploy."; return 0; fi
  local id; id="$(now_id)-$(git rev-parse --short=7 "$HEAD_SHA")"
  local st="$RUN/stage"; mkdir -p "$st/files"
  cat "$RUN/added.lst" "$RUN/modified.lst" | tr '\n' '\0' | (cd "$RUN/target" && tar --null -T - -cf -) | tar -xf - -C "$st/files"
  cp "$RUN/added.lst" "$RUN/modified.lst" "$RUN/deleted.lst" "$st/"
  cp "$RUN/prod.tsv" "$st/prev.manifest"; cp "$RUN/target.tsv" "$st/new.manifest"
  printf 'prev=%s\nnew=%s\nid=%s\nuser=%s\n' "$DEPLOYED" "$HEAD_SHA" "$id" "$(who_am_i)" > "$st/meta"
  echo "uploading $((NA+NM)) file(s) to the staging area (outside the public folder)..."
  (cd "$st" && tar -cf - .) | rsh "mkdir -p $(q "$STATE_DIR/incoming/$id") && tar -xf - -C $(q "$STATE_DIR/incoming/$id")" \
    || stop "upload failed - production unchanged"
  rcall stagehash "$STATE_DIR/incoming/$id/files" | to_tsv > "$RUN/staged.tsv" || stop "could not verify the upload - production unchanged"
  cat "$RUN/added.lst" "$RUN/modified.lst" | sort > "$RUN/up.lst"
  join -t "$TAB" "$RUN/up.lst" "$RUN/target.tsv" > "$RUN/up.tsv"
  cmp -s "$RUN/up.tsv" "$RUN/staged.tsv" || { rcall dropstage "$STATE_DIR" "$id" || true; stop "uploaded files do not match (transfer problem) - production unchanged"; }

  remote_manifest "$RUN/recheck.tsv"
  cmp -s "$RUN/recheck.tsv" "$RUN/prod.tsv" || { rcall dropstage "$STATE_DIR" "$id" || true; stop "production changed during the upload - nothing was written. Run preview again"; }
  echo "applying (backup first)..."
  local rc=0
  WRITING=1
  rcall apply "$REMOTE_ROOT" "$STATE_DIR" "$id" > "$RUN/apply.out" 2>&1 || rc=$?
  case $rc in
    0) ;;
    3|4) WRITING=0; cat "$RUN/apply.out" >&2; rcall dropstage "$STATE_DIR" "$id" || true; stop "could not start (rc=$rc) - production unchanged" ;;
    *) cat "$RUN/apply.out" >&2; fail "error while writing files (rc=$rc)" ;;
  esac
  remote_manifest "$RUN/after.tsv"
  cmp -s "$RUN/after.tsv" "$RUN/target.tsv" || { diff "$RUN/target.tsv" "$RUN/after.tsv" | head -20 >&2 || true; fail "production does not match the commit after copying"; }
  rcall finalize "$STATE_DIR" "$id" "$BACKUP_KEEP" \
    "$(now_id)${TAB}apply${TAB}$(who_am_i)${TAB}$HEAD_SHA${TAB}M=$NM A=$NA D=$ND${TAB}backup=$id" >/dev/null \
    || echo "WARNING: deployed and verified, but writing the record failed. Run 'status' and tell the team." >&2
  WRITING=0
  echo "OK: deployed $(git log -1 --format='%h %s' "$HEAD_SHA") ($NM modified, $NA added, $ND deleted). Verified: production matches the commit."
  echo "backup id: $id   (roll back with: bash bin/deploy-ssh.sh${TOPT} undo)"
  check_urls
}

# ---------------------------------------------------------------- undo
plan_undo() {
  read_state
  [ "$HAS_STATE" = yes ] || stop "no deploy record on the server - nothing to undo"
  local id mode
  if [ -n "$INPROGRESS" ]; then id=${INPROGRESS#undo:}; mode=partial
  else
    [[ $DEPLOYED =~ ^[0-9a-f]{40}$ ]] || stop "no deploy to undo"
    id=$(rcall findbackup "$STATE_DIR" "$DEPLOYED" || true)
    [ -n "$id" ] || stop "no backup of the current deploy (${DEPLOYED:0:12}) - it was a baseline, or its backup was pruned. Undo is not possible; fix forward with a new commit"
    mode=normal
  fi
  [[ $id =~ ^[0-9TZ]+-[0-9a-f]+$ ]] || stop "unexpected backup id '$id'"
  rsh "cat $(q "$STATE_DIR/backups/$id/meta")" > "$RUN/u.meta" || stop "backup $id is incomplete (no meta)"
  U_PREV=$(sed -n 's/^prev=//p' "$RUN/u.meta"); U_NEW=$(sed -n 's/^new=//p' "$RUN/u.meta")
  for f in added.lst modified.lst deleted.lst prev.manifest new.manifest; do
    rsh "cat $(q "$STATE_DIR/backups/$id/$f")" > "$RUN/u.$f" || stop "backup $id is incomplete ($f)"
  done
  local p hit=""
  while IFS= read -r p; do is_excluded "$p" && hit="$hit  $p"$'\n'; done < <(cat "$RUN/u.added.lst" "$RUN/u.modified.lst" "$RUN/u.deleted.lst")
  if [ -n "$hit" ]; then printf '%s' "$hit" >&2
    stop "undo would touch files that are now in EXCLUDE (not yours to change). Restore them by hand from $STATE_DIR/backups/$id/files, or remove the EXCLUDE line"; fi
  rcall stagehash "$STATE_DIR/backups/$id/files" | to_tsv > "$RUN/u.files.tsv" || stop "backup $id cannot be read"
  remote_manifest "$RUN/u.now.tsv"
  if [ "$mode" = normal ]; then
    [ "$U_NEW" = "$DEPLOYED" ] || stop "the newest backup ($id) is not the current deploy - undo cannot pick a safe point"
    filter_tsv < "$RUN/u.new.manifest" | sort -t "$TAB" -k1,1 > "$RUN/u.expect"
    cmp -s "$RUN/u.expect" "$RUN/u.now.tsv" || stop "production changed after deploy $id, so undo would overwrite those changes. Check with 'preview' and decide by hand"
  fi
  echo "== deploy-ssh undo  target=$TARGET  host=$SSH_HOST =="
  echo "undo deploy   : $id ($mode)"
  echo "back to commit: $(git log -1 --format='%h %s' "$U_PREV" 2>/dev/null || echo "${U_PREV:0:12}")"
  echo "restores $(count "$RUN/u.modified.lst") changed + $(count "$RUN/u.deleted.lst") deleted file(s); removes $(count "$RUN/u.added.lst") added file(s)"
  show_list "remove " "$RUN/u.added.lst"
  printf '%s\n' "v$VERSION" "$TARGET" "$id" "$mode" > "$RUN/u.head"
  U_ID=$id; U_MODE=$mode
  TOKEN=$(token_of "$RUN/u.head" "$CONF" "$RUN/u.meta" "$RUN/u.added.lst" "$RUN/u.modified.lst" "$RUN/u.deleted.lst" \
    "$RUN/u.prev.manifest" "$RUN/u.new.manifest" "$RUN/u.files.tsv" "$RUN/u.now.tsv")
}

cmd_undo() {
  load_conf
  if [ -z "$ARG" ]; then
    plan_undo
    echo "TOKEN: $TOKEN"
    echo "NEXT: a person types in a terminal:  bash bin/deploy-ssh.sh${TOPT} undo $TOKEN"
    return 0
  fi
  need_tty
  take_lock
  plan_undo
  [ "$TOKEN" = "$ARG" ] || stop "something changed since you looked (token is now $TOKEN). Run undo without a token again"
  local rc=0
  WRITING=1
  rcall undo "$REMOTE_ROOT" "$STATE_DIR" "$U_ID" > "$RUN/undo.rc" 2>&1 || rc=$?
  if [ "$rc" = 3 ]; then WRITING=0; cat "$RUN/undo.rc" >&2; stop "undo could not start (rc=3) - production unchanged"; fi
  [ "$rc" = 0 ] || { cat "$RUN/undo.rc" >&2; fail "undo stopped half way (rc=$rc). Fix the cause (e.g. permissions), then run undo again - it repeats the same restore"; }
  remote_manifest "$RUN/u.after.tsv"
  filter_tsv < "$RUN/u.prev.manifest" | sort -t "$TAB" -k1,1 > "$RUN/u.prev.tsv"
  cmp -s "$RUN/u.after.tsv" "$RUN/u.prev.tsv" || { diff "$RUN/u.prev.tsv" "$RUN/u.after.tsv" | head -20 >&2 || true; fail "production does not match the state before deploy $U_ID"; }
  rcall undofinal "$STATE_DIR" "$U_ID" "$(now_id)${TAB}undo${TAB}$(who_am_i)${TAB}$U_PREV${TAB}mode=$U_MODE${TAB}backup=$U_ID" >/dev/null \
    || echo "WARNING: restored and verified, but writing the record failed. Run 'status'." >&2
  WRITING=0
  echo "OK: undone. Production is back to the state before deploy $U_ID (verified)."
  echo "NEXT: the commit is still on $BRANCH. Fix it with a new commit (e.g. git revert), push, then preview/apply again."
  check_urls
}

# ---------------------------------------------------------------- baseline
plan_baseline() {
  check_git; read_state
  [ -z "$INPROGRESS" ] || stop "a previous apply or undo did not finish ($INPROGRESS). Run undo first"
  if [ -n "$DEPLOYED" ]; then
    git cat-file -e "$DEPLOYED^{commit}" 2>/dev/null && git merge-base --is-ancestor "$DEPLOYED" "$HEAD_SHA" \
      || stop "the last deployed commit ${DEPLOYED:0:12} is not part of $BRANCH. Sort that out first ('status')"
  fi
  remote_manifest "$RUN/prod.tsv"
  build_target
  only_in "$RUN/prod.tsv" "$RUN/target.tsv" > "$RUN/b.server"
  only_in "$RUN/target.tsv" "$RUN/prod.tsv" > "$RUN/b.repo"
  changed "$RUN/prod.tsv" "$RUN/target.tsv" > "$RUN/b.diff"
  echo "== deploy-ssh baseline  target=$TARGET  host=$SSH_HOST =="
  echo "server path : $REMOTE_ROOT"
  echo "commit      : $(git log -1 --format='%h %s' "$HEAD_SHA")"
  echo "record now  : ${DEPLOYED:+$(git log -1 --format='%h' "$DEPLOYED")}${DEPLOYED:-none (first time)}"
  echo "server vs commit: $(count "$RUN/b.diff") differ, $(count "$RUN/b.server") only on server, $(count "$RUN/b.repo") only in repository"
  show_list "differ        " "$RUN/b.diff"
  show_list "only on server" "$RUN/b.server"
  show_list "only in repo  " "$RUN/b.repo"
  cat "$RUN/b.diff" "$RUN/b.server" > "$RUN/b.fetch"
  fetch_remote_files "$RUN/b.fetch" "$RUN/server"
  [ ! -s "$RUN/b.fetch" ] || echo "server copies: $RUN/server/  (copy what is right into the repository, commit, push, run baseline again)"
  printf '%s\n' "v$VERSION" "$TARGET" "baseline" "$HEAD_SHA" "$DEPLOYED" > "$RUN/b.head"
  TOKEN=$(token_of "$RUN/b.head" "$CONF" "$RUN/prod.tsv" "$RUN/target.tsv")
}

cmd_baseline() {
  load_conf
  if [ -z "$ARG" ]; then
    plan_baseline
    echo
    echo "Recording a baseline says: 'the server as it is now is the start point; next preview compares the"
    echo "commit with it'. Remaining differences will show up in the next preview as changes to deploy."
    echo "TOKEN: $TOKEN"
    echo "NEXT: when the server-side files that should be kept are in the repository, a person types:"
    echo "  bash bin/deploy-ssh.sh${TOPT} baseline $TOKEN"
    return 0
  fi
  need_tty
  take_lock
  plan_baseline
  [ "$TOKEN" = "$ARG" ] || stop "something changed since you looked (token is now $TOKEN). Run baseline without a token again"
  rsh "mkdir -p $(q "$STATE_DIR/backups") && cat > $(q "$STATE_DIR/manifest.new")" < "$RUN/prod.tsv" || stop "could not write the record"
  rcall baseline "$STATE_DIR" "$HEAD_SHA" "$(now_id)${TAB}baseline${TAB}$(who_am_i)${TAB}$HEAD_SHA${TAB}files=$(count "$RUN/prod.tsv")" >/dev/null \
    || stop "could not write the record"
  echo "OK: baseline recorded at $(git log -1 --format='%h %s' "$HEAD_SHA"). Production files were not touched."
  echo "NEXT: bash bin/deploy-ssh.sh${TOPT} preview"
}

# ---------------------------------------------------------------- status / preflight / unlock
cmd_status() {
  load_conf; read_state
  echo "== deploy-ssh status  target=$TARGET  host=$SSH_HOST =="
  echo "server path : $REMOTE_ROOT"
  if [ -n "$DEPLOYED" ]; then echo "deployed    : $(git log -1 --format='%h %s (%an)' "$DEPLOYED" 2>/dev/null || echo "$DEPLOYED (not in your repository - fetch?)")"
  else echo "deployed    : none (run baseline first)"; fi
  echo "lock        : ${LOCK:-free}"
  echo "unfinished  : ${INPROGRESS:-none}"
  echo "recent log  :"
  rsh "tail -n 10 $(q "$STATE_DIR/log") 2>/dev/null" | sed 's/^/  /' || true
  echo "backups     :"
  rsh "ls -1 $(q "$STATE_DIR/backups") 2>/dev/null | tail -n 10" | sed 's/^/  /' || true
}

cmd_preflight() {
  local c miss=""
  for c in git ssh tar find sort comm join awk cut tr cmp sed grep; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
  echo "this PC     : bash ${BASH_VERSION}, hash=$HASH, missing:${miss:- none}"
  command -v curl >/dev/null 2>&1 || echo "  (curl not found: URL checks will be manual)"
  [ -z "$miss" ] || die "install the missing commands first"
  load_conf
  echo "config      : $CONF  host=$SSH_HOST  root=$REMOTE_ROOT  state=$STATE_DIR  source=$SOURCE_DIR  branch=$REMOTE/$BRANCH"
  local out
  out=$(rcall preflight "$REMOTE_ROOT" "$STATE_DIR") || stop "cannot connect: ssh $SSH_HOST (key login must work without a password prompt)"
  echo "$out" | sed 's/^/server      : /'
  case $out in *"MISSING= none"*) ;; *) stop "the server lacks commands this procedure needs (see MISSING)" ;; esac
  case $out in *"ROOT=missing"*) stop "REMOTE_ROOT does not exist" ;; esac
  case $out in *"ROOTW=no"*) stop "REMOTE_ROOT is not writable by this user - do not work around it with sudo; see rule section 3" ;; esac
  case $out in *"STATEW=no"*) stop "STATE_DIR cannot be created by this user" ;; esac
  case $out in *"STATEINSIDE"*) stop "STATE_DIR resolves inside REMOTE_ROOT" ;; esac
  echo "OK: preflight passed."
}

cmd_unlock() {
  need_tty; load_conf; read_state
  [ -n "$LOCK" ] || { echo "OK: no lock."; return 0; }
  echo "lock held by: $LOCK"
  rcall unlock "$STATE_DIR" >/dev/null || stop "could not remove the lock"
  echo "OK: lock removed."
  [ -z "$INPROGRESS" ] || echo "NOTE: an apply or undo did not finish ($INPROGRESS). Run 'undo' next."
}

# ---------------------------------------------------------------- remote helper (POSIX sh)
remote_lib() {
cat <<'REMOTE'
set -u
act=$1; shift
hashcmd() { if command -v sha256sum >/dev/null 2>&1; then echo sha256sum; else echo "shasum -a 256"; fi; }
case $act in
state)
  R=$1 S=$2
  [ -d "$R" ] || { echo NOROOT; exit 0; }
  rr=$(cd "$R" && pwd -P)
  if [ -d "$S" ]; then
    ss=$(cd "$S" && pwd -P)
    case "$ss/" in "$rr"/*) echo INSIDE; exit 0 ;; esac
    echo STATE=yes
    if [ -f "$S/deployed" ]; then echo "DEPLOYED=$(cat "$S/deployed")"; fi
    if [ -f "$S/manifest" ]; then echo MANIFEST=yes; fi
    if [ -d "$S/lock" ]; then echo "LOCK=$(tr '\n' ' ' < "$S/lock/info" 2>/dev/null)"; fi
    if [ -f "$S/in-progress" ]; then echo "INPROGRESS=$(cat "$S/in-progress")"; fi
  else echo STATE=no; fi
  exit 0 ;;
manifest)
  R=$1; shift
  set -f
  cd "$R" || exit 7
  H=$(hashcmd)
  expr="-name .git"
  for d in "$@"; do expr="$expr -o -path ./$d"; done
  find . \( \( $expr \) -type d \) -prune -o -type f -exec $H {} + || exit 7
  find . \( \( $expr \) -type d \) -prune -o -type l -print | sed 's/^/LINK /'
  exit 0 ;;
stagehash)
  cd "$1" || exit 7
  H=$(hashcmd)
  find . -type f -exec $H {} + || exit 7
  exit 0 ;;
lock)
  S=$1 INFO=$2
  mkdir -p "$S" || exit 7
  if mkdir "$S/lock" 2>/dev/null; then printf '%s\n' "$INFO" > "$S/lock/info"; echo LOCKED
  else echo "BUSY $(tr '\n' ' ' < "$S/lock/info" 2>/dev/null)"; fi
  exit 0 ;;
unlock)
  rm -rf "$1/lock"; exit $? ;;
findbackup)
  S=$1 C=$2
  for m in "$S"/backups/*/meta; do
    [ -f "$m" ] || continue
    d=$(dirname "$m"); case $d in *.undone) continue ;; esac
    if grep -qx "new=$C" "$m"; then basename "$d"; fi
  done | sort | tail -n 1
  exit 0 ;;
dropstage)
  rm -rf "$1/incoming/$2"; exit 0 ;;
apply)
  R=$1 S=$2 ID=$3
  X=$S/incoming/$ID; B=$S/backups/$ID
  [ -d "$S/lock" ] || { echo "ERR: lock not held"; exit 3; }
  [ ! -e "$S/in-progress" ] || { echo "ERR: unfinished apply exists"; exit 3; }
  [ ! -e "$B" ] || { echo "ERR: backup id exists"; exit 3; }
  mkdir -p "$B/files" || exit 3
  for f in meta prev.manifest new.manifest added.lst modified.lst deleted.lst; do cp "$X/$f" "$B/$f" || { rm -rf "$B"; exit 3; }; done
  export R B X
  if ! tr '\n' '\0' < "$B/added.lst" | ( cd "$R" && xargs -0 sh -c 'for f do
      if [ -d "$f" ]; then echo "ERR: CONFLICT folder exists on server: $f"; exit 255; fi
      d=$(dirname -- "$f")
      while [ "$d" != "." ]; do
        if [ -L "$d" ]; then echo "ERR: CONFLICT folder is a symbolic link on server: $d"; exit 255; fi
        if [ -e "$d" ] && [ ! -d "$d" ]; then echo "ERR: CONFLICT file exists on server where a folder is needed: $d"; exit 255; fi
        d=$(dirname -- "$d")
      done
    done' sh ); then rm -rf "$B"; exit 3; fi
  if ! cat "$B/modified.lst" "$B/deleted.lst" | tr '\n' '\0' | ( cd "$R" && xargs -0 sh -c 'for f do
      if [ -L "$f" ]; then echo "ERR: CONFLICT is a symbolic link on server: $f"; exit 255; fi
      d=$(dirname -- "$f")
      while [ "$d" != "." ]; do
        if [ -L "$d" ]; then echo "ERR: CONFLICT folder is a symbolic link on server: $d"; exit 255; fi
        d=$(dirname -- "$d")
      done
    done' sh ); then rm -rf "$B"; exit 3; fi
  if ! cat "$B/modified.lst" "$B/deleted.lst" | tr '\n' '\0' | ( cd "$R" && xargs -0 sh -c 'for f do mkdir -p -- "$B/files/$(dirname -- "$f")" && cp -p -- "$f" "$B/files/$f" || exit 255; done' sh ); then
    rm -rf "$B"; echo "ERR: backup failed"; exit 4
  fi
  echo "$ID" > "$S/in-progress" || { rm -rf "$B"; echo "ERR: cannot write marker"; exit 4; }
  cat "$B/added.lst" "$B/modified.lst" | tr '\n' '\0' | ( cd "$X/files" && xargs -0 sh -c 'for f do mkdir -p -- "$R/$(dirname -- "$f")" && cp -- "$f" "$R/$f" || exit 255; done' sh ) || { echo "ERR: copy failed"; exit 5; }
  tr '\n' '\0' < "$B/deleted.lst" | ( cd "$R" && xargs -0 sh -c 'for f do rm -f -- "$f" || exit 255; done' sh ) || { echo "ERR: delete failed"; exit 5; }
  echo APPLIED; exit 0 ;;
finalize)
  S=$1 ID=$2 KEEP=$3 LOG=$4
  B=$S/backups/$ID
  cp "$B/new.manifest" "$S/manifest.tmp" && mv "$S/manifest.tmp" "$S/manifest" || exit 7
  sed -n 's/^new=//p' "$B/meta" > "$S/deployed.tmp" && mv "$S/deployed.tmp" "$S/deployed" || exit 7
  printf '%s\n' "$LOG" >> "$S/log"
  rm -f "$S/in-progress"; rm -rf "$S/incoming/$ID"
  # Keep the backup of this deploy no matter how names sort; prune the oldest of the others.
  n=$(ls -1 "$S/backups" | grep -vx "$ID" | wc -l)
  k=$((KEEP-1))
  if [ "$n" -gt "$k" ]; then ls -1 "$S/backups" | grep -vx "$ID" | sort | head -n $((n-k)) | while read -r d; do rm -rf "$S/backups/$d"; done; fi
  exit 0 ;;
undo)
  R=$1 S=$2 ID=$3
  B=$S/backups/$ID
  [ -d "$S/lock" ] || { echo "ERR: lock not held"; exit 3; }
  if ! cat "$B/added.lst" "$B/modified.lst" "$B/deleted.lst" | tr '\n' '\0' | ( cd "$R" && xargs -0 sh -c 'for f do
      if [ -L "$f" ]; then echo "ERR: CONFLICT is a symbolic link on server: $f"; exit 255; fi
      d=$(dirname -- "$f")
      while [ "$d" != "." ]; do
        if [ -L "$d" ]; then echo "ERR: CONFLICT folder is a symbolic link on server: $d"; exit 255; fi
        d=$(dirname -- "$d")
      done
    done' sh ); then exit 3; fi
  echo "undo:$ID" > "$S/in-progress" || { echo "ERR: cannot write marker"; exit 3; }
  export R B
  tr '\n' '\0' < "$B/added.lst" | ( cd "$R" && xargs -0 sh -c 'for f do rm -f -- "$f" || exit 255; done' sh ) || { echo "ERR: remove failed"; exit 5; }
  cat "$B/modified.lst" "$B/deleted.lst" | tr '\n' '\0' | ( cd "$B/files" && xargs -0 sh -c 'for f do mkdir -p -- "$R/$(dirname -- "$f")" && cp -- "$f" "$R/$f" || exit 255; done' sh ) || { echo "ERR: restore failed"; exit 5; }
  exit 0 ;;
undofinal)
  S=$1 ID=$2 LOG=$3
  B=$S/backups/$ID
  cp "$B/prev.manifest" "$S/manifest.tmp" && mv "$S/manifest.tmp" "$S/manifest" || exit 7
  sed -n 's/^prev=//p' "$B/meta" > "$S/deployed.tmp" && mv "$S/deployed.tmp" "$S/deployed" || exit 7
  printf '%s\n' "$LOG" >> "$S/log"
  rm -f "$S/in-progress"; rm -rf "$S/incoming/$ID"
  mv "$B" "$B.undone"
  exit 0 ;;
baseline)
  S=$1 C=$2 LOG=$3
  mv "$S/manifest.new" "$S/manifest" || exit 7
  printf '%s\n' "$C" > "$S/deployed.tmp" && mv "$S/deployed.tmp" "$S/deployed" || exit 7
  printf '%s\n' "$LOG" >> "$S/log"
  exit 0 ;;
preflight)
  R=$1 S=$2
  echo "USER=$(id -un 2>/dev/null)"
  miss=""
  for c in sh find tar cp mkdir mv rm xargs sed tr cat ls sort head tail wc dirname grep; do command -v $c >/dev/null 2>&1 || miss="$miss $c"; done
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || miss="$miss sha256sum"
  if command -v tar >/dev/null 2>&1; then tar --help 2>&1 | grep -q -- '--null' || miss="$miss tar(--null)"; fi
  echo "MISSING=${miss:- none}"
  if [ -d "$R" ]; then
    echo "ROOT=$(ls -ld "$R")"
    if [ -w "$R" ]; then echo ROOTW=yes; else echo ROOTW=no; fi
    rr=$(cd "$R" && pwd -P)
  else echo ROOT=missing; rr=/nonexistent; fi
  p=$S; while [ ! -d "$p" ]; do p=$(dirname "$p"); done
  if [ -w "$p" ]; then echo "STATEW=yes (nearest existing: $p)"; else echo "STATEW=no (nearest existing: $p)"; fi
  pp=$(cd "$p" && pwd -P); case "$pp/" in "$rr"/*) echo STATEINSIDE ;; esac
  exit 0 ;;
*) echo "unknown action $act"; exit 9 ;;
esac
REMOTE
}

# ---------------------------------------------------------------- dispatch
mkdir -p "$WORK"
for old in "$WORK"/run-*; do
  [ -d "$old" ] || continue
  [ -n "$(find "$old" -maxdepth 0 -mmin +1440 2>/dev/null)" ] || continue
  kill -0 "${old##*-}" 2>/dev/null && continue
  rm -rf "$old"
done
mkdir -p "$RUN"
case $CMD in
  preflight) cmd_preflight ;;
  preview)   cmd_preview ;;
  apply)     cmd_apply ;;
  undo)      cmd_undo ;;
  baseline)  cmd_baseline ;;
  status)    cmd_status ;;
  unlock)    cmd_unlock ;;
  *) die "unknown command '$CMD' (try --help)" ;;
esac
}

main "$@"
