#!/system/bin/sh
# Verify the Termux toolchain can build an Android shared object, and look for
# any Zygisk API header already present on the device.
TC=/data/data/com.termux/files/usr
export PATH="$TC/bin:$PATH"
export LD_LIBRARY_PATH="$TC/lib:$TC/lib64"
W=/data/local/tmp/nativetest
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

echo "=== toolchain ==="
"$TC/bin/clang" --version 2>&1 | head -3
echo "  sysroot: $("$TC/bin/clang" -print-sysroot 2>/dev/null)"
echo "  target triple: $("$TC/bin/clang" -dumpmachine 2>/dev/null)"
echo ""

echo "=== minimal shared object build ==="
cat > t.c <<'EOF'
int add(int a, int b) { return a + b; }
EOF
"$TC/bin/clang" -shared -fPIC -O2 -o t.so t.c 2>&1 | head -20
if [ -f t.so ]; then
  echo "  built: $(stat -c %s t.so) bytes"
  head -c 20 t.so | od -An -tx1 | head -2 | sed 's/^/  /'
  echo "  (7f 45 4c 46 = ELF magic)"
else
  echo "  BUILD FAILED"
fi
echo ""

echo "=== C++ build (we need C++ for the Zygisk API) ==="
cat > t2.cpp <<'EOF'
#include <cstdint>
extern "C" int f(int x) { return x * 2; }
EOF
"$TC/bin/clang++" -shared -fPIC -O2 -std=c++17 -o t2.so t2.cpp 2>&1 | head -20
[ -f t2.so ] && echo "  built: $(stat -c %s t2.so) bytes" || echo "  BUILD FAILED"
echo ""

echo "=== is there a zygisk.hpp anywhere on the device? ==="
find / -name 'zygisk.hpp' 2>/dev/null | head -5
echo "  (searched /)"
echo ""

echo "=== any existing zygisk module .so to model against (vx-tablet installed?) ==="
ls -la /data/adb/modules/*/zygisk/ 2>/dev/null | head -20
echo ""

echo "=== what .so do installed zygisk modules ship? ==="
for m in /data/adb/modules/*/; do
  if [ -d "$m/zygisk" ]; then
    echo "  $(basename $m):"
    ls -la "$m/zygisk/" | tail -n +2 | sed 's/^/      /'
  fi
done
echo ""

echo "=== can we link against liblog/libc++ from Termux? ==="
echo 'int main(){return 0;}' > m.c
"$TC/bin/clang" -o m m.c 2>&1 | head -5 && echo "  executable link OK"
echo ""
cd /; rm -rf "$W"
echo done
