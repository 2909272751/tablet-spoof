#!/system/bin/sh
# ============================================================================
# tablet-spoof / lsposed-enable.sh
# ============================================================================
# Enables (or disables) the tablet-spoof LSPosed module for the whitelisted
# packages WITHOUT hand-editing SQL, so the user never has to run sqlite3.
#
# Usage:
#   lsposed-enable.sh enable     # enable module + scope for both targets
#   lsposed-enable.sh disable    # disable module
#   lsposed-enable.sh status     # report current state (default)
#
# ---------------------------------------------------------------------------
# SCHEMA NOTES (verified against LSPosed v2.2.0 (7854) modules_config.db)
# ---------------------------------------------------------------------------
# The schema is NOT what you would guess, and guessing it silently breaks:
#
#   modules(module_pkg_name PK, apk_path)
#   modules_state(module_pkg_name, user_id, enabled, scope_request_blocked,
#                 PRIMARY KEY(module_pkg_name, user_id))
#   scope(module_pkg_name, app_pkg_name, user_id,
#         PRIMARY KEY(module_pkg_name, app_pkg_name, user_id))
#
# Two traps:
#   1. `enabled` is in modules_state, NOT modules. It is PER-USER.
#   2. the scope package column is `app_pkg_name`, NOT `pkg_name`.
# Getting either wrong makes sqlite3 fail (or worse, match nothing) and the
# module silently stays off.
#
# IMPORTANT: lspd reads this DB ONCE at startup, so any change requires a
# REBOOT. This script says so explicitly rather than appearing to succeed.
#
# Scope of writes: LSPosed's own config database only. Never /data/data/<pkg>,
# never display state.
# ============================================================================

MODULE_ID="io.github.tabletspoof"
DB="/data/adb/lspd/config/modules_config.db"
SQLITE="$(command -v sqlite3 2>/dev/null)"
[ -n "$SQLITE" ] || SQLITE=/system/bin/sqlite3

USER_ID="0"
TARGETS="com.tencent.mm com.tencent.wework"

log() { echo "[tablet-spoof] $*"; }
fail() { echo "[tablet-spoof] ERROR: $*" >&2; exit 1; }

[ -x "$SQLITE" ] || fail "sqlite3 not found (checked PATH and /system/bin/sqlite3)"
[ -f "$DB" ] || fail "LSPosed config not found at $DB -- is LSPosed installed?"

q() { "$SQLITE" "$DB" "$1" 2>/dev/null; }

module_registered() {
  [ "$(q "SELECT COUNT(*) FROM modules WHERE module_pkg_name='$MODULE_ID';")" = "1" ]
}

do_status() {
  log "=== LSPosed state for $MODULE_ID ==="

  if ! module_registered; then
    log "  module row: NOT REGISTERED"
    log "  -> install the APK and open LSPosed manager once so it scans the app"
    log "     (LSPosed creates the row on scan), then re-run: $0 enable"
    return 0
  fi

  log "  module registered: yes"
  log "  apk_path: $(q "SELECT apk_path FROM modules WHERE module_pkg_name='$MODULE_ID';")"

  _state=$(q "SELECT COUNT(*) FROM modules_state WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID;")
  if [ "$_state" = "0" ]; then
    log "  modules_state row for user $USER_ID: ABSENT (module never toggled)"
  else
    log "  enabled (user $USER_ID): $(q "SELECT enabled FROM modules_state WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID;")  (1=enabled)"
  fi

  log "  scope rows:"
  q "SELECT app_pkg_name, user_id FROM scope WHERE module_pkg_name='$MODULE_ID';" | sed 's/^/    /'

  # Whitelist compliance check.
  _extra=$(q "SELECT app_pkg_name FROM scope WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID AND app_pkg_name NOT IN ('com.tencent.mm','com.tencent.wework');")
  if [ -n "$_extra" ]; then
    log "  !! OUT-OF-SCOPE entries present: $_extra"
  else
    log "  scope whitelist: clean (only the two allowed packages)"
  fi

  log "  lspd pid: $(pidof lspd 2>/dev/null || echo 'not running')"
  log "  REMINDER: lspd reads this DB at startup -- a REBOOT is required for changes to apply."
}

do_enable() {
  if ! module_registered; then
    fail "module not registered with LSPosed. Install the APK and open LSPosed manager once so it scans '$MODULE_ID', then re-run."
  fi

  # --- scope: enforce the exact whitelist, idempotently ----------------------
  for t in $TARGETS; do
    _n=$(q "SELECT COUNT(*) FROM scope WHERE module_pkg_name='$MODULE_ID' AND app_pkg_name='$t' AND user_id=$USER_ID;")
    if [ "$_n" = "0" ]; then
      q "INSERT INTO scope(module_pkg_name, app_pkg_name, user_id) VALUES('$MODULE_ID','$t',$USER_ID);"
      log "  scope += $t"
    else
      log "  scope already has $t"
    fi
  done

  # Actively REMOVE anything out of scope: a scope mistake would leak the spoof
  # into unrelated apps, which is the module's cardinal rule.
  _extra=$(q "SELECT app_pkg_name FROM scope WHERE module_pkg_name='$MODULE_ID' AND app_pkg_name NOT IN ('com.tencent.mm','com.tencent.wework');")
  if [ -n "$_extra" ]; then
    for e in $_extra; do
      log "  REMOVING out-of-scope entry: $e"
      q "DELETE FROM scope WHERE module_pkg_name='$MODULE_ID' AND app_pkg_name='$e';"
    done
  fi

  # --- enabled flag lives in modules_state, per user -------------------------
  _n=$(q "SELECT COUNT(*) FROM modules_state WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID;")
  if [ "$_n" = "0" ]; then
    q "INSERT INTO modules_state(module_pkg_name, user_id, enabled, scope_request_blocked) VALUES('$MODULE_ID',$USER_ID,1,0);"
    log "  modules_state row created (enabled=1)"
  else
    q "UPDATE modules_state SET enabled=1 WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID;"
    log "  modules_state.enabled set to 1"
  fi

  # Verify the write actually landed, rather than trusting the exit code.
  _now=$(q "SELECT enabled FROM modules_state WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID;")
  if [ "$_now" != "1" ]; then
    fail "verification failed: enabled reads back as '$_now' (expected 1)"
  fi

  log "done. REBOOT REQUIRED for lspd to load this configuration."
  echo ""
  do_status
}

do_disable() {
  module_registered || fail "module not registered with LSPosed"
  _n=$(q "SELECT COUNT(*) FROM modules_state WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID;")
  if [ "$_n" = "0" ]; then
    q "INSERT INTO modules_state(module_pkg_name, user_id, enabled, scope_request_blocked) VALUES('$MODULE_ID',$USER_ID,0,0);"
  else
    q "UPDATE modules_state SET enabled=0 WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID;"
  fi
  log "module disabled. REBOOT REQUIRED for lspd to load this configuration."
}

case "$1" in
  enable)  do_enable ;;
  disable) do_disable ;;
  status|"") do_status ;;
  *) echo "usage: $0 {enable|disable|status}"; exit 2 ;;
esac
exit 0
