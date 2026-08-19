# Crash-Path Stopped-Announce Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a crash-path emergency tracker announce helper (`crash-stopped-announce.sh`) so that when rTorrent exits abnormally (SIGABRT/EXIT=134/255), s6's `finish` script sends an immediate `event=stopped` HTTP GET request for active torrents, clearing phantom tracker sessions and preventing private-tracker 401 "multiple locations" errors.

**Architecture:** `/etc/services.d/rtorrent/finish` passes exit code `$1` and signal `$2` to `/usr/local/bin/crash-stopped-announce.sh`. When an abnormal exit is detected, the script parses active session torrent files in `${CONFIG_PATH}/rtorrent/session/`, extracts their announce URLs and `info_hash`es, and sends asynchronous `event=stopped` HTTP GET requests via `curl` with a 2-second timeout before s6 restarts rTorrent.

**Tech Stack:** POSIX `sh`, Python 3 (built-in `bencode` decoder or regex bdecode), `curl`, `s6-overlay`.

## Global Constraints

- Must be POSIX-compliant shell (`sh`) and Python 3 standard library only.
- Must NEVER touch or mutate `session/` torrent state files.
- Must execute non-destructively within a 2-second total timeout on crash paths.
- Must pass all existing unit tests in `tests/run_all.sh`.

---

### Task 1: Create `crash-stopped-announce.sh` Helper Script

**Files:**
- Create: `rootfs/usr/local/bin/crash-stopped-announce.sh`
- Test: `tests/configsh/test_crash_stopped_announce.sh`

**Interfaces:**
- Consumes: `$1` (exit code), `$2` (signal), `CONFIG_PATH` (default `/config`), `RT_INC_PORT` (default `50000`).
- Produces: Sends `event=stopped` HTTP GET requests to active session trackers on non-zero exit codes.

- [ ] **Step 1: Write the failing unit test**

Create `tests/configsh/test_crash_stopped_announce.sh`:

```sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../rootfs/usr/local/bin/crash-stopped-announce.sh"

[ -x "$SCRIPT" ] || { echo "FAIL: crash-stopped-announce.sh is missing or not executable"; exit 1; }

# Test exit code 0: should do nothing (return 0)
sh "$SCRIPT" 0 0 >/dev/null || { echo "FAIL: script failed on clean exit code 0"; exit 1; }

echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/configsh/test_crash_stopped_announce.sh`
Expected: FAIL with "crash-stopped-announce.sh is missing or not executable"

- [ ] **Step 3: Write minimal `crash-stopped-announce.sh` implementation**

Create `rootfs/usr/local/bin/crash-stopped-announce.sh`:

```sh
#!/usr/bin/env sh
# Emergency tracker announce on abnormal rTorrent exit (crash-path).
# Sends event=stopped to trackers for active session torrents so private
# trackers do not flag "multiple locations" when rTorrent restarts after a crash.
set -eu

EXIT_CODE="${1:-0}"
SIGNAL_CODE="${2:-0}"

# If exit was clean (0 0), finish script handles normal shutdown via XMLRPC.
if [ "$EXIT_CODE" -eq 0 ] && [ "$SIGNAL_CODE" -eq 0 ]; then
  exit 0
fi

echo "  [+] Abnormal rTorrent exit detected (exit=$EXIT_CODE signal=$SIGNAL_CODE). Dispatching emergency event=stopped announces..."

CONFIG_DIR="${CONFIG_PATH:-/config}/rtorrent"
SESSION_DIR="${CONFIG_DIR}/session"
PORT="${RT_INC_PORT:-50000}"

if [ ! -d "$SESSION_DIR" ]; then
  exit 0
fi

# Run python helper to parse bencoded session torrents and fire event=stopped requests
python3 - "$SESSION_DIR" "$PORT" <<'PYTHON_EOF' 2>/dev/null || true
import sys, os, glob, urllib.parse, urllib.request

session_dir = sys.argv[1]
port = sys.argv[2]

def bdecode(data):
    def decode_func(src, idx):
        if src[idx:idx+1] == b'i':
            idx += 1
            end = src.index(b'e', idx)
            return int(src[idx:end]), end + 1
        elif src[idx:idx+1] == b'l':
            idx += 1
            res = []
            while src[idx:idx+1] != b'e':
                val, idx = decode_func(src, idx)
                res.append(val)
            return res, idx + 1
        elif src[idx:idx+1] == b'd':
            idx += 1
            res = {}
            while src[idx:idx+1] != b'e':
                key, idx = decode_func(src, idx)
                val, idx = decode_func(src, idx)
                res[key] = val
            return res, idx + 1
        elif src[idx:idx+1].isdigit():
            colon = src.index(b':', idx)
            length = int(src[idx:colon])
            start = colon + 1
            return src[start:start+length], start + length
        raise ValueError("Invalid bencode")
    val, _ = decode_func(data, 0)
    return val

torrent_files = glob.glob(os.path.join(session_dir, "*.torrent"))
for tf in torrent_files:
    try:
        with open(tf, 'rb') as f:
            meta = bdecode(f.read())
        
        announce = meta.get(b'announce', b'').decode('utf-8', 'ignore')
        if not announce or not announce.startswith(('http://', 'https://')):
            continue

        # Extract info_hash
        import hashlib
        with open(tf, 'rb') as f:
            raw = f.read()
        idx_info = raw.find(b'4:info')
        if idx_info == -1:
            continue
        info_val, _ = bdecode(raw[idx_info+6:])
        
        # Re-bencode info dictionary to compute SHA1 info_hash
        def bencode(obj):
            if isinstance(obj, int):
                return f"i{obj}e".encode('ascii')
            elif isinstance(obj, bytes):
                return f"{len(obj)}:".encode('ascii') + obj
            elif isinstance(obj, list):
                return b"l" + b"".join(bencode(x) for x in obj) + b"e"
            elif isinstance(obj, dict):
                return b"d" + b"".join(bencode(k) + bencode(v) for k, v in sorted(obj.items())) + b"e"
            raise ValueError()

        info_bytes = bencode(info_val)
        info_hash_bytes = hashlib.sha1(info_bytes).digest()
        quoted_hash = urllib.parse.quote_from_bytes(info_hash_bytes)

        # Construct emergency event=stopped announce URL
        sep = "&" if "?" in announce else "?"
        url = f"{announce}{sep}info_hash={quoted_hash}&peer_id=-RT0160-000000000000&port={port}&uploaded=0&downloaded=0&left=0&event=stopped"

        req = urllib.request.Request(url, headers={'User-Agent': 'rTorrent/0.16.20'})
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass
PYTHON_EOF

exit 0
```

Make `rootfs/usr/local/bin/crash-stopped-announce.sh` executable:
Run: `chmod +x rootfs/usr/local/bin/crash-stopped-announce.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/configsh/test_crash_stopped_announce.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add rootfs/usr/local/bin/crash-stopped-announce.sh tests/configsh/test_crash_stopped_announce.sh
git commit -m "feat(shutdown): add emergency crash-path stopped-announce helper"
```

---

### Task 2: Wire `crash-stopped-announce.sh` into `configurations.sh` s6 finish script

**Files:**
- Modify: `rootfs/etc/cont-init.d/configurations.sh:731-744`
- Test: `tests/configsh/test_graceful_stop.sh`

**Interfaces:**
- Consumes: `$1` (exit code) and `$2` (signal) passed from s6 supervisor to `/etc/services.d/rtorrent/finish`.
- Produces: `finish` script invokes `crash-stopped-announce.sh "$1" "$2"` on service completion.

- [ ] **Step 1: Check existing `test_graceful_stop.sh`**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/configsh/test_graceful_stop.sh`
Expected: PASS

- [ ] **Step 2: Update `configurations.sh` to wire `crash-stopped-announce.sh` in s6 finish**

In `rootfs/etc/cont-init.d/configurations.sh` around lines 731-744, update the generated `/etc/services.d/rtorrent/finish`:

```sh
cat > /etc/services.d/rtorrent/finish <<EOL
#!/bin/sh
# On service stop or crash, notify trackers so private trackers do not flag "multiple locations".
# $1 = exit code of run script, $2 = signal code (or 0)
EXIT_CODE="\${1:-0}"
SIGNAL_CODE="\${2:-0}"

# Run crash-path emergency announce helper if rTorrent exited abnormally
if [ "\${EXIT_CODE}" -ne 0 ] || [ "\${SIGNAL_CODE}" -ne 0 ]; then
  /usr/local/bin/crash-stopped-announce.sh "\${EXIT_CODE}" "\${SIGNAL_CODE}" || true
fi

# On graceful service stop (clean shutdown), ask rTorrent to shut down cleanly via XMLRPC
SOCK="/var/run/rtorrent/scgi.socket"
RPC_URL="http://127.0.0.1:${XMLRPC_HEALTH_PORT}"
if [ -S "\${SOCK}" ]; then
  curl -s --max-time 5 -H "Content-Type: text/xml" \
    --data '<?xml version="1.0"?><methodCall><methodName>system.shutdown</methodName><params></params></methodCall>' \
    "\${RPC_URL}" >/dev/null 2>&1 || true
  # give rtorrent a moment to flush stopped-announces
  i=0; while [ -S "\${SOCK}" ] && [ "$i" -lt 3 ]; do sleep 1; i=\$((i+1)); done
fi
EOL
```

- [ ] **Step 3: Update `tests/configsh/test_graceful_stop.sh`**

Add assertion to `tests/configsh/test_graceful_stop.sh`:

```sh
grep -q 'crash-stopped-announce.sh' "$F" || { echo "FAIL: crash-stopped-announce not wired in finish"; exit 1; }
```

- [ ] **Step 4: Run all unit tests**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/run_all.sh`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/cont-init.d/configurations.sh tests/configsh/test_graceful_stop.sh
git commit -m "feat(shutdown): wire crash-path stopped-announce into s6 rtorrent finish script"
```

---

### Task 3: Apply Live Fix to Container, Deploy to GitHub, and Document Follow-Up Task

**Files:**
- Modify: `README.md`
- Deploy: Push commit to `main` branch.
- Live: Copy `crash-stopped-announce.sh` and updated `/etc/services.d/rtorrent/finish` to running container via SSH.

**Interfaces:**
- Consumes: Git repository state.
- Produces: Live container updated, image built on GHCR `ghcr.io/mountaser/rutorrent:latest`.

- [ ] **Step 1: Run full test suite**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/run_all.sh`
Expected: ALL PASS (16 tests)

- [ ] **Step 2: Update README.md with crash-path stopped announce feature**

Add bullet in `README.md` under Key Features:
`* **Crash-Path Emergency Announce:** When rTorrent exits abnormally, s6's finish script invokes `crash-stopped-announce.sh` to send an emergency `event=stopped` HTTP announce for active session torrents, eliminating private tracker "401: multiple locations" errors.`

- [ ] **Step 3: Push commit to `main`**

```bash
git add README.md
git commit -m "docs: document crash-path emergency tracker announce feature"
git push origin main
```

- [ ] **Step 4: Copy live fix to running container via SSH**

Copy `crash-stopped-announce.sh` to `/usr/local/bin/crash-stopped-announce.sh` inside `binhex-rtorrentvpn` and update `/etc/services.d/rtorrent/finish` live on host `192.168.0.241`.

- [ ] **Step 5: Record Deferred Follow-Up Task**

Document follow-up task: **Measure minimum safe upload cap vs download speed after Force Update**.
