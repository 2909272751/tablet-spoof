#!/system/bin/sh
# Verify ERE-based parsing works on this busybox/Android sed.
echo "=== does sed -E work? ==="
echo "abc" | sed -E -n 's/(a)?/[\1]/p'
echo "rc=$?"
echo ""

echo "=== ERE pattern 1: xDpi=/yDpi= ==="
dumpsys display 2>/dev/null | sed -E -n 's/.*xDpi=([0-9]+(\.[0-9]+)?).*yDpi=([0-9]+(\.[0-9]+)?).*/\1 \3/p' | head -n1
echo ""

echo "=== ERE pattern 2: density N (A x B) dpi ==="
dumpsys display 2>/dev/null | sed -E -n 's/.*density [0-9]+ \(([0-9]+(\.[0-9]+)?) x ([0-9]+(\.[0-9]+)?)\) dpi.*/\1 \3/p' | head -n1
echo ""

echo "=== ERE pattern 4: SurfaceFlinger ==="
dumpsys SurfaceFlinger 2>/dev/null | sed -E -n 's/^[[:space:]]*x-dpi[[:space:]]*:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1
dumpsys SurfaceFlinger 2>/dev/null | sed -E -n 's/^[[:space:]]*y-dpi[[:space:]]*:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1
echo ""

echo "=== busbox version ==="
busybox | head -n1
sed --help 2>&1 | head -n3
