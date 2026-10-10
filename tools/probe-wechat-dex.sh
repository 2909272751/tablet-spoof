#!/system/bin/sh
# ============================================================================
# tablet-spoof / probe-wechat-dex.sh   (AS ROOT, READ-ONLY)
# ============================================================================
# Recon for WeChat (com.tencent.mm) tablet detection.
#
# WeCom's mechanism does NOT transfer: WeChat is a different codebase and keys
# on ro.product.model.is.tablet / ro.build.characteristics / its own isPad-style
# helpers. This script only LOCATES candidate symbols; it changes nothing.
# ============================================================================

PKG=com.tencent.mm
APK=$(pm path "$PKG" 2>/dev/null | head -n1 | sed 's/^package://')
echo "=== $PKG apk: $APK ==="
[ -f "$APK" ] && ls -la "$APK" || { echo "  not found"; exit 1; }
echo ""

WORK=/data/local/tmp/mm-dex
rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK" || exit 1
echo "=== extracting dex (read-only copies) ==="
unzip -o "$APK" 'classes*.dex' >/dev/null 2>&1
ls classes*.dex 2>/dev/null | wc -l | sed 's/^/  dex files: /'
du -sh . 2>/dev/null | sed 's/^/  total: /'
echo ""

echo "=== candidate tablet/pad symbol strings present in dex ==="
for s in \
  isAndroidPad isPad isTablet isPadDevice isTabletDevice \
  isAndroidTablet getDeviceType isAndroidBox \
  ro.product.model.is.tablet ro.build.characteristics \
  local_save_pad_type_android KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE \
  pad_type device_type tablet ; do
  hits=$(grep -la "$s" classes*.dex 2>/dev/null | tr '\n' ' ')
  if [ -n "$hits" ]; then
    printf '  %-40s %s\n' "$s" "$hits"
  else
    printf '  %-40s %s\n' "$s" "(absent)"
  fi
done
echo ""

echo "=== login-screen classes (candidate QR-entry UI) ==="
for s in LoginWxAuthActivity WxAuthActivity LoginActivity \
  mQrLogin mPhoneLogin mQrCodeLogin qrlogin QRLogin ; do
  hits=$(grep -la "$s" classes*.dex 2>/dev/null | tr '\n' ' ')
  printf '  %-30s %s\n' "$s" "${hits:-(absent)}"
done
echo ""

echo "=== the pad KV key in WeChat (if it shares the KV namespace) ==="
for key in KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE local_save_pad_type_android KV_ANDROID_PAD_DISABLE_USE_NEW_JUDGE_PAD_DEVICE_FUC ; do
  hits=$(grep -la "$key" classes*.dex 2>/dev/null | tr '\n' ' ')
  printf '  %-56s %s\n' "$key" "${hits:-(absent)}"
done
echo ""

echo "=== WeChat MMKV / config files of interest ==="
for f in \
  files/mmkv/com.tencent.mm.plugin.setting \
  files/mmkv/mmkv.default \
  files/file_config_build_model \
  shared_prefs/system_config_prefs.xml ; do
  if [ -e "/data/data/$PKG/$f" ]; then
    echo "  present: $f"
  else
    echo "  absent : $f"
  fi
done
echo ""
echo "  all mmkv stores:"
ls -1 "/data/data/$PKG/files/mmkv" 2>/dev/null | head -30 | sed 's/^/    /'
echo ""
echo "  pad-ish paths under the data dir:"
find "/data/data/$PKG" -maxdepth 4 -iname '*pad*' -o -maxdepth 4 -iname '*tablet*' 2>/dev/null | head -20 | sed 's/^/    /'
echo ""

echo "=== device-model related props WeChat might read ==="
for p in ro.product.model ro.product.model.is.tablet ro.build.characteristics \
         ro.build.characteristics.tablet ro.product.device ro.product.name ; do
  v=$(getprop "$p" 2>/dev/null)
  printf '  %-36s [%s]\n' "$p" "$v"
done
echo ""

echo "=== cleanup ==="
cd /; rm -rf "$WORK"
echo "done (read-only; nothing modified)"
