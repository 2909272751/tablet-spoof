#!/system/bin/sh
# ============================================================================
# tablet-spoof / probe-mmkkv.sh   (run AS ROOT)
# ============================================================================
# Read-only reconnaissance of the WeCom MMKV store that carries the two tablet
# signals:
#   * key  KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE   (bool switch)
#   * key  local_save_pad_type_android         (cached pad verdict)
# in /data/data/com.tencent.wework/files/mmkv/com.tencent.pb.common
#
# This script WRITES NOTHING. It only lists and reads.
# ============================================================================

PKG=com.tencent.wework
[ -n "$1" ] && PKG="$1"

DATA="/data/data/$PKG"
echo "=============================================="
echo " MMKV probe for $PKG"
echo "=============================================="
echo ""

echo "--- files/file_config_build_model (correction #1 check) ---"
F="$DATA/files/file_config_build_model"
if [ -f "$F" ]; then
  echo "  EXISTS: $F"
  ls -la "$F"
  echo "  content: [$(cat "$F" 2>/dev/null)]"
  echo "  hexdump:"
  od -c "$F" 2>/dev/null | head -5 | sed 's/^/    /'
else
  echo "  NOT FOUND at $F"
fi
echo ""

echo "--- mmkv dir listing ---"
MMKV="$DATA/files/mmkv"
if [ -d "$MMKV" ]; then
  echo "  dir: $MMKV"
  ls -la "$MMKV"
else
  echo "  NO mmkv dir at $MMKV"
  echo "  searching for mmkv anywhere under $DATA ..."
  find "$DATA" -maxdepth 4 -iname 'mmkv*' 2>/dev/null | sed 's/^/    /'
  echo "  searching for com.tencent.pb.common ..."
  find "$DATA" -maxdepth 5 -name 'com.tencent.pb.common*' 2>/dev/null | sed 's/^/    /'
fi
echo ""

echo "--- the MMKV data + crc files ---"
BASE="$MMKV/com.tencent.pb.common"
for f in "$BASE" "$BASE.crc"; do
  if [ -f "$f" ]; then
    echo "  $f"
    ls -la "$f" | sed 's/^/    /'
  else
    echo "  (absent) $f"
  fi
done
echo ""

echo "--- grep the MMKV blob for the two keys (strings only) ---"
if [ -f "$BASE" ]; then
  for k in KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE local_save_pad_type_android; do
    n=$(strings -a "$BASE" 2>/dev/null | grep -c "$k")
    echo "  '$k' occurrences in blob: ${n:-0}"
  done
  echo ""
  echo "  all KV_ keys visible in blob:"
  strings -a "$BASE" 2>/dev/null | grep -o 'KV_[A-Z_0-9]*' | sort -u | head -40 | sed 's/^/    /'
  echo ""
  echo "  pad-related strings in blob:"
  strings -a "$BASE" 2>/dev/null | grep -i 'pad\|android_pad\|device_type' | head -20 | sed 's/^/    /'
else
  echo "  (no blob to grep)"
fi
echo ""

echo "--- other MMKV stores in the app ---"
if [ -d "$MMKV" ]; then
  echo "  files present:"
  ls -1 "$MMKV" 2>/dev/null | sed 's/^/    /'
fi
echo ""

echo "--- is the app running right now? ---"
PID=$(pidof "$PKG" 2>/dev/null)
if [ -n "$PID" ]; then
  echo "  RUNNING (pid $PID) -- any write would be unsafe"
else
  echo "  NOT running -- safe window for a write"
fi
echo ""
echo "=============================================="
echo " probe done (read-only; nothing was modified)"
echo "=============================================="
