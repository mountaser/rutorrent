# rTorrent Sync, Stability & Fresh-Install Defaults — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rTorrent config and the ruTorrent/Flood UI stay bidirectionally in sync (newest-write-wins), stop the SIGABRT crash-loop, cut boot time for large sessions, eliminate tracker "multiple locations" warnings, and ship all of it as the default for fresh installs.

**Architecture:** A dedicated POSIX-sh helper (`rtstate-sync.sh`) owns all read/validate/write logic for a whitelist of global rTorrent settings. `configurations.sh` calls it once at boot to arbitrate between `rtorrent.rc` and `.rtstate.rc` by file mtime. A hardened rTorrent `schedule` calls the same helper periodically to snapshot live state and write it back into `rtorrent.rc`. The rtorrent s6 service traps SIGTERM for a graceful tracker `stopped` announce. Deprecated 0.16.20 options and concurrency caps fix the crash-loop.

**Tech Stack:** POSIX sh (Alpine BusyBox), rTorrent 0.16.20 `.rc` scripting, XMLRPC-over-HTTP via `curl` against the local no-auth health port (no `xmlrpc2scgi` binary exists in the image), s6-overlay service scripts, Docker/Unraid.

## Global Constraints

- Shell is Alpine BusyBox `sh` (`#!/usr/bin/with-contenv sh`). No bashisms (no arrays, no `[[ ]]` in helper scripts, no `mapfile`). Use `case`, `grep -E`, `sed -E`, `awk`.
- All generated config files MUST be LF-only (repo enforces via `.gitattributes`; `configurations.sh` also runs `tr -d '\r'`).
- rTorrent version is **0.16.20**: `dht.port.set` is invalid (use `dht.override_port.set`); `network.max_open_files.set` is deprecated (use `system.sockets.files.min`).
- The synced file is whichever the image imports: `${CONFIG_PATH}/rtorrent/config/rtorrent.rc` when it exists (binhex layout), else `${CONFIG_PATH}/rtorrent/.rtorrent.rc`.
- `system.file.allocate` is NEVER written from UI state back into `rtorrent.rc`.
- Default upload rate for fresh installs is **unlimited (`0`)**.
- Canonical incoming port is **`50000`** (`RT_INC_PORT` default `50000`), single port, TCP.
- `RT_PREALLOCATE_TYPE` default is **`0`**.
- Preserve existing binhex-compat behavior in `configurations.sh` (session dir rewrite, legacy `port_range` sanitization).
- The `SYNCED_KEYS` whitelist and getter mapping are defined in the spec §4.4; treat that table as authoritative.

**Spec:** `docs/superpowers/specs/2026-08-18-rtorrent-sync-stability-defaults-design.md`

---

## Task 1: Create the sync helper skeleton with the key whitelist

**Files:**
- Create: `rootfs/usr/local/bin/rtstate-sync.sh`
- Test: `tests/rtstate-sync/test_whitelist.sh`

**Interfaces:**
- Produces: executable `rtstate-sync.sh` supporting subcommands `arbitrate <RC> <ST>`, `snapshot <RC> <ST>`, and internal helpers `rtstate_keys` (prints the whitelist, one `config_key|getter|kind` per line), `rtstate_validate <kind> <value>` (exit 0 if valid). `kind` ∈ `int|bool|enum_dht|path|bytes`.

- [ ] **Step 1: Write the failing test**

```sh
# tests/rtstate-sync/test_whitelist.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"

# whitelist must include the critical keys and exclude allocate from write-back kind
out=$("$SUT" __keys)
echo "$out" | grep -q '^throttle.global_up.max_rate.set_kb|throttle.global_up.max_rate|int$' || { echo "FAIL: up rate key"; exit 1; }
echo "$out" | grep -q '^pieces.hash.on_completion.set|pieces.hash.on_completion|bool$' || { echo "FAIL: hash key"; exit 1; }
echo "$out" | grep -q '^system.file.allocate.set|system.file.allocate|bool_readonly$' || { echo "FAIL: allocate must be bool_readonly"; exit 1; }

# validation
"$SUT" __validate int 5120 || { echo "FAIL: 5120 int"; exit 1; }
if "$SUT" __validate int "abc" 2>/dev/null; then echo "FAIL: abc not int"; exit 1; fi
"$SUT" __validate bool 1 || { echo "FAIL: bool 1"; exit 1; }
if "$SUT" __validate bool 2 2>/dev/null; then echo "FAIL: 2 not bool"; exit 1; fi
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtstate-sync/test_whitelist.sh`
Expected: FAIL (file not found / no `__keys`).

- [ ] **Step 3: Write minimal implementation**

```sh
# rootfs/usr/local/bin/rtstate-sync.sh
#!/usr/bin/env sh
# Bidirectional sync between rtorrent.rc and .rtstate.rc for a whitelist of
# global rTorrent settings. POSIX sh (BusyBox) only.
set -eu

# Whitelist: config_key|getter|kind
# kind: int|bool|bool_readonly|enum_dht|path|bytes
rtstate_keys() {
  cat <<'KEYS'
throttle.global_up.max_rate.set_kb|throttle.global_up.max_rate|int
throttle.global_down.max_rate.set_kb|throttle.global_down.max_rate|int
throttle.max_uploads.global.set|throttle.max_uploads.global|int
throttle.max_downloads.global.set|throttle.max_downloads.global|int
throttle.max_uploads.set|throttle.max_uploads|int
throttle.max_peers.normal.set|throttle.max_peers.normal|int
throttle.max_peers.seed.set|throttle.max_peers.seed|int
throttle.min_peers.normal.set|throttle.min_peers.normal|int
throttle.min_peers.seed.set|throttle.min_peers.seed|int
protocol.pex.set|protocol.pex|bool
trackers.use_udp.set|trackers.use_udp|bool
pieces.hash.on_completion.set|pieces.hash.on_completion|bool
directory.default.set|directory.default|path
network.receive_buffer.size.set|network.receive_buffer.size|bytes
network.send_buffer.size.set|network.send_buffer.size|bytes
system.file.allocate.set|system.file.allocate|bool_readonly
KEYS
}

rtstate_validate() {
  kind="$1"; val="$2"
  case "$kind" in
    int|bytes) printf '%s' "$val" | grep -Eq '^-?[0-9]+$' ;;
    bool|bool_readonly) case "$val" in 0|1) return 0;; *) return 1;; esac ;;
    enum_dht) case "$val" in disable|off|auto|on|0|1|2|3) return 0;; *) return 1;; esac ;;
    path) [ -n "$val" ] ;;
    *) return 1 ;;
  esac
}

case "${1:-}" in
  __keys) rtstate_keys ;;
  __validate) shift; rtstate_validate "$@" ;;
  *) echo "usage: rtstate-sync.sh {arbitrate|snapshot} ..." >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtstate-sync/test_whitelist.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/usr/local/bin/rtstate-sync.sh tests/rtstate-sync/test_whitelist.sh
git commit -m "feat(sync): add rtstate-sync helper skeleton with key whitelist and validation"
```

---

## Task 2: In-place key write-back into rtorrent.rc

**Files:**
- Modify: `rootfs/usr/local/bin/rtstate-sync.sh`
- Test: `tests/rtstate-sync/test_writeback.sh`

**Interfaces:**
- Consumes: `rtstate_keys`, `rtstate_validate` from Task 1.
- Produces: `rtstate_set_rc <RC> <config_key> <value>` — replaces an existing `^\s*<key>\s*=...` line in `RC` in place, or appends `key = value` if absent. Idempotent.

- [ ] **Step 1: Write the failing test**

```sh
# tests/rtstate-sync/test_writeback.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"
TMP=$(mktemp -d)
RC="$TMP/rtorrent.rc"
printf '%s\n' "throttle.global_up.max_rate.set_kb = 5120" "protocol.pex.set = 1" > "$RC"

"$SUT" __set_rc "$RC" throttle.global_up.max_rate.set_kb 0
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$RC" || { echo "FAIL: not replaced"; exit 1; }
# unrelated line untouched
grep -qx "protocol.pex.set = 1" "$RC" || { echo "FAIL: pex clobbered"; exit 1; }
# absent key gets appended
"$SUT" __set_rc "$RC" throttle.max_uploads.global.set 15
grep -qx "throttle.max_uploads.global.set = 15" "$RC" || { echo "FAIL: not appended"; exit 1; }
# idempotent: run twice → identical
cp "$RC" "$RC.a"; "$SUT" __set_rc "$RC" throttle.max_uploads.global.set 15
diff -q "$RC" "$RC.a" >/dev/null || { echo "FAIL: not idempotent"; exit 1; }
# no duplicate lines
[ "$(grep -c 'throttle.global_up.max_rate.set_kb' "$RC")" -eq 1 ] || { echo "FAIL: dup up-rate"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtstate-sync/test_writeback.sh`
Expected: FAIL (`__set_rc` unknown).

- [ ] **Step 3: Write minimal implementation**

Add before the `case` dispatch:

```sh
# Escape a string for use as a literal in a sed replacement (RHS).
_sed_rhs_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
# Escape a config key (has dots) for a sed BRE match; dots are literal enough,
# but anchor on start + optional whitespace + literal key + whitespace + '='.
rtstate_set_rc() {
  rc="$1"; key="$2"; val="$3"
  [ -f "$rc" ] || : > "$rc"
  esc_key=$(printf '%s' "$key" | sed -e 's/[.[\*^$]/\\&/g')
  if grep -Eq "^[[:space:]]*${esc_key}[[:space:]]*=" "$rc"; then
    rhs=$(_sed_rhs_escape "${key} = ${val}")
    sed -i -E "s/^[[:space:]]*${esc_key}[[:space:]]*=.*/${rhs}/" "$rc"
  else
    printf '%s = %s\n' "$key" "$val" >> "$rc"
  fi
}
```

Add dispatch cases:

```sh
  __set_rc) shift; rtstate_set_rc "$@" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtstate-sync/test_writeback.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/usr/local/bin/rtstate-sync.sh tests/rtstate-sync/test_writeback.sh
git commit -m "feat(sync): idempotent in-place key write-back into rtorrent.rc"
```

---

## Task 3: Parse .rtstate.rc and apply state → rtorrent.rc (allocate excluded)

**Files:**
- Modify: `rootfs/usr/local/bin/rtstate-sync.sh`
- Test: `tests/rtstate-sync/test_apply_state.sh`

**Interfaces:**
- Consumes: `rtstate_keys`, `rtstate_validate`, `rtstate_set_rc`.
- Produces: `rtstate_apply_state_to_rc <RC> <ST>` — for each whitelisted key found in `ST` with a valid value and kind != `bool_readonly`, call `rtstate_set_rc`. Invalid or read-only keys are skipped.

- [ ] **Step 1: Write the failing test**

```sh
# tests/rtstate-sync/test_apply_state.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"
TMP=$(mktemp -d); RC="$TMP/rc"; ST="$TMP/st"
printf '%s\n' "throttle.global_up.max_rate.set_kb = 5120" > "$RC"
cat > "$ST" <<EOF
# Auto-generated runtime settings state
throttle.global_up.max_rate.set_kb = 0
protocol.pex.set = 1
system.file.allocate.set = 1
throttle.max_peers.normal.set = notanumber
EOF
"$SUT" __apply_state "$RC" "$ST"
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$RC" || { echo "FAIL: up rate not applied"; exit 1; }
grep -qx "protocol.pex.set = 1" "$RC" || { echo "FAIL: pex not applied"; exit 1; }
# allocate must NOT be written into RC
if grep -q "system.file.allocate.set" "$RC"; then echo "FAIL: allocate leaked into RC"; exit 1; fi
# invalid value skipped
if grep -q "throttle.max_peers.normal.set" "$RC"; then echo "FAIL: invalid peer value written"; exit 1; fi
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtstate-sync/test_apply_state.sh`
Expected: FAIL (`__apply_state` unknown).

- [ ] **Step 3: Write minimal implementation**

```sh
rtstate_apply_state_to_rc() {
  rc="$1"; st="$2"
  [ -f "$st" ] || return 0
  rtstate_keys | while IFS='|' read -r ckey getter kind; do
    [ "$kind" = "bool_readonly" ] && continue
    line=$(grep -E "^[[:space:]]*$(printf '%s' "$ckey" | sed -e 's/[.[\*^$]/\\&/g')[[:space:]]*=" "$st" | tail -n1 || true)
    [ -n "$line" ] || continue
    val=$(printf '%s' "$line" | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')
    if rtstate_validate "$kind" "$val"; then
      rtstate_set_rc "$rc" "$ckey" "$val"
    fi
  done
}
```

Add dispatch:

```sh
  __apply_state) shift; rtstate_apply_state_to_rc "$@" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtstate-sync/test_apply_state.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/usr/local/bin/rtstate-sync.sh tests/rtstate-sync/test_apply_state.sh
git commit -m "feat(sync): apply .rtstate.rc into rtorrent.rc, excluding allocate and invalid values"
```

---

## Task 4: Seed .rtstate.rc from rtorrent.rc (config → state mirror)

**Files:**
- Modify: `rootfs/usr/local/bin/rtstate-sync.sh`
- Test: `tests/rtstate-sync/test_seed_state.sh`

**Interfaces:**
- Consumes: `rtstate_keys`, `rtstate_validate`.
- Produces: `rtstate_seed_from_rc <RC> <ST>` — writes `ST` atomically (`ST.tmp` then `mv -f`) containing the header line plus every whitelisted key that exists in `RC` with a valid value (including `bool_readonly` for display).

- [ ] **Step 1: Write the failing test**

```sh
# tests/rtstate-sync/test_seed_state.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"
TMP=$(mktemp -d); RC="$TMP/rc"; ST="$TMP/st"
cat > "$RC" <<EOF
throttle.global_up.max_rate.set_kb = 0
protocol.pex.set = 1
system.file.allocate.set = 0
EOF
"$SUT" __seed_state "$RC" "$ST"
head -n1 "$ST" | grep -q "Auto-generated" || { echo "FAIL: no header"; exit 1; }
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$ST" || { echo "FAIL: up rate not seeded"; exit 1; }
grep -qx "system.file.allocate.set = 0" "$ST" || { echo "FAIL: allocate mirror missing"; exit 1; }
# no temp file left behind
[ ! -f "$ST.tmp" ] || { echo "FAIL: temp left"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtstate-sync/test_seed_state.sh`
Expected: FAIL (`__seed_state` unknown).

- [ ] **Step 3: Write minimal implementation**

```sh
rtstate_seed_from_rc() {
  rc="$1"; st="$2"; tmp="${st}.tmp"
  printf '# Auto-generated runtime settings state\n' > "$tmp"
  rtstate_keys | while IFS='|' read -r ckey getter kind; do
    line=$(grep -E "^[[:space:]]*$(printf '%s' "$ckey" | sed -e 's/[.[\*^$]/\\&/g')[[:space:]]*=" "$rc" 2>/dev/null | tail -n1 || true)
    [ -n "$line" ] || continue
    val=$(printf '%s' "$line" | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')
    rtstate_validate "$kind" "$val" && printf '%s = %s\n' "$ckey" "$val" >> "$tmp"
  done
  mv -f "$tmp" "$st"
}
```

Add dispatch:

```sh
  __seed_state) shift; rtstate_seed_from_rc "$@" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtstate-sync/test_seed_state.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/usr/local/bin/rtstate-sync.sh tests/rtstate-sync/test_seed_state.sh
git commit -m "feat(sync): atomically seed .rtstate.rc mirror from rtorrent.rc"
```

---

## Task 5: Boot arbitration (newest-write-wins)

**Files:**
- Modify: `rootfs/usr/local/bin/rtstate-sync.sh`
- Test: `tests/rtstate-sync/test_arbitrate.sh`

**Interfaces:**
- Consumes: `rtstate_apply_state_to_rc`, `rtstate_seed_from_rc`.
- Produces: `arbitrate <RC> <ST>` subcommand. Rules: if `ST` missing or has no key lines → seed from RC. Else if `mtime(RC) > mtime(ST)` → back up RC to `RC.bak.<ts>`? No — seed ST from RC (config wins). Else (`ST` newer/equal) → back up RC, apply ST→RC, then re-seed ST from RC so both converge.

- [ ] **Step 1: Write the failing test**

```sh
# tests/rtstate-sync/test_arbitrate.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"

mk() { TMP=$(mktemp -d); RC="$TMP/rc"; ST="$TMP/st"; }

# Case A: state missing -> seed from RC (config wins)
mk
printf 'throttle.global_up.max_rate.set_kb = 5120\n' > "$RC"
"$SUT" arbitrate "$RC" "$ST"
grep -qx "throttle.global_up.max_rate.set_kb = 5120" "$ST" || { echo "FAIL A: not seeded"; exit 1; }

# Case B: RC newer than ST -> config wins (ST overwritten to match RC)
mk
printf 'throttle.global_up.max_rate.set_kb = 0\n' > "$ST"
printf '# header\nthrottle.global_up.max_rate.set_kb = 0\n' > "$ST"
sleep 1
printf 'throttle.global_up.max_rate.set_kb = 5120\n' > "$RC"   # RC now newest
"$SUT" arbitrate "$RC" "$ST"
grep -qx "throttle.global_up.max_rate.set_kb = 5120" "$ST" || { echo "FAIL B: config did not win"; exit 1; }

# Case C: ST newer than RC -> UI wins (RC updated), allocate excluded
mk
printf 'throttle.global_up.max_rate.set_kb = 5120\nsystem.file.allocate.set = 0\n' > "$RC"
sleep 1
printf '# header\nthrottle.global_up.max_rate.set_kb = 0\nsystem.file.allocate.set = 1\n' > "$ST"  # ST newest
"$SUT" arbitrate "$RC" "$ST"
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$RC" || { echo "FAIL C: UI did not win"; exit 1; }
grep -qx "system.file.allocate.set = 0" "$RC" || { echo "FAIL C: allocate wrongly changed"; exit 1; }
# converge: RC and ST agree on up rate
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$ST" || { echo "FAIL C: not converged"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtstate-sync/test_arbitrate.sh`
Expected: FAIL (`arbitrate` prints usage / exits 2).

- [ ] **Step 3: Write minimal implementation**

```sh
_has_keys() { grep -Eq '^[[:space:]]*[a-z]' "$1" 2>/dev/null; }
_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

rtstate_arbitrate() {
  rc="$1"; st="$2"
  [ -f "$rc" ] || : > "$rc"
  if [ ! -f "$st" ] || ! _has_keys "$st"; then
    rtstate_seed_from_rc "$rc" "$st"; return 0
  fi
  rc_m=$(_mtime "$rc"); st_m=$(_mtime "$st")
  if [ "$rc_m" -gt "$st_m" ]; then
    rtstate_seed_from_rc "$rc" "$st"            # config wins
  else
    cp -f "$rc" "${rc}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    rtstate_apply_state_to_rc "$rc" "$st"       # UI wins
    rtstate_seed_from_rc "$rc" "$st"            # converge
  fi
}
```

Add dispatch:

```sh
  arbitrate) shift; rtstate_arbitrate "$@" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtstate-sync/test_arbitrate.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/usr/local/bin/rtstate-sync.sh tests/rtstate-sync/test_arbitrate.sh
git commit -m "feat(sync): newest-write-wins boot arbitration converging rtorrent.rc and .rtstate.rc"
```

---

## Task 6: Runtime snapshot from live XMLRPC getters

**Files:**
- Modify: `rootfs/usr/local/bin/rtstate-sync.sh`
- Test: `tests/rtstate-sync/test_snapshot.sh`

**Interfaces:**
- Consumes: `rtstate_keys`, `rtstate_validate`, `rtstate_set_rc`.
- Produces: `snapshot <RC> <ST> <RPC_URL>` subcommand. For each key, fetch the getter via `_rt_get <getter> <RPC_URL>` (curl XMLRPC-over-HTTP against the local no-auth health port, e.g. `http://127.0.0.1:5001`), convert rate getters (bytes→KiB for `*.set_kb`), validate, write `ST` atomically, then apply the same values into `RC` (excluding `bool_readonly`). `_rt_get` is overridable via env `RTSTATE_GET_CMD` for testing. **Note:** the image has NO `xmlrpc2scgi` binary; querying rtorrent is done exactly like `healthcheck` does — `curl` POSTing an XMLRPC `<methodCall>` to `http://127.0.0.1:${XMLRPC_HEALTH_PORT}` which `scgi_pass`es to the socket.

- [ ] **Step 1: Write the failing test**

```sh
# tests/rtstate-sync/test_snapshot.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../../rootfs/usr/local/bin/rtstate-sync.sh"
TMP=$(mktemp -d); RC="$TMP/rc"; ST="$TMP/st"
printf 'throttle.global_up.max_rate.set_kb = 5120\n' > "$RC"

# Fake getter: up rate 0 bytes, everything else returns a benign value
cat > "$TMP/fakeget.sh" <<'EOF'
#!/bin/sh
case "$1" in
  throttle.global_up.max_rate) echo 0 ;;
  throttle.global_down.max_rate) echo 0 ;;
  system.file.allocate) echo 1 ;;
  protocol.pex) echo 1 ;;
  trackers.use_udp) echo 1 ;;
  pieces.hash.on_completion) echo 0 ;;
  directory.default) echo /data/downloads ;;
  network.receive_buffer.size) echo 16777216 ;;
  network.send_buffer.size) echo 16777216 ;;
  *) echo 0 ;;
esac
EOF
chmod +x "$TMP/fakeget.sh"

RTSTATE_GET_CMD="$TMP/fakeget.sh" "$SUT" snapshot "$RC" "$ST" /dev/null
# up rate converted bytes(0)->kb(0) and applied to RC
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$RC" || { echo "FAIL: rate not snapshotted to RC"; exit 1; }
grep -qx "throttle.global_up.max_rate.set_kb = 0" "$ST" || { echo "FAIL: rate not in ST"; exit 1; }
# allocate present in ST mirror but NOT pushed to RC
grep -qx "system.file.allocate.set = 1" "$ST" || { echo "FAIL: allocate mirror missing"; exit 1; }
if grep -q "system.file.allocate.set" "$RC"; then echo "FAIL: allocate leaked to RC"; exit 1; fi
[ ! -f "$ST.tmp" ] || { echo "FAIL: temp left"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtstate-sync/test_snapshot.sh`
Expected: FAIL (`snapshot` unknown).

- [ ] **Step 3: Write minimal implementation**

```sh
# Query one rtorrent getter via XMLRPC-over-HTTP (same path as healthcheck).
# Returns the raw <value> text (int or string). Overridable for tests.
_rt_get() {
  getter="$1"; url="$2"; kind="${3:-int}"
  if [ -n "${RTSTATE_GET_CMD:-}" ]; then
    "$RTSTATE_GET_CMD" "$getter"; return $?
  fi
  body="<?xml version=\"1.0\"?><methodCall><methodName>${getter}</methodName><params></params></methodCall>"
  resp=$(curl -s --max-time 5 -H "Content-Type: text/xml" --data "${body}" "${url}" 2>/dev/null || true)
  # Extract the scalar inside <value>...<i8>|<i4>|<int>|<string>...
  val=$(printf '%s' "$resp" | sed -n -E 's:.*<value><(i8|i4|int)>(-?[0-9]+)</(i8|i4|int)></value>.*:\2:p')
  if [ -z "$val" ]; then
    val=$(printf '%s' "$resp" | sed -n -E 's:.*<value><string>([^<]*)</string></value>.*:\1:p')
  fi
  if [ -z "$val" ]; then
    # Some builds return a bare <value>TEXT</value>
    val=$(printf '%s' "$resp" | sed -n -E 's:.*<value>([^<]*)</value>.*:\1:p')
  fi
  case "$kind" in
    path) printf '%s' "$val" ;;
    *)    printf '%s' "$val" | tr -dc '0-9-' ;;
  esac
}

rtstate_snapshot() {
  rc="$1"; st="$2"; url="$3"; tmp="${st}.tmp"
  printf '# Auto-generated runtime settings state\n' > "$tmp"
  rtstate_keys | while IFS='|' read -r ckey getter kind; do
    raw=$(_rt_get "$getter" "$url" "$kind" || true)
    [ -n "$raw" ] || continue
    val="$raw"
    case "$ckey" in
      *.max_rate.set_kb) val=$(( raw / 1024 )) ;;
    esac
    rtstate_validate "$kind" "$val" || continue
    printf '%s = %s\n' "$ckey" "$val" >> "$tmp"
  done
  mv -f "$tmp" "$st"
  # Propagate to RC (allocate excluded by apply_state).
  rtstate_apply_state_to_rc "$rc" "$st"
}
```

Add dispatch:

```sh
  snapshot) shift; rtstate_snapshot "$@" ;;
```

Note: `_rt_get` passes `kind` so the `path` getter (`directory.default`) keeps
its string value while numeric getters are digit-filtered. In tests,
`RTSTATE_GET_CMD` short-circuits the curl path, so the test invocation
`... snapshot "$RC" "$ST" /dev/null` still works (the URL arg is ignored).

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtstate-sync/test_snapshot.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/usr/local/bin/rtstate-sync.sh tests/rtstate-sync/test_snapshot.sh
git commit -m "feat(sync): hardened runtime snapshot from live XMLRPC getters with atomic write and RC propagation"
```

---

## Task 7: Rewrite .rtlocal.rc snapshot schedule + import order + crash-fix opts

**Files:**
- Modify: `rootfs/etc/rtorrent/.rtlocal.rc:34-39` (perf/memory limits)
- Modify: `rootfs/etc/rtorrent/.rtlocal.rc:61-87` (snapshot schedule + import)
- Test: `tests/rtlocal/test_rtlocal_shape.sh`

**Interfaces:**
- Consumes: `rtstate-sync.sh snapshot` (Task 6) at runtime.
- Produces: an `.rtlocal.rc` that (a) calls the helper on a schedule instead of inline echo, (b) uses `dht.override_port.set`-compatible opts elsewhere (Task 9 handles `.rtlocal` port line), (c) caps curl/socket concurrency.

- [ ] **Step 1: Write the failing test**

```sh
# tests/rtlocal/test_rtlocal_shape.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/../../rootfs/etc/rtorrent/.rtlocal.rc"

# deprecated opt must be gone
if grep -Eq '^[[:space:]]*network\.max_open_files\.set' "$F"; then echo "FAIL: deprecated max_open_files present"; exit 1; fi
grep -Eq '^[[:space:]]*system\.sockets\.files\.min\.set' "$F" || { echo "FAIL: missing sockets.files.min"; exit 1; }
# curl concurrency cap present
grep -Eq '^[[:space:]]*network\.http\.max_open\.set' "$F" || { echo "FAIL: missing http.max_open cap"; exit 1; }
# snapshot uses helper, not inline echo blocks
if grep -q 'Auto-generated runtime settings state' "$F"; then echo "FAIL: inline snapshot still present"; exit 1; fi
grep -q 'rtstate-sync.sh' "$F" || { echo "FAIL: helper not called"; exit 1; }
grep -q 'settings_snapshot' "$F" || { echo "FAIL: schedule missing"; exit 1; }
# snapshot must use the HTTP health port, not a scgi binary
grep -q 'XMLRPC_HEALTH_PORT' "$F" || { echo "FAIL: snapshot not using health RPC port"; exit 1; }
if grep -q 'xmlrpc2scgi' "$F"; then echo "FAIL: references nonexistent xmlrpc2scgi"; exit 1; fi
# state still imported last
grep -Eq 'try_import = \(cat,\(cfg.basedir\),".rtstate.rc"\)' "$F" || { echo "FAIL: try_import missing"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtlocal/test_rtlocal_shape.sh`
Expected: FAIL (inline snapshot present, deprecated opt present).

- [ ] **Step 3: Write minimal implementation**

Replace lines 34-39 block with:

```
# Performance & Memory limits for large sessions (~600 torrents)
pieces.memory.max.set = 3500M
system.sockets.files.min.set = 8192
network.max_open_sockets.set = 1024
network.http.max_open.set = 32
pieces.preload.type.set = 1
pieces.preload.min_size.set = 262144
```

Replace lines 61-87 (the inline snapshot + init + import) with:

```
# Save live UI setting changes to .rtstate.rc periodically (delegated to helper).
# Snapshot queries rtorrent via the local no-auth XMLRPC health port over HTTP
# (same mechanism as healthcheck), NOT a scgi binary.
schedule = settings_snapshot, 10, @RT_STATE_SAVE_SECONDS@, ((execute.nothrow.bg, \
  /usr/local/bin/rtstate-sync.sh, snapshot, \
  (cat,(cfg.basedir),"@RC_BASENAME@"), \
  (cat,(cfg.basedir),".rtstate.rc"), \
  "http://127.0.0.1:@XMLRPC_HEALTH_PORT@"))

# Import runtime settings state if saved (must be last)
try_import = (cat,(cfg.basedir),".rtstate.rc")
```

(`@RC_BASENAME@` is substituted by `configurations.sh` in Task 8; `@XMLRPC_HEALTH_PORT@`
is already substituted by the nginx/config section of `configurations.sh` — add
it to the `.rtlocal.rc` sed substitution list in Task 8 if not already present.)

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtlocal/test_rtlocal_shape.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/rtorrent/.rtlocal.rc tests/rtlocal/test_rtlocal_shape.sh
git commit -m "feat(rtorrent): delegate snapshot to rtstate-sync, cap curl/socket concurrency, fix 0.16.20 opts"
```

---

## Task 8: Wire arbitration + RC_BASENAME + defaults into configurations.sh

**Files:**
- Modify: `rootfs/etc/cont-init.d/configurations.sh:80` (`RT_PREALLOCATE_TYPE` default)
- Modify: `rootfs/etc/cont-init.d/configurations.sh:74` (`RT_INC_PORT` default)
- Modify: `rootfs/etc/cont-init.d/configurations.sh:308-360` (rtorrent bootstrap region — add arbitration + RC_BASENAME substitution)
- Test: `tests/configsh/test_defaults.sh`

**Interfaces:**
- Consumes: `rtstate-sync.sh arbitrate` (Task 5).
- Produces: at boot, before rtorrent starts, `configurations.sh` resolves the synced RC path (`config/rtorrent.rc` if present else `.rtorrent.rc`), substitutes `@RC_BASENAME@` in `.rtlocal.rc`, and runs arbitration.

- [ ] **Step 1: Write the failing test**

```sh
# tests/configsh/test_defaults.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/../../rootfs/etc/cont-init.d/configurations.sh"
grep -Eq 'RT_PREALLOCATE_TYPE=\$\{RT_PREALLOCATE_TYPE:-0\}' "$F" || { echo "FAIL: prealloc default not 0"; exit 1; }
grep -Eq 'RT_INC_PORT=\$\{RT_INC_PORT:-50000\}' "$F" || { echo "FAIL: inc port default not 50000"; exit 1; }
grep -q 'RC_BASENAME' "$F" || { echo "FAIL: RC_BASENAME not resolved"; exit 1; }
grep -q 'rtstate-sync.sh arbitrate' "$F" || { echo "FAIL: arbitration not wired"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/configsh/test_defaults.sh`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Change line 80: `RT_PREALLOCATE_TYPE=${RT_PREALLOCATE_TYPE:-1}` → `RT_PREALLOCATE_TYPE=${RT_PREALLOCATE_TYPE:-0}`.

Change line 74: `RT_INC_PORT=${RT_INC_PORT:-50000}` (already 50000 — confirm; if it reads `:-50000` leave, else set).

Add `@XMLRPC_HEALTH_PORT@` to the `.rtlocal.rc` sed substitution block (the
`sed -e ...  -i /etc/rtorrent/.rtlocal.rc` call around lines 312-324) so the
snapshot schedule URL is resolved:

```sh
    -e "s!@XMLRPC_HEALTH_PORT@!$XMLRPC_HEALTH_PORT!g" \
```

After the rtorrent config bootstrap region (after the block that ends ~line 360, i.e. after legacy `import =` is appended), add:

```sh
# Resolve the synced rtorrent.rc (binhex config path wins if present).
if [ -f "${CONFIG_PATH}/rtorrent/config/rtorrent.rc" ]; then
  RC_BASENAME="config/rtorrent.rc"
else
  RC_BASENAME=".rtorrent.rc"
fi
sed -i "s!@RC_BASENAME@!${RC_BASENAME}!g" /etc/rtorrent/.rtlocal.rc

# Newest-write-wins arbitration so UI state and rtorrent.rc stay in sync.
RC_PATH="${CONFIG_PATH}/rtorrent/${RC_BASENAME}"
ST_PATH="${CONFIG_PATH}/rtorrent/.rtstate.rc"
if [ -x /usr/local/bin/rtstate-sync.sh ]; then
  echo "  [+] Reconciling UI state and rtorrent.rc (newest-write-wins)..."
  /usr/local/bin/rtstate-sync.sh arbitrate "${RC_PATH}" "${ST_PATH}" || \
    echo "  [-] rtstate arbitration skipped (non-fatal)"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/configsh/test_defaults.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/cont-init.d/configurations.sh tests/configsh/test_defaults.sh
git commit -m "feat(boot): wire rtstate arbitration + RC_BASENAME, default prealloc off and port 50000"
```

---

## Task 9: Fix deprecated dht.port.set in .rtlocal.rc

**Files:**
- Modify: `rootfs/etc/rtorrent/.rtlocal.rc:29`
- Test: extend `tests/rtlocal/test_rtlocal_shape.sh`

**Interfaces:**
- Produces: `.rtlocal.rc` uses `dht.override_port.set` (or drops the invalid call) so no 0.16.20 warning.

- [ ] **Step 1: Add failing assertions to the shape test**

Append to `tests/rtlocal/test_rtlocal_shape.sh` before the final `echo "PASS"`:

```sh
if grep -Eq '^[[:space:]]*dht\.port\.set' "$F"; then echo "FAIL: deprecated dht.port.set present"; exit 1; fi
grep -Eq '^[[:space:]]*dht\.override_port\.set' "$F" || { echo "FAIL: dht.override_port.set missing"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/rtlocal/test_rtlocal_shape.sh`
Expected: FAIL (`dht.port.set` still present).

- [ ] **Step 3: Write minimal implementation**

Change line 29 `dht.port.set = @RT_DHT_PORT@` → `dht.override_port.set = @RT_DHT_PORT@`.

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/rtlocal/test_rtlocal_shape.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/rtorrent/.rtlocal.rc tests/rtlocal/test_rtlocal_shape.sh
git commit -m "fix(rtorrent): use dht.override_port.set for 0.16.20"
```

---

## Task 10: Graceful SIGTERM tracker-stop in the rtorrent s6 service

**Files:**
- Modify: `rootfs/etc/cont-init.d/configurations.sh:684-706` (the heredoc that writes `/etc/services.d/rtorrent/run`)
- Test: `tests/configsh/test_graceful_stop.sh`

**Interfaces:**
- Produces: the generated `/etc/services.d/rtorrent/run` traps `TERM` and, on stop, calls rtorrent's clean shutdown (which emits `event=stopped` to trackers) before the process exits; also creates a `finish` script that requests graceful stop.

- [ ] **Step 1: Write the failing test**

```sh
# tests/configsh/test_graceful_stop.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/../../rootfs/etc/cont-init.d/configurations.sh"
# The generated rtorrent run must set up a graceful stop path.
grep -q 'services.d/rtorrent/finish' "$F" || { echo "FAIL: no finish script for graceful stop"; exit 1; }
grep -q 'system.shutdown' "$F" || { echo "FAIL: no graceful shutdown call"; exit 1; }
if grep -q 'xmlrpc2scgi' "$F"; then echo "FAIL: references nonexistent xmlrpc2scgi"; exit 1; fi
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/configsh/test_graceful_stop.sh`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

After the block that writes `/etc/services.d/rtorrent/run` (ends ~line 706), add
a `finish` script that asks rtorrent to shut down cleanly (sending `stopped`):

```sh
cat > /etc/services.d/rtorrent/finish <<EOL
#!/bin/sh
# On service stop, ask rTorrent to shut down gracefully so it announces
# event=stopped to all trackers before exiting (prevents "multiple locations").
# Uses XMLRPC-over-HTTP on the local no-auth health port (same as healthcheck),
# because the image has no xmlrpc2scgi binary.
SOCK="/var/run/rtorrent/scgi.socket"
RPC_URL="http://127.0.0.1:${XMLRPC_HEALTH_PORT}"
if [ -S "\${SOCK}" ]; then
  curl -s --max-time 5 -H "Content-Type: text/xml" \\
    --data '<?xml version="1.0"?><methodCall><methodName>system.shutdown</methodName><params></params></methodCall>' \\
    "\${RPC_URL}" >/dev/null 2>&1 || true
  # give rtorrent a moment to flush stopped-announces
  i=0; while [ -S "\${SOCK}" ] && [ "\$i" -lt 10 ]; do sleep 1; i=\$((i+1)); done
fi
EOL
chmod +x /etc/services.d/rtorrent/finish
```

Note: `${XMLRPC_HEALTH_PORT}` is expanded by `configurations.sh` at heredoc
write time (unescaped `EOL`), baking the concrete port into the finish script.
If `system.shutdown` is unavailable in the build, fall back to a session save +
`d.stop` sweep; document in README (Task 12).

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/configsh/test_graceful_stop.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/cont-init.d/configurations.sh tests/configsh/test_graceful_stop.sh
git commit -m "feat(shutdown): graceful rtorrent stop announces event=stopped to trackers"
```

---

## Task 11: Faster-boot guards for per-boot maintenance sweeps

**Files:**
- Modify: `rootfs/etc/cont-init.d/configurations.sh:645-668` (the `chown -R` perms block)
- Test: `tests/configsh/test_boot_guard.sh`

**Interfaces:**
- Produces: the heavy recursive `chown -R ... ${CONFIG_PATH}` over the whole appdata runs only on first run or when a marker is absent, not on every restart.

- [ ] **Step 1: Write the failing test**

```sh
# tests/configsh/test_boot_guard.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
F="$HERE/../../rootfs/etc/cont-init.d/configurations.sh"
grep -q '.perms_initialized' "$F" || { echo "FAIL: no first-run perms marker"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/configsh/test_boot_guard.sh`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Wrap the whole-tree recursive `chown -R rtorrent:rtorrent ${CONFIG_PATH} ...`
(the first big block around line 647) in a first-run guard, keeping the lighter
per-service chowns unconditional:

```sh
PERMS_MARKER="${CONFIG_PATH}/rtorrent/.perms_initialized"
if [ ! -f "${PERMS_MARKER}" ]; then
  echo "  [+] First-run: fixing appdata ownership (one-time)..."
  chown -R rtorrent:rtorrent \
    ${CONFIG_PATH} \
    ${PASSWD_PATH} \
    ${GEOIP2_PATH} \
    /var/www/rutorrent
  touch "${PERMS_MARKER}" && chown rtorrent:rtorrent "${PERMS_MARKER}" || true
fi
```

(Leave the subsequent targeted `chown` of `/etc/rtorrent`, `/var/run/...` etc.
as-is — those are cheap and needed every boot.)

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/configsh/test_boot_guard.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/cont-init.d/configurations.sh tests/configsh/test_boot_guard.sh
git commit -m "perf(boot): guard whole-appdata chown behind first-run marker"
```

---

## Task 12: Update Unraid template and cleanup guide

**Files:**
- Modify: `rutorrent.xml`
- Create: `docs/CLEANUP.md`
- Test: `tests/docs/test_template_and_docs.sh`

**Interfaces:**
- Produces: template with single incoming port 50000 and prealloc default off; a `CLEANUP.md` with the exact keep/delete list and a session-safety guard. (README is handled entirely in Task 13.)

- [ ] **Step 1: Write the failing test**

```sh
# tests/docs/test_template_and_docs.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../.."
# Template: prealloc default off
grep -Eq 'RT_PREALLOCATE_TYPE.*Default="0"' "$ROOT/rutorrent.xml" || { echo "FAIL: template prealloc default not 0"; exit 1; }
# Cleanup guide
[ -f "$ROOT/docs/CLEANUP.md" ] || { echo "FAIL: CLEANUP.md missing"; exit 1; }
grep -q 'rtorrent/session/' "$ROOT/docs/CLEANUP.md" || { echo "FAIL: cleanup missing session keep"; exit 1; }
grep -qi 'never delete' "$ROOT/docs/CLEANUP.md" || { echo "FAIL: cleanup missing session warning"; exit 1; }
grep -qi 'stopped' "$ROOT/docs/CLEANUP.md" || { echo "FAIL: cleanup missing container-stopped guard"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/docs/test_template_and_docs.sh`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`rutorrent.xml`: set the `RT_PREALLOCATE_TYPE` config `Default="0"` with
description "0=Disabled (recommended), 1=Enabled (fallocate)"; ensure a single
incoming peer port entry `50000/tcp` and no duplicate `51741` entry in the repo
template file.

`docs/CLEANUP.md`: paste the keep/delete list from the spec §7 with a header:
"Run only while the container is STOPPED. NEVER delete `rtorrent/session/`."
Include copy-paste-safe shell that deletes only the listed stale paths, guarded
by a check that the container is not running.

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/docs/test_template_and_docs.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add rutorrent.xml docs/CLEANUP.md tests/docs/test_template_and_docs.sh
git commit -m "docs: single-port + prealloc-off template default and safe config cleanup guide"
```

---

## Task 13: Full README revamp (fork feature documentation)

**Files:**
- Modify: `README.md` (full rewrite of the "About"/"Features" and usage sections)
- Test: `tests/docs/test_readme_features.sh`

**Interfaces:**
- Consumes: nothing (documentation task). Depends on the sync/stability behavior
  from Tasks 1–12 being described accurately.
- Produces: a README that describes THIS image as a standalone, modern,
  high-performance rTorrent/ruTorrent/Flood container — documenting every feature
  and default that differs from the upstream base, WITHOUT mentioning binhex or
  any migration/legacy-compat detail.

**Content requirements (everything different from the base `k44sh/rutorrent` v5.2.8; do NOT mention binhex/legacy migration):**

The README must document these fork differences, gathered from the repo diff
against the base:

- **Engine versions:** libTorrent/rTorrent upgraded `0.15.3` → **`0.16.20`**;
  ruTorrent pinned to **`v5.3.11`**.
- **Flood UI:** official Node `flood` package embedded as an s6 service on port
  **3000** (`--auth none`, waits for the rtorrent socket), giving a modern
  second web UI alongside ruTorrent.
- **MaterialDesign theme** added and set as the default ruTorrent theme.
- **Bidirectional runtime settings sync** (Tasks 1–8): UI edits and hand-edited
  `rtorrent.rc` stay in sync via newest-write-wins; describe scope
  (global throttle/peer/behavior keys), the `system.file.allocate` safety
  exclusion, and the `RT_STATE_SAVE_SECONDS` cadence.
- **Large-session tuning** (600+ torrents): raised socket/preload limits, tuned
  `pieces.memory.max`, first/last-piece prioritization for media previewing,
  capped curl/socket concurrency to prevent tracker-announce overload.
- **Stability:** rtorrent supervised under s6 with a real pty via `dtach`; exit
  diagnostics captured; graceful shutdown announces `event=stopped` to trackers
  (Task 10); startup announce staggering.
- **Faster boot:** cached WAN_IP lookup; first-run-only appdata ownership pass;
  zero-stat PHP OPcache and cached ruTorrent plugin loading for instant page
  loads.
- **Nginx/PHP for big sessions:** dedicated `/RPC2` endpoint with raised SCGI
  timeouts (300s) to stop 502s on large multicalls; enlarged FastCGI buffers.
- **GeoIP2 graceful fallback:** builds/runs without MaxMind credentials (empty
  DBs are created and the GeoIP nginx block is removed if absent).
- **Fresh-install defaults:** upload rate **unlimited**, pre-allocation **off**,
  single incoming peer port **50000/tcp**, `RT_LOG_LEVEL=info`.
- **CI/build:** multi-arch image published to **GHCR**
  (`ghcr.io/mountaser/rutorrent`) via GitHub Actions.
- **Unraid:** ships a ready-to-import `rutorrent.xml` Community-Apps template.
- **New environment variables** unique to this image, documented in a table:
  `ENABLE_FLOOD`, `FLOOD_PORT`, `RT_STATE_SAVE_SECONDS`, `RT_INC_PORT` (default
  50000), `RT_PREALLOCATE_TYPE` (default 0), `WEBUI_USER`/`WEBUI_PASS`,
  `RPC2_USER`/`RPC2_PASS`.
- **Ports table** reflecting this image: `3000` Flood, `9080` ruTorrent, `5000`
  SCGI/RPC (Sonarr/Radarr), `50000/tcp` incoming peer, `9000` WebDAV,
  `6881/udp` DHT.
- **Run instructions:** `docker run`/compose example and an Unraid section, using
  this image's variables and the single-port model.
- Keep the existing base sections that still apply (WebDAV, htpasswd, custom
  plugin/theme, plugin-conf) but ensure examples use this image's paths/ports.

- [ ] **Step 1: Write the failing test**

```sh
# tests/docs/test_readme_features.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
R="$HERE/../../README.md"

# Must NOT mention binhex or migration/legacy compat
if grep -qiE 'binhex|legacy|migrat' "$R"; then echo "FAIL: README mentions binhex/legacy/migration"; exit 1; fi

# Fork feature coverage
grep -q '0.16.20' "$R" || { echo "FAIL: rtorrent version"; exit 1; }
grep -q 'v5.3.11' "$R" || { echo "FAIL: rutorrent version"; exit 1; }
grep -qi 'Flood' "$R" || { echo "FAIL: Flood"; exit 1; }
grep -qi 'MaterialDesign' "$R" || { echo "FAIL: theme"; exit 1; }
grep -qiE 'bidirectional|newest-write-wins' "$R" || { echo "FAIL: sync feature"; exit 1; }
grep -q 'ENABLE_FLOOD' "$R" || { echo "FAIL: ENABLE_FLOOD var"; exit 1; }
grep -q 'RT_STATE_SAVE_SECONDS' "$R" || { echo "FAIL: state-save var"; exit 1; }
grep -q 'RT_PREALLOCATE_TYPE' "$R" || { echo "FAIL: prealloc var"; exit 1; }
grep -q 'ghcr.io/mountaser/rutorrent' "$R" || { echo "FAIL: GHCR image"; exit 1; }
grep -q '50000' "$R" || { echo "FAIL: incoming port"; exit 1; }
grep -q '3000' "$R" || { echo "FAIL: flood port"; exit 1; }
grep -qi 'event=stopped' "$R" || { echo "FAIL: graceful stop doc"; exit 1; }
grep -q 'docker stop' "$R" || { echo "FAIL: docker stop guidance"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/docs/test_readme_features.sh`
Expected: FAIL (base README lacks these / may contain none of the fork markers).

- [ ] **Step 3: Rewrite README.md**

Replace the base "About" + "Features" sections and usage examples with content
covering every bullet in the "Content requirements" above. Concretely, the
rewritten README must include, at minimum:

1. **About:** one paragraph positioning the image as a modern, high-performance
   rTorrent + ruTorrent + Flood container on Alpine + PHP 8.4.
2. **Features** list including: rTorrent/libTorrent `0.16.20`; ruTorrent
   `v5.3.11`; embedded Flood UI (port 3000); MaterialDesign default theme;
   bidirectional runtime settings sync (newest-write-wins, `system.file.allocate`
   excluded); large-session tuning (600+ torrents); graceful tracker
   `event=stopped` shutdown; staggered announces; cached WAN_IP + OPcache +
   cached plugin loading for fast boot/page loads; `/RPC2` with 300s SCGI
   timeouts; GeoIP2 optional with graceful fallback; multi-arch GHCR image;
   Unraid template.
3. **Runtime settings sync** section: what syncs, the `system.file.allocate`
   safety exclusion, `RT_STATE_SAVE_SECONDS` cadence, and:
   "Always stop the container with `docker stop` (SIGTERM), never `docker kill`,
   so rTorrent can announce `event=stopped` to trackers."
4. **Environment variables** tables including the new vars: `ENABLE_FLOOD`,
   `FLOOD_PORT`, `RT_STATE_SAVE_SECONDS`, `RT_INC_PORT` (default `50000`),
   `RT_PREALLOCATE_TYPE` (default `0`), `WEBUI_USER`, `WEBUI_PASS`, `RPC2_USER`,
   `RPC2_PASS`, plus the retained upstream vars still in use.
5. **Ports** table: `3000` Flood, `9080` ruTorrent, `5000` SCGI/RPC,
   `50000/tcp` incoming peer, `9000` WebDAV, `6881/udp` DHT.
6. **Usage:** a `docker run` example and a compose example using
   `ghcr.io/mountaser/rutorrent`, plus an **Unraid** subsection referencing
   `rutorrent.xml`.
7. Retain still-relevant upstream sections (WebDAV, `.htpasswd` population,
   override/add plugin & theme, edit plugin config) with paths/ports aligned to
   this image.

Do NOT include any binhex, legacy, or migration wording anywhere in the file.

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/docs/test_readme_features.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add README.md tests/docs/test_readme_features.sh
git commit -m "docs: revamp README to document fork features, defaults, and usage"
```

---

## Task 14: Full test-suite runner + final integration check

**Files:**
- Create: `tests/run_all.sh`
- Test: itself

**Interfaces:**
- Produces: `tests/run_all.sh` that runs every `tests/**/test_*.sh` and reports pass/fail.

- [ ] **Step 1: Write the runner**

```sh
# tests/run_all.sh
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0
for t in $(find "$HERE" -name 'test_*.sh' | sort); do
  printf '== %s\n' "$t"
  if sh "$t"; then :; else fail=1; fi
done
[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
```

- [ ] **Step 2: Run it**

Run: `sh tests/run_all.sh`
Expected: every test prints `PASS`, final `ALL PASS`.

- [ ] **Step 3: Static lint of shell (no bashisms)**

Run: `find rootfs/usr/local/bin -name '*.sh' -exec sh -n {} \;`
Expected: no syntax errors. If `shellcheck` is available:
`shellcheck -s sh rootfs/usr/local/bin/rtstate-sync.sh` (advisory).

- [ ] **Step 4: Commit**

```bash
git add tests/run_all.sh
git commit -m "test: add aggregate test runner for rtstate sync and config suite"
```

---

## Self-Review Notes (author)

- **Spec coverage:** §4.2 arbitration → Task 5; §4.3 hardened snapshot → Task 6;
  §4.4 whitelist → Task 1; §4.5 crash-fix → Tasks 7,9; §4.6 graceful stop →
  Task 10; §4.7 faster boot → Task 11; §4.8 fresh-install defaults → Task 8;
  §6 template → Task 12; §7 cleanup → Task 12; §8 testing → Tasks 1-14;
  fork-feature README (user request) → Task 13.
- **README scope:** Task 13 documents ALL fork differences vs base
  `k44sh/rutorrent` v5.2.8 (versions, Flood, MaterialDesign, sync, tuning,
  stability, GHCR, Unraid template, new env vars, ports) and forbids any
  binhex/legacy/migration wording via a negative grep test.
- **allocate exclusion** enforced in Tasks 3 and 6 with explicit negative tests.
- **Type consistency:** helper subcommands (`arbitrate`, `snapshot`, `__keys`,
  `__validate`, `__set_rc`, `__apply_state`, `__seed_state`) named consistently
  across tasks; `@RC_BASENAME@` produced in Task 7, substituted in Task 8.
- **RPC transport (resolved):** the image has NO `xmlrpc2scgi` binary. Both
  `_rt_get` (Task 6) and the graceful-stop `finish` script (Task 10) query
  rtorrent via `curl` XMLRPC-over-HTTP on the local no-auth health port
  `127.0.0.1:${XMLRPC_HEALTH_PORT}` — the exact mechanism the existing
  `healthcheck` already uses (`configurations.sh:125`). `@XMLRPC_HEALTH_PORT@` is
  substituted into `.rtlocal.rc` in Task 8. No new binary needed; `curl` is
  already installed.
- **Also verify at execution:** `system.shutdown` availability on rtorrent
  0.16.20; fallback documented in Task 10.
```
