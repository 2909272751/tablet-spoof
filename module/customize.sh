#!/system/bin/sh
# ============================================================================
# tablet-spoof - Magisk / APatch module installer
# ============================================================================
# Magisk/APatch both source this file during installation. It runs inside the
# installer's busybox ash with the module tree unpacked into $MODPATH.
#
# Deliberately minimal: there is NO native payload, NO system/ overlay and NO
# system.prop. Everything this module does happens at boot from service.sh,
# strictly outside the target app processes. See README.md.
# ============================================================================

SKIPUNZIP=0

ui_print " "
ui_print "*******************************"
ui_print "  Tablet Spoof (WeChat/WeCom)  "
ui_print "*******************************"
ui_print " "

# --- Sanity: required files must exist in the zip ---------------------------
for f in service.sh post-fs-data.sh uninstall.sh tablet-spoof.sh; do
  if [ ! -f "$MODPATH/$f" ]; then
    ui_print "! ERROR: missing $f in module package"
    abort "! Corrupt module zip - aborting"
  fi
done
if [ ! -f "$MODPATH/zygisk/arm64-v8a.so" ]; then
  ui_print "! ERROR: native payload missing: zygisk/arm64-v8a.so"
  abort "! Corrupt module zip - aborting"
fi

# ---------------------------------------------------------------------------
# Zygisk payload DISABLED BY DEFAULT  (deliberate, not an oversight)
# ---------------------------------------------------------------------------
# The native payload loads and enforces its whitelist correctly, but on Android
# 15/16 it is not executed inside target app processes, so it performs NO spoof
# (root cause unidentified; see README). Shipping a module that is "active" while
# provably doing nothing is worse than shipping one that is honestly off.
#
# So we create the standard Magisk/APatch `disable` marker, which makes the
# manager show the module as DISABLED. Enabling it is a deliberate act by a user
# on an older Android version, where it may work -- untested there, and we do not
# claim otherwise.
#
# This affects ONLY the Zygisk payload. The LSPosed companion APK (the mechanism
# that actually works) is installed and enabled regardless.
touch "$MODPATH/disable"
ui_print "- Native Zygisk payload: DISABLED by default (see README)"
ui_print "  It is non-functional on Android 15/16. Enable it by removing"
ui_print "  $MODPATH/disable if you are on an older Android and want to test it."
ui_print "  This does NOT affect the LSPosed companion, which is what works."
ui_print " "

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh"  0 0 0755
set_perm "$MODPATH/service.sh"    0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh"  0 0 0755
set_perm "$MODPATH/tablet-spoof.sh" 0 0 0755
[ -f "$MODPATH/lsposed-enable.sh" ] && set_perm "$MODPATH/lsposed-enable.sh" 0 0 0755
[ -f "$MODPATH/verify-native.sh" ] && set_perm "$MODPATH/verify-native.sh" 0 0 0755
set_perm "$MODPATH/zygisk/arm64-v8a.so" 0 0 0644

ui_print "- Native payload: $(ls -l "$MODPATH/zygisk/arm64-v8a.so" | awk '{print $5}') bytes"

# --- Detect targets, purely for the install log ------------------------------
# NOTE: installation NEVER writes into the apps' data dirs. All app-side work
# happens in service.sh at boot, where we can be sure the app is not running.
_tgt=""
for p in com.tencent.mm com.tencent.wework; do
  if pm path "$p" >/dev/null 2>&1 || [ -d "/data/data/$p" ]; then
    _tgt="$_tgt $p"
  fi
done
if [ -n "$_tgt" ]; then
  ui_print "- Installed target(s):$_tgt"
else
  ui_print "- No target app found yet; module stays inert until one appears."
fi

# --- Runtime state dir -------------------------------------------------------
# NOTE: verified on this device that the root manager is APatch 114027, and that
# APatch mounts/reads its modules from /data/adb/modules (identical to Magisk).
# So no per-manager path branching is needed; $MODPATH is supplied by the
# installer either way.
mkdir -p /data/adb/tablet-spoof
set_perm /data/adb/tablet-spoof 0 0 0755

ui_print "- Control flag: /data/adb/tablet-spoof/disable"
ui_print "  (create that file to suspend the module without uninstalling)"
ui_print "- Log: /data/adb/tablet-spoof/tablet-spoof.log"
ui_print " "

# ---------------------------------------------------------------------------
# Install + enrol the LSPosed companion -- THE ACTUALLY-WORKING MECHANISM
# ---------------------------------------------------------------------------
# This MUST happen here, at install time, and not only from service.sh.
#
# Reason: we ship the native Zygisk payload with a `disable` marker (see above),
# and a disabled module's service.sh never runs. If the companion APK were only
# installed from service.sh, then a default flash on this Android version would
# install NOTHING that works -- the module would be inert end to end while the
# installer text claimed otherwise.
#
# An earlier revision of this file removed these calls while rewriting the
# installer and left only the ui_print text promising them. Caught by
# tests/verify-customize-marker.sh, which checks that the behaviour the text
# describes is actually performed. Lesson: installer prose is a claim, and
# claims need the same verification as code.
ui_print "- Installing the LSPosed companion (the mechanism that works)..."
if [ -f "$MODPATH/install-app.sh" ]; then
  if [ -f "$MODPATH/tablet-spoof.apk" ]; then
    sh "$MODPATH/install-app.sh" install 2>&1 | while read -r _l; do ui_print "  $_l"; done
    sh "$MODPATH/install-app.sh" enable  2>&1 | while read -r _l; do ui_print "  $_l"; done
  else
    ui_print "  ! tablet-spoof.apk is MISSING from the zip"
    ui_print "    Nothing would perform the spoof. Install manually if you have it."
  fi
else
  ui_print "  ! install-app.sh missing; cannot enrol automatically."
fi
ui_print " "

ui_print "- HOW THIS MODULE WORKS (read this - two mechanisms are bundled):"
ui_print " "
ui_print "  [ACTIVE] LSPosed companion APK  = tablet-spoof.apk"
ui_print "      This is the mechanism that ACTUALLY WORKS. It is installed by"
ui_print "      this script and enabled in LSPosed for the two target apps."
ui_print " "
ui_print "  [DISABLED by default] Native Zygisk payload"
ui_print "      = zygisk/arm64-v8a.so"
ui_print "      It loads and registers, and its 2-package whitelist is verified,"
ui_print "      BUT on Android 15/16 the payload is not executed inside the target"
ui_print "      app processes, so it performs NO spoof. Cause unidentified."
ui_print "      We therefore ship it DISABLED rather than active-but-inert."
ui_print "      Android <=14 users may test it by removing:"
ui_print "        $MODPATH/disable"
ui_print "      (untested there; we do not claim it works)"
ui_print " "
ui_print "- Requirements for the ACTIVE mechanism:"
ui_print "  * LSPosed must be installed and HEALTHY (Zygisk enabled)."
ui_print "  * REBOOT after installing: LSPosed reads its config at daemon startup."
ui_print "  * Enrolling sometimes needs the LSPosed manager opened once, then:"
ui_print "      sh $MODPATH/install-app.sh enable"
ui_print "    (do this if the steps above reported the module was not registered)"
ui_print " "
ui_print "- Scope is limited to com.tencent.mm and com.tencent.wework only,"
ui_print "  enforced in Zygisk scope, the LSPosed scope list, an exact-match check,"
ui_print "  and the module's own guard. Subprocesses are skipped by design."
ui_print " "
ui_print "- Verify after rebooting (run as root):"
ui_print "    sh $MODPATH/lsposed-enable.sh status  # is the active half healthy?"
ui_print "    sh $MODPATH/tablet-spoof.sh report    # read-only diagnostics"
ui_print " "
ui_print "- ******************** REBOOT REQUIRED ********************"
ui_print "  LSPosed reads its configuration once, at daemon startup, so the"
ui_print "  module will not take effect until you reboot."
ui_print " ***********************************************************"
ui_print " "
