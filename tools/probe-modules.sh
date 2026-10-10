#!/system/bin/sh
# Probe the device's module-manager layout. Read-only.
echo "=== modules dir entries with module.prop ==="
for m in /data/adb/modules/*/; do
  [ -d "$m" ] || continue
  name=$(echo "$m" | sed 's#/data/adb/modules/##; s#/$##')
  if [ -f "$m/module.prop" ]; then
    echo "--- $name"
    cat "$m/module.prop"
    echo ""
  else
    echo "--- $name (NO module.prop)"
  fi
done
echo ""
echo "=== /data/adb full tree (depth 1) ==="
ls -la /data/adb/
echo ""
echo "=== mount type of /data/adb/modules ==="
mount | grep -i 'adb/modules'
echo ""
echo "=== is /data/adb/modules a symlink or real dir ==="
ls -ld /data/adb/modules
