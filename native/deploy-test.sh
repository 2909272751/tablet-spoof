#!/system/bin/sh
set -eu
BASE=/data/local/tmp/ts-native-src/output
MOD=/data/adb/modules/tablet-spoof-pure
for f in "$BASE/zygisk/arm64-v8a.so" "$BASE/lib/libtablet-spoof-engine.so" "$BASE/lib/libc++_shared.so" "$BASE/bridge.dex" /data/local/tmp/ts-native-src/module.prop; do
  [ -s "$f" ] || { echo "Missing payload: $f"; exit 1; }
done
if [ -d "$MOD" ] && [ ! -f "$MOD/module.prop" ]; then
  echo 'Refusing to overwrite unrecognized directory'; exit 1
fi
mkdir -p "$MOD/zygisk" "$MOD/lib"
cp "$BASE/zygisk/arm64-v8a.so" "$MOD/zygisk/arm64-v8a.so"
cp "$BASE/lib/libtablet-spoof-engine.so" "$MOD/lib/libtablet-spoof-engine.so"
cp "$BASE/lib/libc++_shared.so" "$MOD/lib/libc++_shared.so"
cp /data/local/tmp/ts-native-src/module.prop "$MOD/module.prop"
cp "$BASE/bridge.dex" "$MOD/bridge.dex"
chmod 755 "$MOD" "$MOD/zygisk" "$MOD/lib"
chmod 644 "$MOD/module.prop" "$MOD/bridge.dex" "$MOD/zygisk/arm64-v8a.so" "$MOD/lib/"*.so
chcon u:object_r:system_file:s0 "$MOD" "$MOD/lib" "$MOD/bridge.dex"
chcon u:object_r:system_lib_file:s0 "$MOD/lib/libc++_shared.so" "$MOD/lib/libtablet-spoof-engine.so"
touch "$MOD/skip_mount"
echo 'DEPLOYED; reboot required'
