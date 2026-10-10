#!/system/bin/sh
# ============================================================================
# tablet-spoof / service.sh  --  late_start service, runs at boot
# ============================================================================
# Magisk and APatch both execute service.sh in late_start service mode. At this
# point the framework is up, so `am`/`wm`/`pm` are usable.
#
# We intentionally do NOT use post-fs-data.sh for anything that needs the app's
# storage, because at post-fs-data the framework is not ready. post-fs-data.sh
# exists only to set up the state directory early.
# ============================================================================

MODDIR="${0%/*}"
STATE_DIR=/data/adb/tablet-spoof
LOG="$STATE_DIR/tablet-spoof.log"

mkdir -p "$STATE_DIR" 2>/dev/null
chmod 0755 "$STATE_DIR" 2>/dev/null

echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) [tablet-spoof] service.sh start (pid $$)" >> "$LOG" 2>/dev/null

# Wait for the framework to be genuinely ready, otherwise `pm`/`wm` fail and we
# would silently do nothing.
_i=0
while [ "$_i" -lt 120 ]; do
  if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    break
  fi
  sleep 2
  _i=$((_i + 1))
done
echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) [tablet-spoof] boot_completed=$(getprop sys.boot_completed 2>/dev/null) after ${_i} ticks" >> "$LOG" 2>/dev/null

# Give the storage/keystore stack a moment so per-app dirs are readable.
sleep 5

# The engine is idempotent and fail-closed, so a single apply is safe.
if [ -x "$MODDIR/tablet-spoof.sh" ]; then
  "$MODDIR/tablet-spoof.sh" apply >> "$LOG" 2>&1
else
  sh "$MODDIR/tablet-spoof.sh" apply >> "$LOG" 2>&1
fi

# --- keep the companion APK in sync with the module --------------------------
# This is what makes the module self-updating: when a newer module zip is flashed,
# the APK inside it is newer than the installed one, and we replace it at boot.
# install-app.sh compares versionCodes, so on a normal boot this is a cheap no-op.
#
# Also re-asserts the LSPosed scope whitelist AND enabled=1 on every boot, so:
#   * an out-of-scope row added by hand (or another tool) is pruned, and
#   * the module can never remain silently DISABLED.
# That second point is not hypothetical: during development a tooling script left
# enabled=0, the pad entry vanished, and every other signal (registered, scoped,
# apk installed) still looked healthy. Re-asserting it at boot makes that
# self-correcting instead of a silent, hard-to-see failure.
if [ -x "$MODDIR/install-app.sh" ]; then
  "$MODDIR/install-app.sh" install >> "$LOG" 2>&1
  "$MODDIR/install-app.sh" enable  >> "$LOG" 2>&1
else
  sh "$MODDIR/install-app.sh" install >> "$LOG" 2>&1
  sh "$MODDIR/install-app.sh" enable  >> "$LOG" 2>&1
fi

# Record the resulting state, so a support question ("did it enable?") is
# answerable from the log alone rather than by re-deriving it.
{
  echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) [tablet-spoof] enable re-assert result:"
  sh "$MODDIR/lsposed-enable.sh" status 2>/dev/null
} >> "$LOG" 2>&1

# If the target apps are (re)started later in the session, we do not chase them:
# all app-side writes require the process to be stopped. A user-triggered apply
# can be run any time via:
#   su -c sh /data/adb/modules/tablet-spoof/tablet-spoof.sh apply
echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) [tablet-spoof] service.sh done" >> "$LOG" 2>/dev/null

exit 0
