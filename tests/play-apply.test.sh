#!/usr/bin/env bash
# Tests box/play-apply in throwaway directories with a fake docker on PATH: it logs
# what it is asked to do and plays the part of a container that is healthy or not.
# Also holds the text checks on the two systemd units, which no test here can start.
# shellcheck disable=SC2010,SC2015,SC2016 # ls for tidy output; A && ok || bad is the intent; the fake's $ are its own
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
PA="$here/../box/play-apply"
UNIT_PATH="$here/../box/play-apply.path"
UNIT_SERVICE="$here/../box/play-apply.service"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0 passes=0 skips=0
ok() { echo "ok   $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; failures=$((failures + 1)); }
skip() { echo "SKIP $1: $2"; skips=$((skips + 1)); }

for f in "$PA" "$UNIT_PATH" "$UNIT_SERVICE"; do
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
echo "unexpected: $*" >>"$FAKE/docker.log"
exit 1
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
  PATH="$tmp/bin:$PATH" FAKE=$FAKE PLAY_ROOT=$PLAY_ROOT PLAY_STATE=$PLAY_STATE PLAY_COMPOSE="$T/compose.yml" \
    HEALTH_WAIT=${HW:-5} HEALTH_POLL=0 bash "$PA" >"$T/out" 2>"$T/err" || rc=$?
}

st() { cat "$PLAY_STATE/$1" 2>/dev/null || echo none; }
envd() { sed -n 's/^PLAY_DIGEST=//p' "$PLAY_ROOT/image.env" 2>/dev/null; }
running() { cat "$FAKE/running" 2>/dev/null || echo none; }
verbs() { grep -v '^inspect$' "$FAKE/docker.log" | sed 's/sha256:\(.\).*/\1/' | tr '\n' ';'; }
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
grep -qxF 'Requires=docker.service' "$UNIT_SERVICE" && ok "service needs docker" || bad "service docker"

echo
echo "$passes passed, $failures failed, $skips skipped"
[ "$failures" -eq 0 ]
