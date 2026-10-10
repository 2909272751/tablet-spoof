#!/system/bin/sh
# REVERSAL CHECK: the pad entry works while "injected processes = 0".
# That means my injection metric was measuring the WRONG THING.
#
# The metric grepped /proc/<pid>/maps for the string "lspd|LSPosed". If LSPosed
# injects via a memfd or an anonymous mapping (common for modern injection), that
# grep finds nothing even when injection is working perfectly. So "0 injected"
# was a false negative -- and we used it to conclude "LSPosed is broken", which
# was wrong.
#
# This script finds the RIGHT signal.
log() { echo "[reversal] $*"; }

log "=== is the module actually being loaded? (behavioural truth) ==="
log "  the pad entry appears in the UI -> isAndroidPad() returned true"
log "  that can ONLY happen if our hook is installed in WeCom's process"
log "  => the module IS being injected, regardless of any maps grep"
echo ""

log "=== what does WeCom's process actually contain? ==="
PID=$(pidof com.tencent.wework | head -1)
log "  wework main pid: ${PID:-none}"
if [ -n "$PID" ]; then
  log "  --- our module's .so in maps ---"
  grep -c 'io.github.tabletspoof' /proc/$PID/maps 2>/dev/null | sed 's/^/    refs: /'
  grep 'io.github.tabletspoof' /proc/$PID/maps 2>/dev/null | head -3 | sed 's/^/    /'
  log "  --- lspd / LSPosed strings (what my OLD metric grepped for) ---"
  grep -c 'lspd\|LSPosed' /proc/$PID/maps 2>/dev/null | sed 's/^/    refs: /'
  log "  --- memfd / anonymous executable mappings (likely injection vehicle) ---"
  grep -iE 'memfd' /proc/$PID/maps 2>/dev/null | head -5 | sed 's/^/    /'
  grep -c 'memfd' /proc/$PID/maps 2>/dev/null | sed 's/^/    memfd count: /'
fi
echo ""

log "=== does any process match my old metric at all? ==="
N=0
for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
  if grep -qa 'lspd\|LSPosed' /proc/$p/maps 2>/dev/null; then N=$((N+1)); fi
done
log "  processes matching 'lspd|LSPosed' in maps: $N"
log "  (0 here while the feature WORKS => the metric is worthless)"
echo ""

log "=== the RIGHT metric: does the module's own asset appear in the app process? ==="
for p in com.tencent.wework com.tencent.mm; do
  PID=$(pidof "$p" 2>/dev/null | head -1)
  if [ -n "$PID" ]; then
    A=$(grep -c 'io.github.tabletspoof' /proc/$PID/maps 2>/dev/null)
    printf '  %-22s pid=%-7s our-module maps=%s\n' "$p" "$PID" "${A:-0}"
  else
    printf '  %-22s not running\n' "$p"
  fi
done
echo ""

log "=== also confirm via lspd's own log that it loaded us ==="
LOG=$(ls -t /data/adb/lspd/log/modules_*.log 2>/dev/null | head -n1)
log "  modules log: $LOG"
[ -f "$LOG" ] && tail -20 "$LOG" | sed 's/^/    /'
echo ""
VLOG=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -n1)
log "  verbose log mentions of our module:"
grep -c 'tabletspoof' "$VLOG" 2>/dev/null | sed 's/^/    count: /'
grep -i 'tabletspoof' "$VLOG" 2>/dev/null | tail -8 | sed 's/^/    /'
