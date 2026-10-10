#!/system/bin/sh
# Which dex DEFINE the target classes? A defined class has the descriptor in the
# type table AND a class_defs entry. As an on-device approximation we check the
# descriptor's presence per dex; the precise definition check runs host-side.
cd /data/local/tmp/alldex || exit 1
echo "=== descriptor presence per dex ==="
for s in \
  'com/tencent/wework/foundation/logic/Application;' \
  'com/tencent/wework/foundation/impl/WeworkServiceImpl;' ; do
  echo "--- $s"
  for d in classes*.dex; do
    if grep -qa "$s" "$d" 2>/dev/null; then
      echo "      $d"
    fi
  done
done
echo ""
echo "=== isAndroidPad / getDeviceType presence per dex ==="
for m in isAndroidPad getDeviceType ; do
  echo "--- $m"
  for d in classes*.dex; do
    if grep -qa "$m" "$d" 2>/dev/null; then
      echo "      $d"
    fi
  done
done
