#!/system/bin/sh
# Read the read-only stability probe's output.
log() { echo "[stable-read] $*"; }
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
P=/data/data/com.tencent.wework

log "=== artifact identity (must be e0c52a0d6f908be353b3bc386de0252d) ==="
md5sum "$SO" 2>/dev/null | sed 's/^/  hash-before /'
log "  boot: $(uptime | sed 's/^ *//')"
echo ""

log "=== idle md5 baseline (app stopped, no activity) ==="
am force-stop com.tencent.wework 2>/dev/null
sleep 3
M0=$(md5sum "$P/files/mmkv/com.tencent.pb.common" 2>/dev/null | awk '{print $1}')
log "  md5 (idle, pre-launch): $M0"
echo ""

log "=== clear probe log, launch WeCom, read ==="
rm -f "$P/ts_stable.log" 2>/dev/null
am force-stop com.tencent.wework 2>/dev/null
sleep 2
am start -W -n com.tencent.wework/.login.controller.LoginWxAuthActivity 2>&1 | grep -E 'Status|LaunchState' | sed 's/^/  /'
sleep 14
log "  pid: $(pidof com.tencent.wework 2>/dev/null || echo none)"
echo ""

F="$P/ts_stable.log"
if [ -f "$F" ]; then
  log "*** $F ($(stat -c %s "$F") bytes) ***"
  sed 's/^/    /' "$F"
else
  log "$F : ABSENT"
fi
echo ""

log "=== post-launch idle md5 (was the store written during this action?) ==="
am force-stop com.tencent.wework 2>/dev/null
sleep 3
M1=$(md5sum "$P/files/mmkv/com.tencent.pb.common" 2>/dev/null | awk '{print $1}')
log "  md5 (idle, post-launch): $M1"
if [ "$M0" = "$M1" ]; then
  log "  => store UNCHANGED across this launch"
else
  log "  => store CHANGED across this launch (bounded before/after bracket -> meaningful)"
fi
echo ""

log "=== VERDICT (per-process, interleaved pairs) ==="
log "  This build samples BOTH quantities 20x interleaved, so we can tell"
log "  whether either varies WITHIN a process or only BETWEEN processes."
echo ""
log "  --- getDeviceType() verdicts ---"
grep 'getDeviceType() VERDICT' "$F" 2>/dev/null | sed 's/^/    /'
log "  --- isAndroidPad() verdicts ---"
grep 'isAndroidPad() VERDICT' "$F" 2>/dev/null | sed 's/^/    /'
echo ""
log "  --- distinct-value summary ---"
grep 'STABLE getDeviceType distinct' "$F" 2>/dev/null | sed 's/^/    /'
grep 'STABLE   dt value' "$F" 2>/dev/null | sed 's/^/    /'
echo ""
log "  --- pair lines (first 6 of each process) ---"
grep -n 'STABLE pair\[' "$F" 2>/dev/null | head -24 | sed 's/^/    /'
echo ""
log "  *** count of isAndroidPad observations by value ***"
log "    TRUE  : $(grep -c 'isAndroidPad=TRUE' "$F" 2>/dev/null)"
log "    false : $(grep -c 'isAndroidPad=false' "$F" 2>/dev/null)"
echo ""
log "=== artifact identity (must equal hash-before) ==="
md5sum "$SO" 2>/dev/null | sed 's/^/  hash-after  /'
