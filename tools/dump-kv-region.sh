#!/system/bin/sh
# ============================================================================
# tablet-spoof / dump-kv-region.sh  (AS ROOT, READ-ONLY)
# ============================================================================
# Dump exact byte regions around the two keys of interest, and decode the MMKV
# record framing (varint keyLen / key / varint valueLen / value).
#
# Note: `strings -t d` reports the offset of the FIRST character of its match,
# which for an MMKV key is the byte AFTER the varint key-length prefix. So the
# varint lives at (offset-1) when the key is < 128 bytes.
# ============================================================================

BASE=/data/data/com.tencent.wework/files/mmkv/com.tencent.pb.common

hexdump_region() {
  _start=$1; _len=$2
  dd if="$BASE" bs=1 skip=$_start count=$_len 2>/dev/null | od -An -tx1 -v | sed 's/^/    /'
}

show() {
  _name="$1"; _off="$2"
  echo "=== $_name ==="
  echo "  key string starts at offset $_off (varint len at $((_off-1)))"
  _s=$((_off-1)); [ "$_s" -lt 0 ] && _s=0
  echo "  --- raw bytes [$_s .. $((_off+40))] ---"
  hexdump_region "$_s" 48
  echo "  --- byte at $_off-1 (the varint keyLen) ---"
  dd if="$BASE" bs=1 skip=$_s count=1 2>/dev/null | od -An -tu1 | sed 's/^/      keyLen =/'
  echo "  --- byte at (keyEnd) = varint valueLen ---"
  _vlen_pos=$((_off + 25))
  dd if="$BASE" bs=1 skip=$_vlen_pos count=1 2>/dev/null | od -An -tu1 | sed 's/^/      valueLen =/'
  echo ""
}

# --- the two keys ------------------------------------------------------------
# KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE : len 33 -> 0x21, seen at string offset 2856
show "KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE (len 33)" 2856
show "local_save_pad_type_android (len 25)" 1527

echo "=== the tail region 7080..7130 (local_save_pad_type_android occurrences) ==="
hexdump_region 7080 56
echo ""

echo "=== all KV_ANDROID_PAD_* keys: offset, len byte, value byte ==="
for off in 1957 2260 2344 2856; do
  echo "  --- offset $off ---"
  _s=$((off-1))
  printf "      keyLen  : "; dd if="$BASE" bs=1 skip=$_s count=1 2>/dev/null | od -An -tu1
  printf "      key     : "; dd if="$BASE" bs=1 skip=$off count=40 2>/dev/null | tr -d '\0' | sed 's/[^[:print:]]//g'
  echo ""
done
echo ""

echo "=== decode: is there an MMKV terminator (00) before actualSize? ==="
echo "  header actualSize (bytes 0..3):"
od -An -tu4 -N4 "$BASE" | sed 's/^/    /'
echo "  bytes around actualSize (offset 5900..5930):"
hexdump_region 5900 32
echo ""

echo "=== value bytes for the QR_CODE key, one by one ==="
echo "  keyLen@2855, key@2856..2888 (33 bytes), valueLen@2889, value@2890"
printf "  byte[2889] valueLen = "; dd if="$BASE" bs=1 skip=2889 count=1 2>/dev/null | od -An -tu1
echo "  bytes[2890..2900]:"
hexdump_region 2890 11
echo ""

echo "=== value bytes for local_save_pad_type_android (first, @1527) ==="
echo "  keyLen@1526, key@1527..1551 (25 bytes), valueLen@1552, value@1553"
printf "  byte[1552] valueLen = "; dd if="$BASE" bs=1 skip=1552 count=1 2>/dev/null | od -An -tu1
echo "  bytes[1553..1560]:"
hexdump_region 1553 8
echo ""
echo "=== done ==="
