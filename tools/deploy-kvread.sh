#!/system/bin/sh
# Deploy the KV reader probe, hash-verified.
log() { echo "[kvread-deploy] $*"; }
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
NEW=/data/local/tmp/kvread.so
[ -f "$NEW" ] || { log "no build"; exit 1; }

log "hash-before: $(md5sum "$SO" 2>/dev/null | awk '{print $1}')  size=$(stat -c %s "$SO" 2>/dev/null)"
log "payload    : $(md5sum "$NEW" | awk '{print $1}')  size=$(stat -c %s "$NEW")"
cp "$NEW" "$SO"; chmod 644 "$SO"
log "hash-after : $(md5sum "$SO" | awk '{print $1}')  size=$(stat -c %s "$SO")"
echo ""
log "the native module currently has a disable marker:"
[ -f /data/adb/modules/tablet-spoof-native/disable ] && log "  PRESENT (module disabled -> Zygisk will NOT load the payload!)" || log "  absent"
log ""
log "  *** A disabled module's payload is NOT loaded, so this probe would never run."
log "      Removing the marker for the experiment; it will be restored afterwards. ***"
rm -f /data/adb/modules/tablet-spoof-native/disable
log "  marker now: $([ -f /data/adb/modules/tablet-spoof-native/disable ] && echo PRESENT || echo absent)"
echo ""
log "REBOOT REQUIRED."
