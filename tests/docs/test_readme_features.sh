#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
R="$HERE/../../README.md"

# Must NOT mention binhex or migration/legacy compat
if grep -qiE 'binhex|legacy|migrat' "$R"; then echo "FAIL: README mentions binhex/legacy/migration"; exit 1; fi

# Fork feature coverage
grep -q '0.16.20' "$R" || { echo "FAIL: rtorrent version"; exit 1; }
grep -q 'v5.3.11' "$R" || { echo "FAIL: rutorrent version"; exit 1; }
grep -qi 'Flood' "$R" || { echo "FAIL: Flood"; exit 1; }
grep -qi 'MaterialDesign' "$R" || { echo "FAIL: theme"; exit 1; }
grep -qiE 'bidirectional|newest-write-wins' "$R" || { echo "FAIL: sync feature"; exit 1; }
grep -q 'ENABLE_FLOOD' "$R" || { echo "FAIL: ENABLE_FLOOD var"; exit 1; }
grep -q 'RT_STATE_SAVE_SECONDS' "$R" || { echo "FAIL: state-save var"; exit 1; }
grep -q 'RT_PREALLOCATE_TYPE' "$R" || { echo "FAIL: prealloc var"; exit 1; }
grep -q 'ghcr.io/mountaser/rutorrent' "$R" || { echo "FAIL: GHCR image"; exit 1; }
grep -q '50000' "$R" || { echo "FAIL: incoming port"; exit 1; }
grep -q '3000' "$R" || { echo "FAIL: flood port"; exit 1; }
grep -qi 'event=stopped' "$R" || { echo "FAIL: graceful stop doc"; exit 1; }
grep -q 'docker stop' "$R" || { echo "FAIL: docker stop guidance"; exit 1; }
echo "PASS"
