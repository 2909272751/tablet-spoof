#!/system/bin/sh
# ============================================================================
# tablet-spoof / check-module-state.sh   (AS ROOT, READ-ONLY)
# ============================================================================
# Reports whether the module is correctly configured and ACTIVE.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS, AND WHY IT IS STRICTLY READ-ONLY
# ---------------------------------------------------------------------------
# An earlier diagnostic in this project contained a live
#     UPDATE modules_state SET enabled=0 WHERE module_pkg_name='...'
# written to *demonstrate* that an unfiltered state write clobbers the module.
# Running it against the live module did exactly what it said on the tin: it
# **disabled the module**, the pad entry disappeared, and a working device was
# left broken.
#
# The test design was wrong, not just the outcome: an experiment whose side effect
# destroys the thing under test must never be run against a live system. Any
# experiment that perturbs state must (a) run against a COPY, or (b) restore state
# in the same script, and preferably (c) both.
#
# This replacement is therefore read-only. It never writes to the LSPosed DB.
# If you want to prove the clobber behaviour, do it on a copy:
#     cp modules_config.db /data/local/tmp/dbcopy.db
#     sqlite3 /data/local/tmp/dbcopy.db "UPDATE ... enabled=0 ..."
#     sqlite3 /data/local/tmp/dbcopy.db "SELECT ..."
# ---------------------------------------------------------------------------

DB=/data/adb/lspd/config/modules_config.db
SQLITE="$(command -v sqlite3 2>/dev/null)"; [ -n "$SQLITE" ] || SQLITE=/system/bin/sqlite3
MODULE_ID="${1:-io.github.tabletspoof}"
USER_ID=0
PKG=com.tencent.wework

log() { echo "[state] $*"; }

log "=============================================="
log " module state: $MODULE_ID"
log "=============================================="
echo ""

log "--- 1. configuration (read-only) ---"
if [ -x "$SQLITE" ] && [ -f "$DB" ]; then
  _en=$("$SQLITE" "$DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID;" 2>/dev/null)
  log "  enabled        : ${_en:-<no row>}   (1 = active)"
  log "  scope          :"
  "$SQLITE" "$DB" "SELECT app_pkg_name FROM scope WHERE module_pkg_name='$MODULE_ID';" 2>/dev/null | sed 's/^/    /'
  log "  apk registered : $("$SQLITE" "$DB" "SELECT apk_path FROM modules WHERE module_pkg_name='$MODULE_ID';" 2>/dev/null)"
else
  log "  LSPosed DB not reachable at $DB"
fi
echo ""

log "--- 2. infrastructure ---"
log "  lspd           : $(pidof lspd 2>/dev/null || echo NOT-RUNNING)"
log "  NOTE: a maps-based 'injected' count is NOT a valid signal (deleted memfd)."
echo ""

log "--- 3. BEHAVIOUR (the only reliable check) ---"
log "  launching the login activity and looking for the pad entry..."
am force-stop "$PKG" 2>/dev/null
sleep 3
am start -W -n "$PKG/.login.controller.LoginWxAuthActivity" >/dev/null 2>&1
sleep 10
rm -f /sdcard/state-ui.xml
uiautomator dump /sdcard/state-ui.xml >/dev/null 2>&1
if [ -f /sdcard/state-ui.xml ]; then
  _pkg=$(grep -o 'package="[^"]*"' /sdcard/state-ui.xml | sort -u | head -1)
  log "  dump describes : $_pkg"
  if grep -q '平板和手机同时登录' /sdcard/state-ui.xml; then
    log "  pad entry      : PRESENT  => module is ACTIVE and working"
  else
    log "  pad entry      : ABSENT   => module is NOT taking effect"
    log "    texts seen:"
    grep -o 'text="[^"]*"' /sdcard/state-ui.xml | sed 's/text=//' | sort -u | sed 's/^/      /'
  fi
fi
rm -f /sdcard/state-ui.xml
echo ""

log "--- 4. if ABSENT, the first thing to check ---"
log "  Was 'enabled' changed since lspd started? lspd reads this DB ONCE at"
log "  daemon startup, so a flag set AFTER it started has no effect until a"
log "  REBOOT. Setting enabled=1 and re-testing without rebooting will still"
log "  show ABSENT and is a false alarm."
log "  lspd pid: $(pidof lspd 2>/dev/null)   (compare to when you changed the flag)"
