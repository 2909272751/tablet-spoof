#!/system/bin/sh
# Final acceptance check for the tablet-spoof module package.
# Unpacks the zip and validates structure + shell syntax. Read-only w.r.t. apps.
ZIP=/data/local/tmp/ts.zip
DIR=/data/local/tmp/tsx
FAIL=0

rm -rf "$DIR"; mkdir -p "$DIR"
cd "$DIR" || exit 1
unzip -o "$ZIP" >/dev/null 2>&1 || { echo "unzip FAILED"; exit 1; }

echo "=== 1. zip root entries (must be flat) ==="
ls -1

echo ""
echo "=== 2. required files present at root ==="
for f in module.prop customize.sh uninstall.sh service.sh post-fs-data.sh tablet-spoof.sh lsposed-enable.sh install-app.sh tablet-spoof.apk; do
  if [ -f "$f" ]; then
    echo "  OK    $f"
  else
    echo "  MISS  $f"
    FAIL=1
  fi
done

echo ""
echo "=== 2b. the bundled companion APK is valid and correctly scoped ==="
if [ -f tablet-spoof.apk ]; then
  if unzip -t tablet-spoof.apk >/dev/null 2>&1; then
    echo "  OK    apk zip integrity"
  else
    echo "  FAIL  apk zip corrupt"; FAIL=1
  fi
  for e in classes.dex META-INF/xposed/module.prop META-INF/xposed/scope.list META-INF/xposed/java_init.list; do
    if unzip -l tablet-spoof.apk 2>/dev/null | grep -q "$e"; then
      echo "  OK    apk contains $e"
    else
      echo "  FAIL  apk missing $e"; FAIL=1
    fi
  done

  # scope.list inside the embedded APK must be exactly the two allowed packages.
  SCOPE_APK=$(unzip -p tablet-spoof.apk META-INF/xposed/scope.list 2>/dev/null | tr -d '\r' | grep -c .)
  echo "  apk scope.list entries: $SCOPE_APK (expect 2)"
  [ "$SCOPE_APK" = "2" ] || FAIL=1
  if unzip -p tablet-spoof.apk META-INF/xposed/scope.list 2>/dev/null | grep -q 'com.tencent.mm' && \
     unzip -p tablet-spoof.apk META-INF/xposed/scope.list 2>/dev/null | grep -q 'com.tencent.wework'; then
    echo "  OK    apk scope has both allowed packages"
  else
    echo "  FAIL  apk scope missing a package"; FAIL=1
  fi

  # The dropped getDeviceType hook must NOT be present in the shipped dex.
  if unzip -p tablet-spoof.apk classes.dex 2>/dev/null | grep -qa 'getDeviceType'; then
    echo "  FAIL  getDeviceType still referenced in dex (hook should be dropped)"
    FAIL=1
  else
    echo "  OK    getDeviceType absent from dex (hook dropped as required)"
  fi

  if [ -f tablet-spoof.apk.version ]; then
    echo "  OK    apk version sidecar: $(cat tablet-spoof.apk.version)"
  else
    echo "  WARN  no apk version sidecar (installer will always reinstall)"
  fi
fi

echo ""
echo "=== 3. zip structure: no unexpected nesting ==="
# The only allowed subdirectory is `zygisk/` (the Zygisk module payload path is a
# fixed convention). Anything else nested means the zip layout is wrong.
SUB=$(find . -mindepth 1 -type d 2>/dev/null | grep -v '^\./zygisk$' | wc -l)
echo "  unexpected subdirectories: $SUB (expected 0)"
[ "$SUB" = "0" ] || { echo "  (found:)"; find . -mindepth 1 -type d | sed 's/^/    /'; FAIL=1; }
if [ -d ./zygisk ]; then
  echo "  zygisk/ present (required Zygisk payload path)"
  ls -1 ./zygisk | sed 's/^/    /'
  if [ -f ./zygisk/arm64-v8a.so ]; then
    echo "  OK    zygisk/arm64-v8a.so ($(stat -c %s ./zygisk/arm64-v8a.so) bytes)"
    head -c 4 ./zygisk/arm64-v8a.so | od -An -tx1 | grep -q '7f 45 4c 46' \
      && echo "  OK    native payload is ELF" || { echo "  FAIL  not ELF"; FAIL=1; }
  else
    echo "  FAIL  zygisk/arm64-v8a.so MISSING"; FAIL=1
  fi
else
  echo "  NOTE  no zygisk/ dir (native payload optional)"
fi

echo ""
echo "=== 4. line endings (must be LF only, no CR) ==="
for f in *.sh *.prop; do
  CR=$(od -c "$f" 2>/dev/null | grep -c '\\r')
  if [ "$CR" = "0" ]; then
    echo "  OK    $f (no CR)"
  else
    echo "  FAIL  $f contains CR"
    FAIL=1
  fi
done

echo ""
echo "=== 5. no UTF-8 BOM ==="
for f in *.sh *.prop; do
  FIRST=$(od -An -tx1 -N3 "$f" 2>/dev/null | tr -d ' ')
  if [ "$FIRST" = "efbbbf" ]; then
    echo "  FAIL  $f has BOM"
    FAIL=1
  else
    echo "  OK    $f (no BOM)"
  fi
done

echo ""
echo "=== 6. shell syntax (sh -n) ==="
for f in *.sh; do
  if sh -n "$f" 2>/tmp/e; then
    echo "  OK    $f"
  else
    echo "  FAIL  $f"
    sed 's/^/          /' /tmp/e
    FAIL=1
  fi
done

echo ""
echo "=== 7. scope whitelist literal check ==="
SCOPE=$(grep -m1 '^SCOPE=' tablet-spoof.sh)
echo "  $SCOPE"
case "$SCOPE" in
  *com.tencent.mm*com.tencent.wework*|*com.tencent.wework*com.tencent.mm*) echo "  OK    both packages present" ;;
  *) echo "  FAIL  scope line unexpected"; FAIL=1 ;;
esac

echo ""
echo "=== 8. forbidden constructs (density / global size writes) ==="
# Strip comment lines FIRST so documentation that *describes* a rejected
# technique (`wm density 240` cited as proof it does not work) is not counted
# as a use of that technique.
CODE=$(grep -v '^[[:space:]]*#' tablet-spoof.sh)
for pat in 'wm density' 'ro.sf.lcd_density' 'wm size'; do
  HITS=$(echo "$CODE" | grep -cE "$pat[[:space:]]+([0-9]+x[0-9]+|[0-9]+|reset)([[:space:]]|$)")
  echo "  '$pat' write-shaped uses -> $HITS"
done
echo "  NOTE: any wm size/density WRITE would be a violation; all must be 0."
echo "  device_density/device_real_size only READ wm output."
echo ""
echo "=== 8b. explicit proof: density is read-only in the engine ==="
# A real write looks like `wm size 1080x2340` / `wm density 320` / `wm size reset`,
# i.e. an argument that is NOT a shell redirection (`2>/dev/null`) and NOT empty.
WRITES=$(echo "$CODE" | grep -cE 'wm[[:space:]]+(size|density)[[:space:]]+([0-9]+x[0-9]+|[0-9]+|reset)([[:space:]]|$)')
echo "  wm size/density WRITE statements: $WRITES (expected 0)"
[ "$WRITES" = "0" ] || FAIL=1

SETPROP=$(grep -nE 'setprop[[:space:]]+ro\.sf\.lcd_density' tablet-spoof.sh | wc -l)
echo "  setprop ro.sf.lcd_density writes: $SETPROP (expected 0)"
[ "$SETPROP" = "0" ] || FAIL=1

# Prove the only wm usages are reads (captured into a variable).
echo "  every 'wm size'/'wm density' usage in the engine:"
grep -nE 'wm[[:space:]]+(size|density)' tablet-spoof.sh | sed 's/^/    /'

echo ""
echo "=== 8c. no hardcoded device geometry ==="
LITS=$(grep -nE '(1080|2340|440|443|403\.411)' tablet-spoof.sh \
       | grep -v '^[0-9]*:[[:space:]]*#' | wc -l)
echo "  hardcoded MI9-style numbers in active code: $LITS (expected 0)"
[ "$LITS" = "0" ] || FAIL=1

echo ""
echo "=== 9. native payload: present and correctly placed (now EXPECTED) ==="
# This check previously asserted 0 .so files, from when the module was shell-only.
# The native Zygisk payload is now a deliberate part of the package, so the
# assertion is inverted: there must be exactly one, at the Zygisk convention path
# zygisk/<abi>.so. A stale check that asserts the opposite of the intended design
# would fail a correct package -- which is what it just did.
SO_COUNT=$(find . -name '*.so' | wc -l)
echo "  .so files: $SO_COUNT (expected 1)"
[ "$SO_COUNT" = "1" ] || FAIL=1
if [ -f ./zygisk/arm64-v8a.so ]; then
  echo "  OK    correctly at zygisk/arm64-v8a.so"
  # The loader looks up zygisk_module_entry; a payload without it would never be called.
  if strings ./zygisk/arm64-v8a.so 2>/dev/null | grep -q 'zygisk_module_entry'; then
    echo "  OK    exports zygisk_module_entry (loader can find it)"
  else
    echo "  FAIL  zygisk_module_entry absent - loader would never call it"; FAIL=1
  fi
  # -nostdlib++ is required: libc++_shared cannot be resolved from zygote.
  if strings ./zygisk/arm64-v8a.so 2>/dev/null | grep -q 'libc++_shared'; then
    echo "  FAIL  links libc++_shared - will not load from zygote"; FAIL=1
  else
    echo "  OK    no libc++_shared dependency (loads from zygote)"
  fi
else
  echo "  FAIL  native payload missing"; FAIL=1
fi

echo ""
echo "=============================================="
if [ "$FAIL" = 0 ]; then echo " ACCEPTANCE: PASS"; else echo " ACCEPTANCE: FAIL"; fi
echo "=============================================="
exit $FAIL
