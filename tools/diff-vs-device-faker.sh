#!/system/bin/sh
# Why does device_faker's callback run in normal app processes while ours does not?
# Both are mapped in; only one is invoked. Diff the STRUCTURE (not the code).
#
# This is the highest-value check: device_faker is a known-working Zygisk module on
# this exact device/loader, so any structural difference is a strong candidate for
# why our ABI callbacks are not being called for third-party apps.

DF=/data/adb/modules/device_faker
OURS=/data/adb/modules/tablet-spoof-native
TC=/data/data/com.termux/files/usr

echo "=== 1. module tree comparison ==="
echo "--- device_faker (WORKS)"
find "$DF" -maxdepth 2 2>/dev/null | sed 's/^/    /'
echo "--- ours"
find "$OURS" -maxdepth 2 2>/dev/null | sed 's/^/    /'
echo ""

echo "=== 2. module.prop comparison ==="
echo "--- device_faker"; sed 's/^/    /' "$DF/module.prop" 2>/dev/null
echo "--- ours";         sed 's/^/    /' "$OURS/module.prop" 2>/dev/null
echo ""

echo "=== 3. per-arch payloads ==="
echo "--- device_faker"; ls -la "$DF/zygisk/" 2>/dev/null | tail -n +2 | sed 's/^/    /'
echo "--- ours";         ls -la "$OURS/zygisk/" 2>/dev/null | tail -n +2 | sed 's/^/    /'
echo ""

echo "=== 4. EXPORTED SYMBOLS (the key ABI question) ==="
for m in "$DF" "$OURS"; do
  so="$m/zygisk/arm64-v8a.so"
  [ -f "$so" ] || continue
  echo "--- $(basename $m)  ($(stat -c %s "$so") bytes)"
  if [ -x "$TC/bin/llvm-nm" ]; then
    echo "    defined dynamic symbols:"
    "$TC/bin/llvm-nm" -D --defined-only "$so" 2>/dev/null | sed 's/^/      /' | head -25
    echo "    NEEDED:"
    "$TC/bin/llvm-readelf" -d "$so" 2>/dev/null | grep -i needed | sed 's/^/      /'
    echo "    SONAME:"
    "$TC/bin/llvm-readelf" -d "$so" 2>/dev/null | grep -i soname | sed 's/^/      /'
  else
    echo "    (llvm tools missing)"
  fi
done
echo ""

echo "=== 5. does device_faker export zygisk_module_entry / companion? ==="
for m in "$DF" "$OURS"; do
  so="$m/zygisk/arm64-v8a.so"
  [ -f "$so" ] || continue
  echo "--- $(basename $m)"
  for sym in zygisk_module_entry zygisk_companion_entry zygisk_module_ctor; do
    if [ -x "$TC/bin/llvm-nm" ]; then
      if "$TC/bin/llvm-nm" -D --defined-only "$so" 2>/dev/null | grep -q "$sym"; then
        echo "      HAS  $sym"
      else
        echo "      no   $sym"
      fi
    fi
  done
done
echo ""

echo "=== 6. is our module in the Zygisk registry with the right arch tag? ==="
cat /data/adb/zygisksu/modules_info 2>/dev/null | sed 's/^/  /'
echo ""
echo "  ours has only 64-bit; device_faker also only 64-bit?"
ls "$DF/zygisk/" 2>/dev/null | sed 's/^/    df: /'
ls "$OURS/zygisk/" 2>/dev/null | sed 's/^/    us: /'
echo ""

echo "=== 7. any disable/denylist markers? ==="
for m in "$DF" "$OURS"; do
  echo "--- $(basename $m)"
  for f in disable remove skip_mount denylist; do
    [ -e "$m/$f" ] && echo "      MARKER: $f"
  done
done
echo ""
echo "=== 8. Zygisk Next config: is there a per-module allow/deny list? ==="
ls -la /data/adb/zygisksu/ 2>/dev/null | sed 's/^/  /'
od -c /data/adb/zygisksu/znctx 2>/dev/null | head -5 | sed 's/^/  /'
echo ""
echo "=== 9. device_faker's .so: do its strings reveal module conventions? ==="
strings "$DF/zygisk/arm64-v8a.so" 2>/dev/null | grep -iE 'zygisk|denylist|allowlist|companion|REGISTER' | sort -u | head -20 | sed 's/^/  /'
