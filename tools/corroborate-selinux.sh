#!/system/bin/sh
# Corroborate the SELinux hypothesis by finding the actual policy rule that
# blocks dlopen of a file under /data/adb from untrusted_app domains.
#
# If we can show the AVC denial (or the policy rule), the mechanism is proven
# rather than inferred from correlation.
log() { echo "[selinux] $*"; }

log "=== 1. AVC denials in the kernel log involving our module or adb files ==="
dmesg 2>/dev/null | grep -i 'avc' | grep -iE 'adb|tablet-spoof|zygisk' | tail -20 | sed 's/^/  /'
echo "  (empty = no logged denial; SELinux may use dontaudit)"
echo ""

log "=== 2. all AVC denials in the last dmesg, grouped by domain ==="
dmesg 2>/dev/null | grep -i 'avc:.*denied' | \
  sed 's/.*scontext=\([^ ]*\).*/\1/' | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /'
echo ""

log "=== 3. key policy difference: file context of /data/adb vs what domains may exec ==="
ls -Zd /data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so 2>/dev/null | sed 's/^/  /'
ls -Zd /data/adb 2>/dev/null | sed 's/^/  /'
ls -Zd /data/adb/modules 2>/dev/null | sed 's/^/  /'
echo ""

log "=== 4. does the kernel policy allow untrusted_app to exec adb_data_file? ==="
echo "  (checking via sesearch-like inspection if available)"
if command -v sesearch >/dev/null 2>&1; then
  sesearch -A -s untrusted_app -t adb_data_file -c file -p execute 2>/dev/null | head -5 | sed 's/^/    /'
  echo "  --- and for untrusted_app_27 ---"
  sesearch -A -s untrusted_app_27 -t adb_data_file -c file -p execute 2>/dev/null | head -5 | sed 's/^/    /'
else
  echo "    sesearch not available"
fi
echo ""

log "=== 5. compare the policydb domains that exist ==="
echo "  distinct app domains in the policy (via /sys/fs/selinux or dmesg):"
dmesg 2>/dev/null | grep -o 'u:r:untrusted_app[a-z0-9_]*' | sort -u | head -20 | sed 's/^/    /'
echo ""

log "=== 6. THE DIRECT TEST: can a shell/root process dlopen our .so for a"
log "    targetSdk>=30 app? (we already know the callback never fires, but this"
log "    confirms 'mapped but not dlopen-ed' vs 'dlopen denied') ==="
log "    Checking whether the mapping in WeCom has a corresponding loaded library:"
PID=$(pidof com.tencent.wework | head -1)
if [ -n "$PID" ]; then
  echo "  our .so mappings in WeCom:"
  grep 'tablet-spoof-native' /proc/$PID/maps | sed 's/^/    /'
  echo "  --- compare with a lib that IS loaded (liblog) ---"
  grep 'liblog.so' /proc/$PID/maps | head -2 | sed 's/^/    /'
  echo "  --- is our .so in the process's loaded-library list? ---"
  grep -c 'tablet-spoof' /proc/$PID/smaps 2>/dev/null | sed 's/^/    smaps entries: /'
fi
echo ""
log "=== 7. also check a WORKING case (byyoung) for comparison ==="
PID2=$(pidof com.byyoung.setting | head -1)
if [ -n "$PID2" ]; then
  echo "  our .so mappings in byyoung:"
  grep 'tablet-spoof-native' /proc/$PID2/maps | sed 's/^/    /'
fi
