#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/../../rootfs/etc/rtorrent/.rtlocal.rc"

# network.max_open_files.set must be present for 0.16.20
grep -Eq '^[[:space:]]*network\.max_open_files\.set' "$F" || { echo "FAIL: missing network.max_open_files.set"; exit 1; }
if grep -Eq '^[[:space:]]*system\.sockets\.files\.min\.set' "$F"; then echo "FAIL: invalid system.sockets.files.min.set present"; exit 1; fi
# curl concurrency cap present
grep -Eq '^[[:space:]]*network\.http\.max_open\.set' "$F" || { echo "FAIL: missing http.max_open cap"; exit 1; }
# snapshot uses helper, not inline echo blocks
if grep -q 'Auto-generated runtime settings state' "$F"; then echo "FAIL: inline snapshot still present"; exit 1; fi
grep -q 'rtstate-sync.sh' "$F" || { echo "FAIL: helper not called"; exit 1; }
grep -q 'settings_snapshot' "$F" || { echo "FAIL: schedule missing"; exit 1; }
# snapshot must use the HTTP health port, not a scgi binary
grep -q 'XMLRPC_HEALTH_PORT' "$F" || { echo "FAIL: snapshot not using health RPC port"; exit 1; }
if grep -q 'xmlrpc2scgi' "$F"; then echo "FAIL: references nonexistent xmlrpc2scgi"; exit 1; fi
# state still imported last
grep -Eq 'try_import = \(cat,\(cfg.basedir\),".rtstate.rc"\)' "$F" || { echo "FAIL: try_import missing"; exit 1; }
if grep -Eq '^[[:space:]]*dht\.port\.set' "$F"; then echo "FAIL: deprecated dht.port.set present"; exit 1; fi
grep -Eq '^[[:space:]]*dht\.override_port\.set' "$F" || { echo "FAIL: dht.override_port.set missing"; exit 1; }
echo "PASS"
