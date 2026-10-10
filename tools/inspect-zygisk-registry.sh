#!/system/bin/sh
# Zygisk Next keeps its own module registry in /data/adb/zygisksu/.
# Inspect it to see whether new modules must be registered there.
echo "=== /data/adb/zygisksu ==="
ls -la /data/adb/zygisksu/ | sed 's/^/  /'
echo ""
echo "=== znctx ==="
cat /data/adb/zygisksu/znctx 2>/dev/null | tr -d '\0' | sed 's/^/  /'
echo ""
echo "=== modules_info ==="
cat /data/adb/zygisksu/modules_info 2>/dev/null | tr -d '\0' | sed 's/^/  /'
echo ""
echo "=== modules_info.old ==="
cat /data/adb/zygisksu/modules_info.old 2>/dev/null | tr -d '\0' | sed 's/^/  /'
echo ""
echo "=== .magic (hex) ==="
od -An -tx1 /data/adb/zygisksu/.magic 2>/dev/null | sed 's/^/  /'
echo ""
echo "=== which modules are named in modules_info? ==="
for m in $(ls /data/adb/modules/); do
  if grep -qa "$m" /data/adb/zygisksu/modules_info 2>/dev/null; then
    echo "  registered: $m"
  else
    echo "  NOT registered: $m"
  fi
done
echo ""
echo "=== all module dirs present ==="
ls -1 /data/adb/modules/
echo ""
echo "=== any module with a 'disable' marker (Zygisk skips these)? ==="
for m in /data/adb/modules/*/; do
  n=$(basename "$m")
  [ -e "$m/disable" ] && echo "  DISABLED: $n"
  [ -e "$m/remove" ] && echo "  MARKED REMOVE: $n"
done
echo ""
echo "=== does zn-daemon log anywhere readable? ==="
find / -maxdepth 4 -name '*zn*log*' -o -maxdepth 4 -name '*zygisk*.log' 2>/dev/null | head -10 | sed 's/^/  /'
echo ""
echo "=== dmesg: zn-daemon module lines (kernel ring) ==="
dmesg 2>/dev/null | grep -i 'zn-daemon' | tail -15 | sed 's/^/  /'
