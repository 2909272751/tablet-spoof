#!/system/bin/sh
SKIPMOUNT=true
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=false
[ "$BOOTMODE" = true ] || abort '请通过 Magisk/APatch/KernelSU 管理器安装。'
[ "$ARCH" = arm64 ] || abort '当前版本仅支持 arm64-v8a。'
[ "${API:-0}" -ge 26 ] || abort '需要 Android 8.0 或更高版本。'
ui_print '微信与企业微信平板登录：独立 Zygisk 模块'
ui_print '需要已启用的 Zygisk；无需 LSPosed。'
ui_print '当前实测版本：微信 8.0.78 / 企业微信 5.0.3。'
ui_print '不修改全局 DPI、分辨率或聊天数据。'
ui_print '请停用旧的 tablet-spoof LSPosed 模块，避免叠加。'
ui_print '安装后重启；操作按钮可开关，再强停两个应用生效。'
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/zygisk/arm64-v8a.so" 0 0 0644 u:object_r:system_lib_file:s0
set_perm "$MODPATH/lib/libc++_shared.so" 0 0 0644 u:object_r:system_lib_file:s0
set_perm "$MODPATH/lib/libtablet-spoof-engine.so" 0 0 0644 u:object_r:system_lib_file:s0
