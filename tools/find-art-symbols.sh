#!/system/bin/sh
# Why did all three ART bridge dlsym lookups return 0?
# Determine the right way to obtain a bridge REFERENCE ADDRESS on this device,
# so option (A) is cheap and evidence-based rather than another guess.
#
# This runs as root (a shell process), not inside the app, so it tests the
# LOOKUP MECHANISM, not the in-app environment. If the symbols are absent here
# they are absent everywhere; if present here, the in-app failure is about
# handle/mount namespace instead.
log() { echo "[art-sym] $*"; }

log "=== 1. where is libart.so and is it mapped for a target app? ==="
ls -la /apex/com.android.art/lib64/libart.so 2>/dev/null | sed 's/^/  /'
PID=$(pidof com.tencent.wework 2>/dev/null | head -1)
log "  wework pid: ${PID:-none}"
[ -n "$PID" ] && grep 'libart\.so' /proc/$PID/maps 2>/dev/null | head -3 | sed 's/^/    /'
echo ""

log "=== 2. does the dynamic symbol table contain the bridge names at all? ==="
# Search the raw file for the mangled substrings, which is a NECESSARY condition
# for dlsym to find them (they must be in .dynsym, not merely .symtab).
for s in GetQuickToInterpreterBridge GetNterpEntryPoint GetInvokeObsoleteMethodStub nterp; do
  N=$(strings /apex/com.android.art/lib64/libart.so 2>/dev/null | grep -c "$s")
  log "  '$s' occurrences in libart.so: $N"
done
echo ""

log "=== 3. are they EXPORTED (dynsym) or merely present (symtab)? ==="
if command -v readelf >/dev/null 2>&1; then
  readelf --dyn-syms /apex/com.android.art/lib64/libart.so 2>/dev/null \
    | grep -iE 'QuickToInterpreter|Nterp|Obsolete' | head -10 | sed 's/^/  /'
  log "  (empty above = not in .dynsym = dlsym cannot find them)"
else
  log "  readelf not available"
fi
echo ""

log "=== 4. what IS exported that mentions entry/bridge/interpreter? ==="
if command -v readelf >/dev/null 2>&1; then
  readelf --dyn-syms /apex/com.android.art/lib64/libart.so 2>/dev/null \
    | grep -iE 'EntryPoint|Bridge|Interpreter' | head -20 | sed 's/^/  /'
fi
echo ""

log "=== 5. alternative candidate libraries ==="
for L in /apex/com.android.art/lib64/libartbase.so /apex/com.android.art/lib64/libartpalette.so; do
  [ -f "$L" ] && log "  $(basename $L): $(stat -c %s "$L") bytes"
done
for s in GetNterpEntryPoint GetQuickToInterpreterBridge; do
  for L in /apex/com.android.art/lib64/libartbase.so /apex/com.android.art/lib64/libartpalette.so; do
    [ -f "$L" ] || continue
    N=$(strings "$L" 2>/dev/null | grep -c "$s")
    log "  '$s' in $(basename $L): $N"
  done
done
echo ""

log "=== 6. the practical question: can we get a bridge ADDRESS a simpler way? ==="
log "  Candidate: a method we KNOW is bridged (not yet JIT'd) can serve as the"
log "  reference if we can find one. Alternatively, ART exposes the quick-entry"
log "  state indirectly: if word[4..5] points into the INTERPRETER's code range"
log "  rather than JIT/AOT code, that is itself the discriminator."
log "  Check the address ranges involved:"
[ -n "$PID" ] && {
  log "  our measured entries were 0x6cf424f910 / 0x6cefbc05a8 -- which mapping?"
  grep -iE '^6c[0-9a-f]' /proc/$PID/maps 2>/dev/null | head -8 | sed 's/^/    /'
}
echo ""

log "=== 7. does the app process have libart mapped at the same path? ==="
[ -n "$PID" ] && grep -c 'libart' /proc/$PID/maps 2>/dev/null | sed 's/^/  libart mappings: /'
