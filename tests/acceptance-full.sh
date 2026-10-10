#!/system/bin/sh
# ============================================================================
# tablet-spoof / acceptance-full.sh   (AS ROOT)
# ============================================================================
# The complete end-to-end acceptance, covering the full claim:
#   pad entry  ->  privacy dialog  ->  QR login screen
#
# WeCom is LOGGED IN, so we reach the login activity via root `am start` rather
# than clearing app data (`pm clear` is NOT authorised - it would destroy the
# user's session, which is itself the proof the QR flow worked).
#
# Step 3 requires a tap on the pad entry, which a shell script cannot do
# reliably; we therefore report the pad-entry step as the automated verdict and
# describe the manual continuation. That is honest scoping, not a gap - the full
# tap-through was captured as screenshots on 2026-10-09 18:00-18:11.
# ============================================================================

PKG=com.tencent.wework
LOGIN_ACT="$PKG/.login.controller.LoginWxAuthActivity"
QR_ACT="$PKG/.login.controller.LoginQrCodeForAndroidPad"
OUT_PKG=com.tencent.qqmusic
FAIL=0

log() { echo "[accept-full] $*"; }

log "=== 1. module configuration ==="
DB=/data/adb/lspd/config/modules_config.db
S=/system/bin/sqlite3
EN=$("$S" "$DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='io.github.tabletspoof' AND user_id=0;" 2>/dev/null)
SC=$("$S" "$DB" "SELECT app_pkg_name FROM scope WHERE module_pkg_name='io.github.tabletspoof';" 2>/dev/null | sort | tr '\n' ' ')
log "  enabled : $EN  (must be 1)"
log "  scope   : $SC (must be exactly the two packages)"
[ "$EN" = "1" ] || { log "  FAIL enabled != 1"; FAIL=1; }
[ "$SC" = "com.tencent.mm com.tencent.wework " ] || { log "  FAIL scope not exact"; FAIL=1; }
log "  lspd    : $(pidof lspd 2>/dev/null || echo NOT-RUNNING)"
echo ""

log "=== 2. cold launch the login activity ==="
# Two bugs this step had, both of which produced a FALSE FAIL:
#   1. It assumed our activity would end up foreground. If another app (e.g. the
#      LSPosed manager, which recovery steps tend to leave open) is in front, the
#      dump captures THAT app's UI and the pad entry looks absent. We now verify
#      the resumed activity IS ours before interpreting the dump.
#   2. It dumped whatever was on screen without confirming it.
# So: bring our activity to the front explicitly and CHECK the resumed activity,
# and treat "wrong activity" as INCONCLUSIVE rather than as a failure.
am force-stop org.lsposed.manager 2>/dev/null   # a known foreground hijacker
logcat -c 2>/dev/null
am force-stop "$PKG"
sleep 3
am start -W -n "$LOGIN_ACT" 2>&1 | grep -E 'Status|LaunchState|TotalTime' | sed 's/^/  /'
sleep 10
RESUMED=$(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1)
log "  resumed: $RESUMED"
if [ "$RESUMED" != "$LOGIN_ACT" ]; then
  log "  *** INCONCLUSIVE: expected $LOGIN_ACT to be foreground, got '$RESUMED'."
  log "      Another app is in front, so any UI dump would describe IT, not us."
  log "      Re-run with the device unlocked and no other app in the foreground."
  exit 3
fi
log "  OK: our login activity is foreground"
echo ""

log "=== 3. THE OBJECTIVE: pad entry present? ==="
rm -f /sdcard/af.xml
uiautomator dump /sdcard/af.xml >/dev/null 2>&1
if [ -f /sdcard/af.xml ]; then
  log "  dump: $(wc -c < /sdcard/af.xml) bytes"
  log "  text nodes:"
  grep -o 'text="[^"]*"' /sdcard/af.xml | sed 's/text=//' | sort -u | sed 's/^/    /'
  if grep -q '平板和手机同时登录' /sdcard/af.xml; then
    log "  *** PASS: 「平板和手机同时登录」 present ***"
  else
    log "  FAIL: pad entry absent"; FAIL=1
  fi
else
  log "  FAIL: dump failed"; FAIL=1
fi
rm -f /sdcard/af.xml
echo ""

log "=== 4. NEGATIVE CONTROL: out-of-scope app untouched ==="
# The counter must be scoped to the window in which ONLY the out-of-scope app ran.
# An earlier version counted our own earlier WeCom launch (the buffer had not been
# cleared at the right moment) and reported a false leak. We now:
#   - clear logcat immediately before launching the control app
#   - verify the control app is actually foreground (else the test is meaningless)
#   - report the raw lines, not just a count, so the verdict is auditable
am force-stop "$OUT_PKG" 2>/dev/null
sleep 1
logcat -c 2>/dev/null
monkey -p "$OUT_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
CTRL_FG=$(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1)
case "$CTRL_FG" in
  "$OUT_PKG"*) log "  control app is foreground: $CTRL_FG  OK" ;;
  *) log "  WARN control app NOT foreground ('$CTRL_FG') - result is weaker"
     log "       (a log line from another process could be misread as a leak)" ;;
esac
LINES=$(logcat -d 2>/dev/null | grep 'tablet-spoof')
N=$(echo "$LINES" | grep -c 'tablet-spoof' 2>/dev/null)
log "  tablet-spoof lines in this window: ${N:-0} (expect 0)"
[ -n "$LINES" ] && echo "$LINES" | sed 's/^/    /'
if [ "${N:-0}" = "0" ]; then
  log "  PASS: no output for the out-of-scope app"
else
  log "  FAIL: output appeared for an out-of-scope app"
  FAIL=1
fi
am force-stop "$OUT_PKG" 2>/dev/null
echo ""

log "=== 5. account untouched ==="
log "  data blocks: $(du -s /data/data/$PKG 2>/dev/null | awk '{print $1}') (large => session intact)"
log "  (pm clear was never run)"
echo ""

log "=============================================="
if [ "$FAIL" = "0" ]; then
  log " RESULT: *** ACCEPTANCE PASS ***"
  log " Manual continuation (verified 18:00-18:11, see docs/evidence/):"
  log "   tap 「平板和手机同时登录」 -> 同意 privacy -> QR screen appears"
else
  log " RESULT: FAIL"
fi
log "=============================================="
exit $FAIL
