#!/system/bin/sh
# Compare the SHIPPED .so (in the zip, 14952 B) against the CURRENTLY DEPLOYED one
# (20352 B) and establish which is the right thing to ship.
#
# The shipped one is from 21:28 -- BEFORE the CALL/KV/TIMELINE measurement code was
# added. The deployed one has that code. Neither has a hook.
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
ZIPSO=/data/local/tmp/tsx/zigisk/arm64-v8a.so
[ -f "$ZIPSO" ] || ZIPSO=/data/local/tmp/tsx/zygisk/arm64-v8a.so

log() { echo "[compare] $*"; }

log "=== the two artifacts ==="
log "  shipped in zip : $(stat -c %s "$ZIPSO" 2>/dev/null) bytes  md5=$(md5sum "$ZIPSO" 2>/dev/null | awk '{print $1}')"
log "  now deployed   : $(stat -c %s "$SO" 2>/dev/null) bytes  md5=$(md5sum "$SO" 2>/dev/null | awk '{print $1}')"
echo ""

log "=== marker comparison (what each can do) ==="
printf '  %-16s %-10s %-10s\n' "marker" "zip" "deployed"
for s in RESOLVED HOOK_MISS ts_native CALL TIMELINE PROBE-FINAL KV_ANDROID_PAD MEASURE; do
  A=$(strings "$ZIPSO" 2>/dev/null | grep -c -- "$s")
  B=$(strings "$SO" 2>/dev/null | grep -c -- "$s")
  printf '  %-16s %-10s %-10s\n' "$s" "$A" "$B"
done
echo ""

log "=== which is the CORRECT thing to ship? ==="
log "  The zip build (14952): clean resolver -- resolves the method and records"
log "    RESOLVED / HOOK_MISS to ts_native.log. NO measurement scaffolding, NO hook."
log "  The deployed build (20352): the same PLUS the CALL/TIMELINE/PROBE-FINAL"
log "    measurement code, which was diagnostic and is now spent."
log ""
log "  => The zip build is the RIGHT one to ship. The measurement code was"
log "     scaffolding for experiments that have concluded; shipping it would"
log "     leave diagnostic writes in a user-facing module."
echo ""

log "=== confirm NEITHER build can write ART state or app KV ==="
for s in nativeifyMethod setDeviceType; do
  A=$(strings "$ZIPSO" 2>/dev/null | grep -c -- "$s")
  B=$(strings "$SO" 2>/dev/null | grep -c -- "$s")
  printf '  %-18s zip=%s deployed=%s\n' "$s" "$A" "$B"
done
VV=$(strings "$ZIPSO" 2>/dev/null | grep -c 'KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE')
log "  zip contains the KV key constant: $VV  (0 = cannot write that KV)"
