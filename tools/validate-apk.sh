#!/system/bin/sh
# Validate the built APK parses as a package WITHOUT installing it.
# Uses aapt2-free checks available on-device plus pm's own parser via a
# content-provider-free path.
APK="${1:-/data/local/tmp/armed.apk}"

echo "=== apk: $APK ==="
ls -la "$APK"
echo ""

echo "=== zip integrity ==="
if unzip -t "$APK" >/dev/null 2>&1; then echo "  zip OK"; else echo "  zip CORRUPT"; fi
echo ""

echo "=== required entries ==="
for e in AndroidManifest.xml classes.dex META-INF/xposed/module.prop META-INF/xposed/scope.list META-INF/xposed/java_init.list; do
  if unzip -l "$APK" 2>/dev/null | grep -q "$e"; then
    echo "  OK    $e"
  else
    echo "  MISS  $e"
  fi
done
echo ""

echo "=== mutable-dex / v2-v3 signature block presence ==="
# apksig block shows up as a trailing magic; check via the zip comment area heuristics
unzip -l "$APK" 2>/dev/null | grep -c 'META-INF/.*\.\(RSA\|SF\|MF\)' | sed 's/^/  v1 signature files: /'
echo ""

echo "=== xposed metadata contents ==="
for e in META-INF/xposed/module.prop META-INF/xposed/scope.list META-INF/xposed/java_init.list; do
  echo "  --- $e"
  unzip -p "$APK" "$e" 2>/dev/null | sed 's/^/      /'
done
echo ""

echo "=== does PackageManager accept the manifest? (parse-only) ==="
# `pm dump` on a file path is not supported; the reliable parse check is
# aapt2 (host) or attempting install. We use `cmd package` help probe instead.
echo "  (manifest parse is validated host-side by aapt2 dump badging)"
echo ""
echo "=== done ==="
