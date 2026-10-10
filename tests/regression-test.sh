#!/system/bin/sh
# ============================================================================
# tablet-spoof / regression-test.sh   (run AS ROOT, ON DEVICE)
# ============================================================================
# Regression for the QR-login flow after DROPPING the getDeviceType() hook.
#
# DESIGN CONSTRAINT: the user's 企业微信 account is logged in and `pm clear` is
# NOT authorised. So instead of forcing a cold login page, we exercise the EXACT
# hook and the EXACT code path that gates the pad entry:
#
#     LoginWxAuthActivity.initView()  ->  Application.isAndroidPad()
#
# by launching that activity directly as root (it is not exported) and dumping
# the resulting view hierarchy. If isAndroidPad() is hooked, initView() takes the
# pad branch and the pad container becomes VISIBLE, which shows in the dump.
#
# This validates hook + initView with zero account impact.
#
# Usage: regression-test.sh [check|dump]
# NOTHING here clears app data.
# ============================================================================

PKG=com.tencent.wework
LOGIN_ACT="$PKG/.login.controller.LoginWxAuthActivity"
QR_ACT="$PKG/.login.controller.LoginQrCodeForAndroidPad"

log() { echo "[regression] $*"; }

resumed() {
  dumpsys activity activities 2>/dev/null \
    | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' \
    | head -n1
}

do_check() {
  log "=== state (read-only) ==="
  log "resumed        : $(resumed)"
  log "wework pids    : $(pidof $PKG 2>/dev/null | tr '\n' ' ')"
  log "lspd pid       : $(pidof lspd 2>/dev/null || echo NOT-RUNNING)"
  log "uptime         : $(uptime | sed 's/^ *//')"
  _sz=$(du -s "/data/data/$PKG" 2>/dev/null | awk '{print $1}')
  log "account blocks : ${_sz:-unknown} (large => account intact)"
  log "NOTE: this script never clears app data."
}

do_dump() {
  log "=== launching the pad-gated login activity directly ==="
  log "force-stopping $PKG for a cold process (account data untouched)"
  am force-stop "$PKG"
  sleep 3

  log "am start -n $LOGIN_ACT  (root; activity is not exported)"
  am start -W -n "$LOGIN_ACT" 2>&1 | sed 's/^/  /'
  sleep 7

  log "resumed now    : $(resumed)"
  echo ""

  rm -f /sdcard/ui.xml
  uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  if [ -f /sdcard/ui.xml ]; then
    log "uiautomator dump: $(wc -c < /sdcard/ui.xml) bytes"
    echo ""
    echo "--- all text nodes ---"
    grep -o 'text="[^"]*"' /sdcard/ui.xml | sed 's/text=//' | sort -u | sed 's/^/  /'
    echo ""
    echo "--- resource-ids containing pad/qr/login ---"
    grep -oE 'resource-id="[^"]*"' /sdcard/ui.xml | sort -u \
      | grep -iE 'pad|qr|login|phone' | sed 's/^/  /'
    echo ""
    echo "--- VERDICT ---"
    if grep -qi '平板' /sdcard/ui.xml; then
      log "PASS: pad entry text 「平板」 present -> isAndroidPad() took the pad branch"
    elif grep -qiE 'pad|qr' /sdcard/ui.xml; then
      log "PASS: pad/qr node present -> isAndroidPad() took the pad branch"
    else
      log "INCONCLUSIVE: no pad/qr node in the dump."
      log "  The activity may not be launchable directly, or it finished immediately"
      log "  because a session already exists (logged_in => login activity may"
      log "  self-finish). Check the raw dump above before judging."
    fi
  else
    log "uiautomator dump FAILED"
    dumpsys window 2>/dev/null | grep -iE 'mCurrentFocus|mFocusedApp' | sed 's/^/  /'
  fi
  echo ""
  log "account data untouched."
}

case "$1" in
  check|"") do_check ;;
  dump)     do_dump ;;
  *) echo "usage: $0 [check|dump]"; exit 2 ;;
esac
exit 0
