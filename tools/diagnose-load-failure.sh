#!/system/bin/sh
# Why is lspd not loading our module? Look for load errors.
LOG=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -n1)
echo "=== verbose log: $LOG ==="
echo "--- lines mentioning our module id ---"
grep -i 'io.github.tabletspoof' "$LOG" 2>/dev/null | tail -30 | sed 's/^/  /'
echo ""
echo "--- error/warn lines ---"
grep -iE 'error|fail|exception|reject|invalid|skip' "$LOG" 2>/dev/null | tail -40 | sed 's/^/  /'
echo ""
echo "=== how many modules does lspd think it should load? ==="
grep -icE 'module' "$LOG" 2>/dev/null | sed 's/^/  module-ish lines: /'
echo ""
echo "=== apk_path in db vs reality ==="
DB=/data/adb/lspd/config/modules_config.db
P=$(/system/bin/sqlite3 "$DB" "SELECT apk_path FROM modules WHERE module_pkg_name='io.github.tabletspoof';" 2>/dev/null)
echo "  db says: $P"
if [ -f "$P" ]; then echo "  file exists: yes"; ls -la "$P" | sed 's/^/    /'; else echo "  file exists: NO <-- lspd cannot load a missing apk"; fi
echo ""
echo "=== compare: does lspd load ANY module into a process? (sanity) ==="
for m in io.github.qqliveclean io.github.weiboclean; do
  AP=$(/system/bin/sqlite3 "$DB" "SELECT apk_path FROM modules WHERE module_pkg_name='$m';" 2>/dev/null)
  EN=$(/system/bin/sqlite3 "$DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='$m' AND user_id=0;" 2>/dev/null)
  echo "  $m enabled=$EN path=${AP:-none} exists=$([ -f "$AP" ] && echo yes || echo no)"
done
echo ""
echo "=== is WeCom's target process actually the one being started? ==="
echo "  cmdline of pid $(pidof com.tencent.wework): $(cat /proc/$(pidof com.tencent.wework)/cmdline 2>/dev/null | tr '\0' ' ')"
echo "  (module targets the MAIN process; ':sub' processes are intentionally skipped)"
echo ""
echo "=== our module.prop as lspd sees it (from the installed apk) ==="
AP=$(/system/bin/sqlite3 "$DB" "SELECT apk_path FROM modules WHERE module_pkg_name='io.github.tabletspoof';" 2>/dev/null)
if [ -f "$AP" ]; then
  rm -rf /data/local/tmp/modprop; mkdir -p /data/local/tmp/modprop; cd /data/local/tmp/modprop
  unzip -o "$AP" 'META-INF/xposed/*' >/dev/null 2>&1
  for f in META-INF/xposed/*; do echo "  --- $f"; sed 's/^/      /' "$f"; done
  cd /
fi
