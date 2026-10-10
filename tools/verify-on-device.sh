#!/system/bin/sh
# ============================================================================
# tablet-spoof / verify-on-device.sh
# ============================================================================
# Runs ON the Android device (pushed to /data/local/tmp). Read-only with respect
# to the module's targets: it inspects the device, syntax-checks the shell, and
# reports the geometry the engine computes. It does NOT install or apply
# anything, and does not write into /data/data/<pkg>.
#
# Usage:  sh /data/local/tmp/ts-verify.sh [unpacked_dir]
# ============================================================================

DIR="${1:-/data/local/tmp/tsx}"
FAILED=0

echo "=============================================="
echo " tablet-spoof :: on-device verification"
echo "=============================================="
echo ""

# --- 0. environment ----------------------------------------------------------
echo "--- environment ---"
echo "android release : $(getprop ro.build.version.release)"
echo "android sdk     : $(getprop ro.build.version.sdk)"
echo "abi             : $(getprop ro.product.cpu.abi)"
echo "device model    : $(getprop ro.product.model)"
echo ""

# --- 1. root / module manager detection --------------------------------------
echo "--- root / module manager ---"
if [ -d /data/adb/ap ]; then
  echo "APatch         : YES (/data/adb/ap present)"
  APATCH=1
else
  echo "APatch         : no"
fi
if command -v magisk >/dev/null 2>&1; then
  echo "Magisk binary  : $(magisk -c 2>/dev/null)"
else
  echo "Magisk binary  : absent"
fi
if [ -d /data/adb/modules ]; then
  echo "modules dir    : /data/adb/modules present"
  echo "installed mods :"
  for m in /data/adb/modules/*/; do
    [ -d "$m" ] || continue
    echo "    - $(basename "$m")"
  done
else
  echo "modules dir    : MISSING"
  FAILED=1
fi
echo ""

# --- 2. shell syntax of the module scripts -----------------------------------
echo "--- shell syntax check (-n) ---"
if [ -d "$DIR" ]; then
  for f in "$DIR"/*.sh; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    if sh -n "$f" 2>/tmp/tsyn.err; then
      echo "  OK    $n"
    else
      echo "  FAIL  $n"
      sed 's/^/          /' /tmp/tsyn.err
      FAILED=1
    fi
  done
  rm -f /tmp/tsyn.err
else
  echo "  (no unpacked dir at $DIR)"
fi
echo ""

# --- 3. target packages ------------------------------------------------------
echo "--- target packages ---"
for p in com.tencent.mm com.tencent.wework; do
  path=$(pm path "$p" 2>/dev/null | head -n1)
  datadir="/data/data/$p"
  if [ -n "$path" ]; then
    echo "  $p : INSTALLED"
    echo "      apk        : $path"
    echo "      data dir   : $([ -d "$datadir" ] && echo present || echo MISSING)"
    ver=$(dumpsys package "$p" 2>/dev/null | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -n1)
    echo "      versionName: ${ver:-unknown}"
  else
    echo "  $p : not installed"
  fi
done
echo ""

# --- 4. geometry, exactly as the engine computes it --------------------------
echo "--- geometry (used by tablet-spoof.sh) ---"
WSIZE=$(wm size 2>/dev/null)
WDENS=$(wm density 2>/dev/null)
echo "  wm size    : $(echo "$WSIZE" | tr '\n' ' ')"
echo "  wm density : $(echo "$WDENS" | tr '\n' ' ')"

# mirror device_real_size()
LINE=$(echo "$WSIZE" | grep -i 'Override size' | head -n1)
[ -n "$LINE" ] || LINE=$(echo "$WSIZE" | grep -i 'Physical size' | head -n1)
WH=$(echo "$LINE" | sed -n 's/.*: *\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p')
W=$(echo "$WH" | cut -d' ' -f1)
H=$(echo "$WH" | cut -d' ' -f2)

# mirror device_density()
DLINE=$(echo "$WDENS" | grep -i 'Override density' | head -n1)
[ -n "$DLINE" ] || DLINE=$(echo "$WDENS" | grep -i 'Physical density' | head -n1)
D=$(echo "$DLINE" | sed -n 's/.*: *\([0-9][0-9]*\).*/\1/p')
[ -n "$D" ] || D=$(getprop ro.sf.lcd_density)
case "$D" in ''|*[!0-9]*) D=0 ;; esac

echo "  parsed     : W=$W H=$H density=$D"

if [ -n "$W" ] && [ -n "$H" ] && [ "$D" -gt 0 ]; then
  MIN=$W
  [ "$H" -lt "$MIN" ] && MIN=$H
  SW=$(( MIN * 160 / D ))
  echo "  smallestWidthDp = $MIN * 160 / $D = $SW"
  if [ "$SW" -ge 600 ]; then
    echo "  verdict    : already tablet-class (sw>=600) -> app should already offer QR login"
  else
    echo "  verdict    : PHONE-class (sw<600) by density -- the app's density-derived bucket"
  fi
  # physical size in inches, the other signal the app can use
  XDPI=$(wm size 2>/dev/null >/dev/null; dumpsys display 2>/dev/null \
        | sed -n 's/.*[^a-zA-Z]\([0-9][0-9]*\)\.\([0-9]*\) *x *\([0-9][0-9]*\)\.\([0-9]*\) dpi.*/\1.\2/p' | head -n1)
  echo "  (physical xdpi from dumpsys: ${XDPI:-n/a})"
else
  echo "  verdict    : could not parse geometry"
  FAILED=1
fi
echo ""

# --- 5. which of the two packages look tablet-ish already --------------------
echo "--- per-app config probes (read-only) ---"
for p in com.tencent.wework com.tencent.mm; do
  echo "  [$p]"
  for f in files/file_config_build_model shared_prefs/pad_type.xml; do
    if [ -e "/data/data/$p/$f" ]; then
      echo "      present: $f"
    else
      echo "      absent : $f"
    fi
  done
  # look for MMKV/other caches mentioning pad type (names only, no values)
  hits=$(find "/data/data/$p" -maxdepth 3 -iname '*pad*' 2>/dev/null | head -n 10)
  if [ -n "$hits" ]; then
    echo "      pad-ish paths:"
    echo "$hits" | sed 's/^/          /'
  else
    echo "      pad-ish paths: none found at maxdepth 3"
  fi
done
echo ""

# --- 6. result ---------------------------------------------------------------
echo "=============================================="
if [ "$FAILED" = 0 ]; then
  echo " RESULT: PASS"
else
  echo " RESULT: FAIL (see above)"
fi
echo "=============================================="
exit $FAILED
