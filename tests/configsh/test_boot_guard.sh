#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/../../rootfs/etc/cont-init.d/configurations.sh"
grep -q '.perms_initialized' "$F" || { echo "FAIL: no first-run perms marker"; exit 1; }
echo "PASS"
