#!/system/bin/sh
# Why does the dump show LSPosed Manager when WeCom's activity reports as resumed?
# Hypothesis: the manager is being re-launched between our check and the dump (it is
# in the recents/launcher stack, or something is restarting it). We verify by:
#   1. force-stopping the manager and confirming it stays stopped
#   2. checking what is foreground IMMEDIATELY BEFORE the dump
#   3. dumping and checking the dump's own content against the foreground
log() { echo "[why-manager] $*"; }

log "=== 1. is the manager being restarted? ==="
log "  pid before: $(pidof org.lsposed.manager 2>/dev/null || echo none)"
am force-stop org.lsposed.manager 2>/dev/null
sleep 2
log "  pid after force-stop: $(pidof org.lsposed.manager 2>/dev/null || echo none)"
sleep 5
log "  pid 5s later: $(pidof org.lsposed.manager 2>/dev/null || echo none)"
log "  (if it reappears, something keeps relaunching it)"
echo ""

log "=== 2. launch WeCom and watch the foreground over time ==="
am force-stop com.tencent.wework
sleep 2
am start -W -n com.tencent.wework/.login.controller.LoginWxAuthActivity >/dev/null 2>&1
for i in 1 2 3 4 5 6; do
  sleep 2
  FG=$(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1)
  MF=$(dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus' | sed 's/.*mCurrentFocus=//')
  printf '  t+%-2ss resumed=%-60s focus=%s\n' "$((i*2))" "$FG" "$MF"
done
echo ""

log "=== 3. dump NOW and see which app it describes ==="
rm -f /sdcard/w.xml
uiautomator dump /sdcard/w.xml >/dev/null 2>&1
if [ -f /sdcard/w.xml ]; then
  log "  bytes: $(wc -c < /sdcard/w.xml)"
  log "  package hints in the dump:"
  grep -o 'package="[^"]*"' /sdcard/w.xml | sort -u | head -5 | sed 's/^/    /'
  log "  pad entry: $(grep -q '平板和手机同时登录' /sdcard/w.xml && echo PRESENT || echo absent)"
  log "  manager UI markers (仓库/概览/模块/设置):"
  grep -o 'text="\(仓库\|概览\|模块\|设置\)"' /sdcard/w.xml | sort -u | sed 's/^/    /'
fi
rm -f /sdcard/w.xml
echo ""

log "=== 4. uiautomator's own idea of the active window ==="
dumpsys window 2>/dev/null | grep -iE 'mCurrentFocus|mFocusedApp' | head -4 | sed 's/^/  /'
echo ""
log "  NOTE: uiautomator dumps the ACTIVE WINDOW. If an overlay or the manager's'
log "  window has focus, the dump describes that instead -- even while our activity
log "  is the 'resumed' one. This is a known divergence between the activity stack
log "  and window focus."
