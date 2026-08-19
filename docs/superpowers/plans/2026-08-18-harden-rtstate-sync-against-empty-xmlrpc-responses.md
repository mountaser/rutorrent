# Harden `rtstate-sync` Against Empty XMLRPC Responses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent `rtstate-sync.sh` from mistaking empty/failed XMLRPC responses for `0` (unlimited) and clobbering saved UI rate limits during rTorrent startup or heavy load.

**Architecture:** `_rt_get` returns exit code 1 if `val` is empty. `rtstate_snapshot` validates `[ -n "$raw" ]` before running POSIX arithmetic `$(( raw / 1024 ))`. If XMLRPC returns an empty string, `rtstate_snapshot` skips updating that key, preserving the existing value in `.rtstate.rc` and `rtorrent.rc`.

**Tech Stack:** POSIX sh, BusyBox arithmetic, curl XMLRPC over HTTP.

## Global Constraints

- Must be POSIX sh / BusyBox compatible.
- Empty or timed-out XMLRPC responses MUST NOT modify `.rtstate.rc` or `rtorrent.rc`.
- All unit tests in `tests/` must pass via `sh tests/run_all.sh`.

---

### Task 1: Protect `rtstate_snapshot` against empty XMLRPC responses and update tests

**Files:**
- Modify: `rootfs/usr/local/bin/rtstate-sync.sh:103-141`
- Modify: `tests/rtstate-sync/test_snapshot.sh`

**Interfaces:**
- Consumes: XMLRPC responses from `_rt_get`.
- Produces: a hardened `rtstate_snapshot` that aborts key update if `_rt_get` returns empty string or non-zero exit code.

- [ ] **Step 1: Write failing test case**

In `tests/rtstate-sync/test_snapshot.sh`, add a test case where `_rt_get` returns empty for a getter:

```sh
# Test empty XMLRPC response handling: rate must NOT be reset to 0
printf 'throttle.global_up.max_rate.set_kb = 7168\n' > "$RC"
cat > "$TMP/emptyget.sh" <<'EOF'
#!/bin/sh
# Simulate empty response (timed out / busy rtorrent)
exit 1
EOF
chmod +x "$TMP/emptyget.sh"

RTSTATE_GET_CMD="$TMP/emptyget.sh" "$SUT" snapshot "$RC" "$ST" /dev/null
# 7168 KiB rate MUST remain 7168 in RC and MUST NOT become 0
grep -qx "throttle.global_up.max_rate.set_kb = 7168" "$RC" || { echo "FAIL: empty response reset rate in RC"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtstate-sync/test_snapshot.sh`
Expected: FAIL ("empty response reset rate in RC").

- [ ] **Step 3: Update `_rt_get` and `rtstate_snapshot` in `rtstate-sync.sh`**

In `rootfs/usr/local/bin/rtstate-sync.sh`:
1. In `_rt_get`, return 1 if `val` is empty:
```sh
[ -n "$val" ] || return 1
```

2. In `rtstate_snapshot`:
```sh
raw=$(_rt_get "$getter" "$url" "$kind" || true)
[ -n "$raw" ] || continue
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtstate-sync/test_snapshot.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add rootfs/usr/local/bin/rtstate-sync.sh tests/rtstate-sync/test_snapshot.sh
git commit -m "fix(sync): harden rtstate_snapshot to ignore empty/failed XMLRPC queries"
```

---

### Task 2: Full test suite verification, Git push, and build monitoring

**Files:**
- Execute: `tests/run_all.sh`

- [ ] **Step 1: Run full test suite**

Run: `sh tests/run_all.sh`
Expected: `ALL PASS`.

- [ ] **Step 2: Push to GitHub**

Run: `git push origin main`
Expected: Successful push to `main` branch, triggering GitHub Actions build.
