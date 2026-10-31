#!/usr/bin/env bash
# Tests the edge (edge/): the compose file, the nginx config and the Traefik
# config, against the pinned images, run with the same hardening flags as
# compose. Needs Docker. Fixtures live in named volumes (a bind mount cannot
# hold a real symlink on Docker Desktop for Windows); the config files are
# staged in a temp dir that the containers can read.
# shellcheck disable=SC2015 # A && ok || bad is the intent
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$here/.."
E="$repo/edge"
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

failures=0 passes=0
ok() { echo "ok   $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; failures=$((failures + 1)); }

for f in compose.yml traefik.yml dynamic/radar.yml dynamic/isoca.yml dynamic/common.yml nginx/sites.conf; do
  [ -f "$E/$f" ] || { echo "FAIL edge/$f does not exist" >&2; exit 1; }
done
command -v docker >/dev/null || { echo "FAIL docker is needed" >&2; exit 1; }

id="edge-test-$$"
tmp="$(mktemp -d)"
wtmp="$(cygpath -m "$tmp" 2>/dev/null || printf %s "$tmp")" # curl on Windows is native and needs C:/ paths
cleanup() {
  docker rm -f "$id-nginx" "$id-traefik" "$id-fresh" >/dev/null 2>&1
  docker volume rm -f "$id-sites" "$id-acme" "$id-empty" >/dev/null 2>&1
  docker network rm "$id" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT

# The path docker wants for a host path (Git Bash on Windows needs C:/...).
hostpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Pinned images, read from compose so the test and the box cannot drift.
NGINX_IMG="$(grep -E '^\s+image: nginxinc/nginx-unprivileged:' "$E/compose.yml" | head -1 | sed -E 's/^\s+image: //')"
TRAEFIK_IMG="$(grep -E '^\s+image: traefik:' "$E/compose.yml" | head -1 | sed -E 's/^\s+image: //')"

# --- compose file ---------------------------------------------------------------------------

docker compose -f "$(hostpath "$E/compose.yml")" config -q 2>"$tmp/cfgerr" \
  && ok "compose config is valid" || bad "compose config" "$(cat "$tmp/cfgerr")"
docker compose -f "$(hostpath "$E/compose.yml")" config >"$tmp/composed" 2>/dev/null

[ "$(grep -cE '^\s+image: .+@sha256:[0-9a-f]{64}$' "$tmp/composed")" -eq 2 ] \
  && ok "both images are pinned by digest" || bad "image pins"
[ "$(grep -cE '^    read_only: true' "$tmp/composed")" -eq 2 ] \
  && ok "both containers are read_only" || bad "read_only on both"
[ "$(grep -cE '^\s+- ALL$' "$tmp/composed")" -eq 2 ] \
  && ok "both containers drop all capabilities" || bad "cap_drop ALL on both"
[ "$(grep -c 'no-new-privileges:true' "$tmp/composed")" -eq 2 ] \
  && ok "both containers set no-new-privileges" || bad "no-new-privileges on both"
[ "$(grep -c 'max-size: 10m' "$tmp/composed")" -eq 2 ] && [ "$(grep -c 'max-file: "5"' "$tmp/composed")" -eq 2 ] \
  && ok "both containers cap their json-file logs (10m x 5)" || bad "log caps"
[ "$(grep -cE '^\s+(cpus|mem_limit):' "$tmp/composed")" -ge 4 ] \
  && ok "both containers have cpu and memory limits" || bad "limits"
grep -qE '^\s+user: "?65532' "$tmp/composed" \
  && ok "traefik runs as 65532" || bad "traefik user"
awk '/^networks:/{n=1} n' "$tmp/composed" | grep -A6 '^  edge:' | grep -q 'internal: true' \
  && ok "the edge network is internal" || bad "edge network internal"
# nginx may sit on the edge network only
awk '/^  nginx:/{n=1} /^  traefik:/{n=0} n' "$tmp/composed" | awk '/^    networks:/{n=1;next} n&&/^      [a-z]/{print $1} n&&/^    [a-z]/{n=0}' >"$tmp/nginxnets"
[ "$(tr -d ':\n' <"$tmp/nginxnets")" = edge ] \
  && ok "nginx is on the edge network only" || bad "nginx networks" "$(cat "$tmp/nginxnets")"
svc() { awk -v s="  $1:" '$0==s{n=1;next} /^  [a-z]/{n=0} /^[a-z]/{n=0} n' "$tmp/composed"; }
svc traefik | grep -A1 'target: 8000' | grep -q 'published: "80"' && svc traefik | grep -A1 'target: 8443' | grep -q 'published: "443"' \
  && ok "traefik publishes host 80 -> 8000 and 443 -> 8443" || bad "published ports"
svc traefik | grep -B1 -A2 'target: /dynamic' | grep -q 'source: /srv/edge/dynamic' && svc traefik | grep -A2 'target: /dynamic' | grep -q 'read_only: true' \
  && ok "/srv/edge/dynamic is mounted read-only" || bad "dynamic mount"
svc traefik | grep -B1 'target: /acme' | grep -q 'source: /srv/edge/acme' && ! svc traefik | grep -A2 'target: /acme' | grep -q 'read_only: true' \
  && ok "/srv/edge/acme is mounted read-write" || bad "acme mount"
[ "$(svc traefik | awk '/^    networks:/{n=1;next} n&&/^      [a-z]/{print $1} n&&/^    [a-z]/{n=0}' | tr -d ':' | sort | tr '\n' ' ')" = "edge public " ] \
  && ok "traefik is on public and edge" || bad "traefik networks"
svc nginx | grep -q 'ports:' && bad "nginx publishes ports" || ok "nginx publishes nothing"
svc nginx | grep -q '/healthz' && ok "nginx has a healthcheck on /healthz" || bad "nginx healthcheck"
svc traefik | grep -q 'healthcheck:' && bad "traefik has a healthcheck (ruled out)" || ok "traefik has no healthcheck"


# --- forbidden things -----------------------------------------------------------------------

# Comments stripped; whole words, so "permissions" does not trip "ssi".
for f in compose.yml traefik.yml dynamic/radar.yml dynamic/isoca.yml dynamic/common.yml nginx/sites.conf; do
  sed 's/#.*//' "$E/$f" >"$tmp/stripped"
  hit="$(grep -nwE 'alias|ssi|aio|http3|quic|map' "$tmp/stripped"; grep -nE 'ssl_|docker\.sock' "$tmp/stripped")" || true
  [ -z "$hit" ] && ok "edge/$f: no alias/ssi/aio/map/http3/quic/ssl_/docker.sock" || bad "edge/$f" "$hit"
done
grep -qE '^\s*server_tokens off;' "$E/nginx/sites.conf" \
  && ok "server_tokens off" || bad "server_tokens off"

# --- redirect regex -------------------------------------------------------------------------

regex="$(sed -n -E "s/^\s*regex: '(.*)'\s*$/\1/p" "$E/dynamic/isoca.yml" | head -1)"
repl="$(sed -n -E "s/^\s*replacement: '(.*)'\s*$/\1/p" "$E/dynamic/isoca.yml" | head -1)"
if [ -n "$regex" ] && [ -n "$repl" ]; then
  # Go's regexp and perl agree on this pattern; ${1} is perl's too.
  got="$(perl -e '($u,$r,$p)=@ARGV; $p =~ s/\$\{1\}/\$1/; if ($u =~ /$r/) { $x=$1; $p =~ s/\$1/$x/; print $p } else { print "NOMATCH" }' \
    'https://www.isoca.space/foo?x=1' "$regex" "$repl")"
  [ "$got" = 'https://isabellybaldo.github.io/foo?x=1' ] \
    && ok "redirect regex: www.isoca.space/foo?x=1 -> github.io/foo?x=1" || bad "redirect regex" "$got"
  got="$(perl -e '($u,$r,$p)=@ARGV; $p =~ s/\$\{1\}/\$1/; if ($u =~ /$r/) { $x=$1; $p =~ s/\$1/$x/; print $p } else { print "NOMATCH" }' \
    'http://isoca.space/' "$regex" "$repl")"
  [ "$got" = 'https://isabellybaldo.github.io/' ] \
    && ok "redirect regex: bare isoca.space/ -> github.io/" || bad "redirect regex root" "$got"
else
  bad "redirect regex not found in edge/dynamic/isoca.yml"
fi

# --- nginx, hardened like compose ------------------------------------------------------------

docker network create "$id" >/dev/null 2>&1 || { echo "FAIL cannot create a docker network" >&2; exit 1; }
docker volume create "$id-sites" >/dev/null
docker volume create "$id-acme" >/dev/null

# Helper: run a root shell in the nginx image with the sites volume (the image has sh).
rootsh() { docker run --rm -i --user 0 --entrypoint sh -v "$id-sites:/srv/sites" -v "$id-acme:/acme" "$NGINX_IMG" -s; }

rootsh >/dev/null <<'EOF' || { echo "FAIL fixture build" >&2; exit 1; }
set -e
cd /srv/sites
rel() { # $1 = x|y
  d=radar/releases/$1
  mkdir -p $d/site-assets $d/math-assets $d/frozen
  printf '<!doctype html><title>index-%s</title><p>INDEX-%s with enough text to be worth compressing, yes</p>\n' "$1" "$1" >$d/index.html
  printf '<!doctype html><title>math-%s</title><p>MATH-%s with enough text to be worth compressing, yes</p>\n' "$1" "$1" >$d/math.html
  printf '<!doctype html><title>sweet-%s</title><p>SWEET-%s with enough text to be worth compressing, yes</p>\n' "$1" "$1" >$d/sweet.html
  printf 'console.log("asset %s, long enough to be worth compressing, really");\n' "$1" >$d/site-assets/a.js
  printf '\0asm\1\0\0\0 padding padding padding padding padding padding padding padding\n' >$d/math-assets/m.wasm
  printf '{"frozen":"%s","rows":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18]}\n' "$1" >$d/frozen/public.json
}
rel x
rel y
ln -s releases/x radar/current
chmod -R a+rX /srv/sites
chown 65532:65532 /acme 2>/dev/null || true
EOF
# the acme dir is a bind-mount-like dir owned by 65532, 0700, as on the box
docker run --rm --user 0 --entrypoint sh -v "$id-acme:/acme" "$NGINX_IMG" -c 'chown 65532:65532 /acme && chmod 0700 /acme'

docker run -d --name "$id-nginx" --network "$id" --network-alias nginx -p 127.0.0.1::8080 \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp \
  -v "$(hostpath "$E/nginx/sites.conf"):/etc/nginx/conf.d/default.conf:ro" \
  -v "$id-sites:/srv/sites:ro" "$NGINX_IMG" >/dev/null 2>"$tmp/nerr" \
  || { bad "nginx container starts" "$(cat "$tmp/nerr")"; exit 1; }

ver="$(docker exec "$id-nginx" nginx -v 2>&1 | sed -E 's|.*nginx/||')"
[ "$(printf '%s\n1.30.6\n' "$ver" | sort -V | head -1)" = 1.30.6 ] \
  && ok "nginx is $ver (>= 1.30.6)" || bad "nginx version" "$ver"
docker exec "$id-nginx" nginx -t >"$tmp/nt" 2>&1 \
  && ok "nginx -t passes (read_only, cap_drop ALL, tmpfs /tmp)" || bad "nginx -t" "$(cat "$tmp/nt")"

NP="$(docker port "$id-nginx" 8080/tcp | head -1 | sed -E 's/.*://')"
for _ in $(seq 1 30); do curl -s -o /dev/null -H 'Host: radar.isoca.space' "http://127.0.0.1:$NP/" && break; sleep 0.5; done

# req <port> <host> <path> [curl args]: sets C (status), H (headers, lowercased), B (body)
req() {
  local port="$1" host="$2" path="$3"
  shift 3
  C="$(curl -s -o "$wtmp/body" -D "$wtmp/hdr" -w '%{http_code}' -H "Host: $host" "$@" "http://127.0.0.1:$port$path")" || C="curl-$?"
  H="$(tr -d '\r' <"$tmp/hdr" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  B="$(tr -d '\000' <"$tmp/body" 2>/dev/null)"
}
nreq() { req "$NP" radar.isoca.space "$@"; }

nreq /;               [ "$C" = 200 ] && [[ "$B" == *INDEX-x* ]] && ok "/ -> 200 index" || bad "/" "$C"
echo "$H" | grep -q '^content-type: text/html' && echo "$H" | grep -q '^cache-control: no-cache' \
  && ok "/ is html and no-cache" || bad "/ headers" "$H"
nreq /math;           [ "$C" = 200 ] && [[ "$B" == *MATH-x* ]] && ok "/math -> 200 math.html" || bad "/math" "$C"
echo "$H" | grep -q '^content-type: text/html' && echo "$H" | grep -q '^cache-control: no-cache' \
  && ok "/math is html and no-cache" || bad "/math headers" "$H"
nreq /sweet;          [ "$C" = 200 ] && [[ "$B" == *SWEET-x* ]] && ok "/sweet -> 200" || bad "/sweet" "$C"
nreq /math.html;      [ "$C" = 200 ] && echo "$H" | grep -q '^cache-control: no-cache' \
  && ok "/math.html is no-cache" || bad "/math.html" "$C"
nreq /site-assets/a.js
[ "$C" = 200 ] && echo "$H" | grep -q '^cache-control: public, max-age=31536000, immutable' \
  && ok "/site-assets/a.js -> 200, 1 year immutable" || bad "/site-assets/a.js" "$C $H"
nreq /math-assets/m.wasm
[ "$C" = 200 ] && echo "$H" | grep -q '^content-type: application/wasm' && echo "$H" | grep -q 'max-age=31536000, immutable' \
  && ok "m.wasm is application/wasm, 1 year immutable" || bad "wasm" "$C $H"
nreq /frozen/public.json
[ "$C" = 200 ] && echo "$H" | grep -q '^cache-control: public, max-age=86400' \
  && ok "/frozen/public.json -> 200, 1 day" || bad "frozen" "$C $H"
nreq /nope;           [ "$C" = 404 ] && ok "/nope -> 404" || bad "/nope" "$C"
nreq /site-assets/;   [ "$C" = 404 ] && ok "/site-assets/ -> 404 (no listing)" || bad "/site-assets/" "$C"
nreq /frozen/;        [ "$C" = 404 ] && ok "/frozen/ -> 404 (no listing)" || bad "/frozen/" "$C"
nreq /math-assets/;   [ "$C" = 404 ] && ok "/math-assets/ -> 404 (no listing)" || bad "/math-assets/" "$C"
nreq /;               echo "$H" | grep -qE '^server: nginx\s*$' \
  && ok "Server header carries no version" || bad "Server header" "$(echo "$H" | grep '^server')"

for p in / /math /site-assets/a.js /math-assets/m.wasm /frozen/public.json; do
  nreq "$p" -H 'Accept-Encoding: gzip'
  echo "$H" | grep -q '^content-encoding: gzip' && ok "gzip on $p" || bad "gzip on $p" "$H"
done

req "$NP" other.example /; [ "$C" = curl-52 ] && ok "unknown Host -> 444 (connection closed)" || bad "unknown host" "$C"
C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NP/" 2>/dev/null)"
[ "$C" = 000 ] && ok "a Host of 127.0.0.1 is also refused" || bad "ip host" "$C"

nreq /.hidden;        [ "$C" = 404 ] && ok "/.hidden -> 404" || bad "/.hidden" "$C"
nreq /.git/config;    [ "$C" = 404 ] && ok "/.git/config -> 404" || bad "/.git/config" "$C"
nreq /site-assets/.x; [ "$C" = 404 ] && ok "a dotfile under an asset dir -> 404" || bad "dotfile in assets" "$C"
nreq /healthz;        [ "$C" != 200 ] && ok "Host radar.isoca.space /healthz is not 200 ($C)" || bad "/healthz via radar host"
C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NP/healthz")"
[ "$C" = 200 ] && ok "the default server answers /healthz" || bad "default /healthz" "$C"

# healthy on a fresh box: no sites, so no `current`; the healthcheck command is the compose one
docker volume create "$id-empty" >/dev/null
hc="$(sed -n -E 's/^\s+test: \[(.*)\]$/\1/p' "$E/compose.yml" | head -1 | sed -E 's/"CMD", //; s/", "/ /g; s/"//g')"
docker run -d --name "$id-fresh" --network "$id" --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp \
  --health-cmd "$hc" --health-interval 2s --health-timeout 3s --health-retries 3 \
  -v "$(hostpath "$E/nginx/sites.conf"):/etc/nginx/conf.d/default.conf:ro" -v "$id-empty:/srv/sites:ro" "$NGINX_IMG" >/dev/null
st=""
for _ in $(seq 1 30); do
  st="$(docker inspect -f '{{.State.Health.Status}}' "$id-fresh" 2>/dev/null)"
  [ "$st" = healthy ] && break
  sleep 1
done
[ "$st" = healthy ] && ok "nginx is healthy with no current (cmd: $hc)" || bad "fresh-box health" "$st"
docker rm -f "$id-fresh" >/dev/null 2>&1

# re-point `current` (relative symlink) and expect the new release at once
docker run --rm --user 0 --entrypoint sh -v "$id-sites:/srv/sites" "$NGINX_IMG" -c 'cd /srv/sites/radar && ln -sfn releases/y current'
nreq /;      [ "$C" = 200 ] && [[ "$B" == *INDEX-y* ]] && ok "after re-pointing current, / serves the new release" || bad "repoint /" "$C $B"
nreq /math;  [[ "$B" == *MATH-y* ]] && ok "after re-pointing current, /math serves the new release" || bad "repoint /math" "$B"

# --- traefik, hardened like compose ----------------------------------------------------------

cfg="$tmp/cfg"
mkdir -p "$cfg/dynamic"
# The only change to the static file: a CA that cannot resolve, so no ACME traffic leaves the test.
sed -E 's|^(\s*)storage:.*|&\n\1caServer: https://acme.invalid/directory|' "$E/traefik.yml" >"$cfg/traefik.yml"
grep -q 'acme.invalid' "$cfg/traefik.yml" || bad "could not point ACME at a dead CA (is there a storage: key?)"
cp "$E"/dynamic/*.yml "$cfg/dynamic/"
chmod -R a+rX "$cfg"
chmod a+rx "$tmp"

docker run -d --name "$id-traefik" --network "$id" -p 127.0.0.1::8000 -p 127.0.0.1::8443 --user 65532:65532 \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  -v "$(hostpath "$cfg/traefik.yml"):/etc/traefik/traefik.yml:ro" \
  -v "$(hostpath "$cfg/dynamic"):/dynamic:ro" \
  -v "$id-acme:/acme" "$TRAEFIK_IMG" >/dev/null 2>"$tmp/terr" \
  || { bad "traefik container starts" "$(cat "$tmp/terr")"; exit 1; }

tver="$(docker exec "$id-traefik" traefik version 2>&1 | sed -n -E 's/^Version:\s+//p')"
case "$tver" in 3.*) ok "traefik is $tver (v3)" ;; *) bad "traefik version" "$tver" ;; esac

HP="$(docker port "$id-traefik" 8000/tcp | head -1 | sed -E 's/.*://')"
SP="$(docker port "$id-traefik" 8443/tcp | head -1 | sed -E 's/.*://')"

# sreq <host> <path> [curl args]: https on websecure, self-signed default cert, so -k
sreq() {
  local host="$1" path="$2"
  shift 2
  C="$(curl -sk -o "$wtmp/body" -D "$wtmp/hdr" -w '%{http_code}' --resolve "$host:$SP:127.0.0.1" -H "Host: $host" "$@" "https://$host:$SP$path")" || C="curl-$?"
  H="$(tr -d '\r' <"$tmp/hdr" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  B="$(tr -d '\000' <"$tmp/body" 2>/dev/null)"
}

# The router loads from the file provider a moment after start.
for _ in $(seq 1 40); do
  sreq radar.isoca.space /
  [ "$C" = 200 ] && break
  sleep 0.5
done
logs="$(docker logs "$id-traefik" 2>&1)"
[ "$C" = 200 ] && ok "traefik loaded the routers and reaches nginx over the network (https /, 200)" \
  || bad "radar via traefik" "$C; logs: $(echo "$logs" | tail -15)"

# A router that names a middleware that does not resolve is dropped (404), so these 200s and headers
# prove the sec@file, csp-radar@file, rl@file and inflight@file references resolved across files.
echo "$logs" | grep -qiE 'does not exist|middleware .* not found|unknown' \
  && bad "traefik logs a missing middleware" "$(echo "$logs" | grep -iE 'does not exist|not found|unknown')" \
  || ok "no unresolved @file references in the traefik logs"
echo "$logs" | grep -q '"ClientHost":"[0-9a-f.:]\+"' && ok "traefik access log (JSON) carries ClientHost" || bad "access log" "$(echo "$logs" | tail -3)"
unexpected="$(echo "$logs" | grep -E '(^|[[:space:]])ERR([[:space:]]|$)|level=error' | grep -viE 'acme|letsencrypt|acme.invalid')" || true
[ -z "$unexpected" ] && ok "no ERR lines in traefik logs beyond ACME's" || bad "unexpected ERR lines" "$unexpected"

sreq radar.isoca.space /math
[ "$C" = 200 ] && [[ "$B" == *MATH-y* ]] && ok "https /math -> 200 via traefik" || bad "https /math" "$C"
echo "$H" | grep -q '^strict-transport-security: max-age=31536000' && ! echo "$H" | grep -q 'preload' \
  && ok "HSTS 1 year, no preload" || bad "HSTS" "$(echo "$H" | grep strict)"
echo "$H" | grep -q '^x-frame-options: deny' && ok "frame deny" || bad "frame deny"
echo "$H" | grep -q '^x-content-type-options: nosniff' && ok "nosniff" || bad "nosniff"
echo "$H" | grep -q '^referrer-policy: same-origin' && ok "referrer same-origin" || bad "referrer"
csp="default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
[ "$(echo "$H" | sed -n 's/^content-security-policy: //p')" = "$csp" ] && ok "CSP is exact" || bad "CSP" "$(echo "$H" | grep content-security)"
echo "$H" | grep -qE '^server: nginx\s*$' && ok "Server header through traefik: nginx, no version" || bad "Server through traefik"

sreq isoca.space "/foo?x=1"
[ "$C" = 302 ] && [ "$(echo "$H" | sed -n 's/^location: //p')" = 'https://isabellybaldo.github.io/foo?x=1' ] \
  && ok "https isoca.space/foo?x=1 -> 302 github.io/foo?x=1" || bad "isoca.space redirect" "$C $(echo "$H" | grep location)"
sreq www.isoca.space "/"
[ "$C" = 302 ] && [ "$(echo "$H" | sed -n 's/^location: //p')" = 'https://isabellybaldo.github.io/' ] \
  && ok "https www.isoca.space/ -> 302 github.io/" || bad "www redirect" "$C $(echo "$H" | grep location)"
sreq stranger.example /; [ "$C" = 404 ] && ok "an unrouted host gets traefik's 404" || bad "unrouted host" "$C"

# http: everything redirects to https
for h in radar.isoca.space isoca.space; do
  req "$HP" "$h" "/a/b?q=1"
  [ "$C" = 301 ] || [ "$C" = 308 ] && [ "$(echo "$H" | sed -n 's/^location: //p')" = "https://$h/a/b?q=1" ] \
    && ok "http $h -> $C to https, path and query kept" || bad "http redirect $h" "$C $(echo "$H" | grep location)"
done
req "$HP" radar.isoca.space "/.well-known/acme-challenge/nonesuch"
[ "$C" = 404 ] && ok "the ACME challenge path is not swallowed by the https redirect (404 for an unknown token)" \
  || bad "acme challenge path" "$C $(echo "$H" | grep location)"

# the same limiter sits on the isoca.space router (every public router has one)
codes="$(curl -sk -o /dev/null -w '%{http_code}
' --resolve "isoca.space:$SP:127.0.0.1" "https://isoca.space:$SP/?[1-150]" | sort | uniq -c | tr -s ' ' | tr '
' ';')"
echo "$codes" | grep -q '429' && ok "rate limit on isoca.space: a 150-request burst gets 429s ($codes)" || bad "rate limit on isoca.space" "$codes"

# the rate limiter: a burst of 150 on one source is cut off (average 10/s, burst 40)
codes="$(curl -sk -o /dev/null -w '%{http_code}\n' --resolve "radar.isoca.space:$SP:127.0.0.1" "https://radar.isoca.space:$SP/?[1-150]" | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
echo "$codes" | grep -q '429' && ok "rate limit: a 150-request burst gets 429s ($codes)" || bad "rate limit" "$codes"

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
