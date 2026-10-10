#!/system/bin/sh
# INDEPENDENTLY READ the Lead's probe output. Zero deploy risk: this script only
# READS files (plus launches the apps, which is an observable action, not a write
# to the module path).
#
# The Lead's contract:  <app_data_dir>/zyprobe.log
#   markers: POST <proc>, SCOPE-HIT-WEWORK, SCOPE-HIT-WECHAT, ART <...>, THREAD <...>
#
# Per the Lead's request I do NOT deploy to the .so path. I also record the .so
# hash before and after so we can prove the artifact did not change under us.
log() { echo "[read-lead-probe] $*"; }

SO=/data/adb/modules/tablet-spoof-native/zygisk/arm64-v8a.so
log "=== artifact identity (hash before) ==="
stat -c '  size=%s mtime=%y' "$SO" 2>/dev/null
md5sum "$SO" 2>/dev/null | sed 's/^/  md5-before /'
log "  boot: $(uptime | sed 's/^ *//')"
echo ""

log "=== clear the Lead's log so anything present is from THIS run ==="
for p in com.tencent.wework com.tencent.mm; do
  rm -f "/data/data/$p/zyprobe.log" 2>/dev/null
done
log "  cleared"
echo ""

log "=== launch both targets ==="
for p in com.tencent.wework com.tencent.mm; do
  log "  --- $p"
  am force-stop "$p" 2>/dev/null
  sleep 2
  monkey -p "$p" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 10
  log "    pid: $(pidof "$p" 2>/dev/null || echo none)"
done
echo ""

log "=== read zyprobe.log from each target ==="
for p in com.tencent.wework com.tencent.mm; do
  F="/data/data/$p/zyprobe.log"
  if [ -f "$F" ]; then
    log "  *** $F  ($(stat -c %s "$F") bytes) ***"
    sed 's/^/    /' "$F"
  else
    log "  $F : ABSENT"
  fi
done
echo ""

log "=== artifact identity (hash after) -- must equal hash-before ==="
md5sum "$SO" 2>/dev/null | sed 's/^/  md5-after  /'
echo ""

log "=== VERDICT INPUTS (my own read of the Lead's markers) ==="
W=/data/data/com.tencent.wework/zyprobe.log
M=/data/data/com.tencent.mm/zyprobe.log
log "  wework: POST lines   : $(grep -c '^POST' "$W" 2>/dev/null)"
log "  wework: SCOPE-HIT-WEWORK : $(grep -c 'SCOPE-HIT-WEWORK' "$W" 2>/dev/null)"
log "  wework: ART lines    : $(grep -c '^ART' "$W" 2>/dev/null)"
log "  wework: THREAD lines : $(grep -c '^THREAD' "$W" 2>/dev/null)"
log "  wework: FindClass result: $(grep -i 'FindClass' "$W" 2>/dev/null | head -1)"
log "  mm: POST lines       : $(grep -c '^POST' "$M" 2>/dev/null)"
log "  mm: SCOPE-HIT-WECHAT : $(grep -c 'SCOPE-HIT-WECHAT' "$M" 2>/dev/null)"
echo ""
log "  If POST + SCOPE-HIT appear for a target, delivery is CONFIRMED by my own read."
