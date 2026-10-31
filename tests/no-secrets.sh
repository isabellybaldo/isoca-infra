#!/usr/bin/env bash
# Fails if a tracked file holds something this public repo must never hold:
# a real IPv4 address, a private key header, or an SSH key fingerprint.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
report() { echo "no-secrets: $1" >&2; fail=1; }

mapfile -t files < <(git ls-files | grep -v -e '^local\.env\.example$' -e '^tests/no-secrets\.sh$')

for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  # IPv4 literals, minus 127.0.0.1, 0.0.0.0 and the documentation range 203.0.113.0/24.
  while IFS= read -r hit; do
    report "$f: IPv4 literal: $hit"
  done < <(grep -InoE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' "$f" \
    | grep -vE '(^|[^0-9.])(127\.0\.0\.1|0\.0\.0\.0|203\.0\.113\.[0-9]{1,3})([^0-9]|$)' || true)
  if grep -InE 'BEGIN (OPENSSH|RSA|EC) PRIVATE KEY' "$f" >/dev/null; then
    report "$f: private key header"
  fi
  if grep -InE 'SHA256:[0-9a-fA-F]{64}' "$f" >/dev/null; then
    report "$f: 64-hex fingerprint"
  fi
done

[ "$fail" -eq 0 ] && echo "no-secrets: clean (${#files[@]} files)"
exit "$fail"
