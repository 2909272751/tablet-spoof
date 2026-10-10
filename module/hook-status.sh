#!/system/bin/sh
# ============================================================================
# tablet-spoof / hook-status.sh   (run AS ROOT)
# ============================================================================
# Reads the out-of-band status the in-process module writes, and prints a verdict.
#
# WHY TWO LOCATIONS: the first design wrote only to /data/adb/tablet-spoof/, which
# CANNOT work -- /data/adb is 700 root:root and SELinux is Enforcing, so an app uid
# (u0_a398 for WeCom) can never create a file there. The write failed silently,
# which is the worst outcome for a fail-loud channel.
#
# The working design puts the writer inside the app's own sandbox (the only place
# an app may write) and the reader here, as root. This script checks both, so it
# also works if a future layout ever allows the module path.
# ============================================================================

MODULE_STATUS=/data/adb/tablet-spoof/hook-status
# Deliberately named to match WeCom's own "ww*" file conventions, so it is not a
# conspicuous foreign artifact in the target's private storage.
APP_STATUS_NAME=ww_device_metrics.dat

TARGETS="com.tencent.wework com.tencent.mm"

FOUND=""
for p in $TARGETS; do
  f="/data/data/$p/files/$APP_STATUS_NAME"
  if [ -f "$f" ]; then
    FOUND="$f"
    break
  fi
done
[ -n "$FOUND" ] || { [ -f "$MODULE_STATUS" ] && FOUND="$MODULE_STATUS"; }

if [ -z "$FOUND" ]; then
  echo "hook-status: ABSENT"
  echo "  checked:"
  echo "    $MODULE_STATUS   (cannot be written by an app uid - expected absent)"
  for p in $TARGETS; do
    echo "    /data/data/$p/files/$APP_STATUS_NAME"
  done
  echo ""
  echo "  The in-process module has not recorded a status."
  echo "  Means one of:"
  echo "    * the module is not loaded into the target process at all"
  echo "    * the target app has not been launched since the last reboot"
  echo "    * the Context hook failed, so there was nowhere to write"
  echo "  Verify lspd is loaded:  pidof lspd ; then launch the app once."
  exit 1
fi

echo "hook-status: present"
echo "  path : $FOUND"
echo "  mtime: $(date -r "$FOUND" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c %y "$FOUND" 2>/dev/null)"
echo ""
sed 's/^/  /' "$FOUND"
echo ""

STATUS=$(sed -n 's/^status=//p' "$FOUND" | head -n1)
case "$STATUS" in
  ok)
    echo "VERDICT: hooks installed correctly."
    exit 0
    ;;
  HOOK_MISS)
    echo "VERDICT: *** HOOK MISS - THE SPOOF IS INACTIVE ***"
    echo "  The app was probably updated and the target class/method moved."
    echo "  Fix: re-run tools/audit-hook-targets.py against the new APK, then update"
    echo "       the resolution ladder in app/src/io/github/tabletspoof/Hooks.java."
    exit 2
    ;;
  skipped)
    echo "VERDICT: module loaded but deliberately did nothing here (see reason)."
    exit 0
    ;;
  *)
    echo "VERDICT: unrecognised status '$STATUS'."
    exit 2
    ;;
esac