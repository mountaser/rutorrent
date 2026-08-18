# rTorrent ⇄ ruTorrent/Flood Sync, Stability & Fresh-Install Defaults — Design

**Date:** 2026-08-18
**Repo:** `mountaser/rutorrent` (fork of `k44sh/rutorrent`)
**Status:** Approved for implementation

---

## 1. Problem Statement

A production deployment (~590 torrents, Unraid, appdata reused from a deprecated
binhex image) exhibits four distinct, confirmed problems:

1. **UI ≠ config desync.** A hand-set `throttle.global_up.max_rate.set_kb = 5120`
   in `rtorrent.rc` never takes effect. The live `.rtstate.rc` (imported last)
   overrides it with `throttle.global_up.max_rate.set_kb = 0`.

2. **Speed regression after config edits.** The live `.rtstate.rc` also carries
   `system.file.allocate.set = 1`, silently re-enabling disk pre-allocation the
   operator had explicitly disabled — re-introducing HDD contention on the Unraid
   array.

3. **rTorrent crash-loop.** `rtorrent-exit.log` shows 35× `EXIT=134` (SIGABRT).
   stderr root cause:
   `terminate called after throwing 'torrent::internal_error' / what(): CurlGet::activate() error calling curl_multi_add_handle: Out of memory`.
   With ~590 torrents announcing simultaneously, curl's multi-handle stack aborts
   the process every ~32 minutes. Each crash reloads the session and collapses
   speeds. Two deprecated-option warnings also appear on boot
   (`dht.port.set`, `network.max_open_files.set`).

4. **Tracker "seeding from >3 locations" warnings on reboot.** Per the BitTorrent
   spec, trackers key a peer session on `peer_id` + `key` and expect
   `event=stopped` on graceful shutdown. rTorrent regenerates `peer_id`/`key` on
   each process start, and a SIGABRT crash never sends `event=stopped`. The
   crash-loop therefore manufactures multiple concurrent "locations" per announce
   interval, tripping private-tracker limits (PrivateHD, FileList, Blutopia,
   TorrentLeech).

### Root cause of the persistence mechanism (current design)

`rootfs/etc/rtorrent/.rtlocal.rc` ends with:

```
schedule = settings_snapshot, 10, @RT_STATE_SAVE_SECONDS@, ((execute.nothrow.bg, sh, -c, ... write .rtstate.rc ...)))
try_import = (cat,(cfg.basedir),".rtstate.rc")
```

`.rtstate.rc` is (a) written every `RT_STATE_SAVE_SECONDS` from live memory via a
backgrounded shell (race/truncation risk), and (b) imported **last**, so it
overrides the user's `rtorrent.rc` and image defaults unconditionally. It is
one-directional clobbering: UI state always wins, hand-edits are silently
reverted, and any bad value silently breaks the rest of the import
(`try_import` is non-fatal).

---

## 2. Goals

- **Bidirectional sync:** UI edits persist to the config file AND hand-edits to
  the config apply at runtime. Neither side silently clobbers the other.
- **Conflict rule:** newest-write-wins (compare file mtimes).
- **Broad scope:** all global rTorrent settings a user realistically changes in
  ruTorrent/Flood, including behavioral flags (e.g. hash-on-completion).
- **Safety:** `system.file.allocate` defaults OFF and can never be pushed from
  UI back into the config (prevents the pre-alloc footgun).
- **Stability:** eliminate the SIGABRT crash-loop; no torrents dropped.
- **Graceful shutdown:** send `event=stopped` to trackers on stop; stable
  `peer_id`/`key` across restarts.
- **Faster boot** for large (~590-torrent) sessions.
- **Fresh-install defaults:** every fix ships as the image default so a clean
  deploy is correct with zero manual tuning.
- **Single incoming port:** canonical `50000/tcp`.

## 3. Non-Goals / Boundaries

- **Per-torrent settings** (labels, priorities, per-torrent ratio rules) are NOT
  synced — they already persist in each torrent's session files.
- **ruTorrent plugin settings** (`share/settings/*.dat`) and **Flood UI prefs**
  (Flood DB) are NOT mirrored into `rtorrent.rc` — rTorrent's XMLRPC cannot read
  them; they already persist independently.
- **`protocol.encryption`** has no clean XMLRPC getter → config-authored only,
  not UI-synced.

---

## 4. Architecture

### 4.1 Three-layer config load order

```
rtorrent -o import=/etc/rtorrent/.rtlocal.rc
  ├─ layer 1: .rtlocal.rc            image defaults + crash-fixes + buffers
  ├─ layer 2: import rtorrent.rc     user-authored config = the synced file
  └─ layer 3: try_import .rtstate.rc  UI snapshot — applied only when arbitration says UI is newer
```

The user's `rtorrent.rc` is the synced file. `.rtstate.rc` is a mirror used for
UI→config propagation and is only imported when it is the most recent writer.

### 4.2 Boot arbitration (newest-write-wins)

Runs in `configurations.sh` before rtorrent starts. Let `SYNCED_KEYS` be the
whitelist (§4.4). Given `rtorrent.rc` (path `RC`) and `.rtstate.rc` (path `ST`):

```
if ST missing OR empty:
    regenerate ST from RC (seed UI mirror from config)   # config wins
elif mtime(RC) > mtime(ST):
    regenerate ST from RC                                 # config edited more recently → config wins
else:  # mtime(ST) >= mtime(RC)
    for each key in SYNCED_KEYS present in ST:
        write value back into RC (in-place line replace)  # UI edited more recently → UI wins
    # then regenerate ST from RC so both are byte-identical for synced keys
```

Result: after arbitration, `RC` and `ST` carry identical values for every synced
key. Neither side is silently lost; the most recent human/UI action is the one
that survives. A `.bak` of `RC` is kept before any write-back.

`system.file.allocate` is explicitly excluded from the ST→RC write-back branch:
its value may be read for display but is never propagated from UI into `RC`.

### 4.3 Runtime snapshot writer (hardened)

Replaces the current backgrounded-echo scheduler. Every `RT_STATE_SAVE_SECONDS`:

1. Read each synced key via its XMLRPC getter.
2. Validate each value (numeric or known enum). Skip invalid values — never
   write a partial/garbage line.
3. Write all lines to `${ST}.tmp`, then atomic `mv -f` to `ST`.
4. Propagate the same validated values into `RC` via in-place key replacement
   (excluding `system.file.allocate`), so UI changes reach the config file within
   `RT_STATE_SAVE_SECONDS`.

Atomic temp+rename guarantees `ST` is never observed truncated by `try_import`.

### 4.4 Sync whitelist (`SYNCED_KEYS`)

Global keys with reliable XMLRPC getters and setters:

| Config key (`.set_kb`/`.set`) | Getter | Notes |
| --- | --- | --- |
| `throttle.global_up.max_rate.set_kb` | `throttle.global_up.max_rate` | bytes → /1024 |
| `throttle.global_down.max_rate.set_kb` | `throttle.global_down.max_rate` | bytes → /1024 |
| `throttle.max_uploads.global.set` | `throttle.max_uploads.global` | |
| `throttle.max_downloads.global.set` | `throttle.max_downloads.global` | |
| `throttle.max_uploads.set` | `throttle.max_uploads` | per-torrent default |
| `throttle.max_peers.normal.set` | `throttle.max_peers.normal` | |
| `throttle.max_peers.seed.set` | `throttle.max_peers.seed` | |
| `throttle.min_peers.normal.set` | `throttle.min_peers.normal` | |
| `throttle.min_peers.seed.set` | `throttle.min_peers.seed` | |
| `protocol.pex.set` | `protocol.pex` | 0/1 |
| `trackers.use_udp.set` | `trackers.use_udp` | 0/1 |
| `dht.mode.set` | `dht.mode` | enum (disable/off/auto/on) — see note |
| `pieces.hash.on_completion.set` | `pieces.hash.on_completion` | 0/1 |
| `directory.default.set` | `directory.default` | string path |
| `network.receive_buffer.size.set` | `network.receive_buffer.size` | bytes |
| `network.send_buffer.size.set` | `network.send_buffer.size` | bytes |
| `system.file.allocate.set` | `system.file.allocate` | read-only mirror; **never** ST→RC |

Note: `dht.mode` getter returns a numeric enum; the snapshot maps it to the
string form for the `.set`. If mapping is unavailable in the running build, the
key is omitted from write-back (config-authored only) rather than risk a bad
value.

### 4.5 Crash-loop fix

In `.rtlocal.rc` defaults:

- `dht.port.set` → `dht.override_port.set` (0.16.20 rename).
- `network.max_open_files.set` → `system.sockets.files.min` (0.16.20 rename).
- `trackers.delay_scrape.set = yes` (already templated — ensure active).
- Cap concurrent DNS/HTTP tracker work and sockets for large sessions:
  - `network.max_open_sockets.set` reduced to a session-safe ceiling.
  - `network.http.max_open.set` bounded (limits simultaneous curl handles → the
    direct fix for `curl_multi_add_handle: Out of memory`).
- Tune `pieces.memory.max.set` appropriately for ~590 torrents.

None of these disable or drop torrents; they cap concurrency only.

### 4.6 Graceful shutdown & stable tracker identity

In the rtorrent s6 service run script (`/etc/services.d/rtorrent/run` generated
by `configurations.sh`):

- Trap `SIGTERM`; on receipt, issue rTorrent shutdown that sends
  `event=stopped` to all trackers before exit via an XMLRPC `system.shutdown`
  call. The image has **no** `xmlrpc2scgi` binary; the call is made with `curl`
  over the local no-auth XMLRPC health port (`127.0.0.1:${XMLRPC_HEALTH_PORT}`),
  the same transport the existing `healthcheck` uses. Then wait for the process
  to exit cleanly.
- Preserve session directory (already persisted) so `peer_id`/`key` are reused
  across restarts.
- Operational note (docs): stop via `docker stop` (SIGTERM), never `docker kill`.

### 4.7 Faster boot

- Trust fast-resume: do not force a startup re-hash; rely on
  `*.libtorrent_resume` session files.
- Guard per-boot maintenance sweeps in `configurations.sh` (`chown -R`, whole-file
  `sed` passes) behind first-run markers / changed-file checks so they do not run
  across the entire appdata on every restart.

### 4.8 Fresh-install defaults

- `RT_PREALLOCATE_TYPE` default `1` → `0`.
- `RT_INC_PORT` default `50000`; single incoming port, TCP.
- Default shipped upload rate: **unlimited (`0`)**.
- On first run (no existing `rtorrent.rc`/`.rtstate.rc`), seed both files with
  the synced-key defaults so a clean `/config` starts tuned and in-sync.

---

## 5. Binhex-Legacy Compatibility (must preserve)

The live appdata reuses a binhex layout. Existing `configurations.sh` logic that
MUST remain intact:

- Detect `session/` (no-dot) and rewrite `.session/` → `session/` (line ~335).
- Sanitize legacy `config/rtorrent.rc` (comment out duplicate `port_range`,
  `network.port_random.set`, `scgi_port`, etc.) to avoid double-bind aborts.
- Comment out `trackers.use_udp.set` in `.rtstate.rc` post-processing.

The new arbitration/write-back must operate on whichever `rtorrent.rc` the image
already imports (`config/rtorrent.rc` when present, else `.rtorrent.rc`).

---

## 6. Unraid Template Changes (operator-applied)

- Single incoming port: `50000/tcp` (operator removes the `51741` entry + router
  forward; forwards `50000/tcp`).
- `RT_LOG_LEVEL`: `debug` → `info`.
- Expose new tuning variables (state-save interval) with correct defaults.
- Pin to a fixed image tag after the fixed image is built/pushed.

---

## 7. Config-Folder Cleanup (operator-run, container stopped)

**KEEP (never delete):** `rtorrent/session/` (live session — ~590 torrents),
`rtorrent/config/rtorrent.rc`, `rtorrent/.rtorrent.rc`, `rtorrent/.rtstate.rc`,
`rtorrent/log/`, `rtorrent/watch/`, `rtorrent/.wan_ip_cache`,
`rutorrent/share/` (live UI settings), `rutorrent/conf/{config.php,plugins.ini,access.ini}`,
`flood/`, `geoip/`.

**DELETE (stale leftovers, no session impact):** `rtorrent/.session/` (empty),
`rtorrent/logs/` (2023), `pyrocore/`, root-level `nginx/`, `supervisord.log`,
`access.log*`, `perms.txt`, `apply-performance-fix.sh`,
`fix-rtorrent-fragmentation.sh`, all `*.bak.*`,
`rutorrent/conf/{access-swap.sh,access_no,access_yes,users/}`,
`rutorrent/user-plugins/`.

**Guard:** confirm container stopped; never touch `session/`; delete
`session/rtorrent.lock` only while stopped.

---

## 8. Testing Strategy

- **Arbitration unit tests** (shell, using fixture temp dirs): config-newer,
  state-newer, state-missing, state-empty cases → assert `RC` and `ST` converge
  for synced keys; assert `system.file.allocate` never propagates ST→RC.
- **Snapshot validation tests:** feed malformed getter output → assert bad lines
  skipped, `ST` never truncated, `RC` unchanged for invalid keys.
- **Line-replace idempotency:** running write-back twice yields identical files.
- **Crash-fix verification:** boot against a copy of the live session; assert zero
  `EXIT=134` in `rtorrent-exit.log` over 1h and no `curl_multi_add_handle` in
  stderr; assert no deprecated-option warnings.
- **Graceful-stop verification:** `docker stop` → assert an `event=stopped`
  announce is emitted (log inspection) before exit.
- **Fresh-install test:** empty `/config` → assert seeded `rtorrent.rc`/`.rtstate.rc`
  with unlimited upload, allocate off, port 50000, and a clean single-port bind.

---

## 9. Limitations (accepted)

- Sub-second simultaneous same-key edits reconcile at file-mtime (second)
  granularity.
- ruTorrent-plugin / Flood settings are not mirrored into `rtorrent.rc`.
- Write-back normalizes formatting of whitelisted key lines in `rtorrent.rc`
  (`.bak` retained).
- If the container is restarted faster than a tracker's announce interval, the
  tracker's own ghost-peer timeout may briefly show a duplicate until it expires;
  graceful-stop minimizes but cannot eliminate this. `docker kill` bypasses
  graceful-stop.

---

## 10. Files Touched (image)

- `rootfs/etc/rtorrent/.rtlocal.rc` — load order, hardened snapshot, crash-fix
  opts, buffers, defaults.
- `rootfs/etc/cont-init.d/configurations.sh` — boot arbitration, write-back,
  deprecated-opt sanitization, boot-speed guards, graceful-stop service script,
  default `RT_PREALLOCATE_TYPE=0`, `RT_INC_PORT=50000`, fresh-install seeding.
- `rutorrent.xml` — pre-alloc default off, single port, documented sync.
- `README.md` — document sync behavior, boundaries, cleanup, `docker stop` note.
