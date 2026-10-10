#!/system/bin/sh
# Verify the status-file CHANNEL works from an app-like uid, before spending a
# reboot on it. We compile a tiny .so that only writes the status file, load it
# into a test process running as an unprivileged uid, and check the file appears.
#
# Rationale: the LSPosed status channel failed because /data/adb is 0700 root.
# I am not going to assume /data/local/tmp is writable from an app uid -- I will
# prove it, because "the status channel is silently dead" is exactly the bug we
# already shipped once.
TC=/data/data/com.termux/files/usr
W=/data/local/tmp/statustest
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

cat > t.cpp <<'EOF'
#include <cstdio>
#include <ctime>
#include <sys/stat.h>
extern "C" int writeStatus(const char* msg) {
    FILE* f = fopen("/data/local/tmp/tablet-spoof-status", "a");
    if (!f) return -1;
    fprintf(f, "%lld %s\n", (long long)time(nullptr), msg);
    fflush(f); fclose(f);
    chmod("/data/local/tmp/tablet-spoof-status", 0666);
    return 0;
}
EOF

"$TC/bin/clang++" -shared -fPIC -O2 -nostdlib++ -o t.so t.cpp 2>&1 | sed 's/^/  /'
ls -la t.so 2>/dev/null | sed 's/^/  /'

echo ""
echo "=== test 1: write as ROOT ==="
rm -f /data/local/tmp/tablet-spoof-status
cat > drv.c <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char** argv) {
    void* h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
    int (*fn)(const char*) = (int(*)(const char*))dlsym(h, "writeStatus");
    if (!fn) { fprintf(stderr, "dlsym failed\n"); return 1; }
    return fn("wrote-as-root") == 0 ? 0 : 1;
}
EOF
"$TC/bin/clang" -O2 -o drv drv.c -ldl 2>&1 | sed 's/^/  /'
./drv "$W/t.so" && echo "  driver rc=0" || echo "  driver FAILED"
echo "  file now:"; cat /data/local/tmp/tablet-spoof-status 2>/dev/null | sed 's/^/    /'

echo ""
echo "=== test 2: write as an UNPRIVILEGED uid (simulates the app process) ==="
# nsenter isn't reliable here; use `su` to drop to the shell uid, which is
# equally unprivileged w.r.t. /data/adb and representative for /data/local/tmp.
rm -f /data/local/tmp/tablet-spoof-status
chmod 755 "$W"; chmod 755 "$W/drv"; chmod 644 "$W/t.so"
su shell -c "$W/drv $W/t.so" 2>&1 | sed 's/^/  /'
echo "  file now:"
if [ -f /data/local/tmp/tablet-spoof-status ]; then
  cat /data/local/tmp/tablet-spoof-status | sed 's/^/    /'
  echo "  RESULT: /data/local/tmp IS writable from an unprivileged uid"
else
  echo "    (absent)"
  echo "  RESULT: NOT writable -- choose another path"
fi

echo ""
echo "=== permissions of the target dir ==="
ls -ld /data/local/tmp | sed 's/^/  /'
cd /; rm -rf "$W"
