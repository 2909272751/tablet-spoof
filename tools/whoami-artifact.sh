#!/system/bin/sh
# Identify the deployed artifact BEFORE interpreting any behaviour.
# Same discipline as before: an unidentified artifact's behaviour means nothing.
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
log() { echo "[whoami] $*"; }

log "=== deployed artifact ==="
stat -c '  size=%s  mtime=%y' "$SO" 2>/dev/null
md5sum "$SO" 2>/dev/null | sed 's/^/  md5 /'
log "  boot: $(uptime | sed 's/^ *//')"
echo ""

log "=== marker scan (which build is this?) ==="
for s in RESOLVED HOOK_MISS ts_native ts_call MEASURE ArtProbe ts_probe callprobe nativeifyMethod; do
  if strings "$SO" 2>/dev/null | grep -q "$s"; then
    log "  present : $s"
  else
    log "  absent  : $s"
  fi
done
echo ""

log "=== does it contain our three CALL sites? ==="
for s in isAndroidPad getDeviceType gk; do
  N=$(strings "$SO" 2>/dev/null | grep -c "$s")
  log "  '$s' occurrences: $N"
done
echo ""

log "=== my deployed build was 17048 bytes -- is this it? ==="
SZ=$(stat -c %s "$SO" 2>/dev/null)
if [ "$SZ" = "17048" ]; then
  log "  YES: 17048 = my build with the three CALL lines"
else
  log "  NO: size is $SZ, not 17048 -> someone else's build"
  log "     The Lead may have deployed their callprobe. Do NOT interpret MY markers."
fi
