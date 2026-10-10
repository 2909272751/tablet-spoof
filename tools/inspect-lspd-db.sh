#!/system/bin/sh
# Inspect the LSPosed modules_config.db schema and current rows.
DB=/data/adb/lspd/config/modules_config.db
S=/system/bin/sqlite3

echo "=== schema ==="
"$S" "$DB" ".schema" 2>&1
echo ""
echo "=== tables ==="
"$S" "$DB" ".tables" 2>&1
echo ""
echo "=== modules (all rows) ==="
"$S" -header -column "$DB" "SELECT * FROM modules;" 2>&1 | head -30
echo ""
echo "=== modules columns ==="
"$S" "$DB" "PRAGMA table_info(modules);" 2>&1
echo ""
echo "=== scope columns ==="
"$S" "$DB" "PRAGMA table_info(scope);" 2>&1
echo ""
echo "=== our module row? ==="
"$S" "$DB" "SELECT * FROM modules WHERE module_pkg_name='io.github.tabletspoof';" 2>&1
echo ""
echo "=== our scope rows? ==="
"$S" "$DB" "SELECT * FROM scope WHERE module_pkg_name='io.github.tabletspoof';" 2>&1
echo ""
echo "=== scope rows for a known module (LSPosed itself) ==="
"$S" -header -column "$DB" "SELECT * FROM scope LIMIT 12;" 2>&1
