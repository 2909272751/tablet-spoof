#!/system/bin/sh
# ============================================================================
# tablet-spoof / uninstall.sh
# ============================================================================
# Magisk/APatch run this when the module is removed from the manager app.
# It must FULLY revert everything the module did:
#
#   1. restore any files the guarded-write layer backed up (tablet-spoof.sh revert)
#   2. disable the LSPosed module, delete its scope rows and its modules row
#   3. uninstall the bundled companion APK
#   4. remove our runtime state dir
#
# Uninstall happens BEFORE the module directory is deleted, so these scripts are
# still available here.
#
# NOTE: lspd reads modules_config.db once at startup, so the LSPosed-side changes
# take effect on the next boot -- which is fine, because removing a Magisk module
# requires a reboot anyway.
#
# IMPORTANT: the log path lives in the state dir we delete, so all logging is
# finished before that rm.
# ============================================================================

MODDIR="${0%/*}"
STATE_DIR=/data/adb/tablet-spoof
LOG="$STATE_DIR/tablet-spoof.log"

echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) [tablet-spoof] uninstall.sh start" >> "$LOG" 2>/dev/null

# --- 1. undo app-side changes while the revert logic is still present --------
if [ -x "$MODDIR/tablet-spoof.sh" ]; then
  "$MODDIR/tablet-spoof.sh" revert >> "$LOG" 2>&1
else
  sh "$MODDIR/tablet-spoof.sh" revert >> "$LOG" 2>&1
fi

# --- 2+3. disable in LSPosed and uninstall the companion APK -----------------
# install-app.sh uninstall does both, in the safe order: it disables and deletes
# the scope/module rows FIRST, then uninstalls the package. Doing it the other
# way round would leave LSPosed pointing at a missing APK.
if [ -x "$MODDIR/install-app.sh" ]; then
  "$MODDIR/install-app.sh" uninstall >> "$LOG" 2>&1
else
  sh "$MODDIR/install-app.sh" uninstall >> "$LOG" 2>&1
fi

# --- 4. remove runtime state -------------------------------------------------
# We deliberately do NOT touch /data/data/<target>/ here: revert already restored
# exactly the files we had backed up, and nothing else was ever modified.
rm -rf "$STATE_DIR" 2>/dev/null

exit 0
