#!/system/bin/sh
# ============================================================================
# Build the DETERMINATION payload (resolver + measurement, NO hook).
#
# Sources: zygisk.hpp, tablet_spoof.cpp, resolve_hook.hpp, art_hook.hpp
#          (art_hook.cpp is NOT compiled into this build -- no hook is installed)
#
# The measurement build deliberately excludes the hook implementation so that
# nothing in the deployed artifact can accidentally patch ART state.
# ============================================================================
TC=/data/data/com.termux/files/usr
SRC=/data/local/tmp/det-src
OUT=/data/local/tmp/det.so
log() { echo "[det-build] $*"; }

rm -rf "$SRC"; mkdir -p "$SRC"
for f in zygisk.hpp tablet_spoof.cpp resolve_hook.hpp art_hook.hpp; do
  cp "/data/local/tmp/$f" "$SRC/" 2>/dev/null
  [ -f "$SRC/$f" ] || { log "MISSING source: $f"; exit 1; }
done

log "sources staged:"
ls -1 "$SRC" | sed 's/^/  /'
echo ""

# Confirm no hook code is linked in: art_hook.cpp must NOT be present.
if [ -f "$SRC/art_hook.cpp" ]; then
  log "WARNING: art_hook.cpp present in staging -- removing (measurement build)"
  rm -f "$SRC/art_hook.cpp"
fi

rm -f "$OUT"
"$TC/bin/clang++" \
    -shared -fPIC -O2 -std=c++17 \
    -fvisibility=hidden -fno-exceptions -fno-rtti -nostdlib++ \
    -Wl,-z,max-page-size=16384 -Wl,-soname,arm64-v8a.so \
    -I "$SRC" -o "$OUT" \
    "$SRC/tablet_spoof.cpp" \
    -llog -ldl > /data/local/tmp/det-build.log 2>&1
RC=$?
sed 's/^/  /' /data/local/tmp/det-build.log

if [ $RC -ne 0 ] || [ ! -f "$OUT" ]; then
  log "COMPILE FAILED (clang rc=$RC)"; exit 1
fi
log "built: $(stat -c %s "$OUT") bytes"
head -c 4 "$OUT" | od -An -tx1 | grep -q '7f 45 4c 46' || { log "not ELF"; exit 1; }

# Prove the loader can find us.
ENTRY=$("$TC/bin/llvm-nm" -D --defined-only "$OUT" 2>/dev/null | grep -c zygisk_module_entry)
log "  zygisk_module_entry exports: $ENTRY"
[ "$ENTRY" -ge 1 ] || { log "MISSING entry symbol"; exit 1; }

# Prove no libc++ dependency (would prevent loading from zygote).
if strings "$OUT" | grep -q 'libc++_shared'; then
  log "  FAIL: links libc++_shared (cannot load from zygote)"; exit 1
fi
log "  no libc++_shared: OK"

# Prove the measurement strings are present (so we know what will be written).
for s in MEASURE DET HOOK_MISS ts_hook; do
  if strings "$OUT" | grep -q "$s"; then log "  marker present: $s"; else log "  MISSING marker: $s"; fi
done
echo ""
log "NOT deploying -- caller deploys after hash-before."
