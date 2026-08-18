# rTorrent Socket Option Fix & Shutdown Finish Timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the rTorrent 0.16.20 startup crash (`EXIT=255` caused by invalid `system.sockets.files.min.set`) by reverting to `network.max_open_files.set`, and fix s6 `finish` script SIGKILL warnings by reducing the stop wait loop to under 5 seconds.

**Architecture:** `.rtlocal.rc` option line 36 is restored to `network.max_open_files.set = 8192`. The generated `/etc/services.d/rtorrent/finish` script wait loop in `configurations.sh` is capped at 3 seconds (`$i -lt 3`) to stay under s6's 5s execution limit.

**Tech Stack:** POSIX sh, rTorrent 0.16.20 `.rc` syntax, s6-overlay service finish script.

## Global Constraints

- Shell scripts use POSIX sh / BusyBox (`/bin/sh`).
- rTorrent 0.16.20 `.rc` syntax must not contain invalid getters or setters.
- Tests in `tests/` must all pass via `sh tests/run_all.sh`.

---

### Task 1: Revert `system.sockets.files.min.set` to `network.max_open_files.set`

**Files:**
- Modify: `rootfs/etc/rtorrent/.rtlocal.rc:36`
- Modify: `tests/rtlocal/test_rtlocal_shape.sh`

**Interfaces:**
- Produces: an `.rtlocal.rc` that rTorrent 0.16.20 parses without throwing `input_errorE` on startup.

- [ ] **Step 1: Write the failing test assertion**

In `tests/rtlocal/test_rtlocal_shape.sh`:

```sh
# network.max_open_files.set must be present for 0.16.20
grep -Eq '^[[:space:]]*network\.max_open_files\.set' "$F" || { echo "FAIL: missing network.max_open_files.set"; exit 1; }
if grep -Eq '^[[:space:]]*system\.sockets\.files\.min\.set' "$F"; then echo "FAIL: invalid system.sockets.files.min.set present"; exit 1; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtlocal/test_rtlocal_shape.sh`
Expected: FAIL ("invalid system.sockets.files.min.set present").

- [ ] **Step 3: Update `.rtlocal.rc`**

In `rootfs/etc/rtorrent/.rtlocal.rc`, change line 36:
`system.sockets.files.min.set = 8192` -> `network.max_open_files.set = 8192`

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtlocal/test_rtlocal_shape.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/rtorrent/.rtlocal.rc tests/rtlocal/test_rtlocal_shape.sh
git commit -m "fix(rtorrent): use network.max_open_files.set for 0.16.20 compatibility"
```

---

### Task 2: Cap `finish` script wait loop to 3 seconds to avoid s6 SIGKILL warnings

**Files:**
- Modify: `rootfs/etc/cont-init.d/configurations.sh:725`
- Modify: `tests/configsh/test_graceful_stop.sh`

**Interfaces:**
- Produces: `/etc/services.d/rtorrent/finish` wait loop that finishes in < 3s, under s6's 5s timeout.

- [ ] **Step 1: Write the failing test assertion**

In `tests/configsh/test_graceful_stop.sh`:

```sh
grep -q '"\$i" -lt 3' "$F" || { echo "FAIL: finish script loop timeout not capped at 3s"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/configsh/test_graceful_stop.sh`
Expected: FAIL ("finish script loop timeout not capped at 3s").

- [ ] **Step 3: Update `configurations.sh`**

In `rootfs/etc/cont-init.d/configurations.sh` line 725:
`i=0; while [ -S "\${SOCK}" ] && [ "\$i" -lt 10 ]; do sleep 1; i=\$((i+1)); done`
-> `i=0; while [ -S "\${SOCK}" ] && [ "\$i" -lt 3 ]; do sleep 1; i=\$((i+1)); done`

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/configsh/test_graceful_stop.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/cont-init.d/configurations.sh tests/configsh/test_graceful_stop.sh
git commit -m "fix(shutdown): cap finish script wait loop at 3s to prevent s6 SIGKILL warning"
```

---

### Task 3: Full test suite verification, git push, and GitHub build trigger

**Files:**
- Execute: `tests/run_all.sh`

- [ ] **Step 1: Run full test suite**

Run: `sh tests/run_all.sh`
Expected: `ALL PASS`.

- [ ] **Step 2: Push commits to GitHub**

Run: `git push origin main`
Expected: Successful push to `main` branch, triggering GitHub Actions.
