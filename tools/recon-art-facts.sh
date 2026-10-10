#!/system/bin/sh
# Gather the facts we need to make the ART hook safe:
#  - Android API level and ART runtime version
#  - whether libart is loaded and its symbols are resolvable
#  - the pointer size / layout constraints
# Read-only.
echo "=== platform ==="
getprop ro.build.version.sdk | sed 's/^/  sdk: /'
getprop ro.build.version.release | sed 's/^/  release: /'
getprop dalvik.vm.isa.arm64.features | sed 's/^/  isa features: /'
getprop ro.product.cpu.abi | sed 's/^/  abi: /'
echo ""
echo "=== ART runtime ==="
getprop persist.device_config.runtime_native.use_app_image_startup_cache >/dev/null 2>&1
ls -la /apex/com.android.art/lib64/libart.so 2>/dev/null | sed 's/^/  /'
ls -la /apex/com.android.art/javalib/core-oj.jar 2>/dev/null | sed 's/^/  /'
echo "  libart in a running process?"
for p in $(pidof com.tencent.wework) ; do
  grep -c 'libart.so' /proc/$p/maps 2>/dev/null | sed "s/^/    pid $p libart maps: /"
done
echo ""
echo "=== is the ART runtime debuggable / can we read ArtMethod? ==="
echo "  (ArtMethod layout is internal; we probe it empirically instead of assuming)"
echo ""
echo "=== app-level: does the target app run in 64-bit? ==="
for p in $(pidof com.tencent.wework); do
  cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ' | sed 's/^/  cmdline: /'; echo
  # 64-bit process has no 'zygote' 32-bit marker and maps lib64
  grep -c '/lib64/' /proc/$p/maps 2>/dev/null | sed 's/^/  lib64 maps: /'
done
echo ""
echo "=== our module's .so: check for libc++ dependency (the bug that broke loading) ==="
TC=/data/data/com.termux/files/usr
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
[ -f "$SO" ] || SO=/data/adb/modules/tablet-spoof-native-test/zygisk/arm64-v8a.so
echo "  so: $SO"
if [ -x "$TC/bin/llvm-readelf" ]; then
  "$TC/bin/llvm-readelf" -d "$SO" 2>/dev/null | grep -i 'NEEDED' | sed 's/^/    /'
else
  echo "  (llvm-readelf not found; using strings)"
  strings "$SO" 2>/dev/null | grep -i 'libc++\|liblog\|libdl\|libm\.so\|libc\.so' | sort -u | sed 's/^/    /'
fi
echo ""
echo "=== does our stub concept hold: is arm64 the ABI the app uses? ==="
echo "  app abi: $(getprop ro.product.cpu.abi)"
