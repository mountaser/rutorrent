#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"
TMP=$(mktemp -d); RC="$TMP/rc"; ST="$TMP/st"
printf '%s\n' "throttle.global_up.max_rate.set_kb = 5120" > "$RC"
cat > "$ST" <<EOF
# Auto-generated runtime settings state
throttle.global_up.max_rate.set_kb = 0
protocol.pex.set = 1
system.file.allocate.set = 1
throttle.max_peers.normal.set = notanumber
EOF
"$SUT" __apply_state "$RC" "$ST"
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$RC" || { echo "FAIL: up rate not applied"; exit 1; }
grep -qx "protocol.pex.set = 1" "$RC" || { echo "FAIL: pex not applied"; exit 1; }
# allocate must NOT be written into RC
if grep -q "system.file.allocate.set" "$RC"; then echo "FAIL: allocate leaked into RC"; exit 1; fi
# invalid value skipped
if grep -q "throttle.max_peers.normal.set" "$RC"; then echo "FAIL: invalid peer value written"; exit 1; fi
echo "PASS"
