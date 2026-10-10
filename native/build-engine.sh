#!/system/bin/sh
set -eu
TC=/data/data/com.termux/files/usr
export PATH="$TC/bin:$PATH"
export LD_LIBRARY_PATH="$TC/lib"
cd /data/local/tmp/ts-native-src
mkdir -p output/zygisk output/lib
"$TC/bin/clang++" -shared -fPIC -O2 -std=c++23 -fvisibility=hidden -I. \
  -Wl,-z,max-page-size=16384 -Wl,-soname,libtablet-spoof-engine.so -Wl,-z,defs \
  module.cpp obj-flat/liblsplant.a third_party/libdobby.a -llog /system/lib64/libz.so -ldl \
  -o output/lib/libtablet-spoof-engine.so
"$TC/bin/clang++" -shared -fPIC -O2 -std=c++17 -fno-exceptions -fno-rtti -fno-threadsafe-statics -nostdlib++ \
  -fvisibility=hidden -I. -Wl,-z,max-page-size=16384 -Wl,-soname,arm64-v8a.so -Wl,-z,defs \
  loader.cpp -llog -ldl -o output/zygisk/arm64-v8a.so
cp "$TC/lib/libc++_shared.so" output/lib/
chmod 755 output output/zygisk output/lib
chmod 644 output/zygisk/arm64-v8a.so output/lib/*.so
"$TC/bin/llvm-readelf" -d output/zygisk/arm64-v8a.so | grep NEEDED
"$TC/bin/llvm-readelf" -d output/lib/libtablet-spoof-engine.so | grep NEEDED
echo ENGINE_BUILD_OK
