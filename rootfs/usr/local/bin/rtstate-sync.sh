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
