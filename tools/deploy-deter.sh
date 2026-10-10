#!/system/bin/sh
# Deploy the determination payload WITH hash discipline, and record the read script.
# The invariant: hashes taken before deploy, after deploy, and after boot must all
# match, or the result is not attributable to this artifact.
log() { echo "[deploy] $*"; }
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
NEW=/data/local/tmp/det.so

[ -f "$NEW" ] || { log "no build at $NEW"; exit 1; }

log "hash of the payload to deploy:"
md5sum "$NEW" | sed 's/^/  /'
log "hash currently installed (hash-before):"
md5sum "$SO" | sed 's/^/  /'
echo ""

log "=== deploy ==="
cp "$NEW" "$SO"
chmod 644 "$SO"
log "installed hash (hash-after-deploy):"
md5sum "$SO" | sed 's/^/  /'
log "size: $(stat -c %s "$SO")"
echo ""

log "=== verify the deployed artifact is the measurement build ==="
for s in MEASURE DET ts_hook; do
  if strings "$SO" | grep -q "$s"; then log "  present: $s"; else log "  MISSING: $s"; fi
done
log "  must NOT contain hook code:"
if strings "$SO" | grep -q 'nativeifyMethod'; then
  log "    WARNING: nativeifyMethod symbol present"
else
  log "    OK: no native-ify symbol (measurement build confirmed)"
fi
echo ""
log "REBOOT REQUIRED. After reboot, run read-deter.sh."
