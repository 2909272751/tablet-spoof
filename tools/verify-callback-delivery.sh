#!/system/bin/sh
# INDEPENDENTLY VERIFY the Lead's claim that postAppSpecialize IS delivered to both
# target apps. I will not build the ART hook on an unverified premise.
#
# Also re-verify the sink explanation, because that is the causal claim:
#   * app_data_dir is writable by an app uid
#   * /data/local/tmp and /sdcard are NOT
#
# And critically: check whether the callback fires for targetSdk>=30 apps OTHER than
# our targets -- the earlier correlation said they were silent, and if the sink
# explanation is right, that correlation was an artifact too.
log() { echo "[verify] $*"; }

log "=== 1. what is currently deployed, and does it mark scope hits? ==="
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
if [ -f "$SO" ]; then
  log "  deployed .so: $(stat -c %s "$SO") bytes  md5=$(md5sum "$SO" | awk '{print $1}')"
  log "  contains modules.Info strings we can look for:"
  for s in SCOPE-HIT-WEWORK SCOPE-HIT-WECHAT POST-HERE app_data_dir ts_status; do
    if strings "$SO" 2>/dev/null | grep -q "$s"; then log "    HAS  $s"; else log "    no   $s"; fi
  done
else
  log "  no .so deployed!"
fi
echo ""

log "=== 2. clear BOTH the app-data sinks and the fallbacks ==="
rm -f /data/local/tmp/tablet-spoof-status /sdcard/tablet-spoof-status.txt 2>/dev/null
for p in com.tencent.wework com.tencent.mm; do
  rm -f "/data/data/$p/files/ts_status.txt" "/data/data/$p/ts_status.txt" 2>/dev/null
done
log "  cleared"
echo ""

log "=== 3. launch BOTH targets and see where output lands ==="
for p in com.tencent.wework com.tencent.mm; do
  log "  --- $p"
  am force-stop "$p" 2>/dev/null
  sleep 2
  # Hit the main activity (not just the login screen) so the main process starts.
  monkey -p "$p" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 8
  for f in "/data/data/$p/files/ts_status.txt" "/data/data/$p/ts_status.txt" \
           /data/local/tmp/tablet-spoof-status /sdcard/tablet-spoof-status.txt; do
    if [ -f "$f" ]; then
      log "    SINK OK: $f ($(stat -c %s "$f") bytes)"
      sed 's/^/      /' "$f"
    fi
  done
  log "    pid: $(pidof "$p" 2>/dev/null || echo none)"
done
echo ""

log "=== 4. the causal claim: is app_data_dir writable and /data/local/tmp not? ==="
WU=$(stat -c %u /data/data/com.tencent.wework 2>/dev/null)
log "  wework uid: $WU"
for t in "/data/data/com.tencent.wework/files/probe.txt" /data/local/tmp/probe.txt /sdcard/probe.txt; do
  rm -f "$t" 2>/dev/null
  su "$WU" -c "echo x > $t" 2>/dev/null
  if [ -f "$t" ]; then log "    WRITABLE    : $t"; rm -f "$t"; else log "    not writable: $t"; fi
done
echo ""

log "=== 5. was the targetSdk correlation an artifact? test another targetSdk>=30 app ==="
log "  (if the sink was the cause, an unrelated targetSdk>=30 app should ALSO show a"
log "   callback in ITS OWN app_data_dir, once we know where to look)"
for p in com.microsoft.emmx com.qiyi.video; do
  PID=$(pidof "$p" 2>/dev/null)
  [ -z "$PID" ] && { log "  $p not running; skipping"; continue; }
  log "  --- $p (targetSdk $(dumpsys package "$p" 2>/dev/null | sed -n 's/.*targetSdk=\([0-9]*\).*/\1/p' | head -1))"
  for f in "/data/data/$p/files/ts_status.txt" "/data/data/$p/ts_status.txt" "/data/local/tmp/tablet-spoof-status"; do
    [ -f "$f" ] && { log "    SINK: $f"; tail -3 "$f" | sed 's/^/      /'; }
  done
done
log "  (fallbacks are shared, so they only show privileged writers -- expected)"
