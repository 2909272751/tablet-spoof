#!/system/bin/sh
# The decisive test: does OUR code actually execute inside the target process?
#
# Zygisk loads modules into zygote, so grepping the APP's maps for our .so is the
# WRONG signal (that is why it read 0). The right signal is our own log output:
# onLoad() logs unconditionally, and preAppSpecialize() logs only for in-scope
# processes.
echo "=== clear logcat, then start the in-scope target ==="
logcat -c 2>/dev/null
am force-stop com.tencent.wework
sleep 2
monkey -p com.tencent.wework -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 10
echo ""
echo "=== any 'tablet-spoof' tag in logcat? ==="
logcat -d 2>/dev/null | grep -i 'tablet-spoof' | tail -20 | sed 's/^/  /'
N=$(logcat -d 2>/dev/null | grep -ci 'tablet-spoof')
echo "  total matching lines: $N"
echo ""
echo "=== is our module mapped into ZYGOTE (where Zygisk loads modules)? ==="
ZP=$(pidof zygote64)
echo "  zygote64 pid: $ZP"
if [ -n "$ZP" ]; then
  grep -c 'zygisk\|tablet' /proc/$ZP/maps 2>/dev/null | sed 's/^/  refs: /'
fi
echo ""
echo "=== the app process: is zygisk's own lib present (proves injection works)? ==="
PID=$(pidof com.tencent.wework)
echo "  wework pid: $PID"
if [ -n "$PID" ]; then
  echo "  zygisk/memfd refs in app maps:"
  grep -iE 'zygisk|memfd|libpayload' /proc/$PID/maps 2>/dev/null | head -5 | sed 's/^/    /'
  echo "  (count: $(grep -ciE 'zygisk|memfd' /proc/$PID/maps 2>/dev/null))"
fi
echo ""
echo "=== compare: does device_faker (known-working) show in the same places? ==="
echo "  its own log tag:"
logcat -d 2>/dev/null | grep -i 'device_faker\|DeviceFaker' | tail -3 | sed 's/^/    /'
echo ""
echo "=== zygote map sample (what Zygisk actually maps) ==="
[ -n "$ZP" ] && grep -iE 'zygisk|payload|memfd' /proc/$ZP/maps 2>/dev/null | head -8 | sed 's/^/  /'
echo ""
echo "=== modules_info sanity: our recorded size vs the real file ==="
echo "  real .so size: $(stat -c %s /data/adb/modules/tablet-spoof-native-test/zygisk/arm64-v8a.so 2>/dev/null)"
grep 'tablet-spoof' /data/adb/zygisksu/modules_info 2>/dev/null | sed 's/^/  registry: /'
