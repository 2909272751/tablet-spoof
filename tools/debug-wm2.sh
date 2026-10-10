#!/system/bin/sh
# Find EVERY non-comment `wm` usage in the engine and classify read vs write.
F=/data/local/tmp/tsx/tablet-spoof.sh
echo "=== non-comment lines mentioning wm ==="
grep -v '^[[:space:]]*#' "$F" | grep -n '(^|[^a-zA-Z_])wm[[:space:]]*(size|density)' 2>/dev/null
echo "--- fallback (plain grep) ---"
grep -v '^[[:space:]]*#' "$F" | grep -n 'wm ' 
echo ""
echo "=== show every such line verbatim with its line number in the ORIGINAL ==="
awk 'BEGIN{n=0} {n++; if ($0 !~ /^[[:space:]]*#/ && $0 ~ /wm[[:space:]]/) printf "  %4d: %s\n", n, $0}' "$F"
echo ""
echo "=== count of $(wm ...) reads ==="
grep -c '\$(wm ' "$F"
