#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/../../rootfs/etc/cont-init.d/configurations.sh"
grep -Eq 'RT_PREALLOCATE_TYPE=\$\{RT_PREALLOCATE_TYPE:-0\}' "$F" || { echo "FAIL: prealloc default not 0"; exit 1; }
grep -Eq 'RT_INC_PORT=\$\{RT_INC_PORT:-50000\}' "$F" || { echo "FAIL: inc port default not 50000"; exit 1; }
grep -q 'RC_BASENAME' "$F" || { echo "FAIL: RC_BASENAME not resolved"; exit 1; }
grep -q 'chmod +x /usr/local/bin/rtstate-sync.sh' "$F" || { echo "FAIL: rtstate-sync.sh chmod +x missing in configurations.sh"; exit 1; }
grep -q 'rtstate-sync.sh arbitrate' "$F" || { echo "FAIL: arbitration not wired"; exit 1; }
echo "PASS"
