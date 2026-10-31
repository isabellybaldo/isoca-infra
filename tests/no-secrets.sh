#!/usr/bin/env bash
# Fails if a tracked file holds something this public repo must never hold:
# a real IPv4 address, a private key header, or an SSH key fingerprint.
# NO_SECRETS_ROOT points the scan at another git repo (the test uses a temp one).
set -euo pipefail
cd "${NO_SECRETS_ROOT:-$(dirname "$0")/..}"

fail=0
report() { echo "no-secrets: $1" >&2; fail=1; }

git ls-files >/dev/null || { echo "no-secrets: cannot list tracked files (not a git repo?)" >&2; exit 1; }
mapfile -d '' -t files < <(git ls-files -z)
[ "${#files[@]}" -gt 0 ] || { echo "no-secrets: no tracked files, nothing to scan" >&2; exit 1; }

allowed_ip() {
  case "$1" in
    127.0.0.1 | 0.0.0.0 | 203.0.113.[0-9] | 203.0.113.[0-9][0-9] | 203.0.113.[0-9][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

count=0
for f in "${files[@]}"; do
  case "$f" in local.env.example | tests/no-secrets.sh) continue ;; esac
  [ -f "$f" ] || continue
  count=$((count + 1))
  # Every run of digits and dots on its own, so neighbours cannot hide each other.
  rc=0
  runs=$(grep -oE '[0-9]+(\.[0-9]+)*' -- "$f") || rc=$?
  [ "$rc" -le 1 ] || { report "$f: grep failed ($rc)"; continue; }
  while IFS= read -r ip; do
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    allowed_ip "$ip" || report "$f: IPv4 literal: $ip"
  done <<<"$runs"
  if grep -qE 'BEGIN (OPENSSH|RSA|EC) PRIVATE KEY' -- "$f"; then
    report "$f: private key header"
  fi
  if grep -qE 'SHA256:[0-9a-fA-F]{64}' -- "$f"; then
    report "$f: 64-hex fingerprint"
  fi
done

[ "$fail" -eq 0 ] && echo "no-secrets: clean ($count files)"
exit "$fail"
