#!/system/bin/sh
MODDIR=${0%/*}
if [ -f "$MODDIR/off" ]; then
  rm -f "$MODDIR/off"
  echo '已启用平板判定。请强行停止并重新打开微信和企业微信。'
else
  touch "$MODDIR/off"
  echo '已关闭平板判定。请强行停止并重新打开微信和企业微信。'
fi
echo '聊天数据不会被清除。'
