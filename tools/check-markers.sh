#!/system/bin/sh
# Confirm the deployed artifact carries the TIMELINE and KV probe code.
SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
echo "[markers] deployed artifact:"
stat -c '  size=%s mtime=%y' "$SO" 2>/dev/null
md5sum "$SO" 2>/dev/null | sed 's/^/  md5 /'
echo ""
echo "[markers] probe strings (must be present):"
for s in TIMELINE PROBE-FINAL "KV:" HOOK_MISS RESOLVED ts_native; do
  N=$(strings "$SO" 2>/dev/null | grep -c -- "$s")
  printf '  %-14s %s\n' "$s" "$N"
done
echo ""
echo "[markers] the KV key we will try to set:"
strings "$SO" 2>/dev/null | grep -c 'KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE' | sed 's/^/  occurrences: /'
echo "[markers] gqp/Leux class names:"
strings "$SO" 2>/dev/null | grep -E 'logic\.(gqp|Leux)' | sed 's/^/  /'
