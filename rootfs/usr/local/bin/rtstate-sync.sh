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

case "${1:-}" in
  __keys) rtstate_keys ;;
  __validate) shift; rtstate_validate "$@" ;;
  __set_rc) shift; rtstate_set_rc "$@" ;;
  __apply_state) shift; rtstate_apply_state_to_rc "$@" ;;
  *) echo "usage: rtstate-sync.sh {arbitrate|snapshot} ..." >&2; exit 2 ;;
esac
