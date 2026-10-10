#!/system/bin/sh
# ============================================================================
# tablet-spoof / install-app.sh
# ============================================================================
# Installs (or reinstalls) the bundled LSPosed companion APK and registers it
# with LSPosed, then enables it with the strict 2-package scope.
#
# Called by customize.sh during flashing AND by service.sh on boot (so a module
# update replaces the APK without the user touching anything).
#
# Usage:
#   install-app.sh install     install/replace the APK + register
#   install-app.sh enable      enable in LSPosed + enforce scope (reboot needed)
#   install-app.sh uninstall   disable + drop scope rows + uninstall the APK
#   install-app.sh status      report state
#
# Safety: this script only ever manages the ONE package id below. It never
# touches the target apps' data and never changes display state.
# ============================================================================

MODDIR="${0%/*}"
APP_ID="io.github.tabletspoof"
APK_IN_MODULE="$MODDIR/tablet-spoof.apk"

TARGETS="com.tencent.mm com.tencent.wework"
DB="/data/adb/lspd/config/modules_config.db"
SQLITE="$(command -v sqlite3 2>/dev/null)"
[ -n "$SQLITE" ] || SQLITE=/system/bin/sqlite3
USER_ID="0"

log()  { echo "[tablet-spoof] $*"; }
warn() { echo "[tablet-spoof] WARN: $*" >&2; }
die()  { echo "[tablet-spoof] ERROR: $*" >&2; exit 1; }

# --- helpers ----------------------------------------------------------------

installed_path() {
  pm path "$APP_ID" 2>/dev/null | head -n1 | sed 's/^package://'
}

app_installed() { [ -n "$(installed_path)" ]; }

# The PM version code of the installed apk (0 if absent).
installed_version() {
  dumpsys package "$APP_ID" 2>/dev/null | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n1
}

# The version code inside our bundled apk, read without aapt (aapt is not on
# device). We use `pm` on a staged copy via a temp install path instead: simplest
# reliable route is to just (re)install -- Android itself rejects a downgrade.
bundled_version() {
  # Sidecar file written by build.ps1 alongside the apk.
  [ -f "$MODDIR/tablet-spoof.apk.version" ] && cat "$MODDIR/tablet-spoof.apk.version" || echo ""
}

# --- install ----------------------------------------------------------------
do_install() {
  [ -f "$APK_IN_MODULE" ] || die "bundled APK missing: $APK_IN_MODULE"

  _bundled="$(bundled_version)"
  _have="$(installed_version)"

  if app_installed; then
    if [ -n "$_bundled" ] && [ "$_have" = "$_bundled" ]; then
      log "app $APP_ID already at versionCode $_have; skipping install"
      return 0
    fi
    log "reinstalling $APP_ID (installed=$_have bundled=${_bundled:-unknown})"
  else
    log "installing $APP_ID"
  fi

  # -r keeps data; -d allows a downgrade so a module rollback also works.
  _out="$(pm install -r -d "$APK_IN_MODULE" 2>&1)"
  case "$_out" in
    *Success*)
      log "installed: $(installed_path)"
      ;;
    *ALREADY_EXISTS*|*"version downgrade"*)
      log "install reported '$_out' - treating as already present"
      ;;
    *)
      # A failure here must NOT abort the whole module flash: the rest of the
      # module (diagnostics, revert logic) is still useful, and the user can
      # install the APK manually.
      warn "pm install failed: $_out"
      warn "install the APK manually, then run: $MODDIR/install-app.sh enable"
      return 1
      ;;
  esac
  return 0
}

# --- enable in LSPosed ------------------------------------------------------
enable_in_lsposed() {
  [ -x "$SQLITE" ] || { warn "sqlite3 not found; cannot auto-enable"; return 1; }
  [ -f "$DB" ] || { warn "LSPosed config not found at $DB; cannot auto-enable"; return 1; }

  # LSPosed only creates the modules row when its manager has scanned the app.
  # If it has not yet, we cannot insert safely (FK constraint), so we tell the
  # user rather than corrupting the table.
  _n=$("$SQLITE" "$DB" "SELECT COUNT(*) FROM modules WHERE module_pkg_name='$APP_ID';" 2>/dev/null)
  if [ "$_n" != "1" ]; then
    log "module not yet registered with LSPosed."
    log "  -> open the LSPosed manager once so it scans $APP_ID, then reboot."
    log "     (Or re-run: $MODDIR/install-app.sh enable)"
    return 2
  fi

  # scope: insert the two allowed packages, then delete anything else.
  for t in $TARGETS; do
    _e=$("$SQLITE" "$DB" "SELECT COUNT(*) FROM scope WHERE module_pkg_name='$APP_ID' AND app_pkg_name='$t' AND user_id=$USER_ID;" 2>/dev/null)
    if [ "$_e" = "0" ]; then
      "$SQLITE" "$DB" "INSERT INTO scope(module_pkg_name, app_pkg_name, user_id) VALUES('$APP_ID','$t',$USER_ID);" 2>/dev/null
      log "  scope += $t"
    fi
  done
  _extra=$("$SQLITE" "$DB" "SELECT app_pkg_name FROM scope WHERE module_pkg_name='$APP_ID' AND app_pkg_name NOT IN ('com.tencent.mm','com.tencent.wework');" 2>/dev/null)
  for e in $_extra; do
    log "  REMOVING out-of-scope entry: $e"
    "$SQLITE" "$DB" "DELETE FROM scope WHERE module_pkg_name='$APP_ID' AND app_pkg_name='$e';" 2>/dev/null
  done

  # enabled lives in modules_state, per user.
  #
  # IMPORTANT: this must be keyed by (module_pkg_name, user_id). A bare
  # `UPDATE ... SET enabled=1 WHERE module_pkg_name=?` with no user_id filter
  # writes every user's row, and a bare SELECT reads an arbitrary one -- which is
  # how the state can silently disagree with what we think we set. We therefore
  # always scope by $USER_ID and VERIFY the read-back below.
  _s=$("$SQLITE" "$DB" "SELECT COUNT(*) FROM modules_state WHERE module_pkg_name='$APP_ID' AND user_id=$USER_ID;" 2>/dev/null)
  if [ "$_s" = "0" ]; then
    "$SQLITE" "$DB" "INSERT INTO modules_state(module_pkg_name, user_id, enabled, scope_request_blocked) VALUES('$APP_ID',$USER_ID,1,0);" 2>/dev/null
  else
    "$SQLITE" "$DB" "UPDATE modules_state SET enabled=1 WHERE module_pkg_name='$APP_ID' AND user_id=$USER_ID;" 2>/dev/null
  fi

  # Verify the write landed. Without this check, a failed UPDATE would leave the
  # module silently disabled while this script reported success -- which is
  # exactly what happened once during development, and it cost a debugging cycle
  # to find because every other signal (module registered, scope correct, apk
  # installed) looked healthy.
  _now=$("$SQLITE" "$DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='$APP_ID' AND user_id=$USER_ID;" 2>/dev/null)
  if [ "$_now" = "1" ]; then
    log "  LSPosed: enabled=1 (verified), scope enforced"
    return 0
  fi
  warn "verification failed: enabled reads back as '$_now' (expected 1)"
  warn "  -> the module is NOT active. Check manually:"
  warn "     sqlite3 $DB \"SELECT * FROM modules_state WHERE module_pkg_name='$APP_ID';\""
  return 1
}

# --- uninstall --------------------------------------------------------------
do_uninstall() {
  log "removing $APP_ID"

  # 1. disable in LSPosed and drop scope rows first, so nothing tries to load a
  #    module whose apk is about to vanish.
  #
  # NOTE ON THE user_id FILTER -- this is a real bug we hit, not a style choice:
  # an earlier version used `UPDATE modules_state SET enabled=0 WHERE
  # module_pkg_name=?` with NO user_id predicate. That is harmless in itself
  # (disabling on uninstall is correct), BUT the same unfiltered statement can
  # disable a *live* module if this function is ever invoked outside a true
  # uninstall -- e.g. during testing or cleanup. That is exactly how the module
  # ended up `enabled=0` during development, with every other signal (registered,
  # scope correct, apk present) still looking healthy, and the pad entry silently
  # gone. We now scope every state write by user_id, and re-enable on boot.
  if [ -x "$SQLITE" ] && [ -f "$DB" ]; then
    "$SQLITE" "$DB" "UPDATE modules_state SET enabled=0 WHERE module_pkg_name='$APP_ID' AND user_id=$USER_ID;" 2>/dev/null
    "$SQLITE" "$DB" "DELETE FROM scope WHERE module_pkg_name='$APP_ID';" 2>/dev/null
    # modules row: delete last (children cascade).
    "$SQLITE" "$DB" "DELETE FROM modules WHERE module_pkg_name='$APP_ID';" 2>/dev/null
    log "  LSPosed: disabled, scope rows and module row removed"
  else
    log "  LSPosed config not reachable; skipping (LSPosed will prune a missing app)"
  fi

  # 2. uninstall the apk itself. -k is deliberately NOT used: a full removal is
  #    what "revert" means here, and this app stores no user data of value.
  if app_installed; then
    _out="$(pm uninstall "$APP_ID" 2>&1)"
    case "$_out" in
      *Success*) log "  uninstalled $APP_ID" ;;
      *)         warn "  pm uninstall: $_out" ;;
    esac
  else
    log "  $APP_ID not installed; nothing to remove"
  fi
  return 0
}

# --- status -----------------------------------------------------------------
do_status() {
  log "=== tablet-spoof app/module state ==="
  if app_installed; then
    log "  app        : installed ($(installed_version))"
    log "  apk path   : $(installed_path)"
  else
    log "  app        : NOT installed"
  fi
  if [ -x "$SQLITE" ] && [ -f "$DB" ]; then
    _en=$("$SQLITE" "$DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='$APP_ID' AND user_id=$USER_ID;" 2>/dev/null)
    log "  lsposed    : enabled=${_en:-<no state row>}"
    log "  scope      :"
    "$SQLITE" "$DB" "SELECT app_pkg_name FROM scope WHERE module_pkg_name='$APP_ID';" 2>/dev/null | sed 's/^/      /'
  else
    log "  lsposed    : config not reachable"
  fi
  log "  lspd pid   : $(pidof lspd 2>/dev/null || echo 'not running')"
  log "  NOTE: LSPosed reads its config once at startup -- REBOOT after changes."
}

case "$1" in
  install)   do_install ;;
  enable)    enable_in_lsposed ;;
  uninstall) do_uninstall ;;
  status|"") do_status ;;
  *)
    echo "usage: $0 {install|enable|uninstall|status}"
    exit 2
    ;;
esac
exit 0
