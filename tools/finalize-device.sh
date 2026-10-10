#!/system/bin/sh
# Make the device match what a fresh flash of the released zip produces, then do
# the final foreground-asserted behavioural check.
log() { echo "[finalize] $*"; }

log "=== 1. create the disable marker (the zip's customize.sh does this on install) ==="
touch /data/adb/modules/tablet-spoof-native/disable
log "  marker: $([ -f /data/adb/modules/tablet-spoof-native/disable ] && echo PRESENT || echo FAILED)"
log "  (device now equals a fresh flash: native payload disabled by default)"
echo ""

log "=== 2. foreground-asserted behavioural check (the guard that caught a false negative) ==="
am force-stop com.tencent.mm 2>/dev/null     # WeChat self-launches and steals focus
am force-stop org.lsposed.manager 2>/dev/null
sleep 2
am force-stop com.tencent.wework
sleep 3
am start -W -n com.tencent.wework/.login.controller.LoginWxAuthActivity 2>&1 | grep -E 'Status|LaunchState' | sed 's/^/  /'
sleep 10

R=$(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1)
log "  resumed: $R"
if [ "$R" != "com.tencent.wework/.login.controller.LoginWxAuthActivity" ]; then
  log "  *** INCONCLUSIVE: another app is foreground, so a dump would describe IT ***"
  exit 3
fi
log "  OK: WeCom login activity is foreground"

rm -f /sdcard/final.xml
uiautomator dump /sdcard/final.xml >/dev/null 2>&1
if [ -f /sdcard/final.xml ]; then
  log "  dump bytes: $(wc -c < /sdcard/final.xml)"
  log "  package: $(grep -o 'package="[^"]*"' /sdcard/final.xml | sort -u | head -1)"
  if grep -q '平板和手机同时登录' /sdcard/final.xml; then
    log "  *** PAD ENTRY PRESENT -- delivery works ***"
    grep -o 'text="[^"]*"' /sdcard/final.xml | sed 's/text=//' | sort -u | sed 's/^/      /'
  else
    log "  PAD ENTRY ABSENT"
    grep -o 'text="[^"]*"' /sdcard/final.xml | sed 's/Text=//' | sort -u | sed 's/^/      /'
  fi
fi
rm -f /sdcard/final.xml
echo ""

log "=== 3. negative control: out-of-scope app produces nothing ==="
am force-stop com.tencent.qqmusic 2>/dev/null; sleep 1
logcat -c 2>/dev/null
monkey -p com.tencent.qqmusic -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
FG=$(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1)
log "  foreground: $FG"
N=$(logcat -d 2>/dev/null | grep -c 'tablet-spoof')
log "  tablet-spoof log lines: $N (expect 0)"
am force-stop com.tencent.qqmusic 2>/dev/null
