#!/system/bin/sh
# Deploy the built payload into the REAL module (tablet-spoof-native) and show
# exactly what is in place. Read-only w.r.t. anything else.
SO=/data/local/tmp/tablet-spoof/arm64-v8a.so
DIR=/data/adb/modules/tablet-spoof-native

[ -f "$SO" ] || { echo "ERROR: $SO not built"; exit 1; }

echo "=== before ==="
ls -la "$DIR/zygisk/" 2>/dev/null

mkdir -p "$DIR/zygisk"
cp "$SO" "$DIR/zygisk/arm64-v8a.so"
chmod 644 "$DIR/zygisk/arm64-v8a.so"

echo ""
echo "=== after ==="
ls -la "$DIR/zygisk/"
echo ""
echo "  installed .so size: $(stat -c %s "$DIR/zygisk/arm64-v8a.so")"
echo "  source     .so size: $(stat -c %s "$SO")"
echo "  module.prop:"
sed 's/^/    /' "$DIR/module.prop" 2>/dev/null
echo ""
echo "=== remove my stage-1 test module (debris) ==="
rm -rf /data/adb/modules/tablet-spoof-native-test
ls -d /data/adb/modules/tablet-spoof-native* 2>/dev/null | sed 's/^/  remaining: /'
echo ""
echo "REBOOT REQUIRED for Zygisk to load the new .so."
