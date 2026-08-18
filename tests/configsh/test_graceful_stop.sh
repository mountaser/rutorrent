#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/../../rootfs/etc/cont-init.d/configurations.sh"
# The generated rtorrent run must set up a graceful stop path.
grep -q 'services.d/rtorrent/finish' "$F" || { echo "FAIL: no finish script for graceful stop"; exit 1; }
grep -q 'system.shutdown' "$F" || { echo "FAIL: no graceful shutdown call"; exit 1; }
grep -q '\\$i" -lt 3' "$F" || { echo "FAIL: finish script loop timeout not capped at 3s"; exit 1; }
if grep -q 'xmlrpc2scgi' "$F"; then echo "FAIL: references nonexistent xmlrpc2scgi"; exit 1; fi
echo "PASS"
