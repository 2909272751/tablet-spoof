#!/system/bin/sh
# Diagnose why the in-process status file was not written.
echo "=== is the module actually being loaded into WeCom? ==="
pidof com.tencent.wework | tr ' ' '\n' | while read -r p; do
  [ -n "$p" ] || continue
  echo "  pid $p cmdline: $(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')"
done
echo ""
echo "=== does the WeCom process have our dex/module loaded? ==="
for p in $(pidof com.tencent.wework); do
  echo "  --- pid $p"
  grep -c 'tabletspoof' /proc/$p/maps 2>/dev/null | sed 's/^/      tabletspoof refs in maps: /'
  grep -o '/data/app/[^ ]*tabletspoof[^ ]*' /proc/$p/maps 2>/dev/null | sort -u | head -5 | sed 's/^/      /'
done
echo ""
echo "=== lspd log: does it mention our module? ==="
LOG=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -n1)
echo "  log: $LOG"
if [ -n "$LOG" ]; then
  grep -i 'tabletspoof' "$LOG" | tail -20 | sed 's/^/    /'
fi
echo ""
echo "=== lspd modules log ==="
MLOG=$(ls -t /data/adb/lspd/log/modules_*.log 2>/dev/null | head -n1)
echo "  log: $MLOG"
[ -n "$MLOG" ] && sed 's/^/    /' "$MLOG" | tail -10
echo ""
echo "=== LSPosed db state for our module ==="
/system/bin/sqlite3 /data/adb/lspd/config/modules_config.db \
  "SELECT module_pkg_name, apk_path FROM modules WHERE module_pkg_name LIKE '%tabletspoof%';" 2>&1 | sed 's/^/  /'
/system/bin/sqlite3 /data/adb/lspd/config/modules_config.db \
  "SELECT module_pkg_name, user_id, enabled, scope_request_blocked FROM modules_state WHERE module_pkg_name LIKE '%tabletspoof%';" 2>&1 | sed 's/^/  /'
echo "  scope:"
/system/bin/sqlite3 /data/adb/lspd/config/modules_config.db \
  "SELECT module_pkg_name, app_pkg_name FROM scope WHERE module_pkg_name LIKE '%tabletspoof%';" 2>&1 | sed 's/^/  /'
echo ""
echo "=== state dir perms ==="
ls -la /data/adb/tablet-spoof/ 2>&1 | sed 's/^/  /'
echo ""
echo "=== can we see any tabletspoof classload in WeCom? (logcat window) ==="
logcat -d -t 300 2>/dev/null | grep -iE 'tabletspoof|lsposed|xposed' | tail -15 | sed 's/^/  /'
