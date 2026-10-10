#!/system/bin/sh
# Deploy the READ-ONLY stability probe, hash-verified.
log() { echo "[deploy-stable] $*"; }
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
NEW=/data/local/tmp/stable.so

[ -f "$NEW" ] || { log "no build"; exit 1; }

log "hash-before: $(md5sum "$SO" 2>/dev/null | awk '{print $1}')"
log "payload    : $(md5sum "$NEW" | awk '{print $1}')  size=$(stat -c %s "$NEW")"
cp "$NEW" "$SO"; chmod 644 "$SO"
log "hash-after : $(md5sum "$SO" | awk '{print $1}')  size=$(stat -c %s "$SO")"
echo ""
log "=== assert the deployed artifact CANNOT write app KV state ==="
for s in "H(" KV_ANDROID_PAD setDeviceType; do
  strings "$SO" | grep -q -- "$s" && log "  PRESENT (bad): $s" || log "  absent: $s"
done
log "  markers present:"
for s in STABLE ts_stable; do
  strings "$SO" | grep -q "$s" && log "    has $s" || log "    MISSING $s"
done
echo ""
log "REBOOT REQUIRED."
