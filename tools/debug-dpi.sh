#!/system/bin/sh
# Debug the device_physical_dpi() patterns against real dumpsys output.
echo "=== pattern 1: xDpi=/yDpi= ==="
dumpsys display 2>/dev/null | sed -n 's/.*xDpi=\([0-9][0-9]*\(\.[0-9][0-9]*\)\?\).*yDpi=\([0-9][0-9]*\(\.[0-9][0-9]*\)\?\).*/\1 \3/p' | head -n1
echo "rc=$?"
echo ""

echo "=== pattern 2: density N (A x B) dpi ==="
dumpsys display 2>/dev/null | sed -n 's/.*density [0-9][0-9]* (\([0-9][0-9]*\(\.[0-9][0-9]*\)\?\) x \([0-9][0-9]*\(\.[0-9][0-9]*\)\?\)) dpi.*/\1 \3/p' | head -n1
echo "rc=$?"
echo ""

echo "=== pattern 3: A x B dpi ==="
dumpsys display 2>/dev/null | sed -n 's/.*[^0-9]\([0-9][0-9]*\(\.[0-9][0-9]*\)\?\) x \([0-9][0-9]*\(\.[0-9][0-9]*\)\?\) dpi.*/\1 \3/p' | head -n1
echo "rc=$?"
echo ""

echo "=== pattern 4: SurfaceFlinger x-dpi/y-dpi ==="
dumpsys SurfaceFlinger 2>/dev/null | sed -n 's/^[[:space:]]*x-dpi[[:space:]]*:[[:space:]]*\([0-9][0-9]*\(\.[0-9][0-9]*\)\?\).*/\1/p' | head -n1
dumpsys SurfaceFlinger 2>/dev/null | sed -n 's/^[[:space:]]*y-dpi[[:space:]]*:[[:space:]]*\([0-9][0-9]*\(\.[0-9][0-9]*\)\?\).*/\1/p' | head -n1
echo ""

echo "=== does this sed support \\? (GNU vs busybox) ==="
echo "abc" | sed -n 's/\(a\)\?/\1/p'
echo "sed rc=$?"
echo ""

echo "=== syntax check of engine ==="
sh -n /data/local/tmp/tsx/tablet-spoof.sh
echo "sh -n rc=$?"
echo ""

echo "=== what does busybox sed do with the exact line ==="
dumpsys display 2>/dev/null | grep -m1 'mViewports=' | head -c 200
echo ""
