#!/system/bin/sh
# Find where xdpi/ydpi live, so device_physical_dpi() can parse them reliably.
echo "=== dumpsys display: lines with dpi ==="
dumpsys display 2>/dev/null | grep -i dpi | head -40
echo ""
echo "=== dumpsys display: DisplayInfo lines ==="
dumpsys display 2>/dev/null | grep -i 'DisplayInfo' | head -10
echo ""
echo "=== wm size / density ==="
wm size
wm density
echo ""
echo "=== dumpsys window displays: dpi ==="
dumpsys window displays 2>/dev/null | grep -iE 'dpi|init=' | head -20
echo ""
echo "=== dumpsys SurfaceFlinger: dpi ==="
dumpsys SurfaceFlinger 2>/dev/null | grep -i dpi | head -10
echo ""
echo "=== the app-facing metrics via cmd ==="
dumpsys display 2>/dev/null | head -30
