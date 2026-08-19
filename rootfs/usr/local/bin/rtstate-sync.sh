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
    if [ -s "$rc" ] && [ "$(tail -c 1 "$rc" 2>/dev/null || true)" != "$(printf '\n')" ]; then
      printf '\n' >> "$rc"
    fi
    printf '%s = %s\n' "$key" "$val" >> "$rc"
  fi
}

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

_has_keys() { grep -Eq '^[[:space:]]*[a-z]' "$1" 2>/dev/null; }
_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

rtstate_arbitrate() {
  rc="$1"; st="$2"
  [ -f "$rc" ] || : > "$rc"
  if [ ! -f "$st" ] || ! _has_keys "$st"; then
    _log "[arbitrate] No valid UI state found. Seeding .rtstate.rc from rtorrent.rc"
    rtstate_seed_from_rc "$rc" "$st"; return 0
  fi
  rc_m=$(_mtime "$rc"); st_m=$(_mtime "$st")
  if [ "$rc_m" -gt "$st_m" ]; then
    _log "[arbitrate] rtorrent.rc is newer than .rtstate.rc. Config wins, updating .rtstate.rc"
    rtstate_seed_from_rc "$rc" "$st"            # config wins
  else
    _log "[arbitrate] .rtstate.rc is newer than rtorrent.rc. UI wins, updating rtorrent.rc"
    cp -f "$rc" "${rc}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    rtstate_apply_state_to_rc "$rc" "$st"       # UI wins
    rtstate_seed_from_rc "$rc" "$st"            # converge
  fi
}

_log() {
  msg="$1"
  ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "boot")
  line="[${ts}] ${msg}"
  echo "${line}"
  log_file="${RTSTATE_LOG_FILE:-${CONFIG_PATH:-/config}/rtorrent/log/rtstate-sync.log}"
  log_dir=$(dirname "${log_file}")
  if [ -d "${log_dir}" ] || mkdir -p "${log_dir}" 2>/dev/null; then
    printf '%s\n' "${line}" >> "${log_file}" 2>/dev/null || true
  fi
}

# Query one rtorrent getter via XMLRPC-over-HTTP (same path as healthcheck).
# Returns the raw <value> text (int or string). Overridable for tests.
_rt_get() {
  getter="$1"; url="$2"; kind="${3:-int}"
  if [ -n "${RTSTATE_GET_CMD:-}" ]; then
    "$RTSTATE_GET_CMD" "$getter"; return $?
  fi
  body="<?xml version=\"1.0\"?><methodCall><methodName>${getter}</methodName><params></params></methodCall>"
  resp=$(curl -s --connect-timeout 2 --max-time 3 -H "Content-Type: text/xml" --data "${body}" "${url}" 2>/dev/null || true)
  # Extract the scalar inside <value><i8>|<i4>|<int>|<string>...
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
      *.max_rate.set_kb)
        val=$(( raw / 1024 ))
        # Normalize any rate >= 4194300 (rTorrent max/unlimited representation) to 0
        [ "$val" -ge 4194300 ] 2>/dev/null && val=0
        ;;
    esac
    rtstate_validate "$kind" "$val" || continue

    # Check if value changed compared to current state file
    old_line=$(grep -E "^[[:space:]]*$(printf '%s' "$ckey" | sed -e 's/[.[\*^$]/\\&/g')[[:space:]]*=" "$st" 2>/dev/null | tail -n1 || true)
    old_val=""
    if [ -n "$old_line" ]; then
      old_val=$(printf '%s' "$old_line" | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')
    fi
    if [ -n "$old_val" ] && [ "$old_val" != "$val" ]; then
      _log "[snapshot] Changed ${ckey}: ${old_val} -> ${val} (saved to .rtstate.rc & synced to rtorrent.rc)"
    fi

    printf '%s = %s\n' "$ckey" "$val" >> "$tmp"
  done
  mv -f "$tmp" "$st"
  # Propagate to RC (allocate excluded by apply_state).
  rtstate_apply_state_to_rc "$rc" "$st"
}

case "${1:-}" in
  __keys) rtstate_keys ;;
  __validate) shift; rtstate_validate "$@" ;;
  __set_rc) shift; rtstate_set_rc "$@" ;;
  __apply_state) shift; rtstate_apply_state_to_rc "$@" ;;
  __seed_state) shift; rtstate_seed_from_rc "$@" ;;
  __log) shift; _log "$@" ;;
  arbitrate) shift; rtstate_arbitrate "$@" ;;
  snapshot) shift; rtstate_snapshot "$@" ;;
  *) echo "usage: rtstate-sync.sh {arbitrate|snapshot} ..." >&2; exit 2 ;;
esac
