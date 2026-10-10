#!/system/bin/sh
# Locate LSPosed's module config so a module can be enabled without hand-editing SQL.
echo "=== /data/adb/lspd ==="
ls -la /data/adb/lspd/ 2>/dev/null
echo ""
echo "=== find modules_config.db ==="
find /data/adb -maxdepth 4 -name 'modules_config.db' 2>/dev/null
echo ""
echo "=== lspd config dir ==="
ls -la /data/adb/lspd/config 2>/dev/null
echo ""
echo "=== lspd root subdirs ==="
for d in /data/adb/lspd/*/; do echo "  $d"; ls -la "$d" 2>/dev/null | head -8; done
echo ""
echo "=== is sqlite3 available? ==="
command -v sqlite3 && sqlite3 --version || echo "  sqlite3 NOT on PATH"
ls -la /data/adb/ap/bin/busybox 2>/dev/null | head -2
/data/adb/ap/bin/busybox sqlite3 --help 2>&1 | head -3
echo ""
echo "=== lspd process ==="
pidof lspd
echo ""
echo "=== module dir for lsposed ==="
ls -la /data/adb/modules/zygisk_lsposed/ 2>/dev/null | head -12
