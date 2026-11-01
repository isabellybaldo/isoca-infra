#!/usr/bin/env bash
# Tests box/play-apply in throwaway directories with a fake docker on PATH: it logs
# what it is asked to do and plays the part of a container that is healthy or not.
# Also holds the text checks on the two systemd units, which no test here can start.
# shellcheck disable=SC2010,SC2012,SC2015,SC2016 # ls for tidy output; A && ok || bad is the intent; the fake's $ are its own
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
PA="$here/../box/play-apply"
UNIT_PATH="$here/../box/play-apply.path"
UNIT_SERVICE="$here/../box/play-apply.service"
UNIT_TIMER="$here/../box/play-apply.timer"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0 passes=0 skips=0
ok() { echo "ok   $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; failures=$((failures + 1)); }
skip() { echo "SKIP $1: $2"; skips=$((skips + 1)); }

for f in "$PA" "$UNIT_PATH" "$UNIT_SERVICE" "$UNIT_TIMER"; do
  [ -f "$f" ] || { echo "FAIL $f does not exist" >&2; exit 1; }
done

D1=sha256:$(printf 'a%.0s' $(seq 64))
D2=sha256:$(printf 'b%.0s' $(seq 64))
D3=sha256:$(printf 'c%.0s' $(seq 64))

# Git Bash has no flock(1); a stub stands in there. The Linux run takes the real lock.
mkdir -p "$tmp/bin"
if ! command -v flock >/dev/null; then
  printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/flock"
  echo "note: a stub flock stands in on this OS"
fi

# The fake. FAKE holds:
#   docker.log     one line per call: "compose <verb> <digest from --env-file>" or "inspect"
#   running        the digest of the container that is up
#   unhealthy      digests whose container reports unhealthy, one per line
#   starting       digests whose container stays in "starting"
#   pull-fails     digests that cannot be pulled
#   release-on-up  a digest written to desired-image during the next `up`, as a release would
#   cached         digests already on the box, for `docker image inspect`
#   images         lines of `repository digest` that `docker images` lists
#   images-fail    `docker images` fails
#   rmi-fails      `docker image rm` fails
#   rmi.log        one line per `docker image rm`, with its arguments
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
listed() { [ -f "$FAKE/$1" ] && grep -qxF -- "$2" "$FAKE/$1"; }
if [ "$1" = compose ]; then
  shift
  digest='' file=''
  while :; do
    case $1 in
      --env-file) digest=$(sed -n 's/^PLAY_DIGEST=//p' "$2"); shift 2 ;;
      -f) file=$2; shift 2 ;;
      *) break ;;
    esac
  done
  echo "compose $1 $digest" >>"$FAKE/docker.log"
  [ "$file" = "$PLAY_COMPOSE" ] || { echo "wrong compose file: $file" >>"$FAKE/docker.log"; exit 1; }
  case $1 in
    pull) listed pull-fails "$digest" && exit 1; exit 0 ;;
    up)
      echo "$digest" >"$FAKE/running"
      if [ -f "$FAKE/release-on-up" ]; then
        mv "$FAKE/release-on-up" "$PLAY_STATE/desired-image"
      fi
      ;;
    down) rm -f "$FAKE/running" ;;
    ps) [ -f "$FAKE/running" ] && echo 0123456789ab ;;
  esac
  exit 0
fi
if [ "$1" = inspect ]; then
  echo inspect >>"$FAKE/docker.log"
  d=$(cat "$FAKE/running")
  if listed unhealthy "$d"; then echo unhealthy
  elif listed starting "$d"; then echo starting
  else echo healthy; fi
  exit 0
fi
if [ "$1" = images ]; then
  echo "images" >>"$FAKE/docker.log"
  [ ! -f "$FAKE/images-fail" ] || exit 1
  [ ! -f "$FAKE/images" ] || cat "$FAKE/images"
  exit 0
fi
if [ "$1" = image ] && [ "$2" = inspect ]; then
  echo "cached-check" >>"$FAKE/docker.log"
  listed cached "${3##*@}" && [ "${3%@*}" = ghcr.io/isabellybaldo/isoca-play ]
  exit
fi
if [ "$1" = image ] && [ "$2" = rm ]; then
  shift 2
  echo "$*" >>"$FAKE/rmi.log"
  [ ! -f "$FAKE/rmi-fails" ] || exit 1
  exit 0
fi
echo "unexpected: $*" >>"$FAKE/docker.log"
exit 1
EOF
# mktemp, as play-apply calls it. Logs where. FAKE/full-at N makes the Nth temp file a
# link to /dev/full, so the write fails with the error a full disk gives.
cat >"$tmp/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/mktemp.log"
if [ -f "$FAKE/full-at" ] && [ "$(wc -l <"$FAKE/mktemp.log")" -eq "$(cat "$FAKE/full-at")" ]; then
  ln -s /dev/full "$PLAY_ROOT/.apply.full" && echo "$PLAY_ROOT/.apply.full"
  exit
fi
exec /usr/bin/mktemp "$@"
EOF
# mv, failing on the target named in FAKE/mv-fails
cat >"$tmp/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ -f "$FAKE/mv-fails" ] && [ "${!#}" = "$(cat "$FAKE/mv-fails")" ]; then exit 1; fi
exec /usr/bin/mv "$@"
EOF
chmod +x "$tmp/bin/"*

n=0
fresh() {
  n=$((n + 1))
  T="$tmp/t$n"
  PLAY_ROOT="$T/play" PLAY_STATE="$T/play/state" FAKE="$T/fake"
  mkdir -p "$PLAY_STATE" "$FAKE"
  grep -E '^    image: ' "$here/../play/compose.yml" >"$T/compose.yml"
  : >"$FAKE/docker.log"
}

# run: rc, $T/out, $T/err
run() {
  rc=0
  PATH="$tmp/bin:$PATH" FAKE=$FAKE PLAY_ROOT=$PLAY_ROOT PLAY_STATE=$PLAY_STATE PLAY_COMPOSE="$T/compose.yml" NO_RETRY="$T/no-retry" \
    HEALTH_WAIT=${HW:-5} HEALTH_POLL=0 bash "$PA" >"$T/out" 2>"$T/err" || rc=$?
}

st() { cat "$PLAY_STATE/$1" 2>/dev/null || echo none; }
envd() { sed -n 's/^PLAY_DIGEST=//p' "$PLAY_ROOT/image.env" 2>/dev/null; }
running() { cat "$FAKE/running" 2>/dev/null || echo none; }
verbs() { grep -vE '^(inspect|images|cached-check)$' "$FAKE/docker.log" | sed 's/sha256:\(.\).*/\1/' | tr '\n' ';'; }
leftovers() { ls -A "$PLAY_STATE" | grep -vxE 'desired-image|applied-image|previous-image|last-result'; ls -A "$PLAY_ROOT" | grep -vxE 'state|image\.env'; }

# on <digest as applied> <digest as previous>: a box that has already released once
on() {
  echo "$1" >"$PLAY_STATE/applied-image"
  echo "$1" >"$PLAY_STATE/desired-image"
  [ -z "${2-}" ] || echo "$2" >"$PLAY_STATE/previous-image"
  echo "PLAY_DIGEST=$1" >"$PLAY_ROOT/image.env"
  echo "$1" >"$FAKE/running"
}
desire() { echo "$1" >"$PLAY_STATE/desired-image"; }

# --- good digests ---------------------------------------------------------------------

fresh
desire "$D1"
run
[ "$rc" -eq 0 ] && ok "first release: exit 0" || bad "first release" "rc=$rc $(cat "$T/err")"
[ "$(st applied-image)" = "$D1" ] && [ "$(running)" = "$D1" ] && [ "$(envd)" = "$D1" ] \
  && ok "first release: applied-image, the container and image.env all name it" || bad "first release state" "$(st applied-image) $(running) $(envd)"
[ "$(st previous-image)" = none ] && ok "first release: no previous-image yet" || bad "first release previous" "$(st previous-image)"
[ "$(verbs)" = "compose pull a;compose up a;compose ps a;" ] && ok "first release: pull, up, health check, through --env-file" || bad "first release calls" "$(verbs)"
[[ "$(st last-result)" == "ok $D1 "* ]] && [ "$(wc -l <"$PLAY_STATE/last-result")" -eq 1 ] \
  && ok "first release: one-line last-result says ok" || bad "first release last-result" "$(st last-result)"
[ -z "$(leftovers)" ] && ok "first release: no temp file left" || bad "first release leftovers" "$(leftovers)"
if [ "$(uname -s)" = Linux ]; then
  # site-deploy runs as deploy and has to read previous-image
  [ "$(stat -c %a "$PLAY_STATE/applied-image" "$PLAY_STATE/last-result" "$PLAY_ROOT/image.env" | sort -u)" = 644 ] \
    && ok "state files are 0644" || bad "state modes"
fi

fresh
on "$D1"
desire "$D2"
run
[ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D2" ] && [ "$(st previous-image)" = "$D1" ] && [ "$(running)" = "$D2" ] && [ "$(envd)" = "$D2" ] \
  && ok "good digest: applied-image updated, previous-image holds the old one" || bad "good digest" "rc=$rc $(st applied-image) $(st previous-image)"

# a rollback is the same move: site-deploy put previous-image in desired-image
fresh
on "$D2" "$D1"
desire "$D1"
run
[ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D1" ] && [ "$(st previous-image)" = "$D2" ] && [ "$(running)" = "$D1" ] \
  && ok "rollback: the old digest runs again, and the one it replaced is now previous" || bad "rollback" "rc=$rc $(st applied-image) $(st previous-image)"

# --- nothing to do --------------------------------------------------------------------

fresh
run
[ "$rc" -eq 0 ] && [ ! -s "$FAKE/docker.log" ] && [ "$(st last-result)" = none ] && ok "no desired-image: nothing runs, exit 0" || bad "no desired-image" "rc=$rc $(verbs)"

fresh
on "$D1"
echo "ok $D1 earlier" >"$PLAY_STATE/last-result"
run
[ "$rc" -eq 0 ] && [ ! -s "$FAKE/docker.log" ] && [ "$(st last-result)" = "ok $D1 earlier" ] \
  && ok "desired is already applied: nothing runs, last-result kept (this is what a restore wakes up to)" || bad "already applied" "rc=$rc $(verbs)"

# --- failures --------------------------------------------------------------------------

fresh
on "$D1"
desire "$D2"
echo "$D2" >"$FAKE/unhealthy"
run
[ "$rc" -ne 0 ] && ok "unhealthy: exit is not 0" || bad "unhealthy exit" "$rc"
[ "$(running)" = "$D1" ] && [ "$(envd)" = "$D1" ] && ok "unhealthy: the old digest is recreated" || bad "unhealthy container" "$(running) $(envd)"
[ "$(st applied-image)" = "$D1" ] && [ "$(st desired-image)" = "$D1" ] && [ "$(st previous-image)" = none ] \
  && ok "unhealthy: applied and desired name the old digest, previous untouched" || bad "unhealthy state" "$(st applied-image) $(st desired-image) $(st previous-image)"
[[ "$(st last-result)" == "failed $D2"* ]] && [[ "$(st last-result)" == *"back on $D1"* ]] && [ "$(wc -l <"$PLAY_STATE/last-result")" -eq 1 ] \
  && ok "unhealthy: one-line last-result says failed, and what runs" || bad "unhealthy last-result" "$(st last-result)"
[ "$(verbs)" = "compose pull b;compose up b;compose ps b;compose up a;compose ps a;" ] \
  && ok "unhealthy: pull, up, check, then back up with the old env-file" || bad "unhealthy calls" "$(verbs)"
[ -z "$(leftovers)" ] && ok "unhealthy: no temp file left" || bad "unhealthy leftovers" "$(leftovers)"
run
[ "$rc" -eq 0 ] && [[ "$(st last-result)" == "failed $D2"* ]] && ok "the run the restore wakes does nothing and keeps the failure on record" || bad "after restore" "rc=$rc $(st last-result)"

fresh
on "$D1"
desire "$D2"
echo "$D2" >"$FAKE/starting"
HW=1
run
HW=''
[ "$rc" -ne 0 ] && [ "$(running)" = "$D1" ] && [ "$(st applied-image)" = "$D1" ] && [[ "$(st last-result)" == "failed $D2"* ]] \
  && ok "never healthy within the wait: the same restore" || bad "health timeout" "rc=$rc $(running) $(st last-result)"

fresh
on "$D1"
desire "$D2"
echo "$D2" >"$FAKE/pull-fails"
run
[ "$rc" -ne 0 ] && [ "$(running)" = "$D1" ] && [ "$(envd)" = "$D1" ] && [ "$(st desired-image)" = "$D1" ] && [[ "$(st last-result)" == "failed $D2"* ]] \
  && ok "pull fails: restored and on record" || bad "pull fails" "rc=$rc $(running) $(st desired-image) $(st last-result)"
[ "$(verbs)" = "compose pull b;" ] && ok "pull fails: the running container is never touched" || bad "pull fails calls" "$(verbs)"

fresh
on "$D1"
desire "$D2"
printf '%s\n%s\n' "$D1" "$D2" >"$FAKE/unhealthy"
run
[ "$rc" -ne 0 ] && [ "$(st applied-image)" = "$D1" ] && [[ "$(st last-result)" == "failed $D2"*"$D1"*"not healthy"* ]] \
  && ok "the old digest is unhealthy too: last-result says so" || bad "both unhealthy" "rc=$rc $(st last-result)"

# the first release has nothing to go back to
fresh
desire "$D1"
echo "$D1" >"$FAKE/unhealthy"
run
[ "$rc" -ne 0 ] && [ "$(running)" = none ] && [ "$(st applied-image)" = none ] && [ "$(st desired-image)" = none ] \
  && [[ "$(st last-result)" == "failed $D1"* ]] && [ ! -e "$PLAY_ROOT/image.env" ] \
  && ok "first release fails: taken down, desired cleared so a re-run releases again" || bad "first release fails" "rc=$rc $(running) $(st desired-image) $(st last-result) $(ls "$PLAY_ROOT")"
[ -z "$(leftovers)" ] && ok "first release fails: no temp file left" || bad "first failure leftovers" "$(leftovers)"

fresh
desire "$D1"
echo "$D1" >"$FAKE/pull-fails"
run
[ "$rc" -ne 0 ] && [ "$(st desired-image)" = none ] && [ "$(verbs)" = "compose pull a;" ] && [ ! -e "$PLAY_ROOT/image.env" ] \
  && ok "first pull fails (a private package): nothing up, a re-run can try again" || bad "first pull fails" "rc=$rc $(verbs)"
rm "$FAKE/pull-fails"
: >"$FAKE/docker.log"
desire "$D1"
run
[ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D1" ] && ok "...and the re-run of the same digest works" || bad "first pull retry" "rc=$rc $(st last-result)"

# --- a release that lands while another is being applied -------------------------------

fresh
on "$D1"
desire "$D2"
echo "$D3" >"$FAKE/release-on-up"
run
[ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D3" ] && [ "$(st previous-image)" = "$D2" ] && [ "$(running)" = "$D3" ] \
  && ok "a release landing mid-apply is applied next" || bad "release mid-apply" "rc=$rc $(st applied-image) $(st previous-image)"

fresh
on "$D1"
desire "$D2"
echo "$D2" >"$FAKE/unhealthy"
echo "$D3" >"$FAKE/release-on-up"
run
[ "$(st desired-image)" = "$D3" ] && [ "$(st applied-image)" = "$D3" ] && [ "$(running)" = "$D3" ] \
  && ok "a failure's restore does not overwrite a newer release" || bad "restore clobbers" "$(st desired-image) $(st applied-image)"
[ "$rc" -ne 0 ] && ok "...and the run still reports the failure" || bad "failure forgotten" "$rc"

# --- hostile state -----------------------------------------------------------------------

hostile() { # hostile <name>: desired-image is already planted
  run
  if [ "$rc" -eq 0 ]; then bad "$1" "exit 0"
  elif [ -s "$FAKE/docker.log" ]; then bad "$1" "docker ran: $(verbs)"
  elif [ "$(st applied-image)" != "$D1" ] || [ "$(running)" != "$D1" ] || [ "$(envd)" != "$D1" ]; then bad "$1" "state moved"
  elif [[ "$(st last-result)" != failed* ]]; then bad "$1" "last-result: $(st last-result)"
  elif grep -q 'evil' "$PLAY_STATE/last-result" "$T/err" "$T/out"; then bad "$1" "its bytes were echoed"
  else ok "$1"; fi
}
for bytes in \
  "sha256:evil;reboot" \
  '$(evil)' \
  "sha256:evil" \
  "sha256:$(printf 'a%.0s' $(seq 63))" \
  "${D1}a" \
  "sha256:$(printf 'A%.0s' $(seq 64))" \
  "ghcr.io/evil/image@$D1" \
  "ghcr.io/isabellybaldo/isoca-play@$D1" \
  "$D2 --evil" \
  "-$D2" \
  "$D2"$'\nPLAY_DIGEST=evil' \
  ""; do
  fresh
  on "$D1"
  printf '%s\n' "$bytes" >"$PLAY_STATE/desired-image"
  keep=$(cat "$PLAY_STATE/desired-image")
  hostile "hostile desired-image -> nothing runs ($(printf '%q' "$bytes" | cut -c1-28))"
  [ "$(cat "$PLAY_STATE/desired-image")" = "$keep" ] || bad "a hostile desired-image was rewritten"
done

fresh
on "$D1"
rm "$PLAY_STATE/desired-image"
mkdir "$PLAY_STATE/desired-image"
hostile "desired-image is a directory -> nothing runs"

fresh
on "$D1"
head -c 100000 /dev/zero | tr '\0' a >"$PLAY_STATE/desired-image"
hostile "an enormous desired-image -> nothing runs"

fresh
on "$D1"
if ln -sf "$T/planted" "$PLAY_STATE/desired-image" 2>/dev/null && [ -L "$PLAY_STATE/desired-image" ]; then
  echo "$D2" >"$T/planted"
  hostile "desired-image is a symlink -> not followed, nothing runs"

  # a root process writing in a directory deploy owns must not follow a link either
  fresh
  on "$D1"
  desire "$D2"
  echo keep >"$T/victim"
  ln -s "$T/victim" "$PLAY_STATE/previous-image"
  ln -s "$T/victim" "$PLAY_STATE/last-result"
  run
  [ "$rc" -eq 0 ] && [ "$(cat "$T/victim")" = keep ] && [ ! -L "$PLAY_STATE/previous-image" ] && [ ! -L "$PLAY_STATE/last-result" ] \
    && [ "$(st previous-image)" = "$D1" ] && ok "a link planted at a state file is replaced, its target untouched" || bad "planted link" "rc=$rc $(cat "$T/victim")"
else
  skip "symlinked state files" "no real symlinks on this OS"
fi

fresh
on "$D1"
desire "$D2"
echo 'sha256:evil;reboot' >"$PLAY_STATE/applied-image"
run
[ "$rc" -ne 0 ] && [ ! -s "$FAKE/docker.log" ] && [[ "$(st last-result)" == failed* ]] && ! grep -q evil "$PLAY_STATE/last-result" \
  && ok "a hostile applied-image -> nothing runs (there is no known way back)" || bad "hostile applied-image" "rc=$rc $(verbs)"

fresh
on "$D1"
desire "$D2"
sed -i 's,isabellybaldo/isoca-play,somebody/else,' "$T/compose.yml"
run
[ "$rc" -ne 0 ] && [ ! -s "$FAKE/docker.log" ] && [ "$(st applied-image)" = "$D1" ] && [[ "$(st last-result)" == "failed $D2"*"nothing ran"* ]] \
  && ok "a compose file naming another image -> nothing runs" || bad "other image in compose" "rc=$rc $(verbs) $(st last-result)"

# --- temp files stay out of the deploy-owned directory --------------------------------

# Root writing and chmodding a temp file there can be sent through a swapped-in link.
fresh
on "$D1"
desire "$D2"
echo "$D2" >"$FAKE/unhealthy"
run
desire "$D3"
run
[ -s "$FAKE/mktemp.log" ] && ! grep -qvxF -- "-p $PLAY_ROOT .apply.XXXXXX" "$FAKE/mktemp.log" \
  && ok "every temp file is made in root's directory, none in the state directory" || bad "temp file place" "$(sort -u "$FAKE/mktemp.log")"
[ "$(st applied-image)" = "$D3" ] && [ -z "$(leftovers)" ] && ok "...and renamed into state, leaving nothing behind" || bad "temp rename" "$(st applied-image) $(leftovers)"

# --- a write that fails: never ok, the old file intact, and the next run finishes it ----

if ln -s /dev/full "$tmp/probe-full" 2>/dev/null && [ -L "$tmp/probe-full" ]; then
  # A good run makes temp files in this order: 1 image.env.next, 2 previous-image,
  # 3 applied-image, 4 last-result.
  for at in 1 2 3 4; do
    fresh
    on "$D3" "$D1"
    desire "$D2"
    echo "$at" >"$FAKE/full-at"
    run
    name="a full disk at write $at"
    [ "$rc" -ne 0 ] && ok "$name: exit is not 0" || bad "$name: exit" "$rc"
    [ -s "$PLAY_STATE/applied-image" ] && [ -s "$PLAY_STATE/previous-image" ] && ok "$name: no state file is empty" || bad "$name: empty state" "$(ls -l "$PLAY_STATE")"
    [[ "$(st last-result)" != ok* ]] && ok "$name: ok is not recorded" || bad "$name: recorded ok" "$(st last-result)"
    [ -z "$(leftovers)" ] && ok "$name: no temp file left" || bad "$name: leftovers" "$(leftovers)"
    if [ "$at" -lt 3 ]; then
      [ "$(st applied-image)" = "$D3" ] && [ "$(st previous-image)" = "$D1" ] && ok "$name: the old files are unchanged" || bad "$name: old files" "$(st applied-image) $(st previous-image)"
    fi
    if [ "$at" = 1 ]; then
      [ ! -s "$FAKE/docker.log" ] && ok "$name: docker is not touched" || bad "$name: docker ran" "$(verbs)"
    fi
    rm "$FAKE/full-at"
    if [ "$at" != 4 ]; then
      run
      [ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D2" ] && [ "$(st previous-image)" = "$D3" ] && [ "$(running)" = "$D2" ] && [ "$(envd)" = "$D2" ] && [[ "$(st last-result)" == "ok $D2 "* ]] \
        && ok "$name: the next run finishes the job" || bad "$name: next run" "rc=$rc $(st applied-image) $(st previous-image) $(st last-result)"
    fi
  done

  # go_back: 1 image.env.next, 2 image.env, 3 desired-image, 4 last-result
  fresh
  on "$D1"
  desire "$D2"
  echo "$D2" >"$FAKE/unhealthy"
  echo 2 >"$FAKE/full-at"
  run
  [ "$rc" -ne 0 ] && [ "$(running)" = "$D1" ] && [ "$(envd)" = "$D1" ] && [ "$(st desired-image)" = "$D1" ] \
    && ok "go_back cannot rewrite image.env, which still names the old digest: it goes back anyway" || bad "go_back full, env good" "rc=$rc $(running) $(envd)"

  fresh
  on "$D1"
  desire "$D2"
  echo "$D2" >"$FAKE/unhealthy"
  echo 2 >"$FAKE/full-at"
  rm "$PLAY_ROOT/image.env"
  run
  [ "$rc" -ne 0 ] && [ "$(verbs)" = "compose pull b;compose up b;compose ps b;" ] && [ "$(st desired-image)" = "$D2" ] && [ "$(st applied-image)" = "$D1" ] \
    && [[ "$(st last-result)" == "failed $D2"*"image.env"* ]] \
    && ok "go_back cannot name the old digest: no blind recreate, desired kept for a retry, on record" || bad "go_back full, no env" "rc=$rc $(verbs) $(st desired-image) $(st last-result)"

  fresh
  on "$D1"
  desire "$D2"
  echo "$D2" >"$FAKE/unhealthy"
  echo 3 >"$FAKE/full-at"
  run
  [ "$rc" -ne 0 ] && [ "$(st desired-image)" = "$D2" ] && [ "$(running)" = "$D1" ] && [[ "$(st last-result)" == *"could not be restored"* ]] \
    && ok "desired-image cannot be restored: the old file intact and the failure on record" || bad "restore full" "rc=$rc $(st desired-image) $(st last-result)"
else
  skip "a full disk" "no real symlinks to /dev/full on this OS"
fi

fresh
on "$D1"
desire "$D2"
echo "$PLAY_ROOT/image.env" >"$FAKE/mv-fails"
run
[ "$rc" -ne 0 ] && [ "$(st applied-image)" = "$D1" ] && [ "$(envd)" = "$D1" ] && [[ "$(st last-result)" == "failed $D2"* ]] \
  && ok "image.env cannot be renamed into place: not recorded as ok, old files intact" || bad "env mv fails" "rc=$rc $(st applied-image) $(st last-result)"
rm "$FAKE/mv-fails"
run
[ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D2" ] && [ "$(envd)" = "$D2" ] && ok "...and the next run finishes the job" || bad "env mv retry" "rc=$rc $(st last-result)"

fresh
on "$D1"
desire "$D2"
echo "$PLAY_STATE/applied-image" >"$FAKE/mv-fails"
run
[ "$rc" -ne 0 ] && [ "$(st applied-image)" = "$D1" ] && [[ "$(st last-result)" == "failed $D2"* ]] \
  && ok "applied-image cannot be renamed into place: not recorded as ok" || bad "applied mv fails" "rc=$rc $(st applied-image) $(st last-result)"

# --- a digest already on the box needs no registry ----------------------------------------

fresh
on "$D2" "$D1"
desire "$D1"
echo "$D1" >"$FAKE/cached"
echo "$D1" >"$FAKE/pull-fails"
run
[ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D1" ] && [ "$(running)" = "$D1" ] && [ "$(verbs)" = "compose up a;compose ps a;" ] \
  && ok "a rollback to a cached image needs no pull, so a registry outage cannot block it" || bad "cached rollback" "rc=$rc $(verbs) $(st last-result)"

fresh
on "$D1"
desire "$D2"
echo "$D1" >"$FAKE/cached"
run
[ "$rc" -eq 0 ] && [ "$(verbs)" = "compose pull b;compose up b;compose ps b;" ] && ok "a digest that is not cached is pulled" || bad "uncached pull" "rc=$rc $(verbs)"

# --- a bad digest whose restore failed is not recreated every minute ------------------------

if ln -s /dev/full "$tmp/probe-full2" 2>/dev/null && [ -L "$tmp/probe-full2" ]; then
  fresh
  on "$D1"
  desire "$D2"
  echo "$D2" >"$FAKE/unhealthy"
  echo 3 >"$FAKE/full-at" # 1 image.env.next, 2 image.env, 3 desired-image
  run
  [ "$rc" -ne 0 ] && [ "$(cat "$T/no-retry" 2>/dev/null)" = "$D2" ] && [ "$(st desired-image)" = "$D2" ] && [ "$(running)" = "$D1" ] \
    && ok "restore fails: the digest goes in the no-retry marker" || bad "marker written" "rc=$rc $(cat "$T/no-retry" 2>&1)"

  # still cannot write: the next temp file is the next line of the log
  : >"$FAKE/docker.log"
  echo "$(($(wc -l <"$FAKE/mktemp.log") + 1))" >"$FAKE/full-at"
  run
  [ "$rc" -ne 0 ] && [ ! -s "$FAKE/docker.log" ] && [ "$(cat "$T/no-retry")" = "$D2" ] && [ "$(st desired-image)" = "$D2" ] \
    && ok "the disk is still full: docker is not touched, the marker stays" || bad "marker, still full" "rc=$rc $(verbs)"

  rm "$FAKE/full-at"
  run
  [ "$rc" -ne 0 ] && [ ! -s "$FAKE/docker.log" ] && [ ! -e "$T/no-retry" ] && [ "$(st desired-image)" = "$D1" ] && [ "$(running)" = "$D1" ] \
    && ok "the disk is free: restored without recreating, the marker gone" || bad "marker, freed" "rc=$rc $(verbs) $(st desired-image)"
  run
  [ "$rc" -eq 0 ] && [ ! -s "$FAKE/docker.log" ] && ok "...and the next run is a plain no-op" || bad "after marker" "rc=$rc $(verbs)"

  rm "$FAKE/unhealthy"
  desire "$D2"
  run
  [ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D2" ] && ok "...and releasing that digest again really tries it" || bad "re-release after marker" "rc=$rc $(st last-result)"

  # "up but not recorded" keeps its retry, and never gets a marker
  fresh
  on "$D1"
  desire "$D2"
  echo 2 >"$FAKE/full-at" # 1 image.env.next, 2 previous-image or applied-image
  run
  [ "$rc" -ne 0 ] && [ ! -e "$T/no-retry" ] && ok "up but not recorded: no marker" || bad "not recorded, marker" "rc=$rc"
  rm "$FAKE/full-at"
  : >"$FAKE/docker.log"
  run
  [ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D2" ] && [[ "$(verbs)" == *"compose up b"* ]] && ok "up but not recorded: the next run retries and finishes" || bad "not recorded, retry" "rc=$rc $(verbs)"
else
  skip "the no-retry marker" "no real symlinks to /dev/full on this OS"
fi

# a marker naming another digest neither blocks this one nor outlives it
fresh
on "$D1"
desire "$D2"
echo "$D3" >"$T/no-retry"
run
[ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D2" ] && [ ! -e "$T/no-retry" ] && ok "a stale marker for another digest is ignored and cleared" || bad "stale marker" "rc=$rc $(st applied-image)"

# --- a no-op run, which the timer starts every minute --------------------------------------

fresh
on "$D2" "$D1"
printf '%s %s\n' "ghcr.io/isabellybaldo/isoca-play" "$D3" >"$FAKE/images"
echo "ok $D2 earlier" >"$PLAY_STATE/last-result"
before=$(cd "$PLAY_ROOT" && ls -A . state | tr '\n' ' '; cat state/* image.env)
run
run
after=$(cd "$PLAY_ROOT" && ls -A . state | tr '\n' ' '; cat state/* image.env)
[ "$rc" -eq 0 ] && [ ! -s "$FAKE/docker.log" ] && [ ! -e "$FAKE/rmi.log" ] && [ "$before" = "$after" ] \
  && ok "a no-op run calls docker not at all, prunes nothing, changes no file" || bad "no-op run" "rc=$rc $(cat "$FAKE/docker.log")"

# --- pruning this image's old digests ------------------------------------------------------

D4=sha256:$(printf 'd%.0s' $(seq 64))
R=ghcr.io/isabellybaldo/isoca-play
fresh
on "$D1" "$D3"
desire "$D2"
{
  echo "$R $D1"
  echo "$R $D2"
  echo "$R $D3"
  echo "$R $D4"
  echo "$R <none>"
  echo "ghcr.io/somebody/else $D3"
  echo "$R sha256:evil;reboot"
} >"$FAKE/images"
run
[ "$rc" -eq 0 ] && [ "$(LC_ALL=C sort "$FAKE/rmi.log" | tr '\n' ' ')" = "$R@$D3 $R@$D4 " ] \
  && ok "after a good apply: only this image's digests, other than applied and previous, go" || bad "prune" "rc=$rc $(cat "$FAKE/rmi.log" 2>&1)"
[[ "$(st last-result)" == "ok $D2 "* ]] && ok "...and the result is ok" || bad "prune result" "$(st last-result)"

fresh
on "$D1"
desire "$D2"
echo "$R $D3" >"$FAKE/images"
touch "$FAKE/rmi-fails"
run
[ "$rc" -eq 0 ] && [ "$(st applied-image)" = "$D2" ] && [[ "$(st last-result)" == "ok $D2 "* ]] && [ -s "$FAKE/rmi.log" ] \
  && ok "a failed image removal does not fail the run" || bad "rmi fails" "rc=$rc $(st last-result)"

fresh
on "$D1"
desire "$D2"
touch "$FAKE/images-fail"
run
[ "$rc" -eq 0 ] && [[ "$(st last-result)" == "ok $D2 "* ]] && ok "a failed image listing does not fail the run" || bad "images fails" "rc=$rc $(st last-result)"

fresh
on "$D1" "$D3"
desire "$D2"
echo "$D2" >"$FAKE/unhealthy"
printf '%s %s\n' "$R" "$D3" "$R" "$D1" "$R" "$D4" >"$FAKE/images"
run
[ ! -e "$FAKE/rmi.log" ] && ok "a failed apply prunes nothing" || bad "prune after failure" "$(cat "$FAKE/rmi.log")"

sed 's/#.*//' "$PA" | grep -qE 'docker[^|]* prune|docker rmi|image rm .*(-f|--force)|--rmi' && bad "a blanket or forced image removal" || ok "no blanket prune and no forced removal"

# --- the fixed image, the units ------------------------------------------------------------

[ "$(sed -n -E 's/^readonly IMAGE=//p' "$PA")" = ghcr.io/isabellybaldo/isoca-play ] \
  && ok "play-apply names one fixed image" || bad "fixed image"
grep -qF "image: ghcr.io/isabellybaldo/isoca-play@\${PLAY_DIGEST" "$here/../play/compose.yml" \
  && ok "the compose file takes only a digest, never an image name" || bad "compose image line" "$(grep image: "$here/../play/compose.yml")"

grep -qxF 'PathChanged=/srv/play/state/desired-image' "$UNIT_PATH" && ok "path unit watches desired-image" || bad "path unit watch"
grep -qxF 'Unit=play-apply.service' "$UNIT_PATH" && ok "path unit starts the service" || bad "path unit target"
grep -qxF 'WantedBy=multi-user.target' "$UNIT_PATH" && ok "path unit starts at boot" || bad "path unit install"
grep -qxF 'Type=oneshot' "$UNIT_SERVICE" && ok "service is oneshot" || bad "service type"
grep -qxF 'ExecStart=/usr/local/bin/play-apply' "$UNIT_SERVICE" && ok "service runs the installed script" || bad "service ExecStart"
grep -qE '^User=' "$UNIT_SERVICE" && bad "service sets a user: it needs root for docker" || ok "service runs as root"
grep -qxE 'TimeoutStartSec=[0-9]+' "$UNIT_SERVICE" && ok "service has a time limit" || bad "service timeout"
grep -qxF 'Requisite=docker.service' "$UNIT_SERVICE" && ! grep -q '^Requires=' "$UNIT_SERVICE" \
  && ok "service needs docker up, and never starts one an admin stopped" || bad "service docker"
sed -n '/^\[Unit\]/,/^\[Service\]/p' "$UNIT_SERVICE" | grep -qxF 'StartLimitIntervalSec=0' \
  && ok "service: no start limit, in [Unit], so fast repeats cannot kill the path unit" || bad "service start limit"
grep -qxF 'OnCalendar=minutely' "$UNIT_TIMER" && ok "timer runs every minute, whatever the last run's result" || bad "timer schedule"
grep -qxF 'Unit=play-apply.service' "$UNIT_TIMER" && ok "timer starts the service" || bad "timer target"
grep -qxF 'WantedBy=timers.target' "$UNIT_TIMER" && ok "timer starts at boot" || bad "timer install"

echo
echo "$passes passed, $failures failed, $skips skipped"
[ "$failures" -eq 0 ]
