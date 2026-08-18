#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../.."
# Template: prealloc default off
grep -Eq 'RT_PREALLOCATE_TYPE.*Default="0"' "$ROOT/rutorrent.xml" || { echo "FAIL: template prealloc default not 0"; exit 1; }
# Cleanup guide
[ -f "$ROOT/docs/CLEANUP.md" ] || { echo "FAIL: CLEANUP.md missing"; exit 1; }
grep -q 'rtorrent/session/' "$ROOT/docs/CLEANUP.md" || { echo "FAIL: cleanup missing session keep"; exit 1; }
grep -qi 'never delete' "$ROOT/docs/CLEANUP.md" || { echo "FAIL: cleanup missing session warning"; exit 1; }
grep -qi 'stopped' "$ROOT/docs/CLEANUP.md" || { echo "FAIL: cleanup missing container-stopped guard"; exit 1; }
echo "PASS"
