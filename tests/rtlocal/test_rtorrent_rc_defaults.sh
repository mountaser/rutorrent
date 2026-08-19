#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/../../rootfs/etc/rtorrent/.rtorrent.rc"

grep -Eq '^[[:space:]]*throttle\.global_up\.max_rate\.set_kb = 5120' "$F" || { echo "FAIL: global_up not 5120"; exit 1; }
grep -Eq '^[[:space:]]*throttle\.global_down\.max_rate\.set_kb = 0' "$F" || { echo "FAIL: global_down not 0"; exit 1; }
grep -Eq '^[[:space:]]*throttle\.max_peers\.normal\.set = 150' "$F" || { echo "FAIL: max_peers.normal not 150"; exit 1; }
grep -Eq '^[[:space:]]*throttle\.max_peers\.seed\.set = 75' "$F" || { echo "FAIL: max_peers.seed not 75"; exit 1; }
grep -Eq '^[[:space:]]*throttle\.max_uploads\.set = 50' "$F" || { echo "FAIL: max_uploads not 50"; exit 1; }
grep -Eq '^[[:space:]]*dht\.mode\.set = disable' "$F" || { echo "FAIL: dht.mode.set not disable"; exit 1; }
grep -Eq '^[[:space:]]*protocol\.pex\.set = no' "$F" || { echo "FAIL: protocol.pex.set not no"; exit 1; }
grep -Eq '^[[:space:]]*trackers\.use_udp\.set = no' "$F" || { echo "FAIL: trackers.use_udp.set not no"; exit 1; }

echo "PASS"
