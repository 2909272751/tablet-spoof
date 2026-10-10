#!/system/bin/sh
# Build the READ-ONLY KV-reader probe with the control pair.
# Must NOT contain H( (the writer) or any KV write.
TC=/data/data/com.termux/files/usr
SRC=/data/local/tmp/kvread-src
OUT=/data/local/tmp/kvread.so
log() { echo "[kvread-build] $*"; }

rm -rf "$SRC"; mkdir -p "$SRC"
for f in zygisk.hpp kv_read_probe.cpp; do
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
    -I "$SRC" -o "$OUT" "$SRC/kv_read_probe.cpp" \
    -llog -lpthread > /data/local/tmp/kvread-build.log 2>&1
RC=$?
sed 's/^/  /' /data/local/tmp/kvread-build.log
if [ $RC -ne 0 ] || [ ! -f "$OUT" ]; then log "COMPILE FAILED rc=$RC"; exit 1; fi

log "built: $(stat -c %s "$OUT") bytes"
head -c 4 "$OUT" | od -An -tx1 | grep -q '7f 45 4c 46' || { log "not ELF"; exit 1; }
E=$("$TC/bin/llvm-nm" -D --defined-only "$OUT" 2>/dev/null | grep -c zygisk_module_entry)
log "  zygisk_module_entry: $E"; [ "$E" -ge 1 ] || exit 1
strings "$OUT" | grep -q 'libc++_shared' && { log "FAIL libc++"; exit 1; }
log "  no libc++_shared: OK"
echo ""

log "=== ASSERT THIS PROBE CANNOT WRITE KV ==="
log "  (the writer is 'H'; the reader is 'l' -- checking the deployed string table)"
for s in KVREAD ts_kvread; do
  strings "$OUT" | grep -q "$s" && log "    has $s" || log "    MISSING $s"
done
echo ""
log "  reader method name present : $(strings "$OUT" | grep -c '(Ljava/lang/String;Ljava/lang/Object;)Ljava/lang/Object;')"
log "  KEY strings present (expected -- we must name the keys to read them):"
strings "$OUT" | grep -c 'KV_ANDROID_PAD' | sed 's/^/    /'
echo ""
log "  NOTE: the key strings MUST be present (we read them). What must be ABSENT"
log "  is any call to the writer. We cannot prove absence by strings alone, so the"
log "  source is the guarantee: kv_read_probe.cpp calls only 'l' (the reader)."
log "  grep the source:"
grep -c 'GetMethodID(gqpCls, "H"' /data/local/tmp/kv_read_probe.cpp | sed 's/^/    writer calls in source: /'
grep -c 'CallVoidMethod' /data/local/tmp/kv_read_probe.cpp | sed 's/^/    void-returning calls in source: /'
