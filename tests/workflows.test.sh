#!/usr/bin/env bash
# Text checks on .github/workflows/*.yml (python's yaml module is not
# everywhere, so no parsing; run actionlint for syntax). Like a lint for the
# rules this repo cares about: pinned actions, minimal permissions, no
# host-key bypass, inputs and secrets only through env.
# shellcheck disable=SC2015,SC2016 # A && ok || bad is the intent; ${{ is literal
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
W="$here/../.github/workflows"

failures=0 passes=0
ok() { echo "ok   $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; failures=$((failures + 1)); }

for f in ci deploy-static rollback edge-config; do
  [ -f "$W/$f.yml" ] || { echo "FAIL .github/workflows/$f.yml does not exist" >&2; exit 1; }
done

# run_bodies <file>: the text of every `run:` (one-liners and blocks).
run_bodies() {
  awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    inrun && (/^[[:space:]]*$/ || ind($0) > base) { print; next }
    { inrun = 0 }
    /^[[:space:]]*(- )?run:/ {
      base = ind($0); if ($0 ~ /^[[:space:]]*- /) base += 2
      line = $0; sub(/^[[:space:]]*(- )?run:[[:space:]]*/, "", line)
      if (line ~ /^[|>][-+]?$/) inrun = 1; else print line
    }' "$1"
}

for path in "$W"/*.yml; do
  f=${path##*/}

  # 1. every `uses:` is a 40-hex SHA with a tag comment (local ./ paths excepted)
  bad_uses=$(grep -E '^\s*(-\s+)?uses:' "$path" | grep -vE 'uses:\s+\./' |
    grep -vE 'uses:\s+[A-Za-z0-9._/-]+@[0-9a-f]{40}\s+# v[0-9][0-9A-Za-z._-]*\s*$')
  [ -z "$bad_uses" ] && ok "$f: uses pinned to a SHA with a tag comment" || bad "$f: unpinned uses" "$bad_uses"

  # 2. no host-key bypass in any form
  grep -i 'StrictHostKeyChecking' "$path" | grep -qvF 'StrictHostKeyChecking=yes' && bad "$f: StrictHostKeyChecking other than yes" || ok "$f: StrictHostKeyChecking is never relaxed"

  # no way for a fork's pull request to reach a secret
  grep -q 'pull_request_target' "$path" && bad "$f: pull_request_target" || ok "$f: no pull_request_target"

  # every job states its permissions; only contents: read in this repo
  njobs=$(awk '/^jobs:/{j=1;next} j&&/^  [a-z][a-z0-9_-]*:$/{c++} END{print c+0}' "$path")
  nperm=$(grep -c '^    permissions:$' "$path")
  [ "$njobs" -gt 0 ] && [ "$njobs" = "$nperm" ] && ok "$f: every job states its permissions" || bad "$f: job permissions" "$njobs jobs, $nperm blocks"
  grep -E '^ +[a-z-]+: write' "$path" && bad "$f: a write permission" || ok "$f: no write permission"

  # checkout leaves no token on disk for later steps
  [ "$(grep -c 'uses: actions/checkout@' "$path")" = "$(grep -c 'persist-credentials: false' "$path")" ] && ok "$f: checkout keeps no credentials" || bad "$f: persist-credentials"

  # every ssh: host key checked against the pinned file, stderr out of the public log
  nssh=$(grep -c 'out=\$(ssh ' "$path")
  [ "$(grep -c 'out=\$(ssh -i "\$RUNNER_TEMP/ssh/key" -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=' "$path")" = "$nssh" ] && ok "$f: each ssh ($nssh) has StrictHostKeyChecking=yes and the pinned file as its only source" || bad "$f: ssh host key options"
  [ "$(grep -cF '2>"$RUNNER_TEMP/ssh/err")' "$path")" = "$nssh" ] && ok "$f: ssh stderr, which names host and port, stays out of the log" || bad "$f: ssh stderr"
  run_bodies "$path" | grep -qE 'ssh [^|]*-v|ssh -[a-zA-Z]*v' && bad "$f: verbose ssh" || ok "$f: no verbose ssh"

  # 3. top-level permissions: contents: read and nothing else
  perms=$(awk '/^permissions:/ {p = 1; next} p && /^[^[:space:]]/ {exit} p && NF {print}' "$path")
  [ "$perms" = "  contents: read" ] && ok "$f: permissions are contents: read only" || bad "$f: permissions" "got: ${perms:-none}"
  grep -qE 'write' <<<"$perms" && bad "$f: a write permission"

  # 4. no expression inside run: (inputs and secrets go through env:)
  if run_bodies "$path" | grep -qF '${{'; then bad "$f: \${{ }} inside run:"; else ok "$f: no \${{ }} inside run:"; fi
  # 5. no secret or input expression anywhere but env:/with:/concurrency/if lines
  grep -nE '\$\{\{\s*(secrets|inputs|github\.event\.inputs)\.' "$path" |
    grep -vE '^[0-9]+:\s+[A-Z_]+: \$\{\{|^[0-9]+:\s*(group|if|concurrency|cancel-in-progress):|^[0-9]+:\s+(artifact|name|path):' >/tmp/.wf$$ || true
  [ ! -s /tmp/.wf$$ ] && ok "$f: inputs/secrets only on env: lines" || bad "$f: inputs/secrets outside env:" "$(cat /tmp/.wf$$)"
  rm -f /tmp/.wf$$
done

# ci.yml has its own pins; the deploy workflows must pin the same checkout
grep -q 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' "$W/ci.yml" && ok "ci.yml: checkout v7.0.1 pinned" || bad "ci.yml: checkout pin"

# ci.yml scans the whole history with the pinned gitleaks image (a digest, like R1 step 6)
grep -qF 'zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f' "$W/ci.yml" && ok "ci.yml: gitleaks image pinned by digest" || bad "ci.yml: gitleaks image pin"
grep -qF -- '--log-opts=--all' "$W/ci.yml" && grep -qF -- '--redact' "$W/ci.yml" && ok "ci.yml: gitleaks scans all history, redacted" || bad "ci.yml: gitleaks flags"
grep -qE 'sudo bash tests/site-deploy.test.sh' "$W/ci.yml" && ok "ci.yml: site-deploy tests also run as root" || bad "ci.yml: root site-deploy run"
grep -qE 'sudo bash tests/play-apply.test.sh' "$W/ci.yml" && ok "ci.yml: play-apply tests also run as root" || bad "ci.yml: root play-apply run"
# box/ also holds systemd units, which are not shell
grep -qF 'files=(box/site-deploy box/play-apply tests/*.sh)' "$W/ci.yml" && ok "ci.yml: shellcheck gets both box scripts and no unit file" || bad "ci.yml: shellcheck file list"

# every deploy job has a time limit and an ssh keepalive
for f in deploy-static rollback edge-config; do
  grep -qE '^    timeout-minutes: 15$' "$W/$f.yml" && ok "$f.yml: timeout-minutes 15" || bad "$f.yml: timeout-minutes"
  grep -qF 'ServerAliveInterval=30' "$W/$f.yml" && ok "$f.yml: ssh keepalive" || bad "$f.yml: ServerAliveInterval"
done

# deploy jobs: only a push to main or a dispatch on main
for f in deploy-static edge-config; do
  grep -qF "if: github.ref == 'refs/heads/main' && (github.event_name == 'push' || github.event_name == 'workflow_dispatch')" "$W/$f.yml" && ok "$f.yml: guarded to push or dispatch on main" || bad "$f.yml: event guard"
done
grep -qF "if: github.ref == 'refs/heads/main' && github.event_name == 'workflow_dispatch'" "$W/rollback.yml" && ok "rollback.yml: guarded to dispatch on main" || bad "rollback.yml: event guard"
# pull_request runs get no secrets and no environment
grep -qE 'secrets\.[A-Z]|environment:' "$W/ci.yml" && bad "ci.yml: runs on pull requests but names a secret or environment" || ok "ci.yml: no secret and no environment"
# the keys behind these workflows can do nothing but their forced command
grep -q 'restrict,command="/usr/local/bin/site-deploy"' "$here/../runbooks/01-box-setup.md" && ok "runbook 1: the deploy key is restrict plus a forced command" || bad "runbook 1: authorized_keys line"

# environment: production
for f in deploy-static rollback edge-config; do
  grep -qE '^    environment: production$' "$W/$f.yml" && ok "$f.yml: job environment is production" || bad "$f.yml: environment: production on the job"
done
# never on a calling job (a `uses:` job) and none at workflow level
grep -qE '^environment:' "$W/deploy-static.yml" && bad "deploy-static.yml: environment at workflow level"

# deploy-static: reusable, three inputs, no declared secrets, checks the four
D="$W/deploy-static.yml"
grep -qE '^  workflow_call:' "$D" && ok "deploy-static.yml: workflow_call" || bad "deploy-static.yml: workflow_call"
grep -qE '^    secrets:' "$D" && bad "deploy-static.yml: declares on.workflow_call.secrets" || ok "deploy-static.yml: declares no secrets"
for i in site artifact url; do
  grep -qE "^      $i:" "$D" && ok "deploy-static.yml: input $i" || bad "deploy-static.yml: input $i"
done
for s in DEPLOY_SSH_KEY DEPLOY_HOST DEPLOY_PORT DEPLOY_KNOWN_HOSTS; do
  grep -qF "$s: \${{ secrets.$s }}" "$D" && grep -qF "$s" <(run_bodies "$D") &&
    ok "deploy-static.yml: $s read from env and checked" || bad "deploy-static.yml: $s not wired"
done
grep -qE 'concurrency:' "$D" && grep -qF 'deploy-${{ inputs.site }}' "$D" && ok "deploy-static.yml: concurrency per site" || bad "deploy-static.yml: concurrency"
grep -qF '^[a-z0-9-]{1,32}$' "$D" && ok "deploy-static.yml: site validated with site-deploy's regex" || bad "deploy-static.yml: site regex"
grep -qF '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7,40}$' "$here/../box/site-deploy" && grep -qE 'date -u \+%Y%m%dT%H%M%SZ' "$D" && ok "deploy-static.yml: release id like site-deploy's" || bad "deploy-static.yml: release id"
# main only
grep -qF "github.ref == 'refs/heads/main'" "$D" && ok "deploy-static.yml: main only" || bad "deploy-static.yml: main only"
grep -qF "github.ref == 'refs/heads/main'" "$W/rollback.yml" && ok "rollback.yml: main only" || bad "rollback.yml: main only"
grep -qE 'branches: \[main\]' "$W/edge-config.yml" && grep -qF 'edge/dynamic/**' "$W/edge-config.yml" && ok "edge-config.yml: push to main on edge/dynamic/**" || bad "edge-config.yml: trigger"
grep -qF "github.ref == 'refs/heads/main'" "$W/edge-config.yml" && ok "edge-config.yml: main only (dispatch too)" || bad "edge-config.yml: main only"
grep -qE '^  workflow_dispatch:' "$W/rollback.yml" && ok "rollback.yml: workflow_dispatch" || bad "rollback.yml: workflow_dispatch"
grep -qE '^  workflow_dispatch:' "$W/edge-config.yml" && ok "edge-config.yml: workflow_dispatch" || bad "edge-config.yml: workflow_dispatch"
grep -qF '</dev/null' <(run_bodies "$W/rollback.yml") && ok "rollback.yml: stdin is /dev/null" || bad "rollback.yml: </dev/null"

# every deploy workflow checks host keys via a pinned known_hosts and cleans the key up
for f in deploy-static rollback edge-config; do
  p="$W/$f.yml"
  grep -qF 'UserKnownHostsFile=' "$p" && grep -qF 'IdentitiesOnly=yes' "$p" && grep -qF 'BatchMode=yes' "$p" && ok "$f.yml: ssh uses pinned known_hosts, only the one key, no prompts" || bad "$f.yml: ssh options"
  grep -qF 'if: always()' "$p" && ok "$f.yml: key removed in an always() step" || bad "$f.yml: key cleanup"
  # host and port are secrets: never echoed
  run_bodies "$p" | grep -E '\becho\b[^;}|]*\$\{?DEPLOY_(HOST|PORT)|set -x|xtrace' && bad "$f.yml: host/port echoed or tracing on" || ok "$f.yml: host/port not echoed"
done

echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
