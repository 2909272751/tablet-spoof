#!/system/bin/sh
# Diagnose the acceptance-full FAIL. Two suspects, both plausibly MY test's fault:
#  1. step 2: the login activity launched (Status: ok, COLD) but the resumed activity
#     ended up being org.lsposed.manager -> something brought the manager forward
#     (the Lead's recovery attempts opened it). So we dumped the MANAGER's UI, not ours.
#  2. step 4 "negative control": 1 tablet-spoof log line while running qqmusic -- but
#     the counter greps the WHOLE logcat, and our own step-2 launch (WeCom) may still
#     be in the buffer, OR the line came from another process legitimately.
log() { echo "[diag] $*"; }

log "=== current foreground activity ==="
dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1 | sed 's/^/  /'
echo ""

log "=== is LSPosed Manager running/focused? ==="
pidof org.lsposed.manager 2>/dev/null | sed 's/^/  manager pid: /'
dumpsys window 2>/dev/null | grep -iE 'mCurrentFocus' | head -2 | sed 's/^/  /'
echo ""

log "=== redo step 2 properly: force US to the front, then dump ==="
am force-stop org.lsposed.manager 2>/dev/null
am force-stop com.tencent.wework
sleep 3
am start -W -n com.tencent.wework/.login.controller.LoginWxAuthActivity 2>&1 | grep -E 'Status|LaunchState'
sleep 8
R=$(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1)
log "  resumed now: $R"
rm -f /sdcard/d.xml
uiautomator dump /sdcard/d.xml >/dev/null 2>&1
if [ -f /sdcard/d.xml ]; then
  log "  dump bytes: $(wc -c < /sdcard/d.xml)"
  log "  text nodes:"
  grep -o 'text="[^"]*"' /sdcard/d.xml | sed 's/text=//' | sort -u | sed 's/^/    /'
  if grep -q '平板和手机同时登录' /sdcard/d.xml; then
    log "  *** pad entry PRESENT ***"
  else
    log "  pad entry ABSENT"
  fi
fi
echo ""

log "=== step 4 redone properly: WHICH process produced the line? ==="
logcat -c 2>/dev/null
FM=$(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1)
log "  (before launching qqmusic, foreground is: $FM)"
am force-stop com.tencent.qqmusic 2>/dev/null
sleep 2
monkey -p com.tencent.qqmusic -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
log "  foreground now: $(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1)"
log "  tablet-spoof lines in this window:"
logcat -d 2>/dev/null | grep 'tablet-spoof' | sed 's/^/    /'
log "  (if the only lines are from WeCom's earlier launch, the control is fine --"
log "   the test must clear logcat AFTER the WeCom step, which it does; so a line"
log "   here means either a leak or a stale-buffer artifact)"
am force-stop com.tencent.qqmusic 2>/dev/null
rm -f /sdcard/d.xml
