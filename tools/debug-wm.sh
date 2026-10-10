#!/system/bin/sh
# Show exactly which lines match the "wm WRITE" pattern, to prove they are
# false positives (reads with a stderr redirect) or genuine writes.
F=/data/local/tmp/tsx/tablet-spoof.sh
echo "=== lines matching the WRITE pattern ==="
grep -nE 'wm[[:space:]]+(size|density)[[:space:]]+([0-9]+x[0-9]+|[0-9]+|reset)([[:space:]]|$)' "$F"
echo ""
echo "=== ALL wm size / wm density mentions with context ==="
grep -nE 'wm[[:space:]]+(size|density)' "$F"
echo ""
echo "=== every use of the wm command at all ==="
grep -nE '\bwm\b' "$F"
