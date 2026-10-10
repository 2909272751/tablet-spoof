# tablet-spoof 开发与验证

- 本项目要求优先验证独立 Zygisk 路径；新的 `native/` 引擎不依赖 LSPosed 管理器、服务或模块 APK。
- 原有 `app/` 是 LSPosed 路径，不能将其产生的效果归功于 `src/` 或 `native/`。
- 原生验证前先关闭 `zygisk_lsposed` 并重启，确认 `lspd` 未运行。记录其他可能影响目标应用的模块，执行同一环境的开/关对照。
- APatch 的框架开关用正式 `apd module disable/enable` 操作；当前前台窗口与 UI XML 必须匹配目标应用，不能使用 dumpsys 中残留的历史窗口；Windows ADB 拉取先落到 ASCII 临时目录再复制到中文路径。
- 只允许在 `com.tencent.mm` 与 `com.tencent.wework` 的主进程作用；其他应用和子进程卸载自身库。不要修改全局 DPI、分辨率、系统型号或屏幕配置。
- 不清除应用数据，不手工改写 MMKV，不在证据或日志里保存账号、聊天消息、口令。
- 校验“引擎加载、方法实际调用、入口可见、真实二维码、扫码成功和双端同时在线”各层证据。前一层不能代替后一层。
- 不能把类名猜测称为锚点扫描。已知混淆名只支持对应已核实版本；变更后必须重新分析和对照测试。
- 原生引擎使用成熟 ART 引擎及 `.symtab` / `.dynsym` 符号解析；禁止猜测 ArtMethod 偏移或随意将 Java 方法强制改为 native。
- 构建和部署的每个步骤必须检查退出码，失败时停止，不能继续重启。用 `tools/native-adb.py` 执行受检部署。
- 当前构建环境可用手机上的 Termux Clang；原生库依赖只允许包内运行库与 Android 系统库，不得留下 Termux 专用路径或 `libz.so.1` 依赖。
