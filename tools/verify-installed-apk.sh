#!/system/bin/sh
# Verify the INSTALLED companion APK is the 2-hook build with no getDeviceType.
APK=$(pm path io.github.tabletspoof 2>/dev/null | head -n1 | sed 's/^package://')
echo "installed apk: $APK"
[ -f "$APK" ] || { echo "not installed"; exit 1; }
W=/data/local/tmp/idcheck
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
unzip -o "$APK" classes.dex >/dev/null 2>&1
echo ""
echo "=== hook ids present in the INSTALLED dex ==="
grep -ao 'tablet-spoof:[a-zA-Z.:]*' classes.dex 2>/dev/null | sort -u | sed 's/^/  /'
echo ""
echo "=== count ==="
grep -ao 'tablet-spoof:[a-zA-Z.:]*' classes.dex 2>/dev/null | sort -u | wc -l
echo ""
echo "=== getDeviceType present? (expect 0) ==="
grep -ac 'getDeviceType' classes.dex 2>/dev/null
echo ""
echo "=== isAndroidPad present? (expect >0) ==="
grep -ac 'isAndroidPad' classes.dex 2>/dev/null
echo ""
echo "=== SABOTAGE build marker (the distinguishing string) ==="
# NOTE: SABOTAGE_FORCE_MISS exists in BOTH builds (it is the constant's NAME).
# Only the sabotage build contains the corrupted class suffix, so that is the
# marker to test. Checking SABOTAGE_FORCE_MISS would report every build as
# sabotaged -- a false positive that would make this check worthless.
_S=$(grep -ac 'SabotagedDoesNotExist' classes.dex 2>/dev/null)
echo "  SabotagedDoesNotExist occurrences: ${_S:-0}"
if [ "${_S:-0}" != "0" ]; then
  echo "  => THIS IS A SABOTAGE TEST BUILD (hooks deliberately broken)"
else
  echo "  => normal build (hooks intact)"
fi
echo ""
echo "=== xposed metadata ==="
unzip -l "$APK" 2>/dev/null | grep -E 'xposed' | sed 's/^/  /'
echo ""
cd /; rm -rf "$W"
echo "done"
