#!/system/bin/sh
# ============================================================================
# tablet-spoof / decode-mmkv.sh  (AS ROOT, READ-ONLY)
# ============================================================================
# Full MMKV record-stream decoder, written as a self-contained shell script.
# Decodes EVERY record from offset 4 up to actualSize and prints
# (offset, keyLen, key, valueLen, valueHex).
#
# MMKV framing (little-endian, after the 4-byte actualSize header):
#   keyLen   : varint32
#   key      : keyLen bytes
#   valueLen : varint32   (raw byte count, does NOT include the wire-type byte)
#   value    : valueLen bytes
#   ... repeat until a zero-length key (varint 0) or actualSize is reached.
#
# MMKV varint: 7 bits per byte, little-endian, high bit = continuation.
# ============================================================================

BASE=/data/data/com.tencent.wework/files/mmkv/com.tencent.pb.common

# Read 1 byte at an offset as an unsigned decimal. (busybox od)
rd1() {
  dd if="$BASE" bs=1 skip="$1" count=1 2>/dev/null | od -An -tu1 | tr -d ' \n'
}

# Read N bytes at an offset as space-separated hex.
rdn_hex() {
  _s=$1; _n=$2
  [ "$_n" -le 0 ] && return 0
  dd if="$BASE" bs=1 skip="$_s" count="$_n" 2>/dev/null | od -An -tx1 -v | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'
}

# Read N bytes at an offset as printable text (control chars -> '.').
rdn_txt() {
  _s=$1; _n=$2
  [ "$_n" -le 0 ] && return 0
  dd if="$BASE" bs=1 skip="$_s" count="$_n" 2>/dev/null | tr -c '[:print:]' '.'
}

# Decode a varint starting at offset $1. Echoes "<value> <bytes_consumed>".
rdvarint() {
  _pos=$1
  _val=0
  _shift=0
  _used=0
  while [ "$_used" -lt 5 ]; do
    _b=$(rd1 "$_pos")
    [ -z "$_b" ] && { echo "0 0"; return; }
    # value |= (b & 0x7f) << shift   -- shell has no bitwise on strings, but
    # busybox ash supports $(( )) arithmetic with << and &.
    _val=$(( _val | ((_b & 127) << _shift) ))
    _used=$((_used + 1))
    _pos=$((_pos + 1))
    [ "$_b" -lt 128 ] && break
    _shift=$((_shift + 7))
  done
  echo "$_val $_used"
}

echo "=== MMKV full decode: $BASE ==="
ASZ=$(od -An -tu4 -N4 "$BASE" | tr -d ' \n')
echo "  actualSize (header) = $ASZ"
echo "  file size           = $(stat -c %s "$BASE" 2>/dev/null || wc -c < "$BASE")"
echo ""

POS=4
N=0
echo "  idx  off    kLen key                                    vLen value"
echo "  ---  -----  ---- -------------------------------------- ---- ------------------------------"
while [ "$POS" -lt "$ASZ" ]; do
  R=$(rdvarint "$POS")
  KLEN=$(echo "$R" | cut -d' ' -f1)
  KUSED=$(echo "$R" | cut -d' ' -f2)
  [ "$KUSED" = "0" ] && break
  POS_KEY=$((POS + KUSED))

  if [ "$KLEN" -eq 0 ]; then
    echo "  --- terminator at $POS ---"
    break
  fi

  KEY=$(rdn_txt "$POS_KEY" "$KLEN")
  POS_VLEN=$((POS_KEY + KLEN))
  R2=$(rdvarint "$POS_VLEN")
  VLEN=$(echo "$R2" | cut -d' ' -f1)
  VUSED=$(echo "$R2" | cut -d' ' -f2)
  POS_VAL=$((POS_VLEN + VUSED))

  VHEX=$(rdn_hex "$POS_VAL" "$VLEN")
  # keep the display bounded
  case ${#VHEX} in
    *[!0-9]*) ;; esac
  if [ "${#VHEX}" -gt 60 ]; then VHEX="$(echo "$VHEX" | cut -c1-57)..."; fi

  N=$((N + 1))
  printf "  %-3s  %-5s  %-4s %-38s %-4s %s\n" "$N" "$POS" "$KLEN" "$KEY" "$VLEN" "$VHEX"

  POS=$((POS_VAL + VLEN))
  [ "$N" -gt 400 ] && { echo "  (truncated at 400 records)"; break; }
done
echo ""
echo "  total records decoded: $N"
echo "  final position: $POS (actualSize $ASZ)"
echo ""
echo "=== the records we care about ==="
POS=4; N=0
while [ "$POS" -lt "$ASZ" ]; do
  R=$(rdvarint "$POS"); KLEN=$(echo "$R" | cut -d' ' -f1); KUSED=$(echo "$R" | cut -d' ' -f2)
  [ "$KUSED" = "0" ] && break
  POS_KEY=$((POS + KUSED))
  [ "$KLEN" -eq 0 ] && break
  KEY=$(rdn_txt "$POS_KEY" "$KLEN")
  POS_VLEN=$((POS_KEY + KLEN))
  R2=$(rdvarint "$POS_VLEN"); VLEN=$(echo "$R2" | cut -d' ' -f1); VUSED=$(echo "$R2" | cut -d' ' -f2)
  POS_VAL=$((POS_VLEN + VUSED))
  case "$KEY" in
    *PAD*|*pad*)
      echo "  off=$POS keyLen=$KLEN key='$KEY' valLen=$VLEN valOff=$POS_VAL"
      echo "        value hex: $(rdn_hex "$POS_VAL" "$VLEN")"
      ;;
  esac
  POS=$((POS_VAL + VLEN))
  N=$((N + 1))
  [ "$N" -gt 400 ] && break
done
echo ""
echo "=== .crc file ==="
CRCF=/data/data/com.tencent.wework/files/mmkv/com.tencent.pb.common.crc
od -An -tx1 -v -N16 "$CRCF" | sed 's/^/  /'
echo ""
echo "=== done ==="
