#!/system/bin/sh
# Investigate why the callback fires for other third-party apps but not WeCom.
# Implements the lead's checks #4 (executable mapping?), #2 (timing), #1 (child
# zygote), #3 (process characteristics).

log() { echo "[why] $*"; }

log "=== CHECK #4 FIRST: is our .so mapped EXECUTABLE in WeCom? ==="
PID=$(pidof com.tencent.wework)
log "  wework main pid: ${PID:-none}"
if [ -n "$PID" ]; then
  echo "  --- our .so mappings ---"
  grep 'tablet-spoof-native' /proc/$PID/maps 2>/dev/null | sed 's/^/    /'
  echo "  --- are any of them executable (r-xp / --xp)? ---"
  EXEC=$(grep 'tablet-spoof-native' /proc/$PID/maps 2>/dev/null | grep -c 'r-xp\|--xp')
  log "  executable mappings: $EXEC"
  echo "  --- for contrast: how is device_faker mapped in a process that DOES fire? ---"
  grep 'device_faker' /proc/$PID/maps 2>/dev/null | sed 's/^/    /'
  echo "  --- and in a process where our callback DID fire (com.android.shell) ---"
  SP=$(pidof com.android.shell)
  [ -n "$SP" ] && grep -E 'tablet-spoof-native' /proc/$SP/maps 2>/dev/null | sed 's/^/    /'
fi
echo ""

log "=== our .so mapped in EVERY wework process (incl. subprocesses)? ==="
for p in $(pidof com.tencent.wework); do
  CMD=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
  N=$(grep -c 'tablet-spoof-native' /proc/$p/maps 2>/dev/null)
  EX=$(grep 'tablet-spoof-native' /proc/$p/maps 2>/dev/null | grep -c 'r-xp')
  printf '  pid %-7s maps=%-3s exec=%-3s %s\n' "$p" "${N:-0}" "${EX:-0}" "$CMD"
done
echo ""

log "=== CHECK #1: how many processes does WeCom run, and did ANY write status? ==="
log "  distinct procs in the /sdcard sink:"
grep -o 'proc=[^ ]*' /sdcard/tablet-spoof-status.txt 2>/dev/null | sort -u | sed 's/^/    /'
echo ""

log "=== CHECK #2: launch WeCom AFTER boot is well settled, then re-read ==="
log "  uptime now: $(uptime | sed 's/^ *//')"
rm -f /sdcard/tablet-spoof-status.txt
am force-stop com.tencent.wework
sleep 3
am start -W -n com.tencent.wework/.login.controller.LoginWxAuthActivity >/dev/null 2>&1
sleep 15
log "  status file after a SETTLED launch:"
if [ -f /sdcard/tablet-spoof-status.txt ]; then
  sed 's/^/    /' /sdcard/tablet-spoof-status.txt
else
  log "    (still absent -> callback did not fire even on a settled launch)"
fi
log "  app-data sink:"
[ -f /data/data/com.tencent.wework/files/ts_status.txt ] \
  && sed 's/^/    /' /data/data/com.tencent.wework/files/ts_status.txt \
  || log "    (absent)"
echo ""

log "=== CHECK #3: process/zygote characteristics for the WeCom main process ==="
PID2=$(pidof com.tencent.wework)
log "  pid: ${PID2:-none}"
if [ -n "$PID2" ]; then
  log "  ppid: $(awk '{print $4}' /proc/$PID2/stat 2>/dev/null)"
  log "  parent cmdline: $(cat /proc/$(awk '{print $4}' /proc/$PID2/stat 2>/dev/null)/cmdline 2>/dev/null | tr '\0' ' ')"
  log "  uid: $(stat -c %u /proc/$PID2 2>/dev/null)"
  log "  is 64-bit (has lib64 maps): $(grep -c '/lib64/' /proc/$PID2/maps 2>/dev/null)"
  log "  has libart (ART process): $(grep -c 'libart.so' /proc/$PID2/maps 2>/dev/null)"
  log "  zygote processes: $(pidof zygote64) / $(pidof zygote)"
  log "  cmdline: $(cat /proc/$PID2/cmdline 2>/dev/null | tr '\0' ' ')"
fi
echo ""

log "=== compare with a third-party app where our callback DID fire ==="
log "  com.byyoung.setting pid: $(pidof com.byyoung.setting)"
log "  com.android.shell pid: $(pidof com.android.shell)"
