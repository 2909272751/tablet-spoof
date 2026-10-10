#!/system/bin/sh
# Extract ALL WeCom dex files (cheap on-device) so we can find where the target
# classes are actually DEFINED. Flattened names for corruption safety.
APK=$(pm path com.tencent.wework 2>/dev/null | head -n1 | sed 's/^package://')
WORK=/data/local/tmp/alldex
rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK" || exit 1
unzip -o -j "$APK" 'classes*.dex' >/dev/null 2>&1
chmod 644 *.dex 2>/dev/null
echo "extracted: $(ls *.dex 2>/dev/null | wc -l)"
du -sh . 2>/dev/null
ls -la | head -30
