#!/system/bin/sh
# ============================================================================
# tablet-spoof / check-lsposed-health.sh   (AS ROOT)
# ============================================================================
# Determines whether LSPosed is actually working.
#
# ⚠️ READ THIS: WHY THE OBVIOUS METRIC IS WRONG
# --------------------------------------------
# The intuitive check is "is lspd/LSPosed mapped into app processes?" — e.g.
#   grep -l LSPosed /proc/<pid>/maps
# **That check produces FALSE NEGATIVES on a device where LSPosed works perfectly.**
#
# Measured on this device while the feature demonstrably worked (the pad entry
# appeared, proving our hook ran inside WeCom):
#     processes matching 'lspd|LSPosed' in maps : 0
#     our own module's .so in the app's maps    : 0
#     app process memfd mappings                : 5   <-- the actual vehicle
#
# LSPosed injects via a **deleted memfd**, so nothing appears in `maps` under a
# filename. A filename grep therefore cannot see it at all.
#
# We shipped that wrong metric once and it led to the confident, false conclusion
# "LSPosed is broken on this device" — which nearly went into the user-facing
# documentation. This file now checks the RIGHT things and treats the maps grep
# as explicitly unreliable.
#
# WHAT ACTUALLY DETERMINES HEALTH (in order):
#   1. CONFIGURATION: is the module enabled, and scoped to the right packages?
#      (An enabled=0 module is silent while everything else looks healthy. This
#      bit us for real — and it was our own tooling that cleared the flag.)
#   2. BEHAVIOUR: does the feature work? That is the only ground truth. The
#      pad entry appearing proves the hook ran; nothing else does.
#   3. INFRASTRUCTURE: is lspd alive at all?
#
# Usage: check-lsposed-health.sh [package]
# ============================================================================

PKG="${1:-com.tencent.wework}"
DB=/data/adb/lspd/config/modules_config.db
SQLITE="$(command -v sqlite3 2>/dev/null)"; [ -n "$SQLITE" ] || SQLITE=/system/bin/sqlite3
MODULE_ID=io.github.tabletspoof
USER_ID=0
FAIL=0

log() { echo "[health] $*"; }

log "=============================================="
log " LSPosed health for $PKG"
log "=============================================="
echo ""

# --- 1. configuration --------------------------------------------------------
log "1. CONFIGURATION"
if [ -x "$SQLITE" ] && [ -f "$DB" ]; then
  _en=$("$SQLITE" "$DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='$MODULE_ID' AND user_id=$USER_ID;" 2>/dev/null)
  if [ "$_en" = "1" ]; then
    log "   module enabled : 1  OK"
  else
    log "   module enabled : ${_en:-<absent>}  *** FAIL ***"
    log "     An 'enabled=0' module is completely silent while every other signal"
    log "     looks healthy. Fix: lsposed-enable.sh enable, then REBOOT."
    FAIL=1
  fi
  log "   scope          :"
  _sc=$("$SQLITE" "$DB" "SELECT app_pkg_name FROM scope WHERE module_pkg_name='$MODULE_ID';" 2>/dev/null)
  echo "$_sc" | sed 's/^/     /'
  if [ "$_sc" = "com.tencent.mm
com.tencent.wework" ] || [ "$(echo "$_sc" | sort | tr '\n' ' ')" = "com.tencent.mm com.tencent.wework " ]; then
    log "   scope exact    : yes (both allowed packages, nothing else)  OK"
  else
    log "   scope exact    : NO - expected exactly com.tencent.mm + com.tencent.wework  *** FAIL ***"
    FAIL=1
  fi
else
  log "   LSPosed config not reachable at $DB  *** FAIL ***"
  FAIL=1
fi
echo ""

# --- 2. infrastructure -------------------------------------------------------
log "2. INFRASTRUCTURE"
_lspd=$(pidof lspd 2>/dev/null)
if [ -n "$_lspd" ]; then
  log "   lspd alive     : yes (pid $_lspd)  OK"
else
  log "   lspd alive     : NO  *** FAIL ***"
  FAIL=1
fi
log "   NOTE: a maps-based 'injected process' count is NOT a valid health signal"
log "         here (LSPosed uses a deleted memfd). It is reported below for"
log "         reference only, and a reading of 0 does NOT mean LSPosed is broken."
_n=0
for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
  grep -qa 'lspd\|LSPosed' /proc/$p/maps 2>/dev/null && _n=$((_n+1))
done
log "   (maps grep, UNRELIABLE): $_n"
echo ""

# --- 3. behaviour: the only ground truth -------------------------------------
log "3. BEHAVIOUR  <- the only reliable check"
log "   Launching the login activity and looking for the pad entry..."
am force-stop "$PKG" 2>/dev/null
sleep 3
am start -W -n "$PKG/.login.controller.LoginWxAuthActivity" >/dev/null 2>&1
sleep 10
rm -f /sdcard/health-ui.xml
uiautomator dump /sdcard/health-ui.xml >/dev/null 2>&1
if [ -f /sdcard/health-ui.xml ]; then
  if grep -q '平板和手机同时登录' /sdcard/health-ui.xml; then
    log "   pad entry      : PRESENT  => LSPosed IS working, module IS active  OK"
  else
    log "   pad entry      : ABSENT   => the spoof is NOT taking effect  *** FAIL ***"
    log "     (check configuration above first: enabled=1 and scope)"
    log "     texts seen:"
    grep -o 'text="[^"]*"' /sdcard/health-ui.xml | sort -u | sed 's/^/       /'
    FAIL=1
  fi
else
  log "   pad entry      : could not dump UI  (inconclusive)"
  FAIL=1
fi
rm -f /sdcard/health-ui.xml
echo ""

log "=============================================="
if [ "$FAIL" = "0" ]; then
  log " RESULT: HEALTHY - the mechanism is working"
else
  log " RESULT: NOT WORKING - see the FAIL lines above"
fi
log "=============================================="
exit $FAIL
