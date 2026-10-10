#!/system/bin/sh
# ============================================================================
# tablet-spoof / acceptance-native.sh   (run AS ROOT)
# ============================================================================
# The decisive acceptance test for the NATIVE payload.
#
# Verifies, in order:
#   1. our payload executes (positive control)
#   2. the ART hook reports NATIVE-IFIED (the mechanism fired)
#   3. the pad entry appears on the login screen  <-- the actual objective
#   4. NEGATIVE CONTROL: an out-of-scope app produces zero tablet-spoof output
#
# Step 4 is only meaningful once step 1 is green -- a negative control that
# passes because nothing is running proves nothing. That ordering is deliberate.
#
# WeCom is currently LOGGED IN, so we reach the login activity via root `am start`
# rather than by clearing app data. `pm clear` is NOT used and would destroy the
# user's session.
# ============================================================================

PKG=com.tencent.wework
LOGIN_ACT="$PKG/.login.controller.LoginWxAuthActivity"
OUT_PKG=com.tencent.qqmusic

log() { echo "[accept] $*"; }
FAIL=0

log "=== 1. does the payload execute? (positive control) ==="
logcat -c 2>/dev/null
am force-stop "$PKG"
sleep 3
am start -W -n "$LOGIN_ACT" >/dev/null 2>&1
sleep 10
PAYLOAD_HITS=$(logcat -d 2>/dev/null | grep -c 'tablet-spoof')
log "  tablet-spoof log lines: $PAYLOAD_HITS"
logcat -d 2>/dev/null | grep 'tablet-spoof' | tail -10 | sed 's/^/    /'
if [ "$PAYLOAD_HITS" = "0" ]; then
  log "  FAIL: payload did not execute -> nothing else below is meaningful"
  FAIL=1
else
  log "  OK: payload is executing"
fi
echo ""

log "=== 2. did the ART hook fire? (NATIVE-IFIED) ==="
HOOK_HITS=$(logcat -d 2>/dev/null | grep -c 'NATIVE-IFIED')
log "  NATIVE-IFIED lines: $HOOK_HITS"
logcat -d 2>/dev/null | grep -E 'NATIVE-IFIED|HOOK_MISS|HOOKED' | tail -8 | sed 's/^/    /'
if [ "$HOOK_HITS" -gt 0 ]; then
  log "  OK: hook installed"
else
  if logcat -d 2>/dev/null | grep -q 'HOOK_MISS'; then
    log "  HOOK_MISS reported (see reason above) -- this is a loud, honest failure"
  else
    log "  no hook line at all: the hook path may not have run"
  fi
  FAIL=1
fi
echo ""

log "=== 3. THE OBJECTIVE: is the pad entry on the login screen? ==="
rm -f /sdcard/ui.xml
uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
if [ -f /sdcard/ui.xml ]; then
  log "  dump: $(wc -c < /sdcard/ui.xml) bytes"
  echo "  --- text nodes ---"
  grep -o 'text="[^"]*"' /sdcard/ui.xml | sed 's/text=//' | sort -u | sed 's/^/      /'
  echo ""
  if grep -q '平板和手机同时登录' /sdcard/ui.xml; then
    log "  *** PASS: 「平板和手机同时登录」 IS PRESENT -> pad login available ***"
  else
    log "  FAIL: pad entry NOT present on the login screen"
    FAIL=1
  fi
else
  log "  FAIL: uiautomator dump failed"
  FAIL=1
fi
echo ""

log "=== 4. NEGATIVE CONTROL: out-of-scope app must be untouched ==="
logcat -c 2>/dev/null
am force-stop "$OUT_PKG" 2>/dev/null
sleep 2
monkey -p "$OUT_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
OUT_HITS=$(logcat -d 2>/dev/null | grep -c 'tablet-spoof')
log "  tablet-spoof lines while running $OUT_PKG: $OUT_HITS (must be 0)"
if [ "$OUT_HITS" = "0" ]; then
  log "  PASS: strict whitelist confirmed"
else
  log "  FAIL: produced output for an out-of-scope app"
  logcat -d 2>/dev/null | grep 'tablet-spoof' | head -5 | sed 's/^/    /'
  FAIL=1
fi
am force-stop "$OUT_PKG" 2>/dev/null
echo ""

if [ "$FAIL" = "0" ]; then
  log "RESULT: *** ACCEPTANCE PASS ***"
else
  log "RESULT: FAIL (see the failing step above)"
fi
exit $FAIL
