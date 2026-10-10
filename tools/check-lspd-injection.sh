#!/system/bin/sh
# Did lspd load ANY module this boot? If yes, the loader works and our module is
# being rejected specifically. If no, the framework itself is degraded.
echo "=== running processes: any leftover from modules? ==="
ps -A 2>/dev/null | grep -iE 'wework|qqlive|weibo|systemui' | head -10 | sed 's/^/  /'
echo ""

echo "=== check each enabled module: is its target process currently running? ==="
DB=/data/adb/lspd/config/modules_config.db
S=/system/bin/sqlite3
for M in io.github.tabletspoof io.github.qqliveclean io.github.weiboclean; do
  echo "--- $M"
  for T in $($S "$DB" "SELECT app_pkg_name FROM scope WHERE module_pkg_name='$M';" 2>/dev/null); do
    PID=$(pidof "$T" 2>/dev/null)
    if [ -n "$PID" ]; then
      N=$(grep -c 'tabletspoof\|qqliveclean\|weiboclean' /proc/$PID/maps 2>/dev/null)
      echo "      $T running (pid $PID) module-lib refs in maps: ${N:-0}"
    else
      echo "      $T not running"
    fi
  done
done
echo ""

echo "=== LSPosed: does the log show it injecting into anything at all? ==="
LOG=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -n1)
echo "  log: $LOG"
echo "  --- injection-ish lines ---"
grep -iE 'LSPosedFramework|loaded module|Loaded |inject' "$LOG" 2>/dev/null | tail -25 | sed 's/^/    /'
echo ""

echo "=== systemui is a reliable lspd target: was it injected? ==="
SP=$(pidof com.android.systemui 2>/dev/null)
echo "  systemui pid: ${SP:-not running}"
[ -n "$SP" ] && grep -c 'lspd\|LSPosed' /proc/$SP/maps 2>/dev/null | sed 's/^/  refs in systemui maps: /'
echo ""

echo "=== our module's scope target: is WeCom's main process alive right now? ==="
echo "  wework pid: $(pidof com.tencent.wework 2>/dev/null || echo none)"
echo ""

echo "=== state dir: has ANY status file ever been written? ==="
ls -la /data/adb/tablet-spoof/ 2>&1 | sed 's/^/  /'
echo ""

echo "=== logcat: look for the module's own load messages (DEBUG is off, but lspd logs) ==="
logcat -d 2>/dev/null | grep -iE 'LSPosed|lspd|tabletspoof' | tail -25 | sed 's/^/  /'
