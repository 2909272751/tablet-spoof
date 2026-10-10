#!/system/bin/sh
# ============================================================================
# tablet-spoof / post-fs-data.sh
# ============================================================================
# Runs very early (before the framework). Keep this extremely cheap: create the
# state directory and nothing else. All real work happens in service.sh.
# ============================================================================

STATE_DIR=/data/adb/tablet-spoof
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 0755 "$STATE_DIR" 2>/dev/null

exit 0
