#!/system/bin/sh
# Read the determination results from <app_data_dir>/ts_hook.log for both targets.
# Hash-checks the artifact before and after, so the result is attributable.
log() { echo "[det-read] $*"; }
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so

log "=== artifact identity ==="
log "  size=$(stat -c %s "$SO" 2>/dev/null)  mtime=$(stat -c %y "$SO" 2>/dev/null)"
md5sum "$SO" 2>/dev/null | sed 's/^/  hash-before /'
log "  boot: $(uptime | sed 's/^ *//')"
log "  (expected bec9829bbef50a2702d4e085b68a7fcc -- anything else = wrong artifact)"
echo ""

log "=== clear logs so anything present is from THIS run ==="
for p in com.tencent.wework com.tencent.mm; do
  rm -f "/data/data/$p/ts_hook.log" 2>/dev/null
done
log "  cleared"
echo ""

log "=== launch both targets (2 attempts each: device is unstable) ==="
for p in com.tencent.wework com.tencent.mm; do
  log "  --- $p"
  am force-stop "$p" 2>/dev/null
  sleep 2
  monkey -p "$p" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 12
  log "    pid: $(pidof "$p" 2>/dev/null || echo none)"
done
echo ""

log "=== read ts_hook.log ==="
for p in com.tencent.wework com.tencent.mm; do
  F="/data/data/$p/ts_hook.log"
  if [ -f "$F" ]; then
    log "*** $F ($(stat -c %s "$F") bytes) ***"
    sed 's/^/    /' "$F"
  else
    log "$F : ABSENT"
  fi
  echo ""
done

log "=== artifact identity (must equal hash-before) ==="
md5sum "$SO" 2>/dev/null | sed 's/^/  hash-after  /'
echo ""

log "=== DETERMINATION SUMMARY ==="
for p in com.tencent.wework com.tencent.mm; do
  F="/data/data/$p/ts_hook.log"
  [ -f "$F" ] || continue
  log "  $p:"
  log "    resolution : $(grep -c 'loadClass(' "$F") loadClass lines"
  log "    ArtMethod  : $(grep 'MEASURE ArtMethod' "$F" | sed 's/.*=//')"
  log "    flags      : $(grep 'MEASURE access_flags' "$F" | sed 's/.*access_flags/access_flags/')"
  log "    bridge refs: $(grep 'DET bridge-symbols' "$F" | head -1)"
  log "    ended with : $(tail -1 "$F")"
done
