#!/system/bin/sh
# Final device cleanup:
#  1. revert the APatch package_config edit (remove the two added lines)
#  2. remove my diagnostic status files from all sinks
#  3. remove the now-obsolete stage-1 skeleton module if present
#  4. report what remains, so the device is left as-found
log() { echo "[cleanup] $*"; }

log "=== 1. APatch package_config revert ==="
BK=/data/local/tmp/package_config.bak
CFG=/data/adb/ap/package_config
log "  current:"
sed 's/^/    /' "$CFG" 2>/dev/null
if [ -f "$BK" ]; then
  log "  backup found: $BK"
  sed 's/^/    /' "$BK"
  cp "$BK" "$CFG" && log "  RESTORED from backup"
  chmod 666 "$CFG" 2>/dev/null
  log "  after restore:"
  sed 's/^/    /' "$CFG"
else
  log "  no backup at $BK -- removing the two tablet-spoof lines by pattern instead"
  # Only remove lines for OUR two packages; never touch other entries.
  grep -v -E '^com\.tencent\.(wework|mm),' "$CFG" > "$CFG.new" 2>/dev/null
  mv "$CFG.new" "$CFG" 2>/dev/null
  chmod 666 "$CFG" 2>/dev/null
  log "  after pattern-based removal:"
  sed 's/^/    /' "$CFG"
fi
echo ""

log "=== 2. remove diagnostic status files from every sink ==="
for f in /sdcard/tablet-spoof-status.txt \
         /data/local/tmp/tablet-spoof-status \
         /data/data/com.tencent.wework/files/ts_status.txt \
         /data/data/com.byyoung.setting/files/ts_status.txt \
         /data/data/com.tencent.mm/files/ts_status.txt \
         /data/local/tmp/uidtest.txt \
         /data/local/tmp/appuid-test.txt \
         /data/local/tmp/shell-test.txt \
         /data/local/tmp/tablet-spoof-status.txt; do
  if [ -e "$f" ]; then rm -f "$f" && log "  removed $f"; fi
done
log "  any ts_status.txt left anywhere under /data/data?"
find /data/data -maxdepth 3 -name 'ts_status.txt' 2>/dev/null | sed 's/^/    /'
echo ""

log "=== 3. remove obsolete diagnostic modules/files ==="
for d in /data/adb/modules/tablet-spoof-native-test; do
  [ -d "$d" ] && { rm -rf "$d"; log "  removed module dir $d"; }
done
rm -rf /data/local/tmp/tablet-spoof-src /data/local/tmp/statustest /data/local/tmp/statustest2 \
       /data/local/tmp/sink-selftest /data/local/tmp/nativetest /data/local/tmp/cmp-* \
       /data/local/tmp/idcheck /data/local/tmp/sabchk /data/local/tmp/modprop 2>/dev/null
log "  scratch dirs removed"
echo ""

log "=== 4. what remains (device left as-found apart from our deliverable) ==="
log "  modules:"
ls -1 /data/adb/modules/ | sed 's/^/    /'
echo ""
log "  our module contents:"
find /data/adb/modules/tablet-spoof-native -maxdepth 2 2>/dev/null | sed 's/^/    /'
echo ""
log "  APatch package_config final state:"
sed 's/^/    /' /data/adb/ap/package_config 2>/dev/null
echo ""
log "  SELinux: $(getenforce 2>/dev/null)"
log "  logcat buffer size: $(logcat -g 2>/dev/null | head -1)"
