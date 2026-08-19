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

        import hashlib
        with open(tf, 'rb') as f:
            raw = f.read()
        idx_info = raw.find(b'4:info')
        if idx_info == -1:
            continue
        info_val, _ = bdecode(raw[idx_info+6:])
        
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

        sep = "&" if "?" in announce else "?"
        url = f"{announce}{sep}info_hash={quoted_hash}&peer_id=-RT0160-000000000000&port={port}&uploaded=0&downloaded=0&left=0&event=stopped"

        req = urllib.request.Request(url, headers={'User-Agent': 'rTorrent/0.16.20'})
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass
PYTHON_EOF

exit 0
