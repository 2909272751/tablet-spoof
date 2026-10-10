#!/system/bin/sh
# Deploy the final clean payload with hash discipline.
log() { echo "[deploy-final] $*"; }
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
NEW=/data/local/tmp/final.so

[ -f "$NEW" ] || { log "no build"; exit 1; }

log "hash-before (currently installed):"
md5sum "$SO" 2>/dev/null | sed 's/^/  /'
log "payload to deploy:"
md5sum "$NEW" | sed 's/^/  /'
log "  size: $(stat -c %s "$NEW")"
echo ""

cp "$NEW" "$SO"
chmod 644 "$SO"

log "hash-after-deploy:"
md5sum "$SO" | sed 's/^/  /'
log "  size: $(stat -c %s "$SO")"
echo ""

log "=== verify no scaffolding in the deployed artifact ==="
for s in MEASURE ArtProbe ts_probe nativeifyMethod; do
  strings "$SO" | grep -q "$s" && log "  PRESENT (bad): $s" || log "  absent: $s"
done
log "  expected markers:"
for s in RESOLVED HOOK_MISS ts_native; do
  strings "$SO" | grep -q "$s" && log "    has $s" || log "    MISSING $s"
done
echo ""
log "REBOOT REQUIRED for Zygisk to load it."
