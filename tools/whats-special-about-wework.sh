#!/system/bin/sh
# The mapping is identical and the process is ordinary, yet only WeCom/WeChat are
# silent. What is special about them?
#
# Leading candidate now: SELinux / uid-based filtering, or a denylist. Zygisk Next
# respects a DENYLIST (Magisk's denylist / APatch equivalent) -- processes on it
# are NOT injected. Our .so being mapped could still be the loader mapping it for
# other reasons, or the denylist check happening at a different stage.
log() { echo "[special] $*"; }

log "=== is there a denylist, and are our two apps on it? ==="
for f in /data/adb/magisk/denylist.txt /data/adb/denylist.txt \
         /data/adb/modules/*/denylist.txt /data/adb/zygisksu/*deny* ; do
  [ -e "$f" ] && { echo "  FOUND: $f"; sed 's/^/    /' "$f" | head -30; }
done
echo "  magisk --denylist ls:"
which magisk >/dev/null 2>&1 && magisk --denylist ls 2>&1 | head -20 | sed 's/^/    /' || echo "    (magisk binary absent)"
echo ""
echo "  APatch/zygisk deny config:"
find /data/adb -maxdepth 3 -iname '*deny*' 2>/dev/null | head -10 | sed 's/^/    /'
echo ""

log "=== SELinux context of the two silent apps vs a working third-party app ==="
for p in com.tencent.wework com.tencent.mm com.byyoung.setting; do
  d=/data/data/$p
  echo "  $p:"
  ls -Zd "$d" 2>/dev/null | sed 's/^/    /'
done
echo ""
log "  live process contexts:"
for p in com.tencent.wework com.byyoung.setting com.android.shell; do
  PID=$(pidof "$p" 2>/dev/null | head -1)
  [ -n "$PID" ] && echo "    $p (pid $PID): $(cat /proc/$PID/attr/current 2>/dev/null)"
done
echo ""

log "=== does WeCom have 'isolatedProcess' / unusual manifest flags? ==="
dumpsys package com.tencent.wework 2>/dev/null | grep -iE 'flags=|sharedUser|processName|isolated' | head -12 | sed 's/^/  /'
echo ""
log "=== requested permissions that might matter (privileged?) ==="
dumpsys package com.tencent.wework 2>/dev/null | grep -iE 'PRIVILEGED|INSTALL_PACKAGES|WRITE_SECURE|MANAGE_USERS' | head -6 | sed 's/^/  /'
echo ""

log "=== THE KEY TEST: is WeCom on Zygisk's internal denylist? ==="
echo "  Zygisk Next stores state in /data/adb/zygisksu/. Look for package names:"
for f in /data/adb/zygisksu/*; do
  [ -f "$f" ] || continue
  hits=$(strings "$f" 2>/dev/null | grep -c 'tencent' || echo 0)
  echo "    $(basename $f): tencent refs=$hits"
done
echo ""
strings /data/adb/zygisksu/znctx 2>/dev/null | head -20 | sed 's/^/    znctx: /'
strings /data/adb/zygisksu/.magic 2>/dev/null | head -5 | sed 's/^/    .magic: /'
echo ""

log "=== compare: which apps have our .so mapped vs which called back ==="
log "  (mapped-but-silent would indicate injection without callback)"
for p in com.tencent.wework com.byyoung.setting com.android.shell com.tencent.qqmusic; do
  PID=$(pidof "$p" 2>/dev/null | head -1)
  if [ -n "$PID" ]; then
    N=$(grep -c 'tablet-spoof-native' /proc/$PID/maps 2>/dev/null)
    IN_STATUS=$(grep -c "proc=$p" /sdcard/tablet-spoof-status.txt 2>/dev/null)
    printf '  %-28s pid=%-7s maps=%-3s in_status_file=%s\n' "$p" "$PID" "${N:-0}" "${IN_STATUS:-0}"
  else
    printf '  %-28s not-running\n' "$p"
  fi
done
