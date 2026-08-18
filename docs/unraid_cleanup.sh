#!/bin/sh
# Safe AppData Cleanup Script for Unraid
set -eu

# Target appdata directory (adjust if your folder name is different)
APPDATA_DIR="/mnt/user/appdata/binhex-rtorrentvpn"

echo "=== rTorrent AppData Cleanup Tool ==="

# 1. Verify directory exists
if [ ! -d "${APPDATA_DIR}" ]; then
  echo "Error: Directory ${APPDATA_DIR} does not exist!"
  echo "Usage: Set APPDATA_DIR in this script to your actual appdata path."
  exit 1
fi

# 2. Check and stop container if running
CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep -E '^(rutorrent|binhex-rtorrentvpn)$' | head -n1 || true)
if [ -n "${CONTAINER_NAME}" ]; then
  echo "[+] Stopping running container '${CONTAINER_NAME}'..."
  docker stop "${CONTAINER_NAME}"
fi

# 3. Safety Guard: Verify rtorrent/session directory is preserved
SESSION_DIR="${APPDATA_DIR}/rtorrent/session"
if [ -d "${SESSION_DIR}" ]; then
  echo "[+] Protected session directory detected (${SESSION_DIR}). Keeping intact."
else
  echo "[!] Warning: No rtorrent/session directory found at ${SESSION_DIR}."
fi

# 4. Remove stale legacy files and folders
echo "[+] Cleaning up stale legacy files and folders..."
rm -rf \
  "${APPDATA_DIR}/.session" \
  "${APPDATA_DIR}/logs" \
  "${APPDATA_DIR}/pyrocore" \
  "${APPDATA_DIR}/access.log"* \
  "${APPDATA_DIR}/supervisord.log" \
  "${APPDATA_DIR}/perms.txt" \
  "${APPDATA_DIR}/"*.sh \
  "${APPDATA_DIR}/"*.bak.* \
  "${APPDATA_DIR}/rutorrent/user-plugins" \
  "${APPDATA_DIR}/rutorrent/conf/access-swap.sh" \
  "${APPDATA_DIR}/rutorrent/access_no" \
  "${APPDATA_DIR}/rutorrent/access_yes" \
  "${APPDATA_DIR}/rutorrent/users"

# 5. Remove stale runtime state file so fresh defaults take effect
if [ -f "${APPDATA_DIR}/rtorrent/.rtstate.rc" ]; then
  echo "[+] Removing legacy .rtstate.rc to apply fresh config defaults..."
  rm -f "${APPDATA_DIR}/rtorrent/.rtstate.rc"
fi

# 6. Reset perms marker to force a clean initial ownership pass
if [ -f "${APPDATA_DIR}/rtorrent/.perms_initialized" ]; then
  echo "[+] Removing .perms_initialized marker to trigger clean ownership check..."
  rm -f "${APPDATA_DIR}/rtorrent/.perms_initialized"
fi

echo "=== Cleanup Complete! You can now start your updated container. ==="
