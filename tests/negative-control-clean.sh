#!/system/bin/sh
# Clean negative-control retest, with the overlay dismissed first.
# The previous run warned that com.android.systemui/.logcat.LogAccessDialogActivity
# was foreground, which makes the result "weaker" (a log line from another process
# could be misread). We dismiss it and re-run so the control is unambiguous.
log() { echo "[negctl] $*"; }

log "=== dismiss any overlay ==="
input keyevent KEYCODE_BACK 2>/dev/null
sleep 1
log "  focus now: $(dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus' | sed 's/.*mCurrentFocus=//')"
echo ""

log "=== stop our targets so nothing of ours is running ==="
am force-stop com.tencent.mm 2>/dev/null
am force-stop com.tencent.wework 2>/dev/null
sleep 2
log "  wework pid: $(pidof com.tencent.wework 2>/dev/null || echo none)"
log "  wecom  pid: $(pidof com.tencent.mm 2>/dev/null || echo none)"
echo ""

log "=== clear logcat, launch the OUT-OF-SCOPE app, observe ==="
logcat -c 2>/dev/null
am force-stop com.tencent.qqmusic 2>/dev/null
sleep 1
monkey -p com.tencent.qqmusic -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
FG=$(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1)
log "  foreground: $FG"
case "$FG" in
  com.tencent.qqmusic*) log "  control app IS foreground  OK (unambiguous)" ;;
  *) log "  WARN control app NOT foreground; result weaker" ;;
esac
N=$(logcat -d 2>/dev/null | grep -c 'tablet-spoof')
log "  tablet-spoof log lines: $N  (must be 0)"
if [ "$N" != "0" ]; then
  log "  the offending lines:"
  logcat -d 2>/dev/null | grep 'tablet-spoof' | head -5 | sed 's/^/    /'
fi
am force-stop com.tencent.qqmusic 2>/dev/null
echo ""
if [ "$N" = "0" ]; then
  log "RESULT: PASS - strict whitelist confirmed (out-of-scope app produced nothing)"
else
  log "RESULT: FAIL"
fi
