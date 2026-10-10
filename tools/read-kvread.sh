#!/system/bin/sh
# Read the KV probe results (control pair + write-then-read + money shot).
log() { echo "[kvread] $*"; }
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
P=/data/data/com.tencent.wework

log "=== artifact identity (must be a56fad63063288e1b415dbc872acf8ad) ==="
md5sum "$SO" 2>/dev/null | sed 's/^/  hash-before /'
log "  size=$(stat -c %s "$SO" 2>/dev/null)"
log "  disable marker: $([ -f /data/adb/modules/tablet-spoof-native/disable ] && echo PRESENT || echo absent)  (must be absent)"
log "  boot: $(uptime | sed 's/^ *//')"
echo ""

log "=== md5 bracket around the launch (bounded control) ==="
am force-stop com.tencent.wework 2>/dev/null; sleep 3
M0=$(md5sum "$P/files/mmkv/com.tencent.pb.common" 2>/dev/null | awk '{print $1}')
log "  idle pre-launch : $M0"
echo ""

log "=== clear probe log and launch ==="
rm -f "$P/ts_kvread.log" 2>/dev/null
am force-stop com.tencent.wework
sleep 2
am start -W -n com.tencent.wework/.login.controller.LoginWxAuthActivity 2>&1 | grep -E 'Status|LaunchState' | sed 's/^/  /'
sleep 16
log "  pid: $(pidof com.tencent.wework 2>/dev/null || echo none)"
echo ""

F="$P/ts_kvread.log"
if [ -f "$F" ]; then
  log "*** $F ($(stat -c %s "$F") bytes) ***"
  sed 's/^/    /' "$F"
else
  log "$F : ABSENT  (if the payload did not load, check the disable marker)"
  log "  module dir contents:"
  ls /data/adb/modules/tablet-spoof-native/ 2>/dev/null | sed 's/^/    /'
fi
echo ""

log "=== post-launch idle md5 ==="
am force-stop com.tencent.wework 2>/dev/null; sleep 3
M1=$(md5sum "$P/files/mmkv/com.tencent.pb.common" 2>/dev/null | awk '{print $1}')
log "  idle post-launch: $M1"
[ "$M0" = "$M1" ] && log "  => store unchanged" || log "  => store changed (bounded -> meaningful)"
echo ""

log "=== THE DECISIVE VALUES ==="
grep -E 'PAD-KEY|CTRL-KEY|dt0|dt1|SUMMARY|WRITE' "$F" 2>/dev/null | sed 's/^/  /'
echo ""
log "=== artifact identity (must equal hash-before) ==="
md5sum "$SO" 2>/dev/null | sed 's/^/  hash-after  /'
