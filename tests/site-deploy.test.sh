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
  SITES_ROOT="$T/sites" EDGE_DYNAMIC="$T/edge/dynamic" EDGE_INCOMING="$T/edge/.incoming"
  mkdir -p "$SITES_ROOT/blog" "$EDGE_DYNAMIC" "$EDGE_INCOMING" "$T/src"
  MAXB=$DEFAULT_MAX KEEPN=5 LOCKW=30 ULIM='' RUN_AS=''
}

# The script locks with flock(1) and switches releases with a symlink. Git Bash
# on Windows has neither a real symlink (ln copies) nor flock, so the tests that
# reach those steps skip with a message there. Refusals happen before them and
# still run.
can_lock() {
  command -v flock >/dev/null && return 0
  skip "$1" "flock is not installed here"
  return 1
}
can_deploy() {
  if [ -z "${HAVE_LINKS-}" ]; then
    HAVE_LINKS=0
    if ln -s probe-target "$tmp/probe" 2>/dev/null && [ -L "$tmp/probe" ]; then HAVE_LINKS=1; fi
  fi
  if [ "$HAVE_LINKS" -ne 1 ]; then
    skip "$1" "no real symlinks on this OS"
    return 1
  fi
  can_lock "$1"
}

# run <ssh command> [stdin file] -> rc, $T/out, $T/err
# Optional: ULIM (address-space limit in KB), RUN_AS (command prefix, e.g. setpriv).
run() {
  rc=0
  (
    [ -z "$ULIM" ] || ulimit -v "$ULIM"
    # shellcheck disable=SC2086 # RUN_AS is a word list on purpose
    SSH_ORIGINAL_COMMAND=$1 SITES_ROOT=$SITES_ROOT EDGE_DYNAMIC=$EDGE_DYNAMIC EDGE_INCOMING=$EDGE_INCOMING \
      MAX_BYTES=$MAXB KEEP=$KEEPN LOCK_WAIT=$LOCKW exec $RUN_AS bash "$SD"
  ) <"${2:-/dev/null}" >"$T/out" 2>"$T/err" || rc=$?
}

# Everything under the world, with types, link targets, sizes and modes.
snap() { (cd "$T" && find sites edge -printf '%p %y %l %s %m\n' | LC_ALL=C sort); }

# good_tar <out> [file...]: a normal archive made the way the deploy workflow makes it (tar -C dir .)
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

if can_deploy "deploy, switch, rollback, prune, KEEP (they need symlinks)"; then
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
if can_lock "rollback without current is refused"; then refused "rollback without current is refused" "rollback blog"; fi

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

if can_deploy "redeploying an existing release is refused"; then
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

# control bytes in a name (a newline could forge a listing line): refused, exit 2
for nm in $'evil\n-rw-r--r-- 0-0 1 2026-01-01 00:00 fine' $'tab\there' $'esc\033[31m' $'del\177x'; do
  fresh
  if echo x >"$T/src/$nm" 2>/dev/null; then
    tar -C "$T/src" -czf "$T/ctl.tgz" -- "$nm"
    refused "control byte in a name ($(printf '%q' "$nm" | cut -c1-12))" "deploy blog $(rel 1)" "$T/ctl.tgz"
    grep -q "$(printf '\033')" "$T/err" && bad "control byte reached stderr"
  else
    skip "control byte in a file name" "this filesystem cannot create such a name"
  fi
done

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
if can_deploy "refusal leaves the previous deploy untouched"; then
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
tar -C "$T/src/e" -czf "$T/e2.tgz" a.yml
if can_lock "edge-config install, replace and staging cleanup"; then
  run "edge-config" "$T/e1.tgz"
  [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "edge config 2 files" ] && [ "$(ls "$EDGE_DYNAMIC" | tr '\n' ' ')" = "a.yml b.yml " ] \
    && ok "edge-config installs the files (./ prefix archive)" || bad "edge-config install" "rc=$rc $(cat "$T/out" "$T/err")"
  [ "$(ls -A "$T/edge" | tr '\n' ' ')" = ".incoming dynamic " ] && [ -z "$(ls -A "$EDGE_INCOMING")" ] \
    && ok "edge-config leaves nothing in the staging dir or beside the target" || bad "edge temp leftovers" "$(ls -A "$T/edge" "$EDGE_INCOMING")"
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

  # a dotted name inside the charset is installed (asserted, not just rc)
  echo "d: 1" >"$T/src/e/a.b.yml"
  tar -C "$T/src/e" -czf "$T/e-dots.tgz" a.yml a.b.yml
  run "edge-config" "$T/e-dots.tgz"
  [ "$rc" -eq 0 ] && [ "$(ls "$EDGE_DYNAMIC" | tr '\n' ' ')" = "a.b.yml a.yml " ] \
    && ok "edge-config installs a.b.yml" || bad "dotted name installed" "rc=$rc $(ls "$EDGE_DYNAMIC")"
fi

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
echo "x" >"$T/src/e/.h.yml"
tar -C "$T/src/e" -czf "$T/e-hidden.tgz" a.yml .h.yml
refused "edge-config with a leading-dot name (.h.yml would be silently dropped)" "edge-config" "$T/e-hidden.tgz"
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

# no temp files left in the staging dir or beside the edge dir on any path
[ "$(ls -A "$T/edge" | tr '\n' ' ')" = ".incoming dynamic " ] && [ -z "$(ls -A "$EDGE_INCOMING")" ] \
  && ok "no temp dirs left after edge refusals" || bad "edge refusals leftovers" "$(ls -A "$T/edge" "$EDGE_INCOMING")"

# --- one layer of gzip only ----------------------------------------------
# tar auto-detects compression on a file argument, so a gzip inside the gzip used
# to unpack past the size cap. 3 MB of zeros, cap 1 MB, upload a few KB.

fresh
dd if=/dev/zero of="$T/src/zeros" bs=1000 count=3000 2>/dev/null
tar -C "$T/src" -cf - zeros | gzip -c | gzip -c >"$T/gzgz.tgz"
MAXB=1000000
[ "$(wc -c <"$T/gzgz.tgz")" -lt "$MAXB" ] || bad "gz(gz) fixture is not small"
refused "gzip inside gzip (deploy)" "deploy blog $(rel 1)" "$T/gzgz.tgz"
mkdir -p "$T/src/ez"
dd if=/dev/zero of="$T/src/ez/a.yml" bs=1000 count=3000 2>/dev/null
tar -C "$T/src/ez" -cf - a.yml | gzip -c | gzip -c >"$T/gzgz-edge.tgz"
refused "gzip inside gzip (edge-config)" "edge-config" "$T/gzgz-edge.tgz"
if command -v bzip2 >/dev/null; then
  tar -C "$T/src" -cf - zeros | bzip2 -c | gzip -c >"$T/bzgz.tgz"
  refused "bzip2 inside gzip" "deploy blog $(rel 1)" "$T/bzgz.tgz"
else
  skip "bzip2 inside gzip" "bzip2 is not installed"
fi

# --- sparse files list their full size ------------------------------------

fresh
truncate -s 5M "$T/src/holes"
echo end >>"$T/src/holes"
tar -C "$T/src" --sparse -czf "$T/sparse-gnu.tgz" holes
tar -C "$T/src" --format=posix --sparse -czf "$T/sparse-posix.tgz" holes
MAXB=1000000
refused "GNU sparse file bigger than MAX_BYTES" "deploy blog $(rel 1)" "$T/sparse-gnu.tgz"
refused "POSIX sparse file bigger than MAX_BYTES" "deploy blog $(rel 1)" "$T/sparse-posix.tgz"
# several files whose sizes only add up past the cap (each is under it)
fresh
mkdir -p "$T/src/many"
for i in 1 2 3 4 5 6; do dd if=/dev/zero of="$T/src/many/f$i" bs=1000 count=200 2>/dev/null; done
tar -C "$T/src/many" -czf "$T/many.tgz" .
MAXB=1000000
refused "sizes that add up past MAX_BYTES" "deploy blog $(rel 1)" "$T/many.tgz"

# --- the check stage is bounded --------------------------------------------

# tar_hdr <name> <typeflag> <size>: a 512-byte ustar/GNU header on stdout
tar_hdr() {
  local name=$1 type=$2 size=$3 sum=256 s i c size11 time11 mode=0000644 zero=0000000
  printf -v size11 '%011o' "$size"
  printf -v time11 '%011o' 1700000000
  for s in "$name" "$mode" "$zero" "$zero" "$size11" "$time11" "$type" 'ustar  '; do
    for ((i = 0; i < ${#s}; i++)); do
      printf -v c '%d' "'${s:i:1}"
      sum=$((sum + c))
    done
  done
  printf '%s' "$name"
  head -c $((100 - ${#name})) /dev/zero
  printf '%s\0%s\0%s\0%s\0%s\0' "$mode" "$zero" "$zero" "$size11" "$time11"
  printf '%06o\0 %s' "$sum" "$type"
  head -c 100 /dev/zero
  printf 'ustar  \0'
  head -c 247 /dev/zero
}

# gnu_longname <bytes> <out.tgz>: a GNU long-name (type L) entry whose name is that long
gnu_longname() {
  local bytes=$1 out=$2 pad
  pad=$(((512 - (bytes + 1) % 512) % 512))
  {
    tar_hdr '././@LongLink' L $((bytes + 1))
    head -c "$bytes" /dev/zero | tr '\0' "${3:-A}"
    head -c $((pad + 1)) /dev/zero
    tar_hdr x 0 0
    head -c 1024 /dev/zero
  } | gzip -1 -c >"$out"
}

fresh
if [ "$(uname -s)" = Linux ]; then
  gnu_longname 50000000 "$T/longname.tgz"
  ULIM=300000 # 300 MB of address space: holding the listing in bash would not fit
  refused "50 MB GNU long name is refused within bounded memory" "deploy blog $(rel 1)" "$T/longname.tgz"
  ULIM=''
  gnu_longname 100000000 "$T/longctl.tgz" $'\001'
  refused "100 MB GNU long name of control bytes hits the tar memory limit or the listing cap" "deploy blog $(rel 1)" "$T/longctl.tgz"
else
  skip "50 MB GNU long name within bounded memory" "needs ulimit -v and Linux tar"
fi
echo x >"$T/src/zeros"
long5000=$(printf 'a%.0s' $(seq 5000))
tar -C "$T/src" -czf "$T/ln.tgz" --transform="s,^zeros\$,$long5000," zeros
refused "entry name over 3500 bytes" "deploy blog $(rel 1)" "$T/ln.tgz"

# --- names that pass the listing but cannot be extracted ----------------------

fresh
echo x >"$T/src/f"
for nm in . a/. ./.; do
  if tar -C "$T/src" -czf "$T/odd.tgz" --transform="s,^f\$,$nm," f 2>/dev/null && tar -tzf "$T/odd.tgz" >/dev/null 2>&1; then
    refused "regular file named '$nm' is refused with exit 2" "deploy blog $(rel 1)" "$T/odd.tgz"
  else
    skip "regular file named '$nm'" "this tar cannot build that entry"
  fi
done

# --- staging, as the deploy user with a root-owned parent ------------------------

fresh
if [ "$(id -u)" = 0 ] && command -v setpriv >/dev/null && command -v flock >/dev/null; then
  mkdir -p "$T/src/e"
  echo "a: 1" >"$T/src/e/a.yml"
  echo "b: 1" >"$T/src/e/b.yml"
  tar -C "$T/src/e" -czf "$T/e1.tgz" .
  chmod 755 "$tmp" "$T"
  chown root:root "$T/edge"
  chmod 755 "$T/edge"
  chown -R 65534:65534 "$EDGE_DYNAMIC" "$EDGE_INCOMING" "$SITES_ROOT/blog"
  # A copy the unprivileged user can reach: the checkout may sit under a private home (Actions runners).
  sd_repo="$SD"
  SD="$T/site-deploy"
  cp "$sd_repo" "$SD"
  chmod 755 "$SD"
  RUN_AS="setpriv --reuid=65534 --regid=65534 --clear-groups"
  run "edge-config" "$T/e1.tgz"
  [ "$rc" -eq 0 ] && [ "$(ls "$EDGE_DYNAMIC" | tr '\n' ' ')" = "a.yml b.yml " ] \
    && ok "edge-config works as an unprivileged user under a root-owned /srv/edge" || bad "edge-config as non-root" "rc=$rc $(cat "$T/err")"
  [ "$(stat -c %U "$T/edge")" = root ] && [ "$(ls -A "$T/edge" | tr '\n' ' ')" = ".incoming dynamic " ] \
    && ok "the root-owned parent is untouched" || bad "root-owned parent changed" "$(ls -A "$T/edge")"
  good_tar "$T/g.tgz"
  run "deploy blog $(rel 1)" "$T/g.tgz"
  [ "$rc" -eq 0 ] && ok "deploy works as an unprivileged user" || bad "deploy as non-root" "rc=$rc $(cat "$T/err")"
  RUN_AS=''
  SD="$sd_repo"
else
  skip "edge-config and deploy as an unprivileged user" "needs root, setpriv and flock (the Linux run as root has them)"
fi

# --- a lock per site, and stale leftovers swept under it -----------------------

fresh
if can_lock "lock tests"; then
  # a second command waits for the first
  flock "$SITES_ROOT/blog" sleep 2 &
  holder=$!
  sleep 0.3
  t0=$(date +%s%N)
  run "rollback blog"
  t1=$(date +%s%N)
  wait "$holder"
  [ "$rc" -eq 2 ] && [ $(((t1 - t0) / 1000000)) -ge 1000 ] \
    && ok "a second command waits for the lock (then judges on fresh state)" || bad "lock wait" "rc=$rc ms=$(((t1 - t0) / 1000000)) $(cat "$T/err")"

  # ...but not forever
  good_tar "$T/g.tgz"
  flock "$SITES_ROOT/blog" sleep 3 &
  holder=$!
  sleep 0.3
  LOCKW=1
  refused "a command that cannot get the lock within LOCK_WAIT is refused" "deploy blog $(rel 1)" "$T/g.tgz"
  LOCKW=30
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null

  # the lock leaves no file behind
  [ -z "$(ls -A "$SITES_ROOT/blog")" ] && ok "locking leaves no lock file" || bad "lock file" "$(ls -A "$SITES_ROOT/blog")"
fi

fresh
if can_deploy "parallel deploys, stale .tmp and .upload sweeps"; then
  good_tar "$T/g.tgz"
  # two deploys at once with KEEP=1: neither may prune the other's new release
  parallel_deploy() { # parallel_deploy <n> -> rc in $T/rc<n>
    (
      prc=0
      SSH_ORIGINAL_COMMAND="deploy blog $(rel "$1")" SITES_ROOT=$SITES_ROOT EDGE_DYNAMIC=$EDGE_DYNAMIC \
        EDGE_INCOMING=$EDGE_INCOMING MAX_BYTES=$MAXB KEEP=1 LOCK_WAIT=30 bash "$SD" <"$T/g.tgz" >"$T/o$1" 2>"$T/e$1" || prc=$?
      echo "$prc" >"$T/rc$1"
    ) &
  }
  parallel_deploy 1
  parallel_deploy 2
  wait
  [ "$(cat "$T/rc1")" = 0 ] && [ "$(cat "$T/rc2")" = 0 ] && [ -f "$SITES_ROOT/blog/current/index.html" ] \
    && [ -z "$(find "$SITES_ROOT/blog" -name '*.tmp' -o -name '.upload.*')" ] \
    && ok "two parallel deploys: both succeed, current is intact, nothing half-done left" || bad "parallel deploys" "$(cat "$T/rc1" "$T/rc2" "$T/e1" "$T/e2") $(ls "$SITES_ROOT/blog/releases")"

  # a SIGKILLed deploy's .tmp must not block the retry; old .upload dirs go, a fresh one stays
  mkdir -p "$SITES_ROOT/blog/releases/$(rel 3).tmp/sub"
  echo x >"$SITES_ROOT/blog/releases/$(rel 3).tmp/sub/f"
  chmod 000 "$SITES_ROOT/blog/releases/$(rel 3).tmp/sub"
  mkdir "$SITES_ROOT/blog/.upload.old" "$SITES_ROOT/blog/.upload.live"
  touch -d '5 hours ago' "$SITES_ROOT/blog/.upload.old"
  run "deploy blog $(rel 3)" "$T/g.tgz"
  [ "$rc" -eq 0 ] && [ -f "$SITES_ROOT/blog/releases/$(rel 3)/index.html" ] && [ ! -e "$SITES_ROOT/blog/releases/$(rel 3).tmp" ] \
    && ok "a stale release .tmp does not block a retry" || bad "stale .tmp" "rc=$rc $(cat "$T/err")"
  [ ! -e "$SITES_ROOT/blog/.upload.old" ] && [ -d "$SITES_ROOT/blog/.upload.live" ] \
    && ok "an abandoned upload dir is swept, a recent one is left alone" || bad "upload sweep" "$(ls -A "$SITES_ROOT/blog")"
fi

fresh
if can_lock "edge staging sweep"; then
  mkdir -p "$EDGE_INCOMING/new.dead" "$EDGE_INCOMING/.upload.old"
  echo x >"$EDGE_INCOMING/new.dead/a.yml"
  touch -d '5 hours ago' "$EDGE_INCOMING/.upload.old"
  mkdir -p "$T/src/e"
  echo "a: 1" >"$T/src/e/a.yml"
  tar -C "$T/src/e" -czf "$T/e1.tgz" .
  run "edge-config" "$T/e1.tgz"
  [ "$rc" -eq 0 ] && [ -z "$(ls -A "$EDGE_INCOMING")" ] && [ "$(ls "$EDGE_DYNAMIC")" = a.yml ] \
    && ok "edge-config sweeps what a killed run left in the staging dir" || bad "edge staging sweep" "rc=$rc $(ls -A "$EDGE_INCOMING")"
fi


# --- the unpacked tree is measured, not just the listing -----------------------
# A pax 0.1 sparse header whose GNU.sparse.size is rewritten (same digit count, so the
# record length still fits) lists as 10 bytes but unpacks to the real hole.

fresh
if can_lock "forged sparse size (deploy and edge-config)"; then
  truncate -s 5M "$T/src/holes"
  echo end >>"$T/src/holes"
  cp "$T/src/holes" "$T/src/a.yml"
  for nm in holes a.yml; do
    tar -C "$T/src" --format=posix --sparse --sparse-version=0.1 -czf "$T/forge-$nm.tgz" "$nm"
    gzip -dc "$T/forge-$nm.tgz" | sed 's/GNU\.sparse\.size=5242884/GNU.sparse.size=0000010/' | gzip -c >"$T/forged-$nm.tgz"
  done
  if tar -tvzf "$T/forged-holes.tgz" 2>/dev/null | grep -q ' 10 '; then
    MAXB=1000000
    refused "forged sparse size (deploy)" "deploy blog $(rel 1)" "$T/forged-holes.tgz"
    grep -q 'too large when unpacked' "$T/err" && ok "...caught by the unpacked-size check" || bad "forged sparse: wrong refusal" "$(cat "$T/err")"
    refused "forged sparse size (edge-config)" "edge-config" "$T/forged-a.yml.tgz"
  else
    skip "forged sparse size" "this tar did not list the forged size as 10 (cannot build the case)"
  fi
fi

# --- no client bytes on stderr, fixed refusals for names that cannot unpack ---

fresh
echo x >"$T/src/f"
comp300=$(printf 'c%.0s' $(seq 300))
tar -C "$T/src" -czf "$T/comp.tgz" --transform="s,^f\$,$comp300," f
refused "path component over 255 bytes" "deploy blog $(rel 1)" "$T/comp.tgz"
if [ "$(uname -s)" = Linux ]; then grep -q 'component too long' "$T/err" && ok "...with its own fixed reason" || bad "component reason" "$(cat "$T/err")"; fi

fresh
if [ "$(uname -s)" = Linux ] && can_lock "a path that fits the archive but not PATH_MAX"; then
  echo x >"$T/src/f"
  deep="$T"
  for _ in 1 2 3 4; do deep="$deep/$(printf 'd%.0s' $(seq 250))"; done
  mkdir -p "$deep/blog"
  SITES_ROOT=$deep
  p240=$(printf 'a%.0s' $(seq 255))
  longpath=''
  for _ in $(seq 13); do longpath="$longpath$p240/"; done
  longpath="${longpath}f.html"
  tar -C "$T/src" -czf "$T/deep.tgz" --transform="s,^f\$,$longpath," f
  run "deploy blog $(rel 1)" "$T/deep.tgz"
  if [ "$rc" -eq 2 ] && [[ "$(cat "$T/err")" == "refused: "* ]] && ! grep -q aaaa "$T/err" && [ "$(wc -l <"$T/err")" -eq 1 ] \
    && grep -q "cannot be unpacked" "$T/err" && [ -z "$(find "$deep/blog" -mindepth 1 | head -1)" ]; then
    ok "a path too long to unpack is a fixed refusal, no client bytes, nothing left behind"
  else
    bad "deep path" "rc=$rc $(head -c 200 "$T/err")"
  fi
fi

# --- tar's memory is bounded, and real sites still fit under the limit ---------

fresh
if [ "$(uname -s)" = Linux ] && can_deploy "legitimate big sites under the tar memory limit"; then
  mkdir -p "$T/big"
  dd if=/dev/zero of="$T/big/one.bin" bs=1M count=185 2>/dev/null
  tar -C "$T/big" -czf "$T/big1.tgz" .
  run "deploy blog $(rel 1)" "$T/big1.tgz"
  [ "$rc" -eq 0 ] && [ "$(stat -c %s "$SITES_ROOT/blog/current/one.bin")" -eq 193986560 ] \
    && ok "a 185 MiB one-file site deploys" || bad "big one-file site" "rc=$rc $(cat "$T/err")"
  rm -rf "$T/big" "$T/big1.tgz"
  mkdir -p "$T/many20k"
  (cd "$T/many20k" && seq 1 20000 | xargs touch)
  tar -C "$T/many20k" -czf "$T/many20k.tgz" .
  run "deploy blog $(rel 2)" "$T/many20k.tgz"
  [ "$rc" -eq 0 ] && [ "$(find "$SITES_ROOT/blog/current/" -type f | wc -l)" -eq 20000 ] \
    && ok "a 20,000-file site deploys" || bad "20k-file site" "rc=$rc $(cat "$T/err")"
fi

echo
echo "$passes passed, $failures failed, $skips skipped"
[ "$failures" -eq 0 ]
