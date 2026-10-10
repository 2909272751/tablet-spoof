#!/system/bin/sh
# Determine whether lspd has (re)started since the new APK was installed.
echo "=== uptime ==="
uptime
echo ""
echo "=== lspd pid + start time (field 22 of /proc/<pid>/stat = starttime ticks) ==="
P=$(pidof lspd)
echo "pid: $P"
if [ -n "$P" ]; then
  awk '{print "  starttime_ticks: "$22}' /proc/$P/stat 2>/dev/null
fi
echo ""
echo "=== clock ticks since boot for reference ==="
awk '{print "  btime: "$1}' /proc/stat 2>/dev/null
echo "  now epoch: $(date +%s)"
echo ""
echo "=== installed companion APK (mtime = when it was installed) ==="
for f in /data/app/*/io.github.tabletspoof*/base.apk; do
  [ -f "$f" ] || continue
  echo "  $f"
  stat -c '    mtime=%y  size=%s' "$f" 2>/dev/null
done
echo ""
echo "=== lspd lock + config mtimes ==="
stat -c '  lock      mtime=%y' /data/adb/lspd/lock 2>/dev/null
stat -c '  config db mtime=%y' /data/adb/lspd/config/modules_config.db 2>/dev/null
echo ""
echo "=== conclusion inputs ==="
echo "  If lspd started BEFORE the apk mtime, the new dex is not live yet."
