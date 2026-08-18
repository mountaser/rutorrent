#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0
for t in $(find "$HERE" -name 'test_*.sh' | sort); do
  printf '== %s\n' "$t"
  if sh "$t"; then :; else fail=1; fi
done
[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
