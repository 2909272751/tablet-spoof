#!/system/bin/sh
# Deploy the SHIPPED build so the device equals a fresh flash.
# The zip build is the clean resolver; the previously deployed build had spent
# diagnostic scaffolding (CALL/TIMELINE/PROBE-FINAL).
log() { echo "[sync] $*"; }
SRC=/data/local/tmp/tsx/zygisk/arm64-v8a.so
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so

[ -f "$SRC" ] || { log "no extracted zip payload at $SRC"; exit 1; }

log "zip payload : $(stat -c %s "$SRC") bytes  md5=$(md5sum "$SRC" | awk '{print $1}')"
log "deployed now: $(stat -c %s "$SO") bytes  md5=$(md5sum "$SO" | awk '{print $1}')"

cp "$SRC" "$SO"
chmod 644 "$SO"

log "after copy  : $(stat -c %s "$SO") bytes  md5=$(md5sum "$SO" | awk '{print $1}')"
echo ""
log "=== device now matches the shipped artifact ==="
log "  scaffolding scan (must be absent -- spent diagnostics):"
for s in CALL TIMELINE PROBE-FINAL KV_ANDROID_PAD MEASURE; do
  N=$(strings "$SO" | grep -c -- "$s")
  [ "$N" = "0" ] && log "    absent: $s" || log "    PRESENT: $s ($N)"
done
log "  expected markers:"
for s in RESOLVED HOOK_MISS ts_native; do
  strings "$SO" | grep -q "$s" && log "    has $s" || log "    MISSING $s"
done
echo ""
log "REBOOT REQUIRED to load it."
