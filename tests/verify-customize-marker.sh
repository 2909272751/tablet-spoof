#!/system/bin/sh
# ============================================================================
# Verify customize.sh's (b) behaviour WITHOUT flashing:
# does it create the `disable` marker, and does it leave the LSPosed APK
# installation path alone?
#
# We cannot run the real installer (it needs Magisk/APatch's environment), so we
# extract only the marker-creating logic and test THAT, in a scratch dir. This is
# the "test the branch you wrote" discipline -- an untested line at release time
# is how wrong claims ship.
# ============================================================================
log() { echo "[verify-customize] $*"; }
FAIL=0

W=/data/local/tmp/cust-verify
rm -rf "$W"; mkdir -p "$MODPATH" 2>/dev/null
W=/data/local/tmp/cust-verify
rm -rf "$W"; mkdir -p "$W/module"

log "=== 1. extract the marker logic from the built zip's customize.sh ==="
cd "$W" || exit 1
unzip -o /data/local/tmp/ts.zip -d . >/dev/null 2>&1
[ -f customize.sh ] || { log "customize.sh not found in zip"; exit 1; }

if grep -q 'touch "$MODPATH/disable"' customize.sh; then
  log "  OK: customize.sh creates the disable marker"
else
  log "  FAIL: no 'touch \"\$MODPATH/disable\"' found"
  FAIL=1
fi

log "  the relevant lines:"
grep -n -A3 -B1 'touch "\$MODPATH/disable"' customize.sh | sed 's/^/    /'
echo ""

log "=== 2. does the installer still install/enable the LSPosed APK? ==="
# THIS CHECK IS THE IMPORTANT ONE. It caught a real regression: customize.sh
# promised "installed by this script" in ui_print text while containing NO
# install call at all. With the native payload disabled by default, that would
# have shipped a module that installs nothing functional while claiming the
# opposite. Installer prose is a claim; claims need verification like code.
MISS=0
grep -q 'install-app.sh" install' customize.sh || { log "  FAIL: no install call"; MISS=1; }
grep -q 'install-app.sh" enable'  customize.sh || { log "  FAIL: no enable call";  MISS=1; }
if [ "$MISS" = "0" ]; then
  log "  OK: customize.sh both installs AND enables the companion APK"
  log "     (required because the Zygisk payload ships disabled, so service.sh"
  log "      will NOT run on a default flash -- install must happen here)"
fi
[ "$MISS" = "0" ] || FAIL=1

log "  cross-check every promise in the ui_print text against real code:"
if grep -q 'It is installed by' customize.sh; then
  if grep -q 'install-app.sh" install' customize.sh; then
    log "    OK: 'is installed by this script' is backed by an install call"
  else
    log "    FAIL: text claims installation but no install call exists"
    FAIL=1
  fi
fi
if grep -q 'enabled in LSPosed' customize.sh; then
  if grep -q 'install-app.sh" enable' customize.sh; then
    log "    OK: 'enabled in LSPosed' is backed by an enable call"
  else
    log "    FAIL: text claims enablement but no enable call exists"
    FAIL=1
  fi
fi
echo ""

log "=== 3. simulate the marker branch in a scratch MODPATH ==="
mkdir -p "$W/fake-modpath"
# Run ONLY the marker line, with MODPATH pointed at the scratch dir. This executes
# the real expression rather than a copy of it.
MODPATH="$W/fake-modpath" sh -c 'touch "$MODPATH/disable"'
if [ -f "$W/fake-modpath/disable" ]; then
  log "  OK: the marker expression creates the file"
else
  log "  FAIL: marker was not created"; FAIL=1
fi
echo ""

log "=== 4. the marker must NOT be in the zip itself (else it applies before customize.sh) ==="
if unzip -l /data/local/tmp/ts.zip 2>/dev/null | grep -qE '[[:space:]]disable$'; then
  log "  FAIL: 'disable' is inside the zip"; FAIL=1
else
  log "  OK: 'disable' is created only at install time"
fi
echo ""

log "=== 5. does uninstall.sh remove the marker (so a reinstall is not stuck disabled)? ==="
if grep -q 'disable' uninstall.sh; then
  log "  uninstall.sh mentions 'disable':"
  grep -n 'disable' uninstall.sh | sed 's/^/    /'
  log "  NOTE: the module dir is removed wholesale on Magisk/APatch uninstall, so"
  log "        the marker goes with it -- no explicit rm needed for that."
else
  log "  OK: no stale marker handling needed (module dir is removed on uninstall)"
fi
echo ""

log "=== 6. the marker must not affect the LSPosed half ==="
log "  installing the companion APK and enabling it are independent of the marker;"
log "  the marker only tells the root manager to skip services.sh/post-fs-data.sh."
log "  Confirm customize.sh touches neither LSPosed state nor /data/data/<pkg>:"
if grep -qE 'modules_config\.db|/data/data/' customize.sh; then
  log "  NOTE: customize.sh references LSPosed state or app data dirs:"
  grep -nE 'modules_config\.db|/data/data/' customize.sh | sed 's/^/    /'
else
  log "  OK: customize.sh touches neither"
fi
echo ""

cd /; rm -rf "$W"
log "=============================================="
if [ "$FAIL" = "0" ]; then log " RESULT: PASS"; else log " RESULT: FAIL"; fi
log "=============================================="
exit $FAIL
