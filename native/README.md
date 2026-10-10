# 微信与企业微信平板登录 v3.0.0

这是独立 Zygisk 模块。无需安装 LSPosed 或配套 APK。模块在两个应用的主进程里加载 LSPlant/Dobby，替换已核实的平板判定；其他进程卸载模块入口库。

## 当前验证范围

- 测试手机：小米 9，Android 16 / API 36，arm64-v8a。
- Root：APatch 114027；注入器：Zygisk Next 1.5.0。
- 微信：8.0.78；企业微信：5.0.3。当前版本严格检查这两个版本号，其他版本会记录 `UNSUPPORTED_VERSION`，保持原应用判定，等待适配。
- 关闭整个 LSPosed 并重启后测试，确认 `lspd` 未运行。
- 两轮「关 → 开」对照，两个应用均符合：关时无平板入口，开时入口恢复，替换方法被实际调用。证据在 `../docs/evidence/native/behavior-results.json`。
- 两个应用均可进入自身的真实扫码登录页面。用户已反馈可正常使用；自动测试只确认入口、二维码和替换调用，不替代逐个账号的双端在线或长期稳定性验证。
- 系统保持 1080 × 2340、440 DPI、SELinux Enforcing。未清除应用数据或改写 MMKV。

## 使用

1. 在 root 管理器安装 `dist/tablet-spoof-pure-v3.0.0.zip`，确认 Zygisk 已启用，然后重启。
2. 停用旧的 `io.github.tabletspoof` LSPosed 模块，避免叠加。其他 LSPosed 模块可继续使用，无需关闭整个框架。只在验证独立原生路径时临时关闭整个 LSPosed。
3. 在测试手机的微信或企业微信登录页，点击「平板和手机同时登录」，用已登录账号的主手机扫码并授权。
4. root 管理器中的「操作」按钮可开关本模块。开关后强行停止并重新打开两个应用即可，不需要清除数据。
5. 在管理器停用/卸载本模块并重启即可恢复。不会自动卸载旧 APK、改动 LSPosed 的其他配置或恢复别人修改过的系统属性。

应用会根据平板判定自行安排部分界面；保持系统 DPI/分辨率并不等于保证所有应用内部页面布局完全相同。

## 排查

先确认当前版本受到支持、Zygisk 正在运行、模块未停用、`off` 文件不存在，再强停并打开应用。使用 root 查看：

```sh
cat /data/user/0/com.tencent.mm/tablet-spoof-native-loader.txt
cat /data/user/0/com.tencent.mm/tablet-spoof-native-engine.txt
cat /data/user/0/com.tencent.mm/files/tablet-spoof-native-status.txt
```

企业微信将路径中的包名换为 `com.tencent.wework`。状态里的 `pid` 应当是当前进程，`hooks` 是安装数量，`hits` 是实际调用数量；旧进程留下的文件不能证明当前生效。

加载阶段应为 `PRE_COMPLETE`，引擎应为 `BOOTSTRAP_INSTALLED`。应用状态应包含 `READY` 且 `hits > 0`。`OFF` 表示本模块的操作开关关闭；`UNSUPPORTED_VERSION` 表示应用已更新，需要重新核实签名，不能猜测其他布尔方法。

SELinux 文件标签是必要安装步骤：附带引擎与 C++ 运行库使用 `system_lib_file`，模块目录和 DEX 使用 `system_file`。安装器只标记自己的文件，不关闭 SELinux、不增加全局允许规则。Zygisk 注册表里出现 ELF，并不能证明它读取了载荷或安装了替换方法。

## 构建

依赖来源和版本在 `third_party/UPSTREAM.txt`，对应源码及许可证保留在 `third_party/`。没有复用用户提供示例的原生二进制或混淆安装脚本。

本机 Android SDK 在 `开发工具链/android_build_tools/Sdk`；手机需已有 Termux Clang。可通过 `TS_SDK` 指定其他 SDK 路径。

```powershell
# 已随源码保存依赖与转换结果；不需要重新下载依赖。
python tools/flatten-native-deps.py
adb push native /data/local/tmp/ts-native-src
adb shell su -c 'sh /data/local/tmp/ts-native-src/build-flat.sh'
./native/build-bridge.ps1
python tools/native-adb.py build
python tools/package-native.py
```

Termux Clang 21.1.8 在编译上游的 C++ 模块 PCM 时发生编译器崩溃。`flatten-native-deps.py` 保留原始源码，单独生成头文件，将 module/import/export 声明转换为 include；实现体不变。上游已包含的 C++ 运行库通过目标进程里的独立加载器载入，入口库本身只依赖 Android 系统库，避免设备需要安装 Termux 才能运行产物。

实机对照：关闭 LSPosed 并重启后运行 `python tests/native-behavior.py`。测试只强停/启动应用和切换本模块的 `off` 文件，不清除账号或聊天数据。

APatch 环境使用管理器或 `apd module disable/enable zygisk_lsposed` 切换框架；不要仅手工放置停用标记。实机测试会核实停用标记和 `lspd` 状态，并检查捕获的前台应用与状态文件 PID。
