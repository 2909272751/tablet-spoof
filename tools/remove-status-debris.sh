#!/system/bin/sh
# Remove the ts_status.txt debris my status channel created.
#
# TWO BUGS IN MY FIRST ATTEMPT, both worth naming because they are the same class
# of error this whole project keeps surfacing:
#   1. `find ... | while read` runs the loop body in a SUBSHELL, so N never
#      incremented in the parent and the count was meaningless.
#   2. my path guard required `/files/` but the real paths are
#      /data/data/<pkg>/ts_status.txt (no /files/ segment), so every item was
#      SKIPPED as "unexpected" -- while the script still printed a confident
#      "removal pass complete".
# The result was a script that reported success and deleted nothing. Fixed:
# match the real path shape, avoid the subshell, and VERIFY the count actually
# dropped to zero rather than trusting the loop.
log() { echo "[debris] $*"; }

log "=== before ==="
BEFORE=$(find /data/data -maxdepth 3 -name 'ts_status.txt' 2>/dev/null | wc -l)
log "  files: $BEFORE"
echo ""

log "=== removing (exact filename only; path shape is /data/data/*/ts_status.txt) ==="
# Collect first (no pipe into the loop -> no subshell), then delete.
LIST=$(find /data/data -maxdepth 3 -name 'ts_status.txt' 2>/dev/null)
for f in $LIST; do
  case "$f" in
    /data/data/*/ts_status.txt)
      rm -f "$f"
      ;;
    *)
      log "  SKIP (unexpected path): $f"
      ;;
  esac
done
log "  pass complete"
echo ""

log "=== after (VERIFIED, not assumed) ==="
AFTER=$(find /data/data -maxdepth 3 -name 'ts_status.txt' 2>/dev/null | wc -l)
log "  files: $AFTER  (was $BEFORE)"
if [ "$AFTER" = "0" ]; then
  log "  PASS: all debris removed"
else
  log "  FAIL: $AFTER still present:"
  find /data/data -maxdepth 3 -name 'ts_status.txt' 2>/dev/null | head -20 | sed 's/^/    /'
fi
echo ""

log "=== the two target apps must be clean ==="
for p in com.tencent.wework com.tencent.mm; do
  R=$(ls -la /data/data/$p/ 2>/dev/null | grep -c 'ts_status')
  W=$(ls -la /data/data/$p/files/ 2>/dev/null | grep -c 'ts_status')
  printf '  %-22s top-level=%s files/=%s\n' "$p" "$R" "$W"
done
echo ""

log "=== /sdcard and tmp sinks ==="
for f in /sdcard/tablet-spoof-status.txt /data/local/tmp/tablet-spoof-status; do
  if [ -e "$f" ]; then rm -f "$f" && log "  removed $f"; else log "  absent: $f"; fi
done
