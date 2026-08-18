#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"

mk() { TMP=$(mktemp -d); RC="$TMP/rc"; ST="$TMP/st"; }

# Case A: state missing -> seed from RC (config wins)
mk
printf 'throttle.global_up.max_rate.set_kb = 5120\n' > "$RC"
"$SUT" arbitrate "$RC" "$ST"
grep -qx "throttle.global_up.max_rate.set_kb = 5120" "$ST" || { echo "FAIL A: not seeded"; exit 1; }

# Case B: RC newer than ST -> config wins (ST overwritten to match RC)
mk
printf 'throttle.global_up.max_rate.set_kb = 0\n' > "$ST"
printf '# header\nthrottle.global_up.max_rate.set_kb = 0\n' > "$ST"
sleep 1
printf 'throttle.global_up.max_rate.set_kb = 5120\n' > "$RC"   # RC now newest
"$SUT" arbitrate "$RC" "$ST"
grep -qx "throttle.global_up.max_rate.set_kb = 5120" "$ST" || { echo "FAIL B: config did not win"; exit 1; }

# Case C: ST newer than RC -> UI wins (RC updated), allocate excluded
mk
printf 'throttle.global_up.max_rate.set_kb = 5120\nsystem.file.allocate.set = 0\n' > "$RC"
sleep 1
printf '# header\nthrottle.global_up.max_rate.set_kb = 0\nsystem.file.allocate.set = 1\n' > "$ST"  # ST newest
"$SUT" arbitrate "$RC" "$ST"
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$RC" || { echo "FAIL C: UI did not win"; exit 1; }
grep -qx "system.file.allocate.set = 0" "$RC" || { echo "FAIL C: allocate wrongly changed"; exit 1; }
# converge: RC and ST agree on up rate
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$ST" || { echo "FAIL C: not converged"; exit 1; }
echo "PASS"
