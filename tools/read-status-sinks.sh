#!/system/bin/sh
# Read the status signals from ALL sinks and report which fired.
# Run after a reboot + launching WeCom.
echo "=== uptime / lspd ==="
uptime | sed 's/^/  /'
echo "  lspd: $(pidof lspd 2>/dev/null || echo not-running)"
echo ""
echo "=== sink 1: app data dir (proven writable by app uid) ==="
F=/data/data/com.tencent.wework/files/ts_status.txt
if [ -f "$F" ]; then
  echo "  PRESENT: $F ($(stat -c '%s bytes, owner=%U' "$F"))"
  sed 's/^/    /' "$F"
else
  echo "  ABSENT: $F"
fi
echo ""
echo "=== sink 2: /data/local/tmp (writable by shell/system only) ==="
F2=/data/local/tmp/tablet-spoof-status
if [ -f "$F2" ]; then
  echo "  PRESENT: $F2 ($(stat -c '%s bytes' "$F2"))"
  echo "  --- lines mentioning our module path or wework ---"
  grep -iE 'wework|CTOR|onLoad' "$F2" 2>/dev/null | tail -20 | sed 's/^/    /'
  echo "  --- total lines: $(wc -l < "$F2") ---"
  echo "  --- distinct process names seen ---"
  grep -o 'proc=[^ ]*' "$F2" 2>/dev/null | sort -u | head -30 | sed 's/^/    /'
else
  echo "  ABSENT: $F2"
fi
echo ""
echo "=== sink 3: /sdcard ==="
F3=/sdcard/tablet-spoof-status.txt
[ -f "$F3" ] && { echo "  PRESENT: $F3"; wc -l < "$F3" | sed 's/^/    lines: /'; grep -i wework "$F3" | tail -5 | sed 's/^/    /'; } || echo "  ABSENT: $F3"
echo ""
echo "=== is our .so loaded in WeCom right now? ==="
PID=$(pidof com.tencent.wework)
echo "  wework pid: ${PID:-none}"
[ -n "$PID" ] && grep -c 'tablet-spoof-native' /proc/$PID/maps 2>/dev/null | sed 's/^/  maps: /'
echo ""
echo "=== trigger a fresh process and wait ==="
am force-stop com.tencent.wework
sleep 2
am start -W -n com.tencent.wework/.login.controller.LoginWxAuthActivity >/dev/null 2>&1
sleep 12
echo "  after launch, app-data sink contents:"
if [ -f "$F" ]; then
  sed 's/^/    /' "$F"
else
  echo "    still ABSENT"
fi
echo ""
echo "  maps now (fresh pid $(pidof com.tencent.wework)):"
PID2=$(pidof com.tencent.wework)
[ -n "$PID2" ] && grep -c 'tablet-spoof-native' /proc/$PID2/maps 2>/dev/null | sed 's/^/    /'
