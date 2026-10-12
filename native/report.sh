#!/system/bin/sh
# Export only this module's diagnostics. Never collect account/chat/UI data.
set -eu
MODDIR=${0%/*}
OUTDIR=/sdcard/Download/TabletSpoof
mkdir -p "$OUTDIR"
REPORT="$OUTDIR/diagnostic-$(date +%Y%m%d-%H%M%S).txt"
{
  echo 'Tablet Spoof diagnostic report'
  date '+%Y-%m-%d %H:%M:%S %z'
  cat "$MODDIR/module.prop"
  echo "android_sdk=$(getprop ro.build.version.sdk)"
  echo "selinux=$(getenforce)"
  if [ -f "$MODDIR/off" ]; then echo 'switch=OFF'; else echo 'switch=ON'; fi
  if [ -f "$MODDIR/disable" ]; then echo 'module_disabled=true'; fi
  for pkg in com.tencent.mm com.tencent.wework; do
    echo "--- $pkg current_pid=$(pidof "$pkg" || true) ---"
    dumpsys package "$pkg" | sed -n '/versionCode=/p;/versionName=/p'
    for home in /data/user/*/"$pkg"; do
      [ -d "$home" ] || continue
      echo "user_data_dir=$home"
      for relative in tablet-spoof-native-loader.txt tablet-spoof-native-engine.txt \
        files/tablet-spoof-native-status.txt files/tablet-spoof/diagnostic.previous.log \
        files/tablet-spoof/diagnostic.log; do
        file="$home/$relative"
        echo "--- $relative ---"
        if [ -f "$file" ]; then tail -c 262144 "$file"; else echo 'NOT_CREATED'; fi
      done
    done
  done
} > "$REPORT"
echo "诊断日志已导出：$REPORT"
