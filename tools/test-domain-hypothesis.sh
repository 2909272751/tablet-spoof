#!/system/bin/sh
# Hypothesis: SELinux domain level (untrusted_app_NN) correlates with whether the
# Zygisk callback fires. Our two silent targets are targetSdk 31 and 34 ->
# untrusted_app_30 / untrusted_app. The one app we PROVED works (byyoung) is
# targetSdk 28 -> untrusted_app_27.
#
# Test: enumerate installed third-party apps with targetSdk >= 30, launch a few,
# and see whether ANY of them produce a status record. If none do, the correlation
# is strong; if some do, the hypothesis is dead.
log() { echo "[domaintest] $*"; }

log "=== clear sinks ==="
rm -f /sdcard/tablet-spoof-status.txt /data/local/tmp/tablet-spoof-status
log "  cleared"
echo ""

log "=== find third-party apps with targetSdk >= 30 ==="
CAND=""
for p in $(pm list packages -3 2>/dev/null | sed 's/package://' | head -80); do
  TS=$(dumpsys package "$p" 2>/dev/null | sed -n 's/.*targetSdk=\([0-9]*\).*/\1/p' | head -1)
  case "$TS" in ''|*[!0-9]*) continue ;; esac
  if [ "$TS" -ge 30 ]; then
    CAND="$CAND $p:$TS"
  fi
done
log "  candidates:$CAND"
echo ""

log "=== launch up to 6 of them and see if the callback fires ==="
N=0
for entry in $CAND; do
  [ "$N" -ge 6 ] && break
  p="${entry%%:*}"
  ts="${entry##*:}"
  # skip our targets so we test OTHER apps
  case "$p" in com.tencent.mm|com.tencent.wework) continue ;; esac

  am force-stop "$p" 2>/dev/null
  sleep 1
  monkey -p "$p" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 4
  HIT=$(grep -c "proc=$p" /sdcard/tablet-spoof-status.txt 2>/dev/null)
  CTX=$(cat /proc/$(pidof "$p" 2>/dev/null | head -1)/attr/current 2>/dev/null | tr -d '\0')
  printf '  targetSdk=%-3s %-42s fired=%-3s %s\n' "$ts" "$p" "${HIT:-0}" "$CTX"
  N=$((N+1))
done
echo ""

log "=== control: the app we know works (targetSdk 28) ==="
rm -f /sdcard/tablet-spoof-status.txt
am force-stop com.byyoung.setting 2>/dev/null
sleep 1
monkey -p com.byyoung.setting -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 5
printf '  targetSdk=28  com.byyoung.setting  fired=%s  %s\n' \
  "$(grep -c 'proc=com.byyoung' /sdcard/tablet-spoof-status.txt 2>/dev/null)" \
  "$(cat /proc/$(pidof com.byyoung.setting 2>/dev/null | head -1)/attr/current 2>/dev/null | tr -d '\0')"
echo ""

log "=== verdict ==="
log "  If ALL targetSdk>=30 apps are silent while the targetSdk=28 control fires,"
log "  the correlation is with the SELinux domain level, not with our module."
