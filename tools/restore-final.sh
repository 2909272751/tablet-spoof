#!/system/bin/sh
# RESTORE the device to the state a fresh flash of the released zip produces:
#   * clean shipped payload (no probe scaffolding)
#   * `disable` marker present (native payload disabled by default)
#   * probe logs removed from app data dirs
#   * LSPosed mechanism untouched
log() { echo "[restore] $*"; }
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
SHIPPED=/data/local/tmp/tsx/zygisk/arm64-v8a.so

log "=== 1. restore the SHIPPED payload ==="
if [ -f "$SHIPPED" ]; then
  log "  shipped: $(stat -c %s "$SHIPPED") bytes  md5=$(md5sum "$SHIPPED" | awk '{print $1}')"
  log "  current: $(stat -c %s "$SO") bytes  md5=$(md5sum "$SO" | awk '{print $1}')"
  cp "$SHIPPED" "$SO"
  chmod 644 "$SO"
  log "  now    : $(stat -c %s "$SO") bytes  md5=$(md5sum "$SO" | awk '{print $1}')"
else
  log "  ERROR: shipped payload not staged at $SHIPPED"
fi
echo ""

log "=== 2. verify scaffolding is gone ==="
for s in KVREAD PAD-KEY CTRL-KEY STABLE TIMELINE PROBE-FINAL CALL MEASURE nativeifyMethod; do
  N=$(strings "$SO" 2>/dev/null | grep -c -- "$s")
  [ "$N" = "0" ] && log "  absent: $s" || log "  PRESENT (bad): $s"
done
log "  expected markers:"
for s in RESOLVED HOOK_MISS ts_native; do
  strings "$SO" 2>/dev/null | grep -q "$s" && log "    has $s" || log "    MISSING $s"
done
log "  KV key constant (must be 0 -> cannot touch the KV): $(strings "$SO" 2>/dev/null | grep -c 'KV_ANDROID_PAD')"
echo ""

log "=== 3. restore the disable marker (fresh-flash behaviour) ==="
touch /data/adb/modules/tablet-spoof-native/disable
log "  marker: $([ -f /data/adb/modules/tablet-spoof-native/disable ] && echo PRESENT || echo FAILED)"
echo ""

log "=== 4. remove probe logs from app data dirs ==="
for p in com.tencent.wework com.tencent.mm; do
  for d in "/data/data/$p" "/data/data/$p/files"; do
    for f in ts_kvread.log ts_native.log ts_stable.log ts_hook.log ts_status.txt zyprobe.log; do
      [ -f "$d/$f" ] && { rm -f "$d/$f"; log "  removed $d/$f"; }
    done
  done
  log "  $p remaining: $(find /data/data/$p -maxdepth 2 \( -name 'ts_*' -o -name 'zyprobe*' \) 2>/dev/null | wc -l)"
done
rm -f /data/local/tmp/kvread.so /data/local/tmp/stable.so /data/local/tmp/final.so 2>/dev/null
echo ""

log "=== 5. LSPosed mechanism (must be intact) ==="
DB=/data/adb/lspd/config/modules_config.db
S=/system/bin/sqlite3
log "  enabled: $("$S" "$DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='io.github.tabletspoof' AND user_id=0;" 2>/dev/null)"
log "  scope:"
"$S" "$DB" "SELECT app_pkg_name FROM scope WHERE module_pkg_name='io.github.tabletspoof';" 2>/dev/null | sed 's/^/    /'
log "  APK: $(pm path io.github.tabletspoof 2>/dev/null || echo 'NOT INSTALLED')"
echo ""

log "=== 6. display untouched ==="
wm size | sed 's/^/  /'
wm density | sed 's/^/  /'
echo ""
log "REBOOT REQUIRED for the restored payload to load."
