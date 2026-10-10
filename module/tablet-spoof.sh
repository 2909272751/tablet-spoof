#!/system/bin/sh
# ============================================================================
# tablet-spoof / tablet-spoof.sh  --  the single source of truth
# ============================================================================
# Makes ONLY com.tencent.mm (WeChat) and com.tencent.wework (WeCom) behave as if
# the device were a tablet-class screen, so their QR-code login is offered.
#
# HARD RULES (do not violate when editing):
#   R1. Scope whitelist: exactly two packages. Any other process/dir is never
#       touched. Every write is preceded by an explicit package-name check.
#   R2. Device-agnostic: NO literal device numbers. All geometry is derived at
#       runtime from the device's own real metrics.
#   R3. Density is NEVER modified (no ro.sf.lcd_density, no densityDpi, no
#       wm density). Changing it would distort the phone layout.
#   R4. Zero injection: this script never loads code into the app process and
#       never patches the APK. WeChat/WeCom anti-tamper checks
#       (onAppCheck / onRootCheck / xposed scans) therefore see nothing from us.
#   R5. Idempotent: safe to run any number of times.
#   R6. Fail-closed: if anything is ambiguous, do nothing and log it.
#
# Usage: tablet-spoof.sh [apply|revert|status|restore]
# ============================================================================

TAG="tablet-spoof"

# --- which packages are in scope --------------------------------------------
# Space separated. Membership test is an exact string compare, never a prefix
# or substring match, so e.g. "com.tencent.mm.plugin" can never match.
SCOPE="com.tencent.mm com.tencent.wework"

STATE_DIR=/data/adb/tablet-spoof
FLAG_DISABLE="$STATE_DIR/disable"
LOG="$STATE_DIR/tablet-spoof.log"
BACKUP_DIR="$STATE_DIR/backup"
STATE_FILE="$STATE_DIR/state.txt"
# A runtime override, honoured from a file so we never hardcode geometry:
#   /data/adb/tablet-spoof/target_dpi   -> force a specific tablet threshold dpi
OVERRIDE_DPI_FILE="$STATE_DIR/target_dpi"
# Optional verbose tracing:
#   /data/adb/tablet-spoof/debug
FLAG_DEBUG="$STATE_DIR/debug"

# ============================================================================
# logging
# ============================================================================
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 0755 "$STATE_DIR" 2>/dev/null

log() {
  _line="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) [$TAG] $*"
  echo "$_line"
  # Keep the log from growing without bound.
  if [ -f "$LOG" ]; then
    _sz=$(wc -c < "$LOG" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    if [ "$_sz" -gt 262144 ]; then
      tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    fi
  fi
  echo "$_line" >> "$LOG" 2>/dev/null
}

dbg() {
  [ -f "$FLAG_DEBUG" ] || return 0
  log "  . $*"
}

# ============================================================================
# scope guard  (R1)
# ============================================================================
# in_scope <pkg> -> 0 iff <pkg> is exactly one of SCOPE.
in_scope() {
  _p="$1"
  [ -n "$_p" ] || return 1
  for _s in $SCOPE; do
    [ "$_p" = "$_s" ] && return 0
  done
  return 1
}

# assert_scope <pkg> -> abort the caller unless <pkg> is exactly in scope.
# Every per-app function calls this first as a belt-and-braces check.
assert_scope() {
  if ! in_scope "$1"; then
    log "SCOPE GUARD: refusing to operate on '$1' (not whitelisted)"
    return 1
  fi
  return 0
}

# ============================================================================
# generic helpers
# ============================================================================

# Is the package installed?
pkg_installed() {
  [ -d "/data/data/$1" ] && return 0
  if command -v pm >/dev/null 2>&1; then
    pm path "$1" 2>/dev/null | grep -q '^package:' && return 0
  fi
  return 1
}

# Is the package currently running? We never touch a live app's files, because
# it may hold them open and flush its own cached copy back over us.
pkg_running() {
  _pid="$(pidof "$1" 2>/dev/null)"
  [ -n "$_pid" ]
}

# Force-stop a package. Returns 0 if it now looks stopped.
pkg_force_stop() {
  assert_scope "$1" || return 1
  log "force-stopping $1"
  am force-stop "$1" >/dev/null 2>&1
  am force-stop --user 0 "$1" >/dev/null 2>&1
  i=0
  while [ $i -lt 15 ]; do
    pkg_running "$1" || { log "  $1 stopped"; return 0; }
    sleep 1
    i=$((i + 1))
  done
  log "  WARN: $1 still running after 15s; will not modify its data"
  return 1
}

# ============================================================================
# device geometry  (R2) -- derived, never hardcoded
# ============================================================================
#
# THE REAL MECHANISM (recovered from bytecode by the Lead):
#
#   WeworkServiceImpl.getDeviceType():
#       qrMode = KV("KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE", false)
#       if (isAndroidBox())            return 327681;  // 0x50001
#       if (qrMode && isAndroidPad())  return 131076;  // 0x20004  <-- QR LOGIN
#       return 131073;                                 // 0x20001  phone
#
#   isAndroidPad() -> Leux.d().f() -> Leux.g()
#       = sqrt( (w/xdpi)^2 + (h/ydpi)^2 ) >= 8.0     // diagonal inches
#
# The tablet verdict is a PHYSICAL DIAGONAL LENGTH, not a dp bucket.
#
# ============================================================================
# HARD RULE -- NO GLOBAL DISPLAY MUTATION, EVER
# ============================================================================
# The user ran `wm size` / `wm density` during investigation and it distorted
# the screen so badly they could not read it ("我压根看不清屏幕了") and crashed
# the launcher. Those commands are GLOBAL: they affect every app on the device,
# which also violates this module's scope whitelist.
#
# They were also PROVEN USELESS for our purpose: `wm density 240` and
# `wm size 1600x2560` do NOT change xdpi/ydpi (403.411 / 404.326 stay constant),
# and xdpi/ydpi is exactly what WeCom reads.
#
# Therefore: this module contains ZERO invocations of the `wm` command, not even
# read-only ones. Physical metrics are read from SurfaceFlinger instead, which is
# authoritative for xdpi/ydpi and is what the display HAL actually reports.
# ============================================================================

# --- read-only physical screen metrics ---------------------------------------

# Panel width/height in pixels, from SurfaceFlinger's activeMode line:
#   activeMode={id=0, hwcId=0, resolution=1080x2340, vsyncRate=60.00 Hz,
#               dpi=403.41x404.33, group=0, ...}
# Echoes "<w> <h>" or empty. READ ONLY (parses dumpsys output; runs nothing).
device_real_size() {
  _sf="$(dumpsys SurfaceFlinger 2>/dev/null)"
  _wh="$(echo "$_sf" | sed -E -n \
    's/.*resolution=([0-9]+)x([0-9]+).*/\1 \2/p' | head -n1)"
  echo "$_wh"
}

# Physical panel dpi, as the app reads them (DisplayMetrics.xdpi / ydpi).
# Returns "<xdpi> <ydpi>" or empty. READ ONLY.
#
# Verified on device that these are immutable from userspace:
#   wm density 240      -> xDpi/ydpi unchanged (403.411 / 404.326)
#   wm size 1600x2560   -> xDpi/ydpi unchanged
#   no system property exists for them.
#
# PORTABILITY NOTE: Android 16's Toybox `sed` does NOT support the BRE GNU
# extension `\?`. Every pattern here uses `sed -E` (ERE), which Toybox does
# support. This matters: with `\?` all patterns silently returned empty on
# device, which is precisely the failure mode that would make the module report
# "unavailable" on some ROMs.
device_physical_dpi() {
  # (1) SurfaceFlinger activeMode: dpi=403.41x404.33
  _sf="$(dumpsys SurfaceFlinger 2>/dev/null)"
  _vals="$(echo "$_sf" | sed -E -n \
    's/.*dpi=([0-9]+(\.[0-9]+)?)x([0-9]+(\.[0-9]+)?).*/\1 \3/p' | head -n1)"

  # (2) SurfaceFlinger independent fields: "x-dpi : 403.41" / "y-dpi : 404.33"
  if [ -z "$_vals" ]; then
    _x="$(echo "$_sf" | sed -E -n 's/^[[:space:]]*x-dpi[[:space:]]*:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
    _y="$(echo "$_sf" | sed -E -n 's/^[[:space:]]*y-dpi[[:space:]]*:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
    [ -n "$_x" ] && [ -n "$_y" ] && _vals="$_x $_y"
  fi

  # (3) Fall back to dumpsys display (still read-only, no wm command):
  #     mViewports=[... densityDpi=440, xDpi=403.411, yDpi=404.326, ...]
  if [ -z "$_vals" ]; then
    _d="$(dumpsys display 2>/dev/null)"
    _vals="$(echo "$_d" | sed -E -n \
      's/.*xDpi=([0-9]+(\.[0-9]+)?).*yDpi=([0-9]+(\.[0-9]+)?).*/\1 \3/p' | head -n1)"
  fi

  echo "$_vals"
}

# Logical density, for diagnostics only (never written).
#
# NOTE: SurfaceFlinger's "DPI: 403.412x404.327" line is the PHYSICAL panel dpi,
# not the logical density -- reading it here would report 403 instead of the
# real 440 and silently mislead. The logical density lives in dumpsys display as
# "densityDpi=<n>".
device_density() {
  _d="$(dumpsys display 2>/dev/null | sed -E -n 's/.*densityDpi=([0-9]+).*/\1/p' | head -n1)"
  if [ -z "$_d" ]; then
    # Fallback: DisplayInfo "... density 440 (403.411 x 404.326) dpi ..."
    _d="$(dumpsys display 2>/dev/null | sed -E -n 's/.*density ([0-9]+) \([0-9].*\) dpi.*/\1/p' | head -n1)"
  fi
  case "$_d" in ''|*[!0-9]*) _d=0 ;; esac
  echo "$_d"
}

# --- the app's actual pad test, in integer math ------------------------------
# diagonal_inches_x10 <w> <h> <xdpi> <ydpi>
#   -> diagonal * 10, rounded, so we can compare against 80 (= 8.0 in) without
#      floating point (busybox ash has no floats).
#
# Implements: sqrt((w/xdpi)^2 + (h/ydpi)^2) * 10
# Using integers scaled by 1000 to preserve precision:
#   ax = w * 1000 / xdpi      (width in inches * 1000)
#   ay = h * 1000 / ydpi
#   diag_x1000 = isqrt(ax^2 + ay^2)
#   result = (diag_x1000 + 50) / 100      (inches * 10, rounded)
diagonal_inches_x10() {
  _w="$1"; _h="$2"; _xdpi="$3"; _ydpi="$4"
  case "$_w$_h" in *[!0-9]*) echo 0; return 0 ;; esac

  # Scale the dpi into integers (they may arrive as "403.411").
  _xi="$(echo "$_xdpi" | sed 's/\..*//')"
  _yi="$(echo "$_ydpi" | sed 's/\..*//')"
  case "$_xi" in ''|*[!0-9]*) _xi=0 ;; esac
  case "$_yi" in ''|*[!0-9]*) _yi=0 ;; esac
  [ "$_xi" -le 0 ] && _xi=$_yi
  [ "$_yi" -le 0 ] && _yi=$_xi
  [ "$_xi" -le 0 ] && { echo 0; return 0; }

  _ax=$(( _w * 1000 / _xi ))
  _ay=$(( _h * 1000 / _yi ))
  _sum=$(( _ax * _ax + _ay * _ay ))
  _diag="$(isqrt "$_sum")"
  echo $(( (_diag + 50) / 100 ))
}

# Integer square root (Newton's method), for shells without math libs.
isqrt() {
  _n="$1"
  case "$_n" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  [ "$_n" -le 0 ] && { echo 0; return 0; }
  _x="$_n"
  _y=$(( (_x + 1) / 2 ))
  while [ "$_y" -lt "$_x" ]; do
    _x="$_y"
    _y=$(( (_x + _n / _x) / 2 ))
  done
  echo "$_x"
}

# Smallest width in dp for the given real size + density. READ-ONLY DIAGNOSTIC
# only -- retained to show why a dp/density approach cannot work.
smallest_width_dp() {
  _w="$1"; _h="$2"; _d="$3"
  case "$_w$_h$_d" in *[!0-9]*) echo 0; return 0 ;; esac
  _min="$_w"; [ "$_h" -lt "$_min" ] && _min="$_h"
  echo $(( _min * 160 / _d ))
}

# Does the REAL hardware already meet the app's >= 8.0 inch pad test?
# Echoes "yes"/"no" plus the measured value, for diagnostics.
device_meets_pad_size() {
  _sz="$(device_real_size)"
  [ -n "$_sz" ] || { echo "unknown"; return 1; }
  set -- $_sz
  _dpi="$(device_physical_dpi)"
  [ -n "$_dpi" ] || { echo "unknown"; return 1; }
  set -- $_dpi "$1" "$2"
  _x="$1"; _y="$2"; _w="$3"; _h="$4"
  _d10="$(diagonal_inches_x10 "$_w" "$_h" "$_x" "$_y")"
  if [ "$_d10" -ge 80 ]; then
    echo "yes (${_d10}x0.1in >= 8.0in)"
  else
    echo "no (${_d10}x0.1in < 8.0in)"
  fi
}

# ============================================================================
# SURFACE LAYER -- the two real signals
# ============================================================================
# Both conditions in getDeviceType() must hold for QR login:
#
#   Surface A : KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE = true
#               -> MMKV: files/mmkv/com.tencent.pb.common
#   Surface B : isAndroidPad() == true
#               -> sqrt((w/xdpi)^2 + (h/ydpi)^2) >= 8.0
#
# Surface A is an MMKV write. That is a HIGH-RISK operation:
#   * MMKV keeps its own CRC32 of the used region and a .crc sidecar.
#   * A wrong CRC makes MMKV treat the file as corrupt and CLEAR the store,
#     which would wipe the user's WeCom config and log them out.
#   * I could not reproduce MMKV's exact CRC/region rules from a static read
#     (stored 3491ffd4 vs zlib 0b0950fd vs sidecar da b3 67 ca -- three
#     different values), and there is no NDK here to build a reference impl.
# Therefore Surface A is gated behind BOTH `enable-surfaces` AND a
# `verified-keys` file, and every write goes through the guarded write harness
# below (backup -> write -> readback verify -> auto-rollback).
#
# Surface B cannot be reached by any wm/property change (xdpi/ydpi are panel
# values, immutable from userspace and global if they could be changed), so the
# only viable implementation is in-process -- i.e. Surface B is expected to be
# carried by the separate hook component, NOT by this shell module. This module
# provides the read-only measurement and the whitelist scaffolding for it.
# ============================================================================

# --- MMKV path for a package -------------------------------------------------
mmkv_pb_common() {
  echo "/data/data/$1/files/mmkv/com.tencent.pb.common"
}
mmkv_pb_common_crc() {
  echo "/data/data/$1/files/mmkv/com.tencent.pb.common.crc"
}

# ============================================================================
# guarded write harness  (Lead requirement (c))
# ============================================================================
# Every app-storage write MUST go through guarded_write:
#   1. assert scope (exact package match)
#   2. refuse while the app is running (caller force-stops first)
#   3. back up the target file AND its .crc sibling, recording md5
#   4. apply the write
#   5. re-read and compare against expectation
#   6. on mismatch -> restore from backup immediately
#
# guarded_write <pkg> <abs_path> <expected_content_file>
#   The new content is read from a staging file so we never embed binary blobs
#   in shell literals.
guarded_write() {
  _pkg="$1"; _target="$2"; _src="$3"

  assert_scope "$_pkg" || return 1
  if ! in_scope "$_pkg"; then return 1; fi

  if pkg_running "$_pkg"; then
    log "  REFUSE write: $_pkg is running"
    return 1
  fi

  if [ ! -f "$_src" ]; then
    log "  REFUSE write: staging file $_src missing"
    return 1
  fi

  case "$_target" in
    *".."*) log "  REFUSE write: suspicious path $_target"; return 1 ;;
  esac
  case "$_target" in
    "/data/data/$_pkg/"*) : ;;
    *) log "  REFUSE write: $_target is outside /data/data/$_pkg/"; return 1 ;;
  esac

  # --- 3. backup target + .crc sibling ---------------------------------------
  _bk="$(backup_path "$_pkg" "$_target")"
  _bk_crc="$(backup_path "$_pkg" "$_target.crc")"

  _pre_md5="$(md5sum "$_target" 2>/dev/null | awk '{print $1}')"

  # --- 4. apply ---------------------------------------------------------------
  if ! cp -f "$_src" "$_target" 2>/dev/null; then
    log "  FAILED to write $_target"
    return 1
  fi
  # Keep ownership/permissions identical to the original.
  chown "$_pkg" "$_target" 2>/dev/null
  chmod 700 "$_target" 2>/dev/null
  log "  wrote $_target (was md5=$_pre_md5)"

  # --- 5. verify --------------------------------------------------------------
  _want_md5="$(md5sum "$_src" 2>/dev/null | awk '{print $1}')"
  _got_md5="$(md5sum "$_target" 2>/dev/null | awk '{print $1}')"
  if [ -n "$_want_md5" ] && [ "$_want_md5" = "$_got_md5" ]; then
    log "  verify OK (md5=$_got_md5)"
    return 0
  fi

  # --- 6. rollback ------------------------------------------------------------
  log "  VERIFY FAILED (want=$_want_md5 got=$_got_md5) -> rolling back"
  restore_path "$_pkg" "$_target" "$_bk"
  restore_path "$_pkg" "$_target.crc" "$_bk_crc"
  log "  rollback done"
  return 1
}

# Backup one file, returning the backup path. Idempotent: never overwrites an
# existing backup, so the ORIGINAL state is always what we can restore.
backup_path() {
  _pkg="$1"; _file="$2"
  [ -f "$_file" ] || { echo ""; return 0; }
  _dest="$BACKUP_DIR/$_pkg"
  mkdir -p "$_dest" 2>/dev/null
  _name="$(echo "$_file" | sed 's#^/data/data/'"$_pkg"'/##; s#/#__#g')"
  if [ ! -f "$_dest/$_name" ]; then
    if cp -f "$_file" "$_dest/$_name" 2>/dev/null; then
      md5sum "$_file" 2>/dev/null | awk '{print $1}' > "$_dest/$_name.md5" 2>/dev/null
      log "  backed up $_file -> $_dest/$_name"
    else
      log "  WARN: could not back up $_file"
      echo ""
      return 1
    fi
  fi
  echo "$_dest/$_name"
}

# Restore one file from a backup path.
restore_path() {
  _pkg="$1"; _target="$2"; _bk="$3"
  assert_scope "$_pkg" || return 1
  [ -n "$_bk" ] || return 0
  [ -f "$_bk" ] || return 0
  cp -f "$_bk" "$_target" 2>/dev/null \
    && log "  restored $_target" \
    || log "  FAILED to restore $_target"
  return 0
}

# --- Surface A: the MMKV QR-login switch -------------------------------------
surface_pad_login_kv() {
  _pkg="$1"; assert_scope "$_pkg" || return 1

  _kv="$STATE_DIR/verified-keys"
  if [ ! -f "$_kv" ]; then
    dbg "Surface A: no $STATE_DIR/verified-keys -> skipped (fail-closed)"
    return 0
  fi

  _file="$(mmkv_pb_common "$_pkg")"
  if [ ! -f "$_file" ]; then
    log "Surface A: $_file absent -> skipped"
    return 0
  fi

  # The staging blob must have been produced by a tool that reproduces MMKV's
  # CRC exactly (see the risk note above). We never synthesise it in shell.
  _staged="$STATE_DIR/staged/$_pkg/$(basename "$_file")"
  if [ ! -f "$_staged" ]; then
    log "Surface A: no verified staged blob at $_staged -> skipped"
    log "           (refusing to write unverified bytes into an MMKV store)"
    return 0
  fi

  log "Surface A: applying verified MMKV blob for $_pkg"
  guarded_write "$_pkg" "$_file" "$_staged" || return 1
  # The .crc sidecar must be replaced together with the data file.
  _staged_crc="$_staged.crc"
  if [ -f "$_staged_crc" ]; then
    guarded_write "$_pkg" "$_file.crc" "$_staged_crc" || return 1
  else
    log "Surface A: WARNING no staged .crc -> MMKV may reject the store"
  fi
  return 0
}

# --- Surface B: the >= 8.0 inch pad verdict ----------------------------------
# Reported, not written: the measurement is immutable from userspace. This
# surface exists so `status` can tell the user whether a hook is required.
surface_pad_size_report() {
  _pkg="$1"; assert_scope "$_pkg" || return 1
  log "Surface B: real-hardware pad test -> $(device_meets_pad_size)"
  log "            (xdpi/ydpi are panel values; not mutable via wm/props)"
  return 0
}

# --- rejected: global wm/density mutations -----------------------------------
# Kept as an explicit, auditable record that these were considered and refused.
surface_wm_global_REJECTED() {
  log "REJECTED: global display-size/density mutation is forbidden by policy"
  log "          It affects EVERY app (breaking the scope whitelist), it wrecked"
  log "          the user's screen during testing, and it cannot change xdpi/ydpi"
  log "          (which is the value WeCom actually reads) -- so it is useless too."
  log "          This module contains zero display-mutation calls."
  return 0
}

# ---- surface table (id:function) --------------------------------------------
surfaces() {
  echo "pad_login_kv:surface_pad_login_kv"
  echo "pad_size_report:surface_pad_size_report"
  echo "wm_global_rejected:surface_wm_global_REJECTED"
}

# Which surfaces are enabled? Empty/unset => none (fully inert install).
enabled_surfaces() {
  if [ -f "$STATE_DIR/enable-surfaces" ]; then
    cat "$STATE_DIR/enable-surfaces" 2>/dev/null
  fi
}

surface_enabled() {
  _want="$1"
  for _s in $(enabled_surfaces); do
    [ "$_s" = "$_want" ] && return 0
  done
  return 1
}

# ============================================================================
# restore everything
# ============================================================================
restore_all() {
  log "restore: reverting backed-up files"
  [ -d "$BACKUP_DIR" ] || { log "  no backups present"; return 0; }
  for _pkgdir in "$BACKUP_DIR"/*; do
    [ -d "$_pkgdir" ] || continue
    _pkg="$(basename "$_pkgdir")"
    assert_scope "$_pkg" || continue
    pkg_force_stop "$_pkg" || continue
    for _b in "$_pkgdir"/*; do
      # skip md5 sidecars
      case "$_b" in *.md5) continue ;; esac
      [ -f "$_b" ] || continue
      _rel="$(basename "$_b" | sed 's#__#/#g')"
      _dest="/data/data/$_pkg/$_rel"
      case "$_dest" in *".."*) log "  REFUSE $_dest"; continue ;; esac
      cp -f "$_b" "$_dest" 2>/dev/null \
        && log "  restored $_dest" \
        || log "  FAILED to restore $_dest"
    done
  done
  return 0
}

# ============================================================================
# main actions
# ============================================================================
do_status() {
  log "=== status ==="
  if [ -f "$FLAG_DISABLE" ]; then
    log "module: DISABLED (flag present: $FLAG_DISABLE)"
  else
    log "module: enabled"
  fi
  log "mode: READ-ONLY diagnostics (writes only if a surface is enabled AND verified)"
  log ""

  # --- whitelist / scope state -------------------------------------------------
  log "--- scope whitelist ---"
  log "SCOPE = $SCOPE  (exact string match; no prefix, no substring)"
  for _p in $SCOPE; do
    if pkg_installed "$_p"; then
      _run=no; pkg_running "$_p" && _run=yes
      log "  IN  $_p : installed=yes running=$_run"
    else
      log "  IN  $_p : installed=no"
    fi
  done
  log "  (any package not listed above is refused by in_scope/assert_scope)"
  log ""

  # --- geometry, read from SurfaceFlinger (no wm command is ever used) --------
  log "--- device geometry (read-only) ---"
  _sz="$(device_real_size)"
  _d="$(device_density)"
  if [ -n "$_sz" ]; then
    set -- $_sz
    log "  panel resolution : ${1}x${2}"
    log "  logical density  : ${_d} (reported only; NEVER written)"
    log "  smallestWidthDp  : $(smallest_width_dp "$1" "$2" "$_d") (diagnostic; density is not the mechanism)"
  else
    log "  panel resolution : unavailable"
  fi
  _dpi="$(device_physical_dpi)"
  log "  physical xdpi/ydpi: ${_dpi:-unavailable}"
  log "  pad-size test    : $(device_meets_pad_size)"
  log "    threshold is 8.0in (PAD_MIN_INCHES in the app companion)"
  log ""

  # --- app-side state: the two real signals -----------------------------------
  log "--- app-side signals (read-only) ---"
  for _p in $SCOPE; do
    [ "$_p" = "com.tencent.wework" ] || continue
    pkg_installed "$_p" || { log "  $_p not installed"; continue; }

    _model_f="/data/data/$_p/files/file_config_build_model"
    if [ -f "$_model_f" ]; then
      log "  build model file : [$(cat "$_model_f" 2>/dev/null)]"
    else
      log "  build model file : absent"
    fi

    _mmkv="$(mmkv_pb_common "$_p")"
    if [ -f "$_mmkv" ]; then
      _szc=$(wc -c < "$_mmkv" 2>/dev/null)
      log "  MMKV store       : present (${_szc} bytes)"
      log "                     $([ -f "$_mmkv.crc" ] && echo 'crc sidecar present' || echo 'NO crc sidecar')"
      # Report whether the two keys are materialised (identifier only, never a
      # value guess -- we cannot safely decode MMKV framing, see README).
      for _k in KV_ANDROID_PAD_LOGIN_TYPE_QR_CODE local_save_pad_type_android; do
        if grep -qa "$_k" "$_mmkv" 2>/dev/null; then
          log "    key present: $_k"
        else
          log "    key ABSENT : $_k"
        fi
      done
      log "    NOTE: values are intentionally NOT decoded or printed here."
      log "          Hand-authoring MMKV bytes is forbidden (CRC risk -> store"
      log "          reset -> user logout). Any write must be done by the app's"
      log "          own code, i.e. by the in-process companion."
    else
      log "  MMKV store       : absent"
    fi
  done
  log ""

  log "--- safety state ---"
  log "  kill switch      : $([ -f "$FLAG_DISABLE" ] && echo 'ENGAGED ('$FLAG_DISABLE')' || echo 'not engaged')"
  log "  enabled surfaces : [$(enabled_surfaces)]"
  log "  verified-keys    : $([ -f "$STATE_DIR/verified-keys" ] && echo present || echo absent)"
  log "  staged blobs     : $(ls "$STATE_DIR/staged" 2>/dev/null | wc -l) package dir(s)"
  log "  backups held     : $([ -d "$BACKUP_DIR" ] && ls "$BACKUP_DIR" 2>/dev/null | wc -l || echo 0) package dir(s)"
  log ""
  log "--- surfaces available ---"
  for _sf in $(surfaces); do
    _sid="${_sf%%:*}"
    log "  $_sid : $(surface_enabled "$_sid" && echo ENABLED || echo disabled)"
  done
  log ""
  log "--- the ACTUAL working mechanism (verified on-device) ---"
  log "  The tablet spoof is performed by the LSPosed companion APK, NOT by this"
  log "  shell module. WeCom's device-type gate lives inside its own process, so"
  log "  no root-side file/prop change can reach it."
  log ""
  log "  Proven flow:"
  log "    1. LSPosed module forces Application.isAndroidPad() -> true"
  log "       (com.tencent.wework.foundation.logic.Application)"
  log "    2. login page then shows 「平板和手机同时登录」"
  log "    3. tap it -> privacy dialog -> 同意"
  log "    4. navigates to LoginQrCodeForAndroidPad -> live QR code"
  log ""
  log "  LSPosed state:"
  _here="$(dirname "$0")"
  if [ -f "$_here/lsposed-enable.sh" ]; then
    sh "$_here/lsposed-enable.sh" status 2>/dev/null | sed 's/^/    /'
  else
    log "    lsposed-enable.sh not found next to this script"
  fi
  log ""
  log "  In-process hook status (must be 'ok' for the spoof to be ACTIVE):"
  _hered="$(dirname "$0")"
  if [ -f "$_hered/hook-status.sh" ]; then
    # Capture both output and exit code: rc=2 means HOOK_MISS, which is the
    # silent-miss alarm we must never bury in a long report.
    _hs_out="$(sh "$_hered/hook-status.sh" 2>&1)"
    _hs_rc=$?
    echo "$_hs_out" | sed 's/^/    /'
    if [ "$_hs_rc" = "2" ]; then
      log ""
      log "  *** ATTENTION: the hook did NOT install. The spoof is INACTIVE. ***"
    fi
  else
    log "    hook-status.sh not found next to this script"
  fi
  log "=============="
}

do_apply() {
  log "=== apply ==="

  # R6: the kill switch is checked first, before anything else.
  if [ -f "$FLAG_DISABLE" ]; then
    log "disabled flag present -> no action taken"
    return 0
  fi

  # If no surface is enabled there is NOTHING to do. Return before touching any
  # process, so the default install is provably inert (not even a force-stop).
  if [ -z "$(enabled_surfaces)" ]; then
    log "no surface enabled -> module inert, no app touched"
    return 0
  fi

  _did=0
  for _p in $SCOPE; do
    assert_scope "$_p" || continue          # R1
    if ! pkg_installed "$_p"; then
      log "$_p not installed -> skipped"
      continue
    fi

    # Determine whether this package has any enabled surface that needs a write.
    _needs_write=0
    for _sf in $(surfaces); do
      _sid="${_sf%%:*}"
      case "$_sid" in
        pad_login_kv) surface_enabled "$_sid" && _needs_write=1 ;;
      esac
    done

    if [ "$_needs_write" = 1 ]; then
      log "processing $_p (write surface enabled)"
      # A storage write requires the app stopped, otherwise it may flush its own
      # copy over ours. The caller opted into this by enabling the surface.
      if pkg_running "$_p"; then
        pkg_force_stop "$_p" || { log "  $_p still running -> skipping write"; continue; }
      fi
    else
      log "processing $_p (read-only surfaces only)"
    fi

    for _sf in $(surfaces); do
      _sid="${_sf%%:*}"
      _sfunc="${_sf#*:}"
      if surface_enabled "$_sid"; then
        "$_sfunc" "$_p"
        _did=1
      else
        dbg "surface $_sid not enabled"
      fi
    done
  done

  if [ "$_did" = 0 ]; then
    log "no surface ran -> module is inert"
  fi

  {
    echo "last_apply=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    echo "enabled_surfaces=$(enabled_surfaces)"
  } > "$STATE_FILE" 2>/dev/null

  log "=== apply done ==="
}

do_revert() {
  log "=== revert ==="
  restore_all
  rm -f "$STATE_FILE" 2>/dev/null
  log "=== revert done ==="
}

case "$1" in
  apply)   do_apply ;;
  revert|restore) do_revert ;;
  # `status` and `report` are the same READ-ONLY diagnostic. `report` is the
  # name the Lead asked for; `status` is kept as an alias.
  status|report) do_status ;;
  ""|*)
    echo "usage: $0 {status|report|apply|revert}"
    echo ""
    echo "  status|report  read-only diagnostics: scope, geometry, app-side"
    echo "                 signals, safety state. Writes nothing."
    echo "  apply          act on enabled surfaces (needs enable-surfaces;"
    echo "                 inert when unset, which is the default)."
    echo "  revert         restore anything backed up and clear state."
    exit 2
    ;;
esac
exit 0
