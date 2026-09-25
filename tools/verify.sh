#!/usr/bin/env bash
# Regenerate exercises/ and solutions/, then check that every exercise
# fails as shipped, every solution passes, and solutions are zig-fmt clean.
# Usage: tools/verify.sh [prefix]     e.g. tools/verify.sh 05
set -u
cd "$(dirname "$0")/.."
python3 tools/gen.py > /dev/null || exit 1
check() {
  f=$1
  if zig test "exercises/$f" > /dev/null 2>&1; then echo "BAD  exercise passes: $f"; return; fi
  if ! out=$(zig test "solutions/$f" 2>&1); then echo "BAD  solution fails: $f"; echo "$out" | tail -25 | sed 's/^/     /'; return; fi
  if ! zig fmt --check "solutions/$f" > /dev/null 2>&1; then echo "BAD  not zig fmt clean: $f"; return; fi
  echo "ok   $f"
}
export -f check
out=$(ls exercises | grep "^${1:-}" | xargs -P 8 -I{} bash -c 'check {}' | sort -k2)
echo "$out"
! grep -q "^BAD" <<< "$out"
