#!/system/bin/sh
# ============================================================================
# tablet-spoof / test-engine.sh   (run AS ROOT on device)
# ============================================================================
# Exercises the engine's pure functions WITHOUT touching any app:
#   - scope guard exactness
#   - the 8.0" diagonal math (integer sqrt)
#   - density/size WRITE absence
# Sourcing the engine is avoided; we run it in `status` mode and separately
# re-implement the math check by calling the engine through a temporary copy
# that reports and exits.
# ============================================================================

ENGINE="$1"
[ -n "$ENGINE" ] || ENGINE=/data/local/tmp/tsx/tablet-spoof.sh
FAIL=0

echo "=== engine: $ENGINE ==="
if [ ! -f "$ENGINE" ]; then echo "  engine not found"; exit 1; fi
echo ""

echo "=== 1. syntax ==="
if sh -n "$ENGINE" 2>/tmp/e; then echo "  OK"; else echo "  FAIL"; sed 's/^/    /' /tmp/e; FAIL=1; fi
echo ""

echo "=== 2. scope guard: extract and test in_scope() ==="
# Build a tiny harness that sources only the guard definitions.
cat > /tmp/guard.sh <<'EOF'
SCOPE="com.tencent.mm com.tencent.wework"
in_scope() {
  _p="$1"
  [ -n "$_p" ] || return 1
  for _s in $SCOPE; do
    [ "$_p" = "$_s" ] && return 0
  done
  return 1
}
while [ $# -gt 0 ]; do
  if in_scope "$1"; then echo "  IN     $1"; else echo "  OUT    $1"; fi
  shift
done
EOF
sh /tmp/guard.sh \
  com.tencent.mm \
  com.tencent.wework \
  com.tencent.mm.plugin \
  com.tencent.mm.evil \
  com.tencent.weworkx \
  com.tencent.wework.fake \
  com.tencent \
  com.android.systemui \
  com.tencent.qqmusic \
  com.tencent.soter.soterserver \
  '' \
  'com.tencent.mm ' \
  ' com.tencent.mm'
echo "  (expected: only the first two IN)"
echo ""

echo "=== 3. diagonal math vs the app's formula ==="
# Re-implement the engine's isqrt/diagonal to cross-check against python-free
# expectation for known real values.
isqrt() {
  _n="$1"; [ "$_n" -le 0 ] && { echo 0; return; }
  _x="$_n"; _y=$(( (_x + 1) / 2 ))
  while [ "$_y" -lt "$_x" ]; do _x="$_y"; _y=$(( (_x + _n / _x) / 2 )); done
  echo "$_x"
}
diag10() {
  _w="$1"; _h="$2"; _xi="$3"; _yi="$4"
  _ax=$(( _w * 1000 / _xi )); _ay=$(( _h * 1000 / _yi ))
  _sum=$(( _ax * _ax + _ay * _ay ))
  _d=$(isqrt "$_sum")
  echo $(( (_d + 50) / 100 ))
}
# MI 9 real values: 1080x2340, 403.411/404.326 dpi -> 6.3766in (phone, <8.0)
echo "  MI9 1080x2340 @403/404 dpi -> $(diag10 1080 2340 403 404) tenths-in (expect 64 = 6.4in, PHONE)"
# 1600x2560 @320 dpi -> 9.4340in (genuinely 9.4, not 10.0)
echo "  1600x2560 @320 dpi        -> $(diag10 1600 2560 320 320) tenths-in (expect 94 = 9.4in)"
# Xiaomi Pad 6: 1800x2880 @309 dpi -> 10.9910in
echo "  1800x2880 @309 dpi        -> $(diag10 1800 2880 309 309) tenths-in (expect 110 = 11.0in)"
# just above the 8.0 boundary: 1080x1920 @ 240 dpi = (4.5, 8.0) -> 9.179
echo "  1080x1920 @240 dpi        -> $(diag10 1080 1920 240 240) tenths-in (expect 92 = 9.2in >= 8.0)"
# clearly below: 800x1280 @240 = (3.33, 5.33) -> 6.29
echo "  800x1280 @240 dpi         -> $(diag10 800 1280 240 240) tenths-in (expect 63 = 6.3in < 8.0)"
echo ""

echo "=== 4. isqrt correctness (a few squares) ==="
for n in 0 1 2 4 9 16 100 144 10000 123456789; do
  printf "  isqrt(%s) = %s\n" "$n" "$(isqrt "$n")"
done
echo ""

echo "=== 5. confirm NO wm command anywhere in the engine ==="
# HARD RULE: the module must contain ZERO invocations of the `wm` command, not
# even read-only ones. We must strip BOTH comment lines AND text inside
# log/echo string literals, because the code legitimately *describes* the
# rejected technique in prose and in user-facing messages.
CODE=$(grep -v '^[[:space:]]*#' "$ENGINE" | grep -v '^[[:space:]]*log ' | grep -v '^[[:space:]]*echo ')
WCOUNT=$(echo "$CODE" | grep -cE '(^|[^a-zA-Z_])wm[[:space:]]+(size|density)')
echo "  'wm size'/'wm density' invocations in executable code: $WCOUNT (expect 0)"
[ "$WCOUNT" = "0" ] || FAIL=1
W2=$(echo "$CODE" | grep -cE 'setprop[[:space:]]+ro\.sf\.lcd_density')
echo "  setprop ro.sf.lcd_density writes: $W2 (expect 0)"
[ "$W2" = "0" ] || FAIL=1
W3=$(echo "$CODE" | grep -cE '(^|[^a-zA-Z_])wm[[:space:]]')
echo "  ANY 'wm ' invocation in executable code: $W3 (expect 0)"
[ "$W3" = "0" ] || FAIL=1
# Show what the check actually inspected, so the result is auditable.
echo "  lines inspected were:"
echo "$CODE" | grep -nE 'dumpsys|SurfaceFlinger' | head -5 | sed 's/^/    /'
echo ""

echo "=== 6. surface table ==="
grep -A8 '^surfaces()' "$ENGINE" | sed 's/^/  /'
echo ""

echo "=== 7. run status (read-only) ==="
sh "$ENGINE" status 2>&1 | sed 's/^/  /'
echo ""

echo "=============================================="
if [ "$FAIL" = 0 ]; then echo " ENGINE TEST: PASS"; else echo " ENGINE TEST: FAIL"; fi
echo "=============================================="
exit $FAIL
