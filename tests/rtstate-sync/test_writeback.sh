#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"
TMP=$(mktemp -d)
RC="$TMP/rtorrent.rc"
printf '%s\n' "throttle.global_up.max_rate.set_kb = 5120" "protocol.pex.set = 1" > "$RC"

"$SUT" __set_rc "$RC" throttle.global_up.max_rate.set_kb 0
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$RC" || { echo "FAIL: not replaced"; exit 1; }
# unrelated line untouched
grep -qx "protocol.pex.set = 1" "$RC" || { echo "FAIL: pex clobbered"; exit 1; }
# absent key gets appended
"$SUT" __set_rc "$RC" throttle.max_uploads.global.set 15
grep -qx "throttle.max_uploads.global.set = 15" "$RC" || { echo "FAIL: not appended"; exit 1; }
# idempotent: run twice -> identical
cp "$RC" "$RC.a"; "$SUT" __set_rc "$RC" throttle.max_uploads.global.set 15
diff -q "$RC" "$RC.a" >/dev/null || { echo "FAIL: not idempotent"; exit 1; }
# no duplicate lines
[ "$(grep -c 'throttle.global_up.max_rate.set_kb' "$RC")" -eq 1 ] || { echo "FAIL: dup up-rate"; exit 1; }
echo "PASS"
