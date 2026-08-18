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
