#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../rootfs/usr/local/bin/crash-stopped-announce.sh"

[ -x "$SCRIPT" ] || { echo "FAIL: crash-stopped-announce.sh is missing or not executable"; exit 1; }

# Test exit code 0: should do nothing (return 0)
sh "$SCRIPT" 0 0 >/dev/null || { echo "FAIL: script failed on clean exit code 0"; exit 1; }

echo "PASS"
