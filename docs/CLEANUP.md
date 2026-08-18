# AppData Cleanup Guide

Run this cleanup only while the container is **STOPPED**.

> **CRITICAL WARNING:** NEVER delete `rtorrent/session/` (or `.session/`). It contains all active torrent resume state, fast-resume data, and hash verification checkpoints for your seeding torrents.

## Safe Stale File Cleanup

Before running this cleanup script, ensure the container is completely stopped.

```bash
# Verify container is stopped before executing cleanup
if docker ps --format '{{.Names}}' | grep -q '^rutorrent$'; then
  echo "ERROR: rutorrent container is currently running! Stop it first with 'docker stop rutorrent'."
  exit 1
fi

APPDATA_DIR="/mnt/user/appdata/binhex-rtorrentvpn"

# Files and directories safe to remove from legacy appdata:
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
```

## Kept Directory Structure

The active image keeps and syncs:
- `rtorrent/session/` — active session state (NEVER delete)
- `config/rtorrent.rc` or `.rtorrent.rc` — user configuration
- `.rtstate.rc` — auto-generated live UI state mirror
- `log/` — active log files (`rtorrent.log`, `rtorrent-stderr.log`, `rtorrent-exit.log`)
- `watch/` — watch directories
- `.wan_ip_cache` — cached external IP
- `rutorrent/share/` — ruTorrent persistent user data
