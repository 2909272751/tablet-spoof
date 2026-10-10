#!/system/bin/sh
# Compare our module metadata against a KNOWN-WORKING module (qqliveclean)
# to find what makes lspd load one and not the other.
DB=/data/adb/lspd/config/modules_config.db
S=/system/bin/sqlite3

echo "=== installed apk paths (db vs pm) ==="
echo "  db  : $($S "$DB" "SELECT apk_path FROM modules WHERE module_pkg_name='io.github.tabletspoof';" 2>/dev/null)"
echo "  pm  : $(pm path io.github.tabletspoof 2>/dev/null)"
echo ""

echo "=== extract and compare META-INF/xposed/* for BOTH modules ==="
for M in io.github.tabletspoof io.github.qqliveclean; do
  AP=$($S "$DB" "SELECT apk_path FROM modules WHERE module_pkg_name='$M';" 2>/dev/null)
  echo "--- $M"
  echo "    db apk_path: $AP"
  echo "    exists     : $([ -f "$AP" ] && echo yes || echo NO)"
  if [ -f "$AP" ]; then
    W=/data/local/tmp/cmp-$M
    rm -rf "$W"; mkdir -p "$W"; cd "$W" || continue
    unzip -o "$AP" 'META-INF/xposed/*' >/dev/null 2>&1
    for f in module.prop scope.list java_init.list; do
      if [ -f "META-INF/xposed/$f" ]; then
        echo "    [$f]"
        sed 's/^/        /' "META-INF/xposed/$f"
      else
        echo "    [$f] MISSING"
      fi
    done
    echo "    classes.dex present: $(unzip -l "$AP" 2>/dev/null | grep -c 'classes.dex')"
    cd /
  fi
  echo ""
done

echo "=== does the dex declare the entry class named in java_init.list? ==="
AP=$(pm path io.github.tabletspoof 2>/dev/null | head -n1 | sed 's/^package://')
W=/data/local/tmp/entrychk
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
unzip -o "$AP" classes.dex >/dev/null 2>&1
ENTRY=$(unzip -p "$AP" META-INF/xposed/java_init.list 2>/dev/null | tr -d '\r' | head -n1)
echo "  java_init.list entry: $ENTRY"
SLASHED=$(echo "$ENTRY" | tr '.' '/')
echo "  as dex descriptor   : L$SLASHED;"
if grep -qa "L$SLASHED;" classes.dex; then echo "  -> entry class PRESENT in dex"; else echo "  -> entry class MISSING from dex  <-- lspd would fail to load"; fi
echo ""
echo "=== does it extend XposedModule? (superclass reference in dex) ==="
grep -qa 'io/github/libxposed/api/XposedModule' classes.dex && echo "  XposedModule referenced: yes" || echo "  XposedModule referenced: NO"
echo ""
cd /; rm -rf "$W"
