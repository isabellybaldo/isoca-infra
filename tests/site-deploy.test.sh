#!/usr/bin/env bash
# Tests box/site-deploy in throwaway directories (no root needed). Hostile
# archives are built at runtime with GNU tar tricks (--transform, -P).
# A case that cannot be built on this OS prints SKIP with the reason; it never
# passes silently. The Linux run is the one that counts.
# shellcheck disable=SC2012,SC2015,SC2016 # info-level: ls for tidy output, A && ok || bad is the intent
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SD="$here/../box/site-deploy"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0 passes=0 skips=0
ok() { echo "ok   $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; failures=$((failures + 1)); }
skip() { echo "SKIP $1: $2"; skips=$((skips + 1)); }

if [ ! -f "$SD" ]; then
  echo "FAIL box/site-deploy does not exist" >&2
  exit 1
fi

DEFAULT_MAX=209715200
n=0
rel() { printf '202610%02dT100000Z-abc1234' "$1"; }

# Fresh world per test: $SITES_ROOT with site "blog", an empty $EDGE_DYNAMIC.
fresh() {
  n=$((n + 1))
  T="$tmp/t$n"
  SITES_ROOT="$T/sites" EDGE_DYNAMIC="$T/edge/dynamic"
  mkdir -p "$SITES_ROOT/blog" "$EDGE_DYNAMIC" "$T/src"
  MAXB=$DEFAULT_MAX KEEPN=5
}

# Without real symlinks (Git Bash on Windows copies instead) `current` cannot
# work, so the tests that follow it skip with a message there.
has_links() {
  if [ -z "${HAVE_LINKS-}" ]; then
    HAVE_LINKS=0
    if ln -s probe-target "$tmp/probe" 2>/dev/null && [ -L "$tmp/probe" ]; then HAVE_LINKS=1; fi
  fi
  [ "$HAVE_LINKS" -eq 1 ] && return 0
  skip "$1" "no real symlinks on this OS"
  return 1
}

# run <ssh command> [stdin file] -> rc, $T/out, $T/err
run() {
  rc=0
  SSH_ORIGINAL_COMMAND=$1 SITES_ROOT=$SITES_ROOT EDGE_DYNAMIC=$EDGE_DYNAMIC \
    MAX_BYTES=$MAXB KEEP=$KEEPN bash "$SD" <"${2:-/dev/null}" >"$T/out" 2>"$T/err" || rc=$?
}

# Everything under the world, with types, link targets, sizes and modes.
snap() { (cd "$T" && find sites edge -printf '%p %y %l %s %m\n' | LC_ALL=C sort); }

# good_tar <out> [file...]: a normal archive made the way Task 4 makes it (tar -C dir .)
good_tar() {
  local out=$1
  shift
  rm -rf "$T/good"
  mkdir -p "$T/good"
  if [ $# -eq 0 ]; then set -- index.html; fi
  local f
  for f in "$@"; do
    mkdir -p "$T/good/$(dirname "$f")"
    echo "<p>$f</p>" >"$T/good/$f"
  done
  tar -C "$T/good" -czf "$out" .
}

deploy_ok() { # deploy_ok <n> : deploy release n of blog with a fresh good archive
  good_tar "$T/g.tgz" index.html assets/app.js
  run "deploy blog $(rel "$1")" "$T/g.tgz"
  [ "$rc" -eq 0 ] || { bad "setup deploy $1" "rc=$rc $(cat "$T/err")"; return 1; }
}

# refused <name> <command> <stdin file>: exit 2, one-line "refused: ..." on
# stderr, nothing on stdout, world byte-for-byte unchanged.
refused() {
  local name=$1 before after
  before=$(snap)
  run "$2" "${3:-/dev/null}"
  after=$(snap)
  if [ "$rc" -ne 2 ]; then bad "$name" "exit $rc, want 2 ($(head -c 200 "$T/err"))"
  elif [[ "$(cat "$T/err")" != "refused: "* ]]; then bad "$name" "stderr not 'refused: ...'"
  elif [ "$(wc -l <"$T/err")" -ne 1 ]; then bad "$name" "stderr is not one line"
  elif [ -s "$T/out" ]; then bad "$name" "printed on stdout"
  elif [ "$before" != "$after" ]; then bad "$name" "filesystem changed"
  else ok "$name"; fi
}

cur() { readlink "$SITES_ROOT/blog/current" 2>/dev/null || echo none; }
releases() { (cd "$SITES_ROOT/blog/releases" 2>/dev/null && ls -A | LC_ALL=C sort | tr '\n' ' '); }

# --- happy paths --------------------------------------------------------

if has_links "deploy, switch, rollback, prune, KEEP (they need symlinks)"; then
fresh
deploy_ok 1
r1_out=$(cat "$T/out")
deploy_ok 2
[ "$r1_out" = "deployed blog $(rel 1)" ] && ok "deploy prints 'deployed <site> <release>'" || bad "deploy output" "$r1_out"
[ "$(cur)" = "releases/$(rel 2)" ] && ok "current is a relative link to the second release" || bad "current" "$(cur)"
[ "$(cat "$SITES_ROOT/blog/current/assets/app.js")" = "<p>assets/app.js</p>" ] && ok "served files are reachable through current" || bad "files through current"
[ "$(releases)" = "$(rel 1) $(rel 2) " ] && ok "no .tmp or spool left after deploys" || bad "leftovers" "$(releases) / $(ls -A "$SITES_ROOT/blog")"
run "rollback blog"
[ "$rc" -eq 0 ] && [ "$(cur)" = "releases/$(rel 1)" ] && [ "$(cat "$T/out")" = "rolled back blog to $(rel 1)" ] && ok "rollback points current at the first release" || bad "rollback" "rc=$rc cur=$(cur) $(cat "$T/out")"
refused "rollback with nothing older is refused" "rollback blog"

# tar -C dir . (a "./" entry) and a plain-name archive both work
fresh
echo hi >"$T/src/a.html"
tar -C "$T/src" -czf "$T/plain.tgz" a.html
run "deploy blog $(rel 1)" "$T/plain.tgz"
[ "$rc" -eq 0 ] && [ -f "$SITES_ROOT/blog/current/a.html" ] && ok "archive without ./ prefix deploys" || bad "plain names" "rc=$rc $(cat "$T/err")"

# KEEP+2 deploys leave exactly KEEP releases, the newest ones
fresh
KEEPN=3
for i in 1 2 3 4 5; do deploy_ok "$i" || break; done
[ "$(releases)" = "$(rel 3) $(rel 4) $(rel 5) " ] && ok "keeps exactly KEEP newest releases" || bad "KEEP" "$(releases)"

# pruning never removes the release current names, even if it is old
fresh
KEEPN=2
for i in 5 6 7; do deploy_ok "$i" || break; done
deploy_ok 1
[ "$(cur)" = "releases/$(rel 1)" ] && [ -d "$SITES_ROOT/blog/releases/$(rel 1)" ] && [ "$(releases)" = "$(rel 1) $(rel 6) $(rel 7) " ] \
  && ok "prune keeps the release current names" || bad "prune protects current" "cur=$(cur) $(releases)"

# rollback is 'newest older than current', not 'previous deployed'
fresh
for i in 1 2 3; do deploy_ok "$i" || break; done
run "rollback blog"
run "rollback blog"
[ "$rc" -eq 0 ] && [ "$(cur)" = "releases/$(rel 1)" ] && ok "rollback twice walks back through the releases" || bad "rollback twice" "cur=$(cur)"
fi

fresh
refused "rollback without current is refused" "rollback blog"

# permissions are normalised (a 000 file and a 700 dir in the archive)
fresh
if [ "$(uname -s)" != Linux ]; then
  skip "modes normalised to 0644/0755" "NTFS does not keep unix modes"
else
  mkdir -p "$T/src/d"
  echo x >"$T/src/d/secret.html"
  echo y >"$T/src/open.html"
  tar -C "$T/src" -czf "$T/m.tgz" --mode='a-rwx' --owner=0 --group=0 d open.html
  run "deploy blog $(rel 1)" "$T/m.tgz"
  f=$(stat -c %a "$SITES_ROOT/blog/current/d/secret.html")
  d=$(stat -c %a "$SITES_ROOT/blog/current/d")
  top=$(stat -c %a "$SITES_ROOT/blog/releases/$(rel 1)")
  [ "$rc" -eq 0 ] && [ "$f" = 644 ] && [ "$d" = 755 ] && [ "$top" = 755 ] && ok "modes normalised to 0644/0755" || bad "modes" "rc=$rc file=$f dir=$d top=$top $(cat "$T/err")"
fi

# --- command parsing ------------------------------------------------------

fresh
good_tar "$T/g.tgz"
refused "unknown command" "ls -la" "$T/g.tgz"
refused "empty command" "" "$T/g.tgz"
refused "unknown site" "deploy nope $(rel 1)" "$T/g.tgz"
refused "bad site name (uppercase)" "deploy Blog $(rel 1)" "$T/g.tgz"
refused "bad site name (traversal)" "deploy ../blog $(rel 1)" "$T/g.tgz"
refused "site name over 32 chars" "deploy $(printf 'a%.0s' $(seq 33)) $(rel 1)" "$T/g.tgz"
refused "bad release id" "deploy blog v1.0" "$T/g.tgz"
refused "release id with traversal" "deploy blog ../20261001T100000Z-abc1234" "$T/g.tgz"
refused "extra argument on deploy" "deploy blog $(rel 1) extra" "$T/g.tgz"
refused "missing release" "deploy blog" "$T/g.tgz"
refused "double space" "deploy  blog $(rel 1)" "$T/g.tgz"
refused "extra argument on rollback" "rollback blog now" "$T/g.tgz"
refused "extra argument on edge-config" "edge-config x" "$T/g.tgz"
refused "trailing newline in command" "deploy blog $(rel 1)"$'\n' "$T/g.tgz"
refused "newline then a second command" "deploy blog $(rel 1)"$'\nrollback blog' "$T/g.tgz"
refused "command separator" "deploy blog $(rel 1); id" "$T/g.tgz"
refused "command substitution" 'deploy $(id) '"$(rel 1)" "$T/g.tgz"
refused "control characters in the command" $'deploy blog \e[31m' "$T/g.tgz"

# --- release collisions -----------------------------------------------------

if has_links "redeploying an existing release is refused"; then
fresh
deploy_ok 1
refused "redeploying an existing release is refused" "deploy blog $(rel 1)" "$T/g.tgz"
fi


# --- hostile archives ---------------------------------------------------------

fresh
echo x >"$T/src/f"
tar -C "$T/src" -czf "$T/up.tgz" --transform='s,^f$,../x,' f
refused "archive with ../x" "deploy blog $(rel 1)" "$T/up.tgz"
tar -C "$T/src" -czf "$T/mid.tgz" --transform='s,^f$,a/../b,' f
refused "archive with a/../b" "deploy blog $(rel 1)" "$T/mid.tgz"
tar -C "$T/src" -czf "$T/dotdot.tgz" --transform='s,^f$,a/..,' f
refused "archive with a trailing .. component" "deploy blog $(rel 1)" "$T/dotdot.tgz"
tar -C "$T/src" -czf "$T/dotdot2.tgz" --transform='s,^f$,./../x,' f
refused "archive with ./../x" "deploy blog $(rel 1)" "$T/dotdot2.tgz"
tar -P -czf "$T/abs.tgz" "$T/src/f" 2>/dev/null
refused "archive with an absolute path" "deploy blog $(rel 1)" "$T/abs.tgz"
tar -C "$T/src" -czf "$T/slash.tgz" --transform='s,^f$,f/,' f
refused "regular file named with a trailing slash" "deploy blog $(rel 1)" "$T/slash.tgz"

# a newline in a name must not forge a listing line (escape quoting)
fresh
nl=$'evil\n-rw-r--r-- 0-0 1 2026-01-01 00:00 fine'
if echo x >"$T/src/$nl" 2>/dev/null; then
  tar -C "$T/src" -czf "$T/nl.tgz" "$nl"
  # allowed or refused, it must never extract anything outside the release
  run "deploy blog $(rel 1)" "$T/nl.tgz"
  if [ "$rc" -eq 0 ]; then
    [ "$(find "$SITES_ROOT/blog/releases/$(rel 1)" -type f -printf x | wc -c)" -eq 1 ] && ok "newline in a name stays one entry" || bad "newline name split"
  else
    ok "newline in a name is refused"
  fi
else
  skip "newline in a file name" "this filesystem cannot create such a name"
fi

# symlink / hard link entries
fresh
if ln -s /etc/passwd "$T/src/link" 2>/dev/null && [ -L "$T/src/link" ]; then
  tar -C "$T/src" -czf "$T/sym.tgz" link
  refused "archive with a symlink" "deploy blog $(rel 1)" "$T/sym.tgz"
else
  skip "archive with a symlink" "cannot create symlinks on this OS"
fi
fresh
echo x >"$T/src/one"
ln "$T/src/one" "$T/src/two" 2>/dev/null
tar -C "$T/src" -czf "$T/hard.tgz" one two
if tar -tvzf "$T/hard.tgz" | grep -q '^h'; then
  refused "archive with a hard link" "deploy blog $(rel 1)" "$T/hard.tgz"
else
  skip "archive with a hard link" "this OS's tar did not record a hard link"
fi

# a device node cannot be built unprivileged; a FIFO can
fresh
if mkfifo "$T/src/pipe" 2>/dev/null && [ -p "$T/src/pipe" ]; then
  tar -C "$T/src" -czf "$T/fifo.tgz" pipe
  refused "archive with a FIFO" "deploy blog $(rel 1)" "$T/fifo.tgz"
else
  skip "archive with a FIFO" "cannot create FIFOs here"
fi

# size caps
fresh
head -c 200000 /dev/urandom >"$T/src/big"
tar -C "$T/src" -czf "$T/big.tgz" big
MAXB=50000
refused "upload over MAX_BYTES" "deploy blog $(rel 1)" "$T/big.tgz"

fresh
dd if=/dev/zero of="$T/src/zeros" bs=1000 count=3000 2>/dev/null
tar -C "$T/src" -czf "$T/bomb.tgz" zeros
MAXB=1000000
[ "$(wc -c <"$T/bomb.tgz")" -lt "$MAXB" ] || bad "bomb fixture is not small"
refused "small gzip that decompresses past MAX_BYTES" "deploy blog $(rel 1)" "$T/bomb.tgz"
refused "same bomb through edge-config" "edge-config" "$T/bomb.tgz"

# truncated and garbage input
fresh
head -c 20000 /dev/urandom >"$T/src/data"
tar -C "$T/src" -czf "$T/full.tgz" data
size=$(wc -c <"$T/full.tgz")
head -c $((size - 20)) "$T/full.tgz" >"$T/trunc.tgz"
refused "truncated gzip (trailer missing)" "deploy blog $(rel 1)" "$T/trunc.tgz"
head -c $((size / 2)) "$T/full.tgz" >"$T/half.tgz"
refused "half an archive" "deploy blog $(rel 1)" "$T/half.tgz"
echo "not an archive at all" >"$T/junk"
refused "not gzip" "deploy blog $(rel 1)" "$T/junk"
gzip -c "$T/junk" >"$T/junk.gz"
refused "gzip of something that is not a tar" "deploy blog $(rel 1)" "$T/junk.gz"
: >"$T/zero"
refused "zero bytes on stdin" "deploy blog $(rel 1)" "$T/zero"
tar -czf "$T/empty.tgz" -T /dev/null
refused "empty archive" "deploy blog $(rel 1)" "$T/empty.tgz"
mkdir -p "$T/src/onlydir/sub"
tar -C "$T/src" -czf "$T/dirs.tgz" onlydir
refused "archive with directories but no files" "deploy blog $(rel 1)" "$T/dirs.tgz"

# a refused deploy after a good one leaves the good one in place
if has_links "refusal leaves the previous deploy untouched"; then
fresh
deploy_ok 1
echo x >"$T/src/f"
tar -C "$T/src" -czf "$T/bad.tgz" --transform='s,^f$,../x,' f
refused "refusal leaves the previous deploy untouched" "deploy blog $(rel 2)" "$T/bad.tgz"
[ "$(cur)" = "releases/$(rel 1)" ] && ok "current still names the first release" || bad "current after refusal" "$(cur)"
fi

# --- edge-config ----------------------------------------------------------------

fresh
mkdir -p "$T/src/e"
echo "a: 1" >"$T/src/e/a.yml"
echo "b: 1" >"$T/src/e/b.yml"
tar -C "$T/src/e" -czf "$T/e1.tgz" .
run "edge-config" "$T/e1.tgz"
[ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "edge config 2 files" ] && [ "$(ls "$EDGE_DYNAMIC" | tr '\n' ' ')" = "a.yml b.yml " ] \
  && ok "edge-config installs the files (./ prefix archive)" || bad "edge-config install" "rc=$rc $(cat "$T/out" "$T/err")"
[ "$(ls -A "$T/edge" | tr '\n' ' ')" = "dynamic " ] && ok "edge-config leaves no temp dir beside the target" || bad "edge temp leftovers" "$(ls -A "$T/edge")"
if [ "$(uname -s)" = Linux ]; then
  [ "$(stat -c %a "$EDGE_DYNAMIC/a.yml")" = 644 ] && ok "edge files are 0644" || bad "edge modes"
fi

# exact-set replacement: b.yml disappears, c.yml appears, a.yml is replaced
rm "$T/src/e/b.yml"
echo "a: 2" >"$T/src/e/a.yml"
echo "c: 1" >"$T/src/e/c.yml"
tar -C "$T/src/e" -czf "$T/e2.tgz" a.yml c.yml
run "edge-config" "$T/e2.tgz"
[ "$rc" -eq 0 ] && [ "$(ls "$EDGE_DYNAMIC" | tr '\n' ' ')" = "a.yml c.yml " ] && [ "$(cat "$EDGE_DYNAMIC/a.yml")" = "a: 2" ] \
  && ok "edge-config replaces the exact set (stale file removed)" || bad "edge-config replace" "rc=$rc $(ls "$EDGE_DYNAMIC")"

# refusals leave the old set alone
echo "z: 1" >"$T/src/e/z.yml"
mkdir -p "$T/src/e/sub"
echo "q: 1" >"$T/src/e/sub/q.yml"
tar -C "$T/src/e" -czf "$T/e-sub.tgz" a.yml sub
refused "edge-config with a subdirectory" "edge-config" "$T/e-sub.tgz"
tar -C "$T/src/e" -czf "$T/e-nested.tgz" a.yml sub/q.yml
refused "edge-config with a nested file" "edge-config" "$T/e-nested.tgz"
echo "<p>" >"$T/src/e/page.html"
tar -C "$T/src/e" -czf "$T/e-html.tgz" a.yml page.html
refused "edge-config with a non-yml file" "edge-config" "$T/e-html.tgz"
echo "x" >"$T/src/e/.hidden.yml"
tar -C "$T/src/e" -czf "$T/e-hidden.tgz" a.yml .hidden.yml
run "edge-config" "$T/e-hidden.tgz"
[ "$rc" -eq 0 ] && ok "edge-config accepts a dotted yml name in the charset" || bad "dotted name" "$rc"
echo "x" >"$T/src/e/we ird.yml"
tar -C "$T/src/e" -czf "$T/e-space.tgz" a.yml "we ird.yml"
refused "edge-config with a space in a name" "edge-config" "$T/e-space.tgz"
echo "x" >"$T/src/e/.yml"
tar -C "$T/src/e" -czf "$T/e-bare.tgz" .yml
refused "edge-config with a name that is only .yml" "edge-config" "$T/e-bare.tgz"
tar -C "$T/src/e" -czf "$T/e-up.tgz" --transform='s,^a.yml$,../a.yml,' a.yml
refused "edge-config with ../a.yml" "edge-config" "$T/e-up.tgz"
tar -P -czf "$T/e-abs.tgz" "$T/src/e/a.yml" 2>/dev/null
refused "edge-config with an absolute path" "edge-config" "$T/e-abs.tgz"
tar -czf "$T/e-empty.tgz" -T /dev/null
refused "edge-config with an empty archive" "edge-config" "$T/e-empty.tgz"
head -c $(($(wc -c <"$T/e2.tgz") - 5)) "$T/e2.tgz" >"$T/e-trunc.tgz"
refused "edge-config with a truncated archive" "edge-config" "$T/e-trunc.tgz"
MAXB=10
refused "edge-config over MAX_BYTES" "edge-config" "$T/e2.tgz"

# no temp files left in the edge parent or the site on any path
[ "$(ls -A "$T/edge" | tr '\n' ' ')" = "dynamic " ] && ok "no temp dirs left beside the edge dir after refusals" || bad "edge refusals leftovers" "$(ls -A "$T/edge")"

echo
echo "$passes passed, $failures failed, $skips skipped"
[ "$failures" -eq 0 ]
