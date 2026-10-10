#!/system/bin/sh
# Why is Zygisk not loading our native module? Compare against a module that DOES
# load (device_faker) to find the difference.
echo "=== Zygisk Next: which modules does it report loading? ==="
for f in /data/adb/modules/zygisksu/*.log /data/adb/zygisksu/*.log; do
  [ -f "$f" ] || continue
  echo "  --- $f"
  tail -30 "$f" | sed 's/^/      /'
done
echo ""
echo "=== the zn-daemon module scan lines (from any log we can read) ==="
LOG=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -n1)
grep -i 'zn-daemon\|zn-zygisk' "$LOG" 2>/dev/null | grep -i 'module' | tail -20 | sed 's/^/  /'
echo ""
echo "=== installed zygisk modules: structure comparison ==="
for m in /data/adb/modules/*/; do
  n=$(basename "$m")
  if [ -d "$m/zygisk" ]; then
    echo "  --- $n"
    echo "      module.prop: $([ -f "$m/module.prop" ] && echo present || echo MISSING)"
    ls -la "$m/zygisk/" | tail -n +2 | sed 's/^/      /'
    # Zygisk Next / Magisk require these markers depending on version
    for marker in disable remove skip_mount; do
      [ -e "$m/$marker" ] && echo "      MARKER: $marker present"
    done
  fi
done
echo ""
echo "=== does Zygisk Next require an explicit module list? ==="
ls -la /data/adb/zygisksu/ 2>/dev/null | sed 's/^/  /'
cat /data/adb/zygisksu/modules 2>/dev/null | sed 's/^/  modules: /'
echo ""
echo "=== device_faker (a module that works) vs ours -- perms and owner ==="
for m in device_faker tablet-spoof-native-test; do
  echo "  --- $m"
  ls -ld /data/adb/modules/$m 2>/dev/null | sed 's/^/      /'
  ls -la /data/adb/modules/$m/zygisk/ 2>/dev/null | tail -n +2 | sed 's/^/      /'
  echo "      module.prop:"; sed 's/^/        /' /data/adb/modules/$m/module.prop 2>/dev/null
done
echo ""
echo "=== is 'update' or 'skip_mount' needed? check a working module's full tree ==="
find /data/adb/modules/device_faker -maxdepth 2 2>/dev/null | sed 's/^/  /'
echo ""
echo "=== Zygisk Next log location discovery ==="
find /data/adb -maxdepth 3 -name '*.log' 2>/dev/null | grep -i 'zygisk' | head -10 | sed 's/^/  /'
