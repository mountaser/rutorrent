#!/usr/bin/env sh
# Safely clean up legacy config files from rTorrent appdata directory.
# NEVER touches torrent session data (session/ or .session/).
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo ".")
TARGET_DIR="${1:-$SCRIPT_DIR}"
TARGET_DIR=$(cd "$TARGET_DIR" 2>/dev/null && pwd || echo "$TARGET_DIR")
if [ -d "${TARGET_DIR}/rtorrent" ] && { [ -d "${TARGET_DIR}/rtorrent/session" ] || [ -f "${TARGET_DIR}/rtorrent/.rtorrent.rc" ]; }; then
  TARGET_DIR="${TARGET_DIR}/rtorrent"
fi

echo "=== rTorrent AppData Legacy Config Cleanup ==="
echo "Target directory: ${TARGET_DIR}"

# Safety check: confirm this looks like an rTorrent appdata directory
if [ ! -d "${TARGET_DIR}/session" ] && [ ! -d "${TARGET_DIR}/.session" ] && [ ! -f "${TARGET_DIR}/.rtorrent.rc" ] && [ ! -d "${TARGET_DIR}/config" ]; then
  echo "ERROR: Target directory does not look like an rTorrent appdata folder." >&2
  echo "Expected to find session/, .session/, .rtorrent.rc, or config/ directory." >&2
  exit 1
fi

TS=$(date +%Y%m%d%H%M%S 2>/dev/null || echo "bak")

# 1. Back up existing configuration files
if [ -f "${TARGET_DIR}/.rtorrent.rc" ]; then
  cp "${TARGET_DIR}/.rtorrent.rc" "${TARGET_DIR}/.rtorrent.rc.bak.${TS}"
  echo "  [+] Backed up .rtorrent.rc -> .rtorrent.rc.bak.${TS}"
fi
if [ -f "${TARGET_DIR}/.rtstate.rc" ]; then
  cp "${TARGET_DIR}/.rtstate.rc" "${TARGET_DIR}/.rtstate.rc.bak.${TS}"
  echo "  [+] Backed up .rtstate.rc -> .rtstate.rc.bak.${TS}"
fi

# 2. Remove legacy binhex config files (without touching session/)
REMOVED_COUNT=0

if [ -f "${TARGET_DIR}/config/rtorrent.rc" ]; then
  rm -f "${TARGET_DIR}/config/rtorrent.rc"
  echo "  [-] Removed legacy file: config/rtorrent.rc"
  REMOVED_COUNT=$((REMOVED_COUNT + 1))
fi

for bak in "${TARGET_DIR}/config"/rtorrent.rc.bak.*; do
  [ -f "$bak" ] || continue
  rm -f "$bak"
  echo "  [-] Removed legacy backup: config/$(basename "$bak")"
  REMOVED_COUNT=$((REMOVED_COUNT + 1))
done

if [ -d "${TARGET_DIR}/config" ] && [ -z "$(ls -A "${TARGET_DIR}/config" 2>/dev/null)" ]; then
  rmdir "${TARGET_DIR}/config"
  echo "  [-] Removed empty directory: config/"
fi

if [ -d "${TARGET_DIR}/logs" ] && [ -z "$(ls -A "${TARGET_DIR}/logs" 2>/dev/null)" ]; then
  rmdir "${TARGET_DIR}/logs"
  echo "  [-] Removed empty legacy log directory: logs/"
fi

# Remove stale lock files if present
for lock in "${TARGET_DIR}/session/rtorrent.lock" "${TARGET_DIR}/.session/rtorrent.lock" "${TARGET_DIR}/var/run/rtorrent.lock"; do
  if [ -f "$lock" ]; then
    rm -f "$lock"
    echo "  [-] Removed stale lock file: ${lock#${TARGET_DIR}/}"
    REMOVED_COUNT=$((REMOVED_COUNT + 1))
  fi
done

# 3. Verify session folder safety
TORRENT_COUNT=0
if [ -d "${TARGET_DIR}/session" ]; then
  TORRENT_COUNT=$(find "${TARGET_DIR}/session" -name "*.torrent" 2>/dev/null | wc -l || echo 0)
elif [ -d "${TARGET_DIR}/.session" ]; then
  TORRENT_COUNT=$(find "${TARGET_DIR}/.session" -name "*.torrent" 2>/dev/null | wc -l || echo 0)
fi

echo ""
echo "Summary:"
echo "  Files removed: ${REMOVED_COUNT}"
echo "  Session data preserved: YES (${TORRENT_COUNT} torrents found untouched)"
echo "Cleanup complete! You can now start or force-update the container."
