#!/system/bin/sh
# ============================================================================
# Deploy the freshly built native payload as a MINIMAL zygisk-only module, so we
# can verify it LOADS before doing any hook work.
#
# This is a deliberate stage-1 test module -- it does NOT touch the main
# tablet-spoof module, so a failure here cannot disturb the working setup.
# ============================================================================
M=tablet-spoof-native-test
DIR=/data/adb/modules/$M
SO=/data/local/tmp/tablet-spoof/arm64-v8a.so

[ -f "$SO" ] || { echo "ERROR: $SO not built"; exit 1; }

rm -rf "$DIR"
mkdir -p "$DIR/zygisk"
cp "$SO" "$DIR/zygisk/arm64-v8a.so"
chmod 644 "$DIR/zygisk/arm64-v8a.so"

cat > "$DIR/module.prop" <<EOF
id=$M
name=Tablet Spoof native payload (stage-1 load test)
version=0.0.1
versionCode=1
author=tablet-spoof
description=Stage-1 load test for the native Zygisk payload. Proves the .so loads before any hook is added.
EOF

echo "deployed $DIR"
ls -la "$DIR" "$DIR/zygisk"
echo ""
echo "NOTE: a REBOOT is required for Zygisk to load a newly added module."
