#!/system/bin/sh
# Verify the exact hook target signatures in WeCom's real dex files.
# READ-ONLY. Run as ROOT.
APK=$(pm path com.tencent.wework 2>/dev/null | head -n1 | sed 's/^package://')
echo "=== WeCom apk: $APK ==="
ls -la "$APK" 2>/dev/null
echo ""
echo "=== dex files in the apk ==="
unzip -l "$APK" 2>/dev/null | grep -E 'classes[0-9]*\.dex' | head -30
echo ""
echo "=== which dex contains which class (byte scan, read-only) ==="
WORK=/data/local/tmp/wework-dex
rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK" || exit 1
unzip -o "$APK" 'classes*.dex' >/dev/null 2>&1
ls -la | head -30
echo ""
for cls in \
  'Lcom/tencent/wework/foundation/logic/Application;' \
  'Lcom/tencent/wework/foundation/impl/WeworkServiceImpl;' \
  'Lcom/tencent/wework/login/controller/LoginWxAuthActivity;' ; do
  echo "--- $cls"
  for d in classes*.dex; do
    if grep -qa "$cls" "$d" 2>/dev/null; then
      echo "      in $d"
    fi
  done
done
echo ""
echo "=== is there an android.app.Application isAndroidPad string anywhere? ==="
grep -la 'isAndroidPad' classes*.dex 2>/dev/null | head
echo ""
echo "=== confirm the descriptor strings exist ==="
for s in 'isAndroidPad' 'getDeviceType' 'initView' 'mQrLogin' 'mPhoneLoginTv' 'mPhoneLoginBtn'; do
  n=$(grep -la "$s" classes*.dex 2>/dev/null | tr '\n' ' ')
  echo "  $s -> ${n:-not found}"
done
echo ""
echo "=== cleanup temp dex copies ==="
cd /; rm -rf "$WORK"
echo "done (nothing was modified)"
