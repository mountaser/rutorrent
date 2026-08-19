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

A modern, high-performance **rTorrent** (`0.16.20`), **ruTorrent** (`v5.3.11`), and **Flood** UI container built on Alpine Linux with PHP 8.4 and Nginx.

Engineered specifically for high-throughput, private-tracker workloads and large sessions (600+ torrents). It features bidirectional UI-to-config settings synchronization, high socket limits for gigabit connections, zero public-swarm leakage by default, and crash-resilient XMLRPC snapshot handling.

---

## Key Features & Architecture

* **Modern Engines & Web UIs:** rTorrent/libTorrent `0.16.20` paired with ruTorrent `v5.3.11` and an embedded modern **Flood** web interface (port 3000).
* **MaterialDesign Default:** ruTorrent defaults out-of-the-box to the polished MaterialDesign theme.
* **High-Throughput Performance Tuning:** Baked with 8,000 global open socket slots, 16,384 max open files, and a 4 GB memory mapping cap (`pieces.memory.max = 4G`) to fully saturate 1 Gbps+ networks without disk I/O bottlenecks.
* **Privacy & Private-Tracker First:** DHT and Peer Exchange (PEX) are disabled by default (`dht.mode.set = disable`, `protocol.pex.set = no`) to eliminate background protocol noise and prevent accidental public swarm traffic.
* **Bidirectional Settings Synchronization:** Live WebUI setting edits and manual `.rtorrent.rc` file edits synchronize automatically via newest-write-wins arbitration at boot and periodic background snapshots.
* **Hardened Atomic Snapshot Sync:** Settings snapshotting uses atomic temporary file writes, max-integer rate normalization, and XMLRPC sanitization to guarantee `.rtstate.rc` integrity.
* **Timestamped Sync & Audit Logging:** Live setting changes, arbitration decisions, and runtime rate updates write to `rtstate-sync.log` with microsecond-accurate timestamps for complete operational visibility.
* **Graceful & Crash-Path Tracker Shutdown:** On container termination or abnormal crash exit, rTorrent announces `event=stopped` to all trackers (via XMLRPC on clean exit and an emergency `crash-stopped-announce.sh` helper on crash exit), preventing "seeding from multiple locations" flags on private trackers. The shutdown supervisor caps wait time to 3s to guarantee clean container stops via `docker stop`.
* **Fast Boot & Sub-Second WebUI Response:** First-run file permission chown markers skip expensive disk walks on restart, WAN IP lookups are cached on startup, PHP OPcache is tuned for zero revalidation, and ruTorrent plugin loading is cached.
* **RPC & Automation Ready:** Dedicated `/RPC2` endpoint with enlarged 300s SCGI timeouts prevents gateway timeout errors during heavy Sonarr and Radarr multicalls.
* **Multi-Arch Support:** Multi-architecture builds published to GitHub Container Registry (`ghcr.io/mountaser/rutorrent`) for `linux/amd64` and `linux/arm64`.
* **Unraid Template:** Includes a ready-to-use `rutorrent.xml` template configured with optimal defaults.

---

## Default Configuration Summary

The container ships pre-tuned with the following default engine limits:

| **Setting** | **Default Value** | **Description & Rationale** |
| ----------- | ----------------- | --------------------------- |
| `throttle.global_up.max_rate.set_kb` | `5120` (5 MB/s) | Default upload rate cap to preserve network upload headroom |
| `throttle.global_down.max_rate.set_kb` | `0` (Unlimited) | Unlimited download throughput |
| `network.max_open_sockets.set` | `8000` | Global connection pool cap designed for high-concurrency downloads |
| `network.max_open_files.set` | `16384` | File descriptor cap accommodating large active sessions |
| `throttle.max_peers.normal.set` | `150` | Maximum peer connections per downloading torrent |
| `throttle.max_peers.seed.set` | `75` | Maximum peer connections per seeding torrent |
| `throttle.max_uploads.set` | `50` | Active upload slots per torrent to maximize reciprocal unchokes |
| `pieces.memory.max.set` | `4G` | Memory address space allocated for piece file chunk mapping |
| `dht.mode.set` | `disable` | DHT disabled by default for private tracker focus |
| `protocol.pex.set` | `no` | Peer Exchange disabled by default |
| `trackers.use_udp.set` | `no` | UDP trackers disabled by default |
| `system.file.allocate.set` | `0` | Sparsely allocated file creation (fallocate off) |
| `network.receive_buffer.size.set` | `16M` | Network socket receive buffer size |
| `network.send_buffer.size.set` | `16M` | Network socket send buffer size |

---

## Bidirectional Runtime Settings Sync

The container reconciles settings between `.rtorrent.rc` and `.rtstate.rc` using a newest-write-wins policy:

1. **Boot Arbitration:** At startup, whichever file has a newer modification timestamp governs the session parameters.
2. **Periodic Snapshot:** Live UI edits to global upload/download rates, peer limits, and download paths snapshot to `.rtstate.rc` every `RT_STATE_SAVE_SECONDS` (default: 10s) and propagate back into `.rtorrent.rc`.
3. **Safety Exclusions:** Critical infrastructure values like file allocation mode and system memory limits are excluded from WebUI overwrite to protect engine stability.

> **IMPORTANT:** Always stop the container gracefully using `docker stop` (SIGTERM) rather than `docker kill` so rTorrent can send `event=stopped` announces to private trackers and cleanly flush session state.

---

## Volume Overview

| **Volume** | **Description** |
| ---------- | --------------- |
| `/config` | Stores rTorrent configuration, session files, ruTorrent settings, and logs |
| `/data` | Main storage directory for media downloads |
| `/passwd` | Holds `.htpasswd` authentication files for WebUI and RPC access |

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
  -v $(pwd)/config:/config \
  -v $(pwd)/data:/data \
  -v $(pwd)/passwd:/passwd \
  ghcr.io/mountaser/rutorrent:latest
```

### Unraid Installation

Copy `rutorrent.xml` into your Unraid templates folder (`/boot/config/plugins/dockerMan/templates-user/`) or install via Community Applications. Ensure port `50000/tcp` is forwarded on your router for incoming connections.

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

### rTorrent Engine

| **Variable** | **Description** | **Default** |
| ------------ | --------------- | ----------- |
| `RT_INC_PORT` | Single incoming BitTorrent peer port (TCP) | `50000` |
| `RT_PREALLOCATE_TYPE` | File pre-allocation mode (`0` = Disabled, `1` = fallocate) | `0` |
| `RT_STATE_SAVE_SECONDS` | Interval in seconds to snapshot live UI state to disk | `10` |
| `RT_SESSION_SAVE_SECONDS` | Interval in seconds to snapshot torrent session files | `1200` |
| `RT_DHT_PORT` | DHT UDP port | `6881` |
| `RT_LOG_LEVEL` | rTorrent logging verbosity (`critical`, `error`, `warn`, `notice`, `info`, `debug`) | `info` |

---

## Ports Reference

| **Port** | **Protocol** | **Description** |
| -------- | ------------ | --------------- |
| `3000` | TCP | Flood Modern Web UI |
| `9080` | TCP | ruTorrent Web UI |
| `5000` | TCP | SCGI / RPC2 Endpoint for Sonarr & Radarr |
| `50000` | TCP | BitTorrent Incoming Peer Listening Port |
| `6881` | UDP | DHT Port (optional) |
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
