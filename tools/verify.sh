#!/usr/bin/env bash
# Regenerate exercises/, hard/ and solutions/, then check that every
# exercise fails as shipped (in both versions), every solution passes, and
# solutions are zig-fmt clean.
# Exercises that need extra `zig test` flags say so in a line
# `// zig test flags: ...` (the GPU exercises link libc: -lc).
# Usage: tools/verify.sh [prefix]     e.g. tools/verify.sh 05
set -u
cd "$(dirname "$0")/.."
python3 tools/gen.py > /dev/null || exit 1
check() {
  f=$1
  flags=$(sed -n 's#^// zig test flags: ##p' "solutions/$f" | head -1)
  # shellcheck disable=SC2086
  if zig test $flags "exercises/$f" > /dev/null 2>&1; then echo "BAD  exercise passes: $f"; return; fi
  # shellcheck disable=SC2086
  if zig test $flags "hard/$f" > /dev/null 2>&1; then echo "BAD  hard exercise passes: $f"; return; fi
  # shellcheck disable=SC2086
  if ! out=$(zig test $flags "solutions/$f" 2>&1); then echo "BAD  solution fails: $f"; echo "$out" | tail -25 | sed 's/^/     /'; return; fi
  if ! zig fmt --check "solutions/$f" > /dev/null 2>&1; then echo "BAD  not zig fmt clean: $f"; return; fi
  echo "ok   $f"
}
export -f check
out=$(ls exercises | grep "^${1:-}" | xargs -P 8 -I{} bash -c 'check {}' | sort -k2)
echo "$out"
! grep -q "^BAD" <<< "$out"
