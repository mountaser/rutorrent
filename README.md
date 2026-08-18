# rTorrent + ruTorrent + Flood Container

<p align="center">
  <a href="https://github.com/mountaser/rutorrent/pkgs/container/rutorrent">
    <img src="https://img.shields.io/badge/container-ghcr.io%2Fmountaser%2Frutorrent-blue?logo=docker" alt="GHCR Image">
  </a>
  <a href="https://github.com/mountaser/rutorrent/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/mountaser/rutorrent" alt="License">
  </a>
</p>

## About

A modern, high-performance **rTorrent** (`0.16.20`), **ruTorrent** (`v5.3.11`), and **Flood** UI container based on Alpine Linux with PHP 8.4 and Nginx. Designed for large sessions (600+ torrents) with bidirectional UI-to-config settings sync, crash-prevention caps, and instant WebUI response times.

---

## Key Features

* **Upgraded Engine & UIs:** rTorrent/libTorrent `0.16.20` paired with ruTorrent `v5.3.11` and an embedded modern **Flood** UI (port 3000).
* **MaterialDesign Default:** RuTorrent includes and defaults to the modern MaterialDesign theme.
* **Bidirectional Settings Sync:** Live WebUI setting changes and hand-edited `rtorrent.rc` configurations synchronize automatically via newest-write-wins arbitration. Dangerous `system.file.allocate` changes in UI are excluded from config write-back to protect storage performance.
* **Large-Session Tuning:** Optimized for 600+ active torrents with socket/preload tuning, `pieces.memory.max` caps, and capped curl/socket concurrency to eliminate tracker announce overload crashes (`EXIT=134 SIGABRT`).
* **Graceful Tracker Stop:** On container shutdown, rTorrent announces `event=stopped` to all trackers before exiting, preventing "seeding from multiple locations" warnings on private trackers.
* **Fast Boot & Instant WebUI:** External WAN IP lookups are cached on startup, PHP OPcache is optimized with zero revalidation, and ruTorrent plugin loading is cached for sub-second page loads.
* **RPC & Automation Ready:** Dedicated `/RPC2` endpoint with enlarged 300s SCGI timeouts prevents HTTP 502 gateway errors during heavy Sonarr/Radarr multicalls.
* **GeoIP2 Graceful Fallback:** Operates seamlessly with or without MaxMind account credentials.
* **Multi-Arch Builds:** Published directly to GitHub Container Registry (`ghcr.io/mountaser/rutorrent`) for `linux/amd64` and `linux/arm64`.
* **Unraid Community Template:** Includes a ready-to-import `rutorrent.xml` template configured with optimal defaults.

---

## Bidirectional Runtime Settings Sync

The container reconciles settings between `rtorrent.rc` and `.rtstate.rc` using a newest-write-wins policy:

1. **Boot Arbitration:** At startup, whichever configuration file has a newer modification time governs the session parameters.
2. **Periodic Snapshot:** Live UI edits to global throttles, peer limits, PEX/UDP options, and default download directories snapshot to `.rtstate.rc` every `RT_STATE_SAVE_SECONDS` (default: 10s) and propagate back into `rtorrent.rc`.
3. **Safety Exclusion:** `system.file.allocate` is read-only from UI state so disk allocation preferences in `rtorrent.rc` are never accidentally overwritten by ruTorrent.

> **IMPORTANT:** Always stop the container gracefully using `docker stop` (SIGTERM) rather than `docker kill` so rTorrent can send `event=stopped` announces to private trackers and cleanly flush state.

---

## Volume Overview

| **Volume** | **Description** |
| ---------- | --------------- |
| `/config` | Stores rTorrent, ruTorrent, Flood, and appdata files |
| `/data` | Main storage directory for downloads |
| `/passwd` | Holds `.htpasswd` files for basic authentication |

---

## Usage

### Docker Compose (Recommended)

```yaml
version: '3.8'
services:
  rutorrent:
    image: ghcr.io/mountaser/rutorrent:latest
    container_name: rutorrent
    environment:
      - PUID=99
      - PGID=100
      - TZ=UTC
      - ENABLE_FLOOD=yes
      - FLOOD_PORT=3000
      - RT_INC_PORT=50000
      - RT_PREALLOCATE_TYPE=0
      - RT_STATE_SAVE_SECONDS=10
      - WEBUI_USER=admin
      - WEBUI_PASS=admin
    ports:
      - "3000:3000"     # Flood UI
      - "9080:9080"     # ruTorrent WebUI
      - "5000:5000"     # SCGI / RPC (Sonarr / Radarr)
      - "50000:50000"   # BitTorrent Incoming Peer Port (TCP)
      - "6881:6881/udp" # DHT UDP Port
    volumes:
      - ./config:/config
      - ./data:/data
      - ./passwd:/passwd
    restart: unless-stopped
```

### Command Line

```bash
mkdir -p config data passwd

docker run -d --name rutorrent \
  -e PUID=99 \
  -e PGID=100 \
  -e TZ=UTC \
  -e ENABLE_FLOOD=yes \
  -e RT_INC_PORT=50000 \
  -e RT_PREALLOCATE_TYPE=0 \
  -p 3000:3000 \
  -p 9080:9080 \
  -p 5000:5000 \
  -p 50000:50000 \
  -p 6881:6881/udp \
  -v $(pwd)/config:/config \
  -v $(pwd)/data:/data \
  -v $(pwd)/passwd:/passwd \
  ghcr.io/mountaser/rutorrent:latest
```

### Unraid Installation

Copy `rutorrent.xml` into your Unraid flash drive templates directory (`/boot/config/plugins/dockerMan/templates-user/`) or add the repository directly in Community Applications. Ensure port `50000/tcp` is forwarded on your router for incoming connections.

---

## Environment Variables

### Application & UIs

| **Variable** | **Description** | **Default** |
| ------------ | --------------- | ----------- |
| `ENABLE_FLOOD` | Enable embedded Flood UI service (`yes`/`no`) | `yes` |
| `FLOOD_PORT` | Internal port for Flood UI | `3000` |
| `RUTORRENT_PORT` | Internal HTTP port for ruTorrent | `9080` |
| `WEBUI_USER` | ruTorrent & Flood WebUI Username | `admin` |
| `WEBUI_PASS` | ruTorrent & Flood WebUI Password | `admin` |
| `RPC2_USER` | RPC2 Username for Sonarr/Radarr | `admin` |
| `RPC2_PASS` | RPC2 Password for Sonarr/Radarr | `admin` |

### rTorrent & Engine

| **Variable** | **Description** | **Default** |
| ------------ | --------------- | ----------- |
| `RT_INC_PORT` | Single incoming BitTorrent peer port | `50000` |
| `RT_PREALLOCATE_TYPE` | File pre-allocation mode (`0` = Disabled, `1` = fallocate) | `0` |
| `RT_STATE_SAVE_SECONDS` | Interval in seconds to snapshot live UI state to disk | `10` |
| `RT_SESSION_SAVE_SECONDS` | Interval in seconds to snapshot torrent session files | `1200` |
| `RT_DHT_PORT` | DHT UDP port | `6881` |
| `RT_LOG_LEVEL` | rTorrent logging verbosity (`critical`, `error`, `warn`, `notice`, `info`, `debug`) | `info` |

---

## Ports Summary

| **Port** | **Protocol** | **Description** |
| -------- | ------------ | --------------- |
| `3000` | TCP | Flood Modern Web UI |
| `9080` | TCP | ruTorrent Web UI |
| `5000` | TCP | SCGI / RPC2 Endpoint for Sonarr & Radarr |
| `50000` | TCP | BitTorrent Incoming Peer Listening Port |
| `6881` | UDP | DHT Port |
| `9000` | TCP | WebDAV Port (optional for completed downloads) |

---

## Management & Customization

### WebDAV Access

WebDAV allows browsing completed downloads in `/data` on port `9000`. Authenticate by creating `/passwd/webdav.htpasswd`.

### Populating `.htpasswd` Files

Generate HTTP basic auth credentials using `htpasswd`:

```bash
docker run --rm -it httpd:2.4-alpine htpasswd -Bbn <username> <password> >> $(pwd)/passwd/webdav.htpasswd
```

Available password files in `/passwd`:
* `rpc.htpasswd` — RPC2 endpoint authentication
* `rutorrent.htpasswd` — ruTorrent WebUI authentication
* `webdav.htpasswd` — WebDAV completed downloads access

### Custom ruTorrent Plugins and Themes

To add or override a ruTorrent plugin or theme:
- Place custom plugins in `/config/rutorrent/plugins/`
- Place custom themes in `/config/rutorrent/themes/`

### Editing Plugin Configurations

Override ruTorrent plugin settings by creating custom PHP config files in `/config/rutorrent/plugins-conf/`. For example, create `/config/rutorrent/plugins-conf/diskspace.php`:

```php
<?php
$diskUpdateInterval = 10; // in seconds
$notifySpaceLimit = 512;  // in MB
```
