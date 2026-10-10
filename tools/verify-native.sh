#!/system/bin/sh
# ============================================================================
# tablet-spoof / verify-native.sh   (run AS ROOT)
# ============================================================================
# Verifies the NATIVE Zygisk payload: does it load, and does the 2-package
# whitelist gate behave correctly?
#
# Run this AFTER a reboot (Zygisk only picks up a new module at boot).
#
# Checks, in order of importance:
#   1. Zygisk actually loaded our .so (independent of any app)
#   2. The payload logs "IN SCOPE" for WeCom
#   3. NEGATIVE CONTROL: it logs nothing for an unrelated app
#
# Step 3 is the one that matters: without it, "the whitelist works" would be an
# untested claim. This project has already shipped one invalid conclusion for
# want of a negative control.
# ============================================================================

MOD=tablet-spoof-native-test
PKG_SCOPE=com.tencent.wework
PKG_OUT=com.android.settings

log() { echo "[verify-native] $*"; }
FAIL=0

log "=== 1. did Zygisk load our payload? ==="
ZLOG=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -n1)
# Zygisk Next logs to its own place; try both.
for f in /data/adb/modules/zygisksu/*.log /data/adb/lspd/log/verbose_*.log; do :; done
echo "  zn-daemon module list:"
dmesg 2>/dev/null | grep -i 'zn-daemon' | grep -i 'module' | tail -12 | sed 's/^/    /'
echo ""
echo "  looking for '$MOD' in any zygisk log:"
FOUND=0
for f in $(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -3) \
         $(ls -t /data/adb/zygisksu/*.log 2>/dev/null | head -3) \
         /data/adb/modules/zygisksu/*.log ; do
  [ -f "$f" ] || continue
  if grep -qi "$MOD" "$f" 2>/dev/null; then
    echo "    FOUND in $f:"
    grep -i "$MOD" "$f" | tail -5 | sed 's/^/      /'
    FOUND=1
  fi
done
[ "$FOUND" = 1 ] || log "  not found in logs (may still have loaded -- check maps below)"
echo ""

log "=== 2. is our .so mapped into the target process? ==="
# Force a fresh process so Zygisk's preAppSpecialize runs.
am force-stop "$PKG_SCOPE"
sleep 2
logcat -c 2>/dev/null
monkey -p "$PKG_SCOPE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
PID=$(pidof "$PKG_SCOPE")
if [ -n "$PID" ]; then
  log "  $PKG_SCOPE pid=$PID"
  MAPS=$(grep -c 'tablet-spoof-native-test\|arm64-v8a.so' /proc/$PID/maps 2>/dev/null)
  log "  our .so in maps: ${MAPS:-0}"
  grep 'tablet-spoof-native-test' /proc/$PID/maps 2>/dev/null | head -3 | sed 's/^/    /'
else
  log "  $PKG_SCOPE not running"
  FAIL=1
fi
echo ""

log "=== 3. did it log IN SCOPE for the target? ==="
SCOPE_HIT=$(logcat -d 2>/dev/null | grep -c "tablet-spoof.*IN SCOPE.*$PKG_SCOPE")
log "  matching log lines: $SCOPE_HIT"
logcat -d 2>/dev/null | grep 'tablet-spoof' | tail -8 | sed 's/^/    /'
[ "$SCOPE_HIT" -gt 0 ] || { log "  NO in-scope log line"; FAIL=1; }
echo ""

log "=== 4. NEGATIVE CONTROL -- unrelated app must produce NO tablet-spoof log ==="
logcat -c 2>/dev/null
am force-stop "$PKG_OUT"
sleep 2
monkey -p "$PKG_OUT" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
OUT_HIT=$(logcat -d 2>/dev/null | grep -c 'tablet-spoof')
log "  tablet-spoof log lines while running $PKG_OUT: $OUT_HIT (MUST be 0)"
if [ "$OUT_HIT" = "0" ]; then
  log "  PASS: strict whitelist confirmed -- no activity for an out-of-scope app"
else
  log "  FAIL: our payload logged for an out-of-scope app!"
  logcat -d 2>/dev/null | grep 'tablet-spoof' | head -5 | sed 's/^/    /'
  FAIL=1
fi
am force-stop "$PKG_OUT" 2>/dev/null
echo ""

if [ "$FAIL" = "0" ]; then
  log "RESULT: PASS"
else
  log "RESULT: FAIL / INCOMPLETE (see above)"
fi
exit $FAIL
