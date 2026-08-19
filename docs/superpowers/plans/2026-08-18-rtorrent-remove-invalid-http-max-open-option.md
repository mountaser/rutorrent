# Remove Invalid `network.http.max_open.set` Option Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the rTorrent 0.16.20 startup crash (`EXIT=255`) caused by invalid command `network.http.max_open.set` on line 38 of `.rtlocal.rc`.

**Architecture:** Remove `network.http.max_open.set = 32` from `rootfs/etc/rtorrent/.rtlocal.rc` and update the shape test in `tests/rtlocal/test_rtlocal_shape.sh`.

**Tech Stack:** POSIX sh, rTorrent 0.16.20 `.rc` syntax.

## Global Constraints

- Shell scripts use POSIX sh / BusyBox (`/bin/sh`).
- rTorrent 0.16.20 `.rc` syntax must not contain invalid getters or setters.
- Tests in `tests/` must all pass via `sh tests/run_all.sh`.

---

### Task 1: Remove invalid `network.http.max_open.set` option from `.rtlocal.rc` and update tests

**Files:**
- Modify: `rootfs/etc/rtorrent/.rtlocal.rc:38`
- Modify: `tests/rtlocal/test_rtlocal_shape.sh`

**Interfaces:**
- Produces: an `.rtlocal.rc` that rTorrent 0.16.20 parses without any syntax errors on startup.

- [ ] **Step 1: Write the failing test assertion**

In `tests/rtlocal/test_rtlocal_shape.sh`:

```sh
if grep -Eq '^[[:space:]]*network\.http\.max_open\.set' "$F"; then echo "FAIL: invalid network.http.max_open.set present"; exit 1; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtlocal/test_rtlocal_shape.sh`
Expected: FAIL ("invalid network.http.max_open.set present").

- [ ] **Step 3: Remove line from `.rtlocal.rc`**

In `rootfs/etc/rtorrent/.rtlocal.rc`, remove line 38 (`network.http.max_open.set = 32`).

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtlocal/test_rtlocal_shape.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/rtorrent/.rtlocal.rc tests/rtlocal/test_rtlocal_shape.sh
git commit -m "fix(rtorrent): remove invalid network.http.max_open.set option for 0.16.20"
```

---

### Task 2: Run full test suite, commit, push, and monitor build

**Files:**
- Execute: `tests/run_all.sh`

- [ ] **Step 1: Run full test suite**

Run: `sh tests/run_all.sh`
Expected: `ALL PASS`.

- [ ] **Step 2: Push commits to GitHub**

Run: `git push origin main`
Expected: Successful push to `main` branch, triggering GitHub Actions build.
