#!/system/bin/sh
# ============================================================================
# Build the FINAL clean native payload.
#
# No measurement scaffolding, no probe markers, no hook. It resolves and records,
# and stops -- see tablet_spoof.cpp for why.
#
# Sources: zygisk.hpp + tablet_spoof.cpp ONLY. art_hook.cpp and resolve_hook.hpp
# are NOT compiled in, so it is structurally impossible for this artifact to
# write ART state (stronger than "the code path is not called").
# ============================================================================
TC=/data/data/com.termux/files/usr
SRC=/data/local/tmp/final-src
OUT=/data/local/tmp/final.so
log() { echo "[final-build] $*"; }

rm -rf "$SRC"; mkdir -p "$SRC"
for f in zygisk.hpp tablet_spoof.cpp; do
  cp "/data/local/tmp/$f" "$SRC/" 2>/dev/null
  [ -f "$SRC/$f" ] || { log "MISSING source: $f"; exit 1; }
done
# Explicitly ensure no hook sources are present.
rm -f "$SRC/art_hook.cpp" "$SRC/art_hook.hpp" "$SRC/resolve_hook.hpp"

log "sources (must be exactly 2):"
ls -1 "$SRC" | sed 's/^/  /'
echo ""

rm -f "$OUT"
"$TC/bin/clang++" \
    -shared -fPIC -O2 -std=c++17 \
    -fvisibility=hidden -fno-exceptions -fno-rtti -nostdlib++ \
    -Wl,-z,max-page-size=16384 -Wl,-soname,arm64-v8a.so \
    -I "$SRC" -o "$OUT" "$SRC/tablet_spoof.cpp" \
    -llog > /data/local/tmp/final-build.log 2>&1
RC=$?
sed 's/^/  /' /data/local/tmp/final-build.log
if [ $RC -ne 0 ] || [ ! -f "$OUT" ]; then log "COMPILE FAILED rc=$RC"; exit 1; fi

log "built: $(stat -c %s "$OUT") bytes"
head -c 4 "$OUT" | od -An -tx1 | grep -q '7f 45 4c 46' || { log "not ELF"; exit 1; }
ENTRY=$("$TC/bin/llvm-nm" -D --defined-only "$OUT" 2>/dev/null | grep -c zygisk_module_entry)
log "  zygisk_module_entry: $ENTRY"
[ "$ENTRY" -ge 1 ] || exit 1
strings "$OUT" | grep -q 'libc++_shared' && { log "  FAIL libc++_shared"; exit 1; }
log "  no libc++_shared: OK"
echo ""

log "=== assert no measurement/hook scaffolding shipped ==="
for s in MEASURE DET\  ArtProbe ts_probe nativeifyMethod; do
  if strings "$OUT" | grep -q "$s"; then log "  PRESENT (should be gone): $s"; else log "  absent: $s"; fi
done
log "  expected present: RESOLVED, HOOK_MISS, ts_native"
for s in RESOLVED HOOK_MISS ts_native; do
  strings "$OUT" | grep -q "$s" && log "    has $s" || log "    MISSING $s"
done
