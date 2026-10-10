#!/system/bin/sh
# ============================================================================
# tablet-spoof / verify-targets.sh   (run AS ROOT)
# ============================================================================
# Module-side CORROBORATING check (design option B).
#
# Why this exists alongside the in-process status file: the status file is
# precise (it proves the hook actually installed) but depends on a Context hook
# and on the app having run. This check is cruder but independent -- it verifies
# that the SYMBOLS the hooks need still exist in the installed APK's dex.
#
# Together:
#   verify-targets.sh  -> "the target symbols still exist"   (cheap, always works)
#   hook-status.sh     -> "the hook actually installed"      (precise, needs a launch)
#
# If the symbols are gone, the app was updated and the hooks WILL silently miss;
# this catches that even before the app is ever launched.
# ============================================================================

log() { echo "[verify-targets] $*"; }
FAIL=0

check_apk() {
  _pkg="$1"; shift
  _apk=$(pm path "$_pkg" 2>/dev/null | head -n1 | sed 's/^package://')
  log "=== $_pkg ==="
  if [ -z "$_apk" ] || [ ! -f "$_apk" ]; then
    log "  not installed"
    return 0
  fi
  log "  apk: $_apk"

  _w=/data/local/tmp/verify-targets-$$
  rm -rf "$_w"; mkdir -p "$_w"
  # Extract only the dex that could contain the symbols. Use -j to flatten.
  if ! unzip -o -j "$_apk" 'classes*.dex' -d "$_w" >/dev/null 2>&1; then
    log "  could not extract dex"
    rm -rf "$_w"
    FAIL=1
    return 1
  fi

  for _sym in "$@"; do
    case "$_sym" in
      */*)
        # a type descriptor: require the L...; form
        if grep -qa "$_sym" "$_w"/*.dex 2>/dev/null; then
          log "  OK   descriptor $_sym present"
        else
          log "  MISS descriptor $_sym ABSENT  <-- hooks will silently miss"
          FAIL=1
        fi
        ;;
      *)
        # a bare method/field name: must appear as a string in some dex
        if grep -qa "$_sym" "$_w"/*.dex 2>/dev/null; then
          log "  OK   name '$_sym' present"
        else
          log "  MISS name '$_sym' ABSENT  <-- hooks will silently miss"
          FAIL=1
        fi
        ;;
    esac
  done
  rm -rf "$_w"
  return 0
}

log "checking hook target symbols in the installed APKs"
log ""

# WeCom: the two hooked classes, by descriptor.
check_apk com.tencent.wework \
  'com/tencent/wework/foundation/logic/Application;' \
  'com/tencent/wework/foundation/impl/WeworkServiceImpl;' \
  'isAndroidPad'

log ""

# WeChat: obfuscated class; the stable anchor is the LOG STRING, not the name.
# We verify the anchor string only, since gk/B WILL rename.
check_apk com.tencent.mm \
  'inTabletEnv, no tablet condition matched, return false'

log ""
if [ "$FAIL" = "0" ]; then
  log "RESULT: PASS - all expected symbols present"
else
  log "RESULT: FAIL - at least one target symbol is missing"
  log "        The app was probably updated. Re-run tools/audit-hook-targets.py"
  log "        and tools/stability-analysis.py against the new APK."
fi
exit $FAIL
