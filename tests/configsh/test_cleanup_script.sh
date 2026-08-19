#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../scripts/cleanup-legacy-config.sh"
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'cleanup_test')

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Setup fake appdata structure
mkdir -p "$TMP_DIR/config" "$TMP_DIR/logs" "$TMP_DIR/session"
touch "$TMP_DIR/config/rtorrent.rc"
touch "$TMP_DIR/config/rtorrent.rc.bak.12345"
touch "$TMP_DIR/.rtorrent.rc"
touch "$TMP_DIR/.rtstate.rc"
touch "$TMP_DIR/session/rtorrent.lock"
touch "$TMP_DIR/session/test.torrent"

# Run cleanup
sh "$SCRIPT" "$TMP_DIR" >/dev/null

# Assertions
if [ -f "$TMP_DIR/config/rtorrent.rc" ]; then echo "FAIL: config/rtorrent.rc not removed"; exit 1; fi
if [ -f "$TMP_DIR/config/rtorrent.rc.bak.12345" ]; then echo "FAIL: config/rtorrent.rc.bak.12345 not removed"; exit 1; fi
if [ -d "$TMP_DIR/config" ]; then echo "FAIL: empty config/ dir not removed"; exit 1; fi
if [ -d "$TMP_DIR/logs" ]; then echo "FAIL: empty logs/ dir not removed"; exit 1; fi
if [ -f "$TMP_DIR/session/rtorrent.lock" ]; then echo "FAIL: stale rtorrent.lock not removed"; exit 1; fi
if [ ! -f "$TMP_DIR/session/test.torrent" ]; then echo "FAIL: session/test.torrent was deleted!"; exit 1; fi

echo "PASS"
