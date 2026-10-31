#!/usr/bin/env bash
# Runs tests/no-secrets.sh against throwaway git repos. Fixtures are built at
# runtime so this file holds no literal the real scan would flag.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/no-secrets.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dot=.
ip() { local IFS=$dot; echo "$*"; }
lo=$(ip 127 0 0 1)
any=$(ip 0 0 0 0)
doc=$(ip 203 0 113 5)
priv=$(ip 10 1 2 3)
pub=$(ip 8 8 8 8)
other=$(ip 198 51 100 7)

failures=0
check() { # name, expected exit, content
  local name=$1 want=$2 content=$3 repo="$tmp/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '%s\n' "$content" >"$repo/fixture.txt"
  git -C "$repo" add fixture.txt
  NO_SECRETS_ROOT="$repo" bash "$script" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then echo "ok   $name"; else echo "FAIL $name: want $want got $got"; failures=$((failures + 1)); fi
}

check loopback-then-private 1 "$lo $priv"
check any-then-public 1 "$any,$pub"
check doc-then-other 1 "$doc $other"
check lone-private 1 "host $priv here"
check key-header 1 "-----BEGIN ""OPENSSH PRIVATE KEY-----"
check fingerprint 1 "SHA256:$(printf '%064d' 0)"
check only-allowed 0 "$lo $any $doc"

[ "$failures" -eq 0 ]
