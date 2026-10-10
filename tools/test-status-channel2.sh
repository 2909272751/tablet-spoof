#!/system/bin/sh
# Rigorous version of the channel test: remove the file, write as an
# unprivileged uid, and verify the CONTENT is from that write (not left over).
TC=/data/data/com.termux/files/usr
W=/data/local/tmp/statustest2
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

cat > t.cpp <<'EOF'
#include <cstdio>
#include <ctime>
#include <sys/stat.h>
extern "C" int writeStatus(const char* msg) {
    FILE* f = fopen("/data/local/tmp/tablet-spoof-status", "a");
    if (!f) return -1;
    fprintf(f, "MARKER:%s\n", msg);
    fflush(f); fclose(f);
    chmod("/data/local/tmp/tablet-spoof-status", 0666);
    return 0;
}
EOF
"$TC/bin/clang++" -shared -fPIC -O2 -nostdlib++ -o t.so t.cpp 2>&1 | sed 's/^/  /'

cat > drv.c <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char** argv) {
    void* h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    int (*fn)(const char*) = (int(*)(const char*))dlsym(h, "writeStatus");
    if (!fn) { fprintf(stderr, "dlsym failed\n"); return 1; }
    int rc = fn(argv[2]);
    fprintf(stderr, "writeStatus rc=%d\n", rc);
    return rc == 0 ? 0 : 1;
}
EOF
"$TC/bin/clang" -O2 -o drv drv.c -ldl 2>&1 | sed 's/^/  /'
chmod 755 drv t.so "$W"

echo ""
echo "=== remove the file first, so content proves WHO wrote ==="
rm -f /data/local/tmp/tablet-spoof-status
echo "  exists before: $([ -f /data/local/tmp/tablet-spoof-status ] && echo yes || echo no)"
echo ""
echo "=== write as unprivileged uid (su shell) ==="
su shell -c "$W/drv $W/t.so UNPRIV" ; echo "  su shell rc=$?"
echo ""
echo "=== result ==="
if [ -f /data/local/tmp/tablet-spoof-status ]; then
  echo "  file contents:"
  cat /data/local/tmp/tablet-spoof-status | sed 's/^/    /'
  if grep -q 'MARKER:UNPRIV' /data/local/tmp/tablet-spoof-status; then
    echo "  RESULT: PASS -- unprivileged uid CAN append to /data/local/tmp"
  else
    echo "  RESULT: unexpected content"
  fi
else
  echo "  FILE ABSENT -> unprivileged uid CANNOT write"
  echo "  RESULT: FAIL -- need a different path"
fi
echo ""
echo "=== also verify append semantics (append, not truncate) ==="
su shell -c "$W/drv $W/t.so UNPRIV2" 2>/dev/null
cat /data/local/tmp/tablet-spoof-status 2>/dev/null | sed 's/^/    /'
LINES=$(wc -l < /data/local/tmp/tablet-spoof-status 2>/dev/null)
echo "  line count: ${LINES:-0} (2 => append works, 1 => truncating)"
cd /; rm -rf "$W"
