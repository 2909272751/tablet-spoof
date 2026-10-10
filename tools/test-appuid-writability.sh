#!/system/bin/sh
# Decide between the two competing readings:
#   (A) postAppSpecialize fires everywhere, but only writable uids can record it
#   (B) postAppSpecialize genuinely does not fire for third-party apps
#
# We test the WRITABILITY half directly: can an app-like uid write to each of the
# candidate status paths? If an app uid cannot write /data/local/tmp either, then
# (A) fully explains the missing WeCom lines and (B) is unproven.
echo "=== uid model ==="
echo "  wework uid: $(stat -c %u /data/data/com.tencent.wework 2>/dev/null)  ($(stat -c %U /data/data/com.tencent.wework 2>/dev/null))"
echo "  shell  uid: $(id -u shell 2>/dev/null)"
echo "  root   uid: $(id -u)"
echo ""
echo "=== candidate paths and their write bits ==="
for d in /data/local/tmp /sdcard /data/adb/tablet-spoof; do
  ls -ld "$d" 2>/dev/null | sed 's/^/  /'
done
echo ""
echo "=== DIRECT test: write as WeCom's uid ==="
# `su <uid>` selects a uid; try the app's numeric uid.
WU=$(stat -c %u /data/data/com.tencent.wework 2>/dev/null)
echo "  attempting as uid $WU"
for target in /data/local/tmp/appuid-test.txt /sdcard/appuid-test.txt /data/data/com.tencent.wework/files/appuid-test.txt; do
  rm -f "$target" 2>/dev/null
  su "$WU" -c "echo hi > $target" 2>/dev/null
  if [ -f "$target" ]; then
    echo "    WRITABLE  : $target"
    rm -f "$target"
  else
    echo "    NOT WRITABLE: $target"
  fi
done
echo ""
echo "=== same test as SHELL uid (for contrast) ==="
for target in /data/local/tmp/shell-test.txt /sdcard/shell-test.txt; do
  rm -f "$target" 2>/dev/null
  su shell -c "echo hi > $target" 2>/dev/null
  if [ -f "$target" ]; then
    echo "    WRITABLE  : $target"
    rm -f "$target"
  else
    echo "    NOT WRITABLE: $target"
  fi
done
echo ""
echo "=== what does Zygisk give us for app_data_dir? (from a live app) ==="
echo "  WeCom data dir: /data/data/com.tencent.wework  (app_data_dir should equal this)"
ls -ld /data/data/com.tencent.wework/files 2>/dev/null | sed 's/^/  files/: /'
echo ""
echo "=== SELinux context of the app data dir (can the app write its own files?) ==="
ls -Zd /data/data/com.tencent.wework/files 2>/dev/null | sed 's/^/  /'
