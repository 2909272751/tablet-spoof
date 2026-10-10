#!/system/bin/sh
# WHY is WeCom crashing? A crash reason is decisive evidence, and it also tells us
# whether the `disable` marker (which I just added) is implicated.
#
# I explicitly do NOT assume the cause. Two live hypotheses:
#   H1: unrelated -- ~40 launches tonight + a known fingerprint-HAL crash storm.
#   H2: the `disable` marker stopped OUR module's service.sh from running, which
#       normally keeps the LSPosed companion enrolled. If so, disabling the native
#       payload interferes with the LSPosed half -- which the docs claim it does NOT.
log() { echo "[crash] $*"; }

log "=== 1. what does the crash actually say? ==="
logcat -d 2>/dev/null | grep -iE 'FATAL EXCEPTION|beginning of crash|com.tencent.wework.*(SIGSEGV|SIGABRT|died|crash)' | tail -20 | sed 's/^/  /'
echo ""

log "=== 2. java-level stack trace, if any ==="
logcat -d 2>/dev/null | grep -A 12 'FATAL EXCEPTION' | tail -30 | sed 's/^/  /'
echo ""

log "=== 3. native crash in the tombstone list? ==="
ls -t /data/tombstones/ 2>/dev/null | head -5 | sed 's/^/  /'
T=$(ls -t /data/tombstones/tombstone_* 2>/dev/null | head -1)
if [ -n "$T" ]; then
  log "  newest: $T  ($(stat -c %y "$T" 2>/dev/null))"
  grep -iE 'pid|process name|signal|abort message' "$T" 2>/dev/null | head -10 | sed 's/^/    /'
fi
echo ""

log "=== 4. H2 test: is the LSPosed companion still installed and enrolled? ==="
log "  APK installed?     : $(pm path io.github.tabletspoof 2>/dev/null || echo 'NOT INSTALLED')"
DB=/data/adb/lspd/config/modules_config.db
S=/system/bin/sqlite3
log "  LSPosed enabled    : $("$S" "$DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='io.github.tabletspoof' AND user_id=0;" 2>/dev/null)"
log "  scope rows         : $("$S" "$DB" "SELECT count(*) FROM scope WHERE module_pkg_name='io.github.tabletspoof';" 2>/dev/null)"
log "  => if the APK is missing or enabled=0, H2 is supported"
echo ""

log "=== 5. H1 test: how many times has WeCom crashed recently? ==="
log "  SIGSEGV/SIGABRT for wework in the buffer: $(logcat -d 2>/dev/null | grep -ciE 'com.tencent.wework.*(SIGSEGV|SIGABRT)')"
log "  fingerprint HAL crash storm lines: $(logcat -d 2>/dev/null | grep -ciE 'fingerprint|goodix|fpc')"
log "  => a high unrelated-crash count supports H1"
echo ""

log "=== 6. does WeCom actually start at all now? ==="
am force-stop com.tencent.wework 2>/dev/null
sleep 3
log "  after force-stop, pid: $(pidof com.tencent.wework 2>/dev/null || echo none)"
am start -W -n com.tencent.wework/.login.controller.LoginWxAuthActivity >/dev/null 2>&1
sleep 12
P=$(pidof com.tencent.wework 2>/dev/null)
log "  after launch, pid: ${P:-none}"
if [ -n "$P" ]; then
  log "  ALIVE -- so it can start. Foreground now:"
  dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* \([^ ]*\) \([^ ]*\) .*/\2/p' | head -1 | sed 's/^/    /'
else
  log "  DEAD immediately -- crash on startup"
fi
echo ""

log "=== 7. the marker question, directly ==="
log "  disable marker present: $([ -f /data/adb/modules/tablet-spoof-native/disable ] && echo YES || echo no)"
log "  OUR module's service.sh would re-install/enrol the companion. A DISABLED"
log "  module's service.sh does NOT run -- so the enrol step is skipped at boot."
log "  BUT the APK was already installed and enrolled earlier, and neither is"
log "  undone by the marker. Check 4 above is the decisive test."
