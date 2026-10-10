#!/system/bin/sh
# Why are the target classes referenced but never defined?
# Check for: split APKs, tinker patch dex, and other dex sources.
PKG=com.tencent.wework
echo "=== all package paths (splits included) ==="
pm path "$PKG"
echo ""
echo "=== package codePath / splits ==="
dumpsys package "$PKG" 2>/dev/null | grep -iE 'codePath|split|primaryCpuAbi|resourcePath' | head -20
echo ""
echo "=== tinker / patch dex dirs under the app data ==="
ls -la "/data/data/$PKG/tinker" 2>/dev/null | head -20
find "/data/data/$PKG/tinker" -name '*.dex' 2>/dev/null | head -20
echo ""
echo "=== any loose dex under the data dir? ==="
find "/data/data/$PKG" -maxdepth 4 -name '*.dex' 2>/dev/null | head -20
echo ""
echo "=== odex/vdex in dalvik-cache for wework ==="
ls -la /data/dalvik-cache/arm64/ 2>/dev/null | grep -i wework | head -20
echo ""
echo "=== app_fix_patch / app_patch_download contents ==="
for d in app_fix_patch app_patch_download app_libs; do
  echo "  --- $d"
  ls -la "/data/data/$PKG/$d" 2>/dev/null | head -10
done
echo ""
echo "=== count dex in base.apk vs total classes ==="
APK=$(pm path "$PKG" 2>/dev/null | head -n1 | sed 's/^package://')
unzip -l "$APK" 2>/dev/null | grep -c 'classes.*\.dex' | sed 's/^/  dex in base.apk: /'
echo ""
echo "=== does any dex define a class whose name merely CONTAINS WeworkServiceImpl? ==="
cd /data/local/tmp/alldex 2>/dev/null || exit 1
grep -la 'WeworkServiceImpl' *.dex 2>/dev/null | sed 's/^/  mentions: /'
echo ""
echo "=== look for the impl package in other forms ==="
for s in 'foundation/impl/' 'foundation/logic/Application' 'WeworkServiceImpl' 'wework/foundation/impl' ; do
  n=$(grep -la "$s" *.dex 2>/dev/null | tr '\n' ' ')
  printf '  %-36s %s\n' "$s" "${n:-none}"
done
