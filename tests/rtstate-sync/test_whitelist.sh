#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"

# whitelist must include the critical keys and exclude allocate from write-back kind
out=$("$SUT" __keys)
echo "$out" | grep -q '^throttle.global_up.max_rate.set_kb|throttle.global_up.max_rate|int$' || { echo "FAIL: up rate key"; exit 1; }
echo "$out" | grep -q '^pieces.hash.on_completion.set|pieces.hash.on_completion|bool$' || { echo "FAIL: hash key"; exit 1; }
echo "$out" | grep -q '^system.file.allocate.set|system.file.allocate|bool_readonly$' || { echo "FAIL: allocate must be bool_readonly"; exit 1; }

# validation
"$SUT" __validate int 5120 || { echo "FAIL: 5120 int"; exit 1; }
if "$SUT" __validate int "abc" 2>/dev/null; then echo "FAIL: abc not int"; exit 1; fi
"$SUT" __validate bool 1 || { echo "FAIL: bool 1"; exit 1; }
if "$SUT" __validate bool 2 2>/dev/null; then echo "FAIL: 2 not bool"; exit 1; fi
echo "PASS"
