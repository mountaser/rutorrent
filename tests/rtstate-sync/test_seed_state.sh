#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"
TMP=$(mktemp -d); RC="$TMP/rc"; ST="$TMP/st"
cat > "$RC" <<EOF
throttle.global_up.max_rate.set_kb = 0
protocol.pex.set = 1
system.file.allocate.set = 0
EOF
"$SUT" __seed_state "$RC" "$ST"
head -n1 "$ST" | grep -q "Auto-generated" || { echo "FAIL: no header"; exit 1; }
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$ST" || { echo "FAIL: up rate not seeded"; exit 1; }
grep -qx "system.file.allocate.set = 0" "$ST" || { echo "FAIL: allocate mirror missing"; exit 1; }
# no temp file left behind
[ ! -f "$ST.tmp" ] || { echo "FAIL: temp left"; exit 1; }
echo "PASS"
