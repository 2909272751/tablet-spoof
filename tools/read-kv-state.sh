#!/system/bin/sh
# ============================================================================
# READ THE ACTUAL STATE, not a hash. Root-side, read-only, no reboot.
# ============================================================================
# WHY: I treated an MMKV md5 difference (1d9413f9... -> 2cd508ab...) as evidence
# of something meaningful. It is not, for two reasons:
#   1. the baseline was taken HOURS earlier across many app launches -- a store
#      that DIDN'T change over that span would be the surprising result, so the
#      difference may say nothing;
#   2. a hash tells you "something changed", never WHAT -- which is why I could
#      not act on it.
# A baseline is only a control if you have shown it is stable. We never did.
#
# So: read the values directly, and test the store's IDLE STABILITY (two reads
# seconds apart with no activity).
# ============================================================================
log() { echo "[kv-read] $*"; }
P=/data/data/com.tencent.wework
BASE="$P/files/mmkv/com.tencent.pb.common"

log "=== 1. idle stability: two md5s seconds apart, no app activity ==="
log "  ensure the app is not running so nothing is writing:"
am force-stop com.tencent.wework 2>/dev/null
sleep 3
log "  wework pid: $(pidof com.tencent.wework 2>/dev/null || echo none)"
H1=$(md5sum "$BASE" 2>/dev/null | awk '{print $1}')
S1=$(stat -c %s "$BASE" 2>/dev/null)
sleep 6
H2=$(md5sum "$BASE" 2>/dev/null | awk '{print $1}')
S2=$(stat -c %s "$BASE" 2>/dev/null)
log "  read 1: md5=$H1 size=$S1"
log "  read 2: md5=$H2 size=$S2"
if [ "$H1" = "$H2" ]; then
  log "  => STABLE while idle. (So a change observed during activity IS meaningful.)"
else
  log "  => *** CHANGES WITH NO ACTIVITY *** md5 comparisons are WORTHLESS as a control."
fi
echo ""

log "=== 2. the recorded baseline vs now ==="
log "  baseline (early session): 1d9413f9173f29e2c6f408f7c5bbfc12"
log "  now:                      $H1"
log "  NOTE: the baseline predates many launches; a difference here is NOT evidence"
log "        of anything on its own. Recorded for completeness only."
echo ""

log "=== 3. THE ACTUAL VALUES (what a hash could never tell us) ==="
log "  file_config_build_model: [$(cat "$P/files/file_config_build_model" 2>/dev/null)]"
echo ""
log "  MMKV key presence (we can locate keys; values need decoding):"
for k in KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE local_save_pad_type_android; do
  N=$(grep -c "$k" "$BASE" 2>/dev/null)
  log "    $k : $N occurrence(s)"
done
echo ""

log "  Attempt the byte-level read of local_save_pad_type_android (latest wins):"
log "    (the store is append-style: the LAST occurrence is the effective value)"
OFFS=$(strings -a -t d "$BASE" 2>/dev/null | grep -F 'local_save_pad_type_android' | awk '{print $1}')
LAST=$(echo "$OFFS" | tail -1)
log "    occurrences at offsets: $(echo $OFFS | tr '\n' ' ')"
if [ -n "$LAST" ]; then
  # The record layout we decoded earlier: keyLen byte, key, valueLen byte, value
  KEYLEN=$(printf '%d' "0x$(dd if="$BASE" bs=1 skip=$((LAST-1)) count=1 2>/dev/null | od -An -tx1 | tr -d ' ')" 2>/dev/null)
  VLENPOS=$((LAST + 25))
  VLEN=$(printf '%d' "0x$(dd if="$BASE" bs=1 skip=$VLENPOS count=1 2>/dev/null | od -An -tx1 | tr -d ' ')" 2>/dev/null)
  log "    last occurrence offset=$LAST  keyLenByte=$KEYLEN  valueLenByte=$VLEN"
  log "    value bytes:"
  dd if="$BASE" bs=1 skip=$((VLENPOS+1)) count=8 2>/dev/null | od -An -tx1 | sed 's/^/      /'
  log "    (0x02 = wire-type int; following byte is the value)"
fi
echo ""

log "=== 4. KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE value byte ==="
KLAST=$(strings -a -t d "$BASE" 2>/dev/null | grep -F 'KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE' | awk '{print $1}' | tail -1)
if [ -n "$KLAST" ]; then
  log "  key at offset $KLAST (33-char key)"
  log "  value byte (at offset+33+1):"
  dd if="$BASE" bs=1 skip=$((KLAST+34)) count=4 2>/dev/null | od -An -tx1 | sed 's/^/    /'
  log "  (bool TRUE typically encodes as 0x01)"
else
  log "  key not located"
fi
