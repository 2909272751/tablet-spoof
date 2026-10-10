#!/system/bin/sh
# Clean up every diagnostic artifact our probes left in the app data dirs, so the
# device handed over has no leftover state from this investigation.
log() { echo "[cleanup] $*"; }

log "=== remove probe logs from both target apps ==="
for p in com.tencent.wework com.tencent.mm; do
  for f in ts_status.txt ts_hook.log ts_native.log ts_stable.log ts_call.log ts_probe.txt zyprobe.log; do
    for d in "/data/data/$p" "/data/data/$p/files"; do
      if [ -f "$d/$f" ]; then rm -f "$d/$f"; log "  removed $d/$f"; fi
    done
  done
  log "  $p remaining ts_*/zyprobe files: $(find /data/data/$p -maxdepth 2 \( -name 'ts_*' -o -name 'zyprobe*' \) 2>/dev/null | wc -l)"
done
echo ""

log "=== remove probe artifacts from scratch space ==="
for f in /data/local/tmp/ts-probe.txt /data/local/tmp/tablet-spoof-status /data/local/tmp/probe.so \
         /data/local/tmp/det.so /data/local/tmp/stable.so /data/local/tmp/final.so \
         /sdcard/ts-probe.txt /sdcard/tablet-spoof-status.txt; do
  [ -f "$f" ] && { rm -f "$f"; log "  removed $f"; }
done
log "  (leaving the .sh tooling and sources -- they document the work)"
echo ""

log "=== final state ==="
log "  deployed payload: $(stat -c %s /data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so) bytes"
log "                  md5=$(md5sum /data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so | awk '{print $1}')"
log "  module dirs:"
ls -d /data/adb/modules/tablet-spoof* 2>/dev/null | sed 's/^/    /'
log "  disable marker on the native test module:"
[ -f /data/adb/modules/tablet-spoof-native/disable ] && log "    PRESENT" || log "    absent"
echo ""

log "=== LSPosed state (the working mechanism -- must be intact) ==="
DB=/data/adb/lspd/config/modules_config.db
S=/system/bin/sqlite3
log "  enabled: $("$S" "$DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='io.github.tabletspoof' AND user_id=0;" 2>/dev/null)"
log "  scope:"
"$S" "$DB" "SELECT app_pkg_name FROM scope WHERE module_pkg_name='io.github.tabletspoof';" 2>/dev/null | sed 's/^/    /'
echo ""

log "=== display untouched ==="
wm size | sed 's/^/  /'
wm density | sed 's/^/  /'
