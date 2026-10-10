#!/system/bin/sh
# CONTROLLED current-boot test: clear all sinks, then launch a known-working
# third-party app and WeCom, and compare. This removes the stale-file trap that
# just fooled me (I read a status file left over from a previous boot).
log() { echo "[controlled] $*"; }

log "boot: $(uptime | sed 's/^ *//')"
log ""
log "=== clear ALL sinks ==="
rm -f /sdcard/tablet-spoof-status.txt
rm -f /data/local/tmp/tablet-spoof-status
rm -f /data/data/com.tencent.wework/files/ts_status.txt
rm -f /data/data/com.byyoung.setting/files/ts_status.txt
rm -f /data/data/com.tencent.qqmusic/files/ts_status.txt
log "  cleared. verifying:"
for f in /sdcard/tablet-spoof-status.txt /data/local/tmp/tablet-spoof-status; do
  log "    $f exists=$([ -f "$f" ] && echo YES || echo no)"
done
echo ""

log "=== CONTROL A: launch com.byyoung.setting (third-party, expected to work) ==="
am force-stop com.byyoung.setting 2>/dev/null
sleep 2
monkey -p com.byyoung.setting -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 10
log "  sinks now:"
for f in /sdcard/tablet-spoof-status.txt /data/local/tmp/tablet-spoof-status; do
  [ -f "$f" ] && { log "    $f:"; sed 's/^/      /' "$f"; }
done
BY=$(grep -c 'byyoung' /sdcard/tablet-spoof-status.txt 2>/dev/null)
log "  byyoung records: ${BY:-0}"
echo ""

log "=== CONTROL B: launch WeCom login activity ==="
rm -f /sdcard/tablet-spoof-status.txt
am force-stop com.tencent.wework 2>/dev/null
sleep 3
am start -W -n com.tencent.wework/.login.controller.LoginWxAuthActivity >/dev/null 2>&1
sleep 15
log "  sinks now:"
for f in /sdcard/tablet-spoof-status.txt /data/local/tmp/tablet-spoof-status \
         /data/data/com.tencent.wework/files/ts_status.txt; do
  if [ -f "$f" ]; then log "    $f:"; sed 's/^/      /' "$f"; else log "    $f: ABSENT"; fi
done
WW=$(grep -c 'wework' /sdcard/tablet-spoof-status.txt 2>/dev/null)
log "  wework records: ${WW:-0}"
echo ""

log "=== verdict inputs ==="
log "  byyoung (control A): ${BY:-0} records"
log "  wework  (control B): ${WW:-0} records"
log "  wework pid=$(pidof com.tencent.wework)  maps=$(grep -c 'tablet-spoof-native' /proc/$(pidof com.tencent.wework)/maps 2>/dev/null)"
