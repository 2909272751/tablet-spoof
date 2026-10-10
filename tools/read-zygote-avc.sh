#!/system/bin/sh
# Read the zygote AVC denials. If they name adb_data_file / our module, the
# mechanism is a zygote-side SELinux restriction. If not, the mechanism is
# elsewhere and we should stop rather than guess.
log() { echo "[zygote-avc] $*"; }

log "=== all zygote-domain AVC denials (the 66) ==="
dmesg 2>/dev/null | grep 'avc:.*denied' | grep 'u:r:zygote:s0' | \
  sed 's/.*avc:  denied  { \([^}]*\) } for \([^ ]*\).*tclass=\([^ ]*\).*/perm=\1 for=\2 tclass=\3/' | \
  sort | uniq -c | sort -rn | head -25 | sed 's/^/  /'
echo ""

log "=== do ANY denials mention our module path or adb_data_file? ==="
dmesg 2>/dev/null | grep 'avc:.*denied' | grep -iE 'tablet-spoof|zygisk|adb_data' | head -10 | sed 's/^/  /'
echo "  (empty above = zygote denials are unrelated to our .so)"
echo ""

log "=== raw sample of zygote denials (first 3, full text) ==="
dmesg 2>/dev/null | grep 'avc:.*denied' | grep 'u:r:zygote:s0' | head -3 | sed 's/^/  /'
echo ""

log "=== untrusted_app denials mentioning our path? ==="
dmesg 2>/dev/null | grep 'avc:.*denied' | grep 'untrusted_app' | head -6 | sed 's/^/  /'
echo ""

log "=== is the file context of our .so one that zygote can execute? ==="
log "  our .so context: $(ls -Zd /data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so 2>/dev/null | awk '{print $1}')"
log "  NOTE: it is system_lib_file, NOT adb_data_file -- interesting!"
log "  device_faker's .so context: $(ls -Zd /data/adb/modules/device_faker/zygisk/arm64-v8a.so 2>/dev/null | awk '{print $1}')"
log "  zygisk_lsposed's .so context: $(ls -Zd /data/adb/modules/zygisk_lsposed/zygisk/arm64-v8a.so 2>/dev/null | awk '{print $1}')"
echo ""

log "=== does a WORKING module's .so have a different context than ours? ==="
for m in device_faker zygisk_lsposed tablet-spoof-native; do
  f=/data/adb/modules/$m/zygisk/arm64-v8a.so
  [ -f "$f" ] && printf '  %-24s %s\n' "$m" "$(ls -Zd "$f" 2>/dev/null | awk '{print $1}')"
done
echo ""

log "=== THE ACTUAL DISCRIMINATOR: does the mapping persist or is it transient? ==="
log "  A dlopen'd lib has a distinct pattern (r--p + r-xp + rw-p, like liblog)."
log "  Ours shows r-xp at offset 0 + two rw-p at 0x2000 -- that is NOT a normal"
log "  dlopen layout. A normal dlopen of a file gives:"
log "    r--p offset 0    (ELF header, read-only)"
log "    r-xp offset X    (code)"
log "    r--p offset Y    (rodata)"
log "    rw-p offset Z    (data)"
log "  Ours lacks the leading r--p and has r-xp at offset 0 -> this looks like the"
log "  loader mapped it via mmap directly (as zygisk does to read/validate), NOT"
log "  via dlopen. That is consistent with 'never loaded' and is a REAL structural"
log "  difference from a loaded library."
echo ""
log "  compare a genuinely loaded lib in the same process:"
PID=$(pidof com.tencent.wework | head -1)
[ -n "$PID" ] && grep -E 'liblog\.so' /proc/$PID/maps | head -3 | sed 's/^/    /'
echo ""
log "  and ours:"
[ -n "$PID" ] && grep 'tablet-spoof-native' /proc/$PID/maps | sed 's/^/    /'
