#!/system/bin/sh
# Build the minimal sink probe on-device, then deploy it.
TC=/data/data/com.termux/files/usr
SRC=/data/local/tmp/probe-src
OUT=/data/local/tmp/probe.so
log() { echo "[probe-build] $*"; }

mkdir -p "$SRC"
cp /data/local/tmp/zygisk.hpp "$SRC/" 2>/dev/null
cp /data/local/tmp/probe_sink.cpp "$SRC/" 2>/dev/null
[ -f "$SRC/probe_sink.cpp" ] || { log "source missing"; exit 1; }
[ -f "$SRC/zygisk.hpp" ] || { log "header missing"; exit 1; }

rm -f "$OUT"
"$TC/bin/clang++" \
    -shared -fPIC -O2 -std=c++17 \
    -fvisibility=hidden -fno-exceptions -fno-rtti -nostdlib++ \
    -Wl,-z,max-page-size=16384 -Wl,-soname,arm64-v8a.so \
    -I "$SRC" -o "$OUT" "$SRC/probe_sink.cpp" -llog > /data/local/tmp/probe-build.log 2>&1
RC=$?
sed 's/^/  /' /data/local/tmp/probe-build.log

if [ $RC -ne 0 ] || [ ! -f "$OUT" ]; then
  log "BUILD FAILED (rc=$RC)"
  exit 1
fi

log "built: $(stat -c %s "$OUT") bytes"
if head -c 4 "$OUT" | od -An -tx1 | grep -q '7f 45 4c 46'; then log "  ELF: OK"; else log "  NOT ELF"; exit 1; fi
log "  entry symbol: $("$TC/bin/llvm-nm" -D --defined-only "$OUT" 2>/dev/null | grep -c zygisk_module_entry)"
log "  probe markers present:"
for s in PROBE SCOPE ts_probe; do
  "$TC/bin/llvm-nm" -D --defined-only "$OUT" >/dev/null 2>&1
  if strings "$OUT" | grep -q "$s"; then log "    HAS $s"; else log "    no  $s"; fi
done

log ""
log "=== deploy ==="
cp "$OUT" /data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
chmod 644 /data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
md5sum /data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so | sed 's/^/  /'
log "REBOOT REQUIRED to load it."
