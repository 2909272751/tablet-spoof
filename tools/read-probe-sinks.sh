#!/system/bin/sh
# Read the sink probe's output from every sink, for both targets.
# Run after a reboot + launching the targets.
log() { echo "[probe-read] $*"; }

log "=== 0. identify what is deployed (never interpret an unidentified artifact) ==="
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
stat -c '  %s bytes  mtime=%y' "$SO" 2>/dev/null
md5sum "$SO" 2>/dev/null | sed 's/^/  md5 /'
if strings "$SO" 2>/dev/null | grep -q 'ts_probe'; then
  log "  marker 'ts_probe' present -> this is MY probe"
else
  log "  marker 'ts_probe' ABSENT   -> this is NOT my probe; results may not apply"
fi
log "  boot: $(uptime | sed 's/^ *//')"
echo ""

log "=== 1. clear all sinks ==="
rm -f /data/local/tmp/ts-probe.txt /sdcard/ts-probe.txt
for p in com.tencent.wework com.tencent.mm; do
  rm -f "/data/data/$p/files/ts_probe.txt" "/data/data/$p/ts_probe.txt" 2>/dev/null
done
log "  cleared"
echo ""

log "=== 2. launch each target, then read ==="
for p in com.tencent.wework com.tencent.mm; do
  log "  --- $p ---"
  am force-stop "$p" 2>/dev/null
  sleep 2
  monkey -p "$p" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 10
  log "    pid: $(pidof "$p" 2>/dev/null || echo none)"
  FOUND=0
  for f in "/data/data/$p/files/ts_probe.txt" "/data/data/$p/ts_probe.txt"; do
    if [ -f "$f" ]; then
      log "    *** APP-DATA SINK: $f ($(stat -c %s "$f") bytes) ***"
      sed 's/^/      /' "$f"
      FOUND=1
    fi
  done
  [ "$FOUND" = "0" ] && log "    no app-data sink output"
done
echo ""

log "=== 3. fallback sinks (these can only be written by privileged uids) ==="
for f in /data/local/tmp/ts-probe.txt /sdcard/ts-probe.txt; do
  if [ -f "$f" ]; then
    log "  $f ($(stat -c %s "$f") bytes):"
    tail -20 "$f" | sed 's/^/    /'
  else
    log "  $f: absent"
  fi
done
echo ""

log "=== 4. VERDICT INPUTS ==="
WW=$(cat /data/data/com.tencent.wework/files/ts_probe.txt 2>/dev/null)
MM=$(cat /data/data/com.tencent.mm/files/ts_probe.txt 2>/dev/null)
log "  wework POST seen : $(echo "$WW" | grep -c 'POST com.tencent.wework$')"
log "  wework PRE  seen : $(echo "$WW" | grep -c 'PRE com.tencent.wework$')"
log "  wework CTOR seen : $(echo "$WW" | grep -c 'CTOR')"
log "  wework FINDCLASS : $(echo "$WW" | grep 'POST-FINDCLASS' | head -1)"
log "  mm POST seen     : $(echo "$MM" | grep -c 'POST com.tencent.mm$')"
echo ""
log "  INTERPRETATION:"
log "   CTOR absent + POST absent  -> .so not executed in that process"
log "   CTOR present + POST absent -> loaded, but specialize not delivered"
log "   POST present               -> delivery WORKS; earlier silence was the sink"
