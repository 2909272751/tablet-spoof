#!/system/bin/sh
# Extract only the WeCom dex files that contain our hook targets, for local audit.
APK=$(pm path com.tencent.wework 2>/dev/null | head -n1 | sed 's/^package://')
echo "apk: $APK"
WORK=/data/local/tmp/auditdex
rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK" || exit 1
# Extract all dex, then keep only those mentioning the target classes.
unzip -o "$APK" 'classes*.dex' >/dev/null 2>&1
echo "extracted: $(ls classes*.dex 2>/dev/null | wc -l) dex"
KEEP=""
for d in classes*.dex; do
  if grep -qa 'foundation/logic/Application;' "$d" 2>/dev/null || \
     grep -qa 'foundation/impl/WeworkServiceImpl;' "$d" 2>/dev/null; then
    KEEP="$KEEP $d"
  fi
done
echo "keeping:$KEEP"
for d in $KEEP; do chmod 644 "$d"; done
# Remove the rest to keep the pull small.
for d in classes*.dex; do
  case " $KEEP " in
    *" $d "*) ;;
    *) rm -f "$d" ;;
  esac
done
ls -la
echo "done"
