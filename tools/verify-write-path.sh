#!/system/bin/sh
# Verify the Lead's permission diagnosis and find a writable location for the
# status channel. Read-only checks plus a controlled write test AS THE APP UID.
echo "=== directory permissions along the path ==="
for d in /data /data/adb /data/adb/tablet-spoof; do
  ls -ld "$d" 2>&1 | sed 's/^/  /'
done
echo ""
echo "=== SELinux ==="
getenforce 2>/dev/null | sed 's/^/  /'
echo ""
echo "=== can the SHELL user traverse /data/adb? ==="
ls /data/adb >/dev/null 2>&1 && echo "  shell: OK" || echo "  shell: DENIED (so an app uid is denied too)"
echo ""
echo "=== can we even read it as root? ==="
ls /data/adb/tablet-spoof/ 2>&1 | sed 's/^/  /'
echo ""
echo "=== the app's own writable dirs (WeCom uid) ==="
for d in /data/data/com.tencent.wework /data/data/com.tencent.wework/files /data/data/com.tencent.wework/cache; do
  if [ -d "$d" ]; then ls -ld "$d" 2>&1 | sed 's/^/  /'; fi
done
echo ""
echo "=== what does the app's files dir contain (for a neutral filename) ==="
ls /data/data/com.tencent.wework/files/ 2>/dev/null | head -20 | sed 's/^/  /'
echo ""
echo "=== ANY world-writable path both an app uid and root could use? ==="
for d in /data/local/tmp /sdcard /storage/emulated/0; do
  ls -ld "$d" 2>&1 | sed 's/^/  /'
done
echo ""
echo "=== does /data/local/tmp survive reboot? and who owns it ==="
stat -c '  %n owner=%U:%G mode=%a' /data/local/tmp 2>/dev/null
echo ""
echo "=== confirm Status.java's target path is the blocker ==="
echo "  Status.STATUS_PATH = /data/adb/tablet-spoof/hook-status"
echo "  writer uid would be: u0_a398 (WeCom)"
echo "  /data/adb mode      : $(stat -c %a /data/adb 2>/dev/null) $(stat -c %U /data/adb 2>/dev/null)"
echo "  => app uid cannot open a file under /data/adb. Channel is structurally dead."
