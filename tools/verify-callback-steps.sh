#!/system/bin/sh
# Run the verification steps individually with error visibility, so a failure in
# one step does not hide the rest.
log() { echo "[step] $*"; }

log "=== A. device sanity ==="
uptime | sed 's/^/  /'
log "  lspd: $(pidof lspd 2>/dev/null || echo none)"
log "  boot_completed: $(getprop sys.boot_completed)"
echo ""

log "=== B. what .so is deployed (size + md5) ==="
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
stat -c '  %s bytes  mtime=%y' "$SO" 2>/dev/null
md5sum "$SO" 2>/dev/null | sed 's/^/  /'
log "  strings that would prove what it does:"
strings "$SO" 2>/dev/null | grep -iE 'tablet-spoof|SCOPE|POST|ts_status|app_data|constructor' | sort -u | head -20 | sed 's/^/    /'
echo ""

log "=== C. clear sinks ==="
rm -f /data/local/tmp/tablet-spoof-status /sdcard/tablet-spoof-status.txt
for p in com.tencent.wework com.tencent.mm; do
  rm -f "/data/data/$p/files/ts_status.txt" 2>/dev/null
done
log "  done"
echo ""

log "=== D. launch WeCom ALONE, then inspect ==="
am force-stop com.tencent.wework 2>/dev/null
sleep 2
monkey -p com.tencent.wework -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
echo "  monkey rc=$?"
sleep 10
log "  wework pid: $(pidof com.tencent.wework 2>/dev/null || echo none)"
log "  --- sinks in wework's data dir ---"
ls -la /data/data/com.tencent.wework/files/ts_status.txt 2>/dev/null | sed 's/^/    /'
ls -la /data/data/com.tencent.wework/ts_status.txt 2>/dev/null | sed 's/^/    /'
log "  --- fallback sinks ---"
ls -la /data/local/tmp/tablet-spoof-status 2>/dev/null | sed 's/^/    /'
ls -la /sdcard/tablet-spoof-status.txt 2>/dev/null | sed 's/^/    /'
log "  --- any file mentioning our module anywhere in wework data ---"
find /data/data/com.tencent.wework -maxdepth 2 -newermt '-3 minutes' -type f 2>/dev/null | head -10 | sed 's/^/    /'
echo ""

log "=== E. launch WeChat ALONE, then inspect ==="
am force-stop com.tencent.mm 2>/dev/null
sleep 2
monkey -p com.tencent.mm -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
echo "  monkey rc=$?"
sleep 10
log "  mm pid: $(pidof com.tencent.mm 2>/dev/null || echo none)"
find /data/data/com.tencent.mm -maxdepth 2 -name 'ts_status.txt' 2>/dev/null | sed 's/^/    /'
find /data/data/com.tencent.mm -maxdepth 2 -newermt '-3 minutes' -type f 2>/dev/null | head -10 | sed 's/^/    /'
echo ""

log "=== F. logcat: does the payload print anything? ==="
logcat -d 2>/dev/null | grep -iE 'tablet-spoof' | tail -15 | sed 's/^/  /'
log "  count: $(logcat -d 2>/dev/null | grep -ci 'tablet-spoof')"
