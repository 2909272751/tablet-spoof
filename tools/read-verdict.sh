#!/system/bin/sh
# Read the runtime-verdict results from <app_data_dir>/ts_native.log.
# Hash-checks the artifact before and after so the result is attributable.
log() { echo "[verdict-read] $*"; }
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so

log "=== artifact identity ==="
log "  size=$(stat -c %s "$SO" 2>/dev/null)"
md5sum "$SO" 2>/dev/null | sed 's/^/  hash-before /'
log "  boot: $(uptime | sed 's/^ *//')"
echo ""

log "=== clear logs (anything present will be from THIS run) ==="
for p in com.tencent.wework com.tencent.mm; do rm -f "/data/data/$p/ts_native.log" 2>/dev/null; done
log "  cleared"
echo ""

log "=== launch both targets (WeChat self-launches, so we force WeCom FIRST) ==="
for p in com.tencent.wework com.tencent.mm; do
  log "  --- $p"
  am force-stop "$p" 2>/dev/null
  sleep 2
  monkey -p "$p" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 14
  log "    pid: $(pidof "$p" 2>/dev/null || echo none)"
done
echo ""

log "=== read ts_native.log ==="
for p in com.tencent.wework com.tencent.mm; do
  F="/data/data/$p/ts_native.log"
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

log "=== THE DECISIVE VALUES ==="
for p in com.tencent.wework com.tencent.mm; do
  F="/data/data/$p/ts_native.log"
  [ -f "$F" ] || continue
  log "  $p:"
  grep -E '^RESOLVED' "$F" | sed 's/^/    /'
  grep -E '^CALL' "$F" | sed 's/^/    /'
done
echo ""
log "INTERPRETATION:"
log "  isAndroidPad() = false -> the 8.0in size test FAILS at runtime (our model holds;"
log "                            a fix must make the measurement succeed)"
log "  isAndroidPad() = TRUE  -> the verdict is FINE and something ELSE gates the UI"
log "                            (our earlier model was incomplete)"
