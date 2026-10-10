#!/system/bin/sh
# After the reboot: is the module injected into WeCom, and did Status run?
echo "=== lspd ==="
echo "  pid: $(pidof lspd 2>/dev/null || echo NOT-RUNNING)"
uptime | sed 's/^/  /'
echo ""
echo "=== WeCom process + injection check ==="
for p in $(pidof com.tencent.wework); do
  echo "  pid $p : $(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')"
  echo "    lspd refs: $(grep -c 'lspd\|LSPosed' /proc/$p/maps 2>/dev/null)"
  echo "    our lib refs: $(grep -c 'tabletspoof' /proc/$p/maps 2>/dev/null)"
  grep -o '/data/app/[^ ]*io.github.tabletspoof[^ ]*' /proc/$p/maps 2>/dev/null | sort -u | head -3 | sed 's/^/      /'
done
echo ""
echo "=== status file candidates ==="
for f in /data/adb/tablet-spoof/hook-status \
         /data/data/com.tencent.wework/files/ww_device_metrics.dat \
         /data/data/com.tencent.mm/files/ww_device_metrics.dat ; do
  if [ -f "$f" ]; then
    echo "  PRESENT: $f  ($(stat -c '%s bytes, owner=%U:%G, mode=%a' "$f" 2>/dev/null))"
    echo "    --- contents ---"
    sed 's/^/      /' "$f"
    echo "    --- end ---"
  else
    echo "  absent : $f"
  fi
done
echo ""
echo "=== did the module log anything to lspd's log? ==="
LOG=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -n1)
echo "  log: $LOG"
grep -iE 'tabletspoof|tablet-spoof' "$LOG" 2>/dev/null | tail -20 | sed 's/^/    /'
echo "  (empty above = our module produced no lspd log lines)"
echo ""
echo "=== Is our module among those lspd reports as loaded? ==="
grep -iE 'loadModule|module.*loaded|preloaded' "$LOG" 2>/dev/null | tail -10 | sed 's/^/  /'
echo ""
echo "=== install time of the currently-installed APK vs lspd start ==="
APK=$(pm path io.github.tabletspoof 2>/dev/null | head -n1 | sed 's/^package://')
echo "  apk: $APK"
stat -c '  apk mtime=%y' "$APK" 2>/dev/null
awk '{print "  lspd starttime_ticks="$22}' /proc/$(pidof lspd)/stat 2>/dev/null
echo "  now: $(date '+%Y-%m-%d %H:%M:%S')"
