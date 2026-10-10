#!/system/bin/sh
# Build the READ-ONLY stability probe.
# No writes to the app. Its only output is <app_data_dir>/ts_stable.log.
TC=/data/data/com.termux/files/usr
SRC=/data/local/tmp/stable-src
OUT=/data/local/tmp/stable.so
log() { echo "[stable-build] $*"; }

rm -rf "$SRC"; mkdir -p "$SRC"
for f in zygisk.hpp stability_probe.cpp; do
  cp "/data/local/tmp/$f" "$SRC/" 2>/dev/null
  [ -f "$SRC/$f" ] || { log "MISSING: $f"; exit 1; }
done
rm -f "$SRC/art_hook.cpp" "$SRC/art_hook.hpp" "$SRC/resolve_hook.hpp"

log "sources:"; ls -1 "$SRC" | sed 's/^/  /'

rm -f "$OUT"
"$TC/bin/clang++" \
    -shared -fPIC -O2 -std=c++17 \
    -fvisibility=hidden -fno-exceptions -fno-rtti -nostdlib++ \
    -Wl,-z,max-page-size=16384 -Wl,-soname,arm64-v8a.so \
    -I "$SRC" -o "$OUT" "$SRC/stability_probe.cpp" \
    -llog -lpthread > /data/local/tmp/stable-build.log 2>&1
RC=$?
sed 's/^/  /' /data/local/tmp/stable-build.log
if [ $RC -ne 0 ] || [ ! -f "$OUT" ]; then log "COMPILE FAILED rc=$RC"; exit 1; fi

log "built: $(stat -c %s "$OUT") bytes"
head -c 4 "$OUT" | od -An -tx1 | grep -q '7f 45 4c 46' || { log "not ELF"; exit 1; }
E=$("$TC/bin/llvm-nm" -D --defined-only "$OUT" 2>/dev/null | grep -c zygisk_module_entry)
log "  zygisk_module_entry: $E"; [ "$E" -ge 1 ] || exit 1
strings "$OUT" | grep -q 'libc++_shared' && { log "FAIL libc++"; exit 1; }
log "  no libc++_shared: OK"
log "  markers (must be present):"
for s in STABLE ts_stable; do
  strings "$OUT" | grep -q "$s" && log "    has $s" || log "    MISSING $s"
done
log "  write-marker scan (must be ABSENT -- this probe must not write app state):"
for s in "H(" KV_ANDROID_PAD setDeviceType; do
  if strings "$OUT" | grep -q -- "$s"; then log "    PRESENT (bad): $s"; else log "    absent: $s"; fi
done
