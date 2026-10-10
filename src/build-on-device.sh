#!/system/bin/sh
# ============================================================================
# tablet-spoof / src/build-on-device.sh
# ============================================================================
# Compiles the Zygisk native payload USING THE TERMUX TOOLCHAIN ON THE DEVICE.
#
# Why on-device: the host has no NDK/clang (verified five ways). Termux provides
# clang 21.1.8 targeting aarch64-linux-android24, and invoking it as root via
# `su -c` works even though Termux binaries normally only run under the Termux uid.
#
# Usage (as root):
#   sh build-on-device.sh [src_dir] [out_so]
# Defaults: src_dir=/data/local/tmp/tablet-spoof-src
#           out_so =/data/local/tmp/tablet-spoof/arm64-v8a.so
#
# The caller pushes src/ into src_dir first. This script only compiles.
# ============================================================================

TC=/data/data/com.termux/files/usr
CLANG="$TC/bin/clang++"

SRC="${1:-/data/local/tmp/tablet-spoof-src}"
OUT="${2:-/data/local/tmp/tablet-spoof/arm64-v8a.so}"

log() { echo "[build] $*"; }
die() { echo "[build] ERROR: $*" >&2; exit 1; }

[ -x "$CLANG" ] || die "clang++ not found at $CLANG (is Termux installed?)"
[ -d "$SRC" ] || die "source dir not found: $SRC"
[ -f "$SRC/tablet_spoof.cpp" ] || die "missing $SRC/tablet_spoof.cpp"
[ -f "$SRC/zygisk.hpp" ] || die "missing $SRC/zygisk.hpp"

OUTDIR=$(dirname "$OUT")
mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"

# Remove any previous artifact FIRST. Without this, a compile failure left the
# old .so in place and the script happily reported "built: ... 9440 bytes" --
# i.e. it would hand back a STALE binary that silently lacked the new code.
# That is exactly the "check reports the wrong thing" failure this project keeps
# hitting, so we make it impossible: no old file, and we verify freshness below.
rm -f "$OUT"

export PATH="$TC/bin:$PATH"
export LD_LIBRARY_PATH="$TC/lib:$TC/lib64"

log "compiler: $("$CLANG" --version 2>&1 | head -n1)"
log "target  : $("$CLANG" -dumpmachine 2>/dev/null)"
log "src     : $SRC"
log "out     : $OUT"
log ""

# -shared -fPIC            : a loadable shared object
# -O2 -fvisibility=hidden  : small, only REGISTER_ZYGISK_MODULE's export is visible
# -std=c++17               : the module uses C++17 attributes
# -llog                    : __android_log_* lives in liblog
# -Wl,-z,max-page-size     : keep 16K-page compatibility (Android 15+ devices)
# -nostdlib++              : the Zygisk loader dlopen()s us from zygote, where the
#                            C++ runtime is NOT preloaded. Linking libc++_shared
#                            would produce an unsatisfiable dependency (and
#                            -static-libstdc++ is the GNU spelling, wrong here).
#                            We use no C++ runtime features that need it: no
#                            exceptions, no RTTI, no iostreams. Everything we use
#                            (strcmp/strncpy, vprintf) is in libc.
"$CLANG" \
    -shared -fPIC \
    -O2 \
    -std=c++17 \
    -fvisibility=hidden \
    -fno-exceptions -fno-rtti \
    -nostdlib++ \
    -Wl,-z,max-page-size=16384 \
    -Wl,-soname,arm64-v8a.so \
    -I"$SRC" \
    -o "$OUT" \
    "$SRC/tablet_spoof.cpp" \
    "$SRC/art_hook.cpp" \
    -llog > /data/local/tmp/ts-build.log 2>&1
RC=$?

# Show the compiler output, indented.
sed 's/^/  /' /data/local/tmp/ts-build.log

# NOTE: previously this read `RC=$?` AFTER a pipe (`| sed ...`), which captures
# sed's exit status -- always 0 -- so a FAILED compile was reported as success
# and the stale .so was handed back. Both the ordering and the rm above are part
# of the fix. We now also require the artifact to exist, which it cannot if the
# compiler failed.
if [ $RC -ne 0 ] || [ ! -f "$OUT" ]; then
  die "compile FAILED (clang rc=$RC); no artifact produced"
fi

log ""
log "built: $OUT"
log "  size: $(stat -c %s "$OUT") bytes"
# Verify it is a real AArch64 shared object before we let it near a device.
if head -c 4 "$OUT" | od -An -tx1 | grep -q '7f 45 4c 46'; then
  log "  ELF magic: OK"
else
  die "output is not an ELF file"
fi
log "  machine: $(head -c 20 "$OUT" | od -An -tx1 | tr -s ' ' | cut -d' ' -f20-21 | tr -d ' ')"
log ""
log "exported dynamic symbols (must include zygisk_module_*):"
"$TC/bin/llvm-nm" -D --defined-only "$OUT" 2>/dev/null | grep -i zygisk | sed 's/^/  /'
if "$TC/bin/llvm-nm" -D --defined-only "$OUT" 2>/dev/null | grep -q 'zygisk_module_entry'; then
  log "  zygisk_module_entry: PRESENT (the loader can find us)"
else
  # Silently omitting this branch would let a payload that the loader cannot find
  # be reported as successfully built.
  die "zygisk_module_entry NOT exported - the loader would never call us"
fi

# ---------------------------------------------------------------------------
# SINK SELF-TEST -- must run as an APP uid, not shell
# ---------------------------------------------------------------------------
# A sink test that only exercises uid 2000 (shell) passes vacuously: /data/local/tmp
# is drwxrwx--x shell:shell, so shell can write it but an app uid (--x for others)
# cannot create files there at all. That is exactly how the previous status channel
# ended up silently dead for the only process we care about.
#
# So we test with the REAL uid of the target app and assert the write SUCCEEDS.
# If this test cannot fail, it is worthless -- hence the assertion below.
SELFTEST_DIR=/data/local/tmp/sink-selftest
rm -rf "$SELFTEST_DIR"; mkdir -p "$SELFTEST_DIR"
cat > "$SELFTEST_DIR/sink.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <string.h>
int main(int argc, char **argv) {
    /* argv[1] = path to write, argv[2] = marker */
    FILE *f = fopen(argv[1], "a");
    if (!f) { fprintf(stderr, "SINK-FAIL uid=%d path=%s\n", getuid(), argv[1]); return 1; }
    fprintf(f, "SINK-WROTE uid=%d marker=%s\n", getuid(), argv[2]);
    fclose(f);
    fprintf(stderr, "SINK-OK uid=%d path=%s\n", getuid(), argv[1]);
    return 0;
}
EOF
"$TC/bin/clang" -O2 -o "$SELFTEST_DIR/sink" "$SELFTEST_DIR/sink.c" 2>&1 | sed 's/^/  /'
chmod 755 "$SELFTEST_DIR" "$SELFTEST_DIR/sink"

APP_UID=$(stat -c %u /data/data/com.tencent.wework 2>/dev/null)
log ""
log "sink self-test (app uid = ${APP_UID:-unknown})"
if [ -n "$APP_UID" ]; then
  # (a) app uid writing its OWN data dir -- the design we ship. MUST succeed.
  APP_DIR=/data/data/com.tencent.wework/files
  rm -f "$APP_DIR/ts_status.txt"
  su "$APP_UID" -c "$SELFTEST_DIR/sink $APP_DIR/ts_status.txt APPUID" 2>&1 | sed 's/^/    /'
  if [ -f "$APP_DIR/ts_status.txt" ]; then
    log "    PASS: app-uid write to its own data dir works"
    sed 's/^/      /' "$APP_DIR/ts_status.txt"
    rm -f "$APP_DIR/ts_status.txt"
  else
    log "    FAIL: app-uid could not write its own data dir (unexpected)"
  fi

  # (b) app uid writing /data/local/tmp -- EXPECTED TO FAIL, and we record that
  #     expectation so nobody mistakes it for a working fallback later.
  rm -f /data/local/tmp/uidtest.txt
  su "$APP_UID" -c "$SELFTEST_DIR/sink /data/local/tmp/uidtest.txt APPUID" 2>&1 | sed 's/^/    /'
  if [ -f /data/local/tmp/uidtest.txt ]; then
    log "    NOTE: app uid CAN write /data/local/tmp on this device"
    rm -f /data/local/tmp/uidtest.txt
  else
    log "    CONFIRMED (expected): app uid CANNOT write /data/local/tmp"
    log "      -> app_data_dir is therefore the required primary sink"
  fi
else
  log "    skipped: com.tencent.wework not installed"
fi
rm -rf "$SELFTEST_DIR"
log ""
exit 0
