#!/system/bin/sh
# Is WeCom/WeChat excluded by a denylist (APatch/zygisk-next), or by SELinux
# domain level? A denylist entry would explain EXACTLY what we see:
# the .so mapped but never dlopen()ed (no constructor fired).

log() { echo "[deny] $*"; }

log "=== APatch config ==="
for f in /data/adb/ap/package_config /data/adb/ap/config /data/adb/ap/*.txt; do
  [ -f "$f" ] && { echo "  --- $f"; sed 's/^/    /' "$f" | head -40; }
done
echo ""
log "=== APatch dir contents ==="
ls -la /data/adb/ap/ 2>/dev/null | sed 's/^/  /'
ls -la /data/adb/ap/log/ 2>/dev/null | sed 's/^/  /'
echo ""

log "=== hunt for any denylist / exclude list mentioning our packages ==="
for f in $(find /data/adb -maxdepth 4 -type f \( -name '*deny*' -o -name '*exclude*' -o -name '*config*' -o -name '*list*' \) 2>/dev/null | head -40); do
  if grep -qa 'tencent' "$f" 2>/dev/null; then
    echo "  *** HIT: $f"
    grep -a 'tencent' "$f" | head -10 | sed 's/^/      /'
  fi
done
echo "  (scan complete)"
echo ""

log "=== does APatch expose a denylist via its CLI? ==="
for c in /data/adb/ap/bin/kptools /data/adb/apd /data/adb/ap/bin/busybox; do
  [ -x "$c" ] && echo "  present: $c"
done
/data/adb/ap/bin/kptools --help 2>&1 | head -20 | sed 's/^/    /'
echo ""

log "=== SELINUX DOMAIN comparison: who fires vs who doesn't ==="
log "  processes that DID fire (from current /sdcard status):"
FIRED=$(grep -o 'proc=[^ ]*' /sdcard/tablet-spoof-status.txt 2>/dev/null | sed 's/proc=//' | sort -u)
for p in $FIRED; do
  PID=$(pidof "$p" 2>/dev/null | head -1)
  if [ -n "$PID" ]; then
    ctx=$(cat /proc/$PID/attr/current 2>/dev/null | tr -d '\0')
    printf '    %-40s %s\n' "$p" "$ctx"
  fi
done
echo ""
log "  processes that did NOT fire (silent, but mapped):"
for p in com.tencent.wework com.tencent.mm; do
  PID=$(pidof "$p" 2>/dev/null | head -1)
  if [ -n "$PID" ]; then
    ctx=$(cat /proc/$PID/attr/current 2>/dev/null | tr -d '\0')
    printf '    %-40s %s\n' "$p" "$ctx"
  else
    printf '    %-40s (not running)\n' "$p"
  fi
done
echo ""

log "=== the domain-level question: untrusted_app_NN distribution ==="
log "  our two targets are untrusted_app_30 (targetSdk 30+). Others?"
for p in com.byyoung.setting com.stevesoltys.seedvault com.tencent.qqmusic; do
  PID=$(pidof "$p" 2>/dev/null | head -1)
  [ -n "$PID" ] && printf '    %-36s %s\n' "$p" "$(cat /proc/$PID/attr/current 2>/dev/null | tr -d '\0')"
done
echo ""
log "=== targetSdk of our targets vs a working app ==="
for p in com.tencent.wework com.tencent.mm com.byyoung.setting; do
  ts=$(dumpsys package "$p" 2>/dev/null | grep -m1 targetSdk | tr -d ' ')
  printf '  %-28s %s\n' "$p" "$ts"
done
