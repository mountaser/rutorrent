#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"
TMP=$(mktemp -d)
LOG="$TMP/rtstate-sync.log"

RTSTATE_LOG_FILE="$LOG" "$SUT" __log "Test log entry"
[ -f "$LOG" ] || { echo "FAIL: log file not created"; exit 1; }
grep -q 'Test log entry' "$LOG" || { echo "FAIL: log content missing"; exit 1; }
echo "PASS"
