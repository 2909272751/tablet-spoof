#!/system/bin/sh
# ============================================================================
# tablet-spoof / probe-kv-layout.sh   (run AS ROOT)
# ============================================================================
# READ-ONLY. Dumps the MMKV K/V record layout around the keys of interest so we
# can implement a byte-exact writer.
#
# MMKV file format (mmap, little-endian):
#   [0..3]   actualSize   uint32
#   then a sequence of records:
#     keyLen     : varint32
#     key bytes
#     valueLen   : varint32   (top bit set => value is a string/bytes)
#     value bytes
#   terminated by a record whose varint32 == 0
#   [end..end+4] CRC32 uint32, padded to 4-byte alignment (stored in .crc file
#                for MMKV >= 1.2 as a separate 4096-byte file holding the LE crc)
#
# .crc file: first 4 bytes = little-endian CRC32 of the whole data file with the
#            CRC field itself treated as zero. (MMKV uses its own crc32 impl.)
# ============================================================================

PKG=com.tencent.wework
BASE="/data/data/$PKG/files/mmkv/com.tencent.pb.common"
CRC="$BASE.crc"

echo "=== file sizes ==="
ls -la "$BASE" "$CRC"
echo ""

echo "=== header: first 4 bytes (uint32 actualSize, LE) ==="
od -An -tu4 -N4 "$BASE" | sed 's/^/  actualSize =/'
echo ""

echo "=== full hexdump (first 512 bytes) ==="
od -Ax -tx1z -N512 "$BASE" | sed 's/^/  /'
echo ""

echo "=== printable strings with byte OFFSETS ==="
# -t d1 gives decimal byte offsets, which lets us compute record positions.
strings -a -t d "$BASE" 2>/dev/null | sed 's/^/  /'
echo ""

echo "=== which strings sit in the first 128 bytes (likely small values) ==="
strings -a -t d -n 1 "$BASE" 2>/dev/null | awk '$1 < 200 {print "  "$0}'
echo ""

echo "=== .crc file content ==="
od -Ax -tx1 -N16 "$CRC" | sed 's/^/  /'
echo ""

echo "=== locate our two keys precisely ==="
for k in KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE local_save_pad_type_android; do
  echo "  key: $k"
  off=$(strings -a -t d "$BASE" 2>/dev/null | grep -F "$k" | head -1 | awk '{print $1}')
  if [ -n "$off" ]; then
    echo "    first offset: $off"
    start=$((off - 8)); [ "$start" -lt 0 ] && start=0
    echo "    context bytes [$start .. $((off+80))]:"
    dd if="$BASE" bs=1 skip=$start count=96 2>/dev/null | od -Ax -tx1z | sed 's/^/      /'
  else
    echo "    not found as a string"
  fi
  echo ""
done

echo "=== all distinct key-ish strings, sorted by offset ==="
strings -a -t d "$BASE" 2>/dev/null | sort -n | head -60 | sed 's/^/  /'
echo ""

echo "=== md5 of current state (baseline for change detection) ==="
md5sum "$BASE" "$CRC" 2>/dev/null | sed 's/^/  /'
echo ""
echo "=== read-only dump complete ==="
