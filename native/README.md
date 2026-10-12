# 微信与企业微信平板登录 v3.1.0

这是独立 Zygisk 模块，无需 LSPosed 或配套 APK。只在两个应用的主进程替换平板判定和企业微信的登录设备类型；其他进程卸载入口库。v3.1.0 取消应用版本白名单，按实际方法签名和 DEX 代码特征识别，不要求每次更新都手工添加版本号。

## 跨版本识别

- 企业微信优先识别稳定的平板布尔签名，缺失时扫描登录界面中的实际调用关系。同时扫描 `getDeviceType()` 实现：必须在同一真实方法中读取二维码登录开关、包含手机/平板枚举并调用同类平板判定，才统一接口和内部实现的平板身份。不能只显示入口而仍向登录引擎报告手机。
- 当前验证过的平板登录枚举为 `131076`。未知版本若改变枚举或移除协议锚点，会留下 `PROTOCOL_MISSING_OR_AMBIGUOUS` 并保留原行为，避免猜测新协议。
- 微信不再信任 `gk.B/C` 这类混淆名称。扫描 APK 中同一静态布尔方法实际引用的 `inTabletEnv` 真/假分支日志，再确认同类唯一的无参布尔包装方法与调用关系。两个目标全部验证后才启用替换；歧义、代码格式不支持、超出资源预算时保留原判定并记录失败。
- 等待应用的 `attachBaseContext` 完成，使用实际类加载器，在 `Application.onCreate` 前安装替换。兼容启动期间的 DelegateLast/Tinker 类加载器切换；再次切换时重新校验目标并回滚旧替换。日志记录安装加载器与实际加载器是否一致。
- 自动发现直接调用者并处理 AOT 内联，同时覆盖已知登录界面。微信用旧类名仅作调用索引的提速提示，目标仍须完整通过语义验证；类名改变时自动执行第二遍调用扫描。构造器和静态初始化器没有反射方法句柄时，汇总记录跳过数量。APK 更新、路径、修改时间、大小变化后识别缓存自动失效；缓存无法使用时重新扫描。
- 泛支持表示不按版本号拒绝、自动识别满足特征的版本。厂商若彻底改变登录协议、判定语义、加密 DEX 或去除锚点，仍需适配；不能保证所有过去和未来版本都成功。
- 扫描上限：单 DEX 64 MiB、总 DEX 256 MiB、64 个 DEX、512 个直接调用者，扫描预算 8 秒。只读取已安装 APK，不扫描账号、聊天或 MMKV。成功计划缓存后，后续启动直接校验签名。

## 当前验证范围

- 测试手机：小米 9，Android 16 / API 36，arm64-v8a。
- Root：APatch 114027；注入器：Zygisk Next 1.5.0。
- 当前手机：微信 8.0.78、企业微信 5.0.11。旧版 v3.0.0 的企业微信验证为 5.0.3。
- 关闭整个 LSPosed 并重启后测试，确认 `lspd` 未运行。
- 两轮「关 → 开」对照，两个应用均符合：关时无平板入口，开时入口恢复，替换方法被实际调用。证据在 `../docs/evidence/native/behavior-results.json`。
- 企业微信 5.0.11 已完成独立原生路径和 LSPosed 开启时的真实账号验证：扫码响应 `code=0`，状态从 `0 → 1 → 2`，进入企业回调 `code=0`，用户确认进入消息页且主副机同时在线；LSPosed 开启时强停再打开仍保持登录；关闭 LSPosed 后的整机重启仍直接进入消息页。修复前仅入口成功，确认后会卡在登录中；本次补齐内部平板判断与登录设备类型，并修复启动后换类加载器导致重启失效的问题。
- 微信 8.0.78 的损坏缓存实机测试自动重新扫描，安装两处替换并恢复平板入口。首次识别及安装实测约 4.2–5.4 秒，之前约 7.9 秒；正常缓存启动无需再次扫描。
- 开关对照记录来自登录协议修复前的入口验证；实际扫码成功记录在 `../docs/evidence/native/wework-login-flow.json`。不替代所有账号、版本或长期双端在线验证。
- 系统保持 1080 × 2340、440 DPI、SELinux Enforcing。未清除应用数据或改写 MMKV。

## 使用

1. 在 root 管理器安装 `dist/tablet-spoof-pure-v3.1.0.zip`，确认 Zygisk 已启用，然后重启。
2. 停用旧的 `io.github.tabletspoof` LSPosed 模块，避免叠加。其他 LSPosed 模块可继续使用，无需关闭整个框架。只在验证独立原生路径时临时关闭整个 LSPosed。
3. 在测试手机的微信或企业微信登录页，点击「平板和手机同时登录」，用已登录账号的主手机扫码并授权。
4. root 管理器中的「操作」按钮先导出当前诊断，再开关本模块。开关后强停并重新打开应用，不需要清除数据。日志在 `下载/TabletSpoof/diagnostic-时间.txt`。
5. 在管理器停用/卸载本模块并重启即可恢复。不会自动卸载旧 APK、改动 LSPosed 的其他配置或恢复别人修改过的系统属性。

应用会根据平板判定自行安排部分界面；保持系统 DPI/分辨率并不等于保证所有应用内部页面布局完全相同。

## 排查

先确认 Zygisk 正在运行、模块未停用、`off` 文件不存在，再强停并打开应用。使用 root 查看：

```sh
cat /data/user/0/com.tencent.mm/tablet-spoof-native-loader.txt
cat /data/user/0/com.tencent.mm/tablet-spoof-native-engine.txt
cat /data/user/0/com.tencent.mm/files/tablet-spoof-native-status.txt
cat /data/user/0/com.tencent.mm/files/tablet-spoof/diagnostic.log
```

企业微信将路径中的包名换为 `com.tencent.wework`。状态里的 `pid` 应当是当前进程，`hooks` 是安装数量，`hits` 是实际调用数量；旧进程留下的文件不能证明当前生效。

加载阶段应为 `PRE_COMPLETE`，引擎应为 `BOOTSTRAP_INSTALLED`。应用状态包含应用版本、模块版本、当前 PID、识别规则、方法签名、逐方法调用次数、耗时和反内联数量。`READY` 且 `hits > 0` 证明替换被实际调用，不证明账号已授权或界面入口一定可见。

企业微信另记录 `FLOW QR_RESPONSE`、`QR_POLL` 的数字错误码/状态、`ENTERPRISE_LOGIN_RESULT` 与等待超时。状态 `1` 为已扫码待确认，`2` 为已确认；不会伪造服务端成功，不记录回调中的令牌、企业/用户信息或错误文本。观察器不可用时记录 `FLOW_DIAGNOSTICS_UNAVAILABLE`。

`FAILED_INSTALL` 时看详细日志的原因与异常栈，例如目标缺失/歧义、签名变化、DEX 越界、预算超限、替换失败。部分安装失败会回滚。诊断日志最多当前和上一份，各约 256 KiB；失败不会清空旧日志。`OFF` 表示操作开关关闭。

仅导出诊断而不切换开关：

```sh
adb shell su -c 'sh /data/adb/modules/tablet-spoof-pure/report.sh'
```

导出包括当前模块/应用版本、当前进程、加载阶段、状态、当前与上一次诊断。不会打包完整 logcat、APK、缓存、登录二维码、账号或聊天。把导出的文本与「哪个页面没有入口/扫码后提示」一起提供，便于适配。

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

`python tests/native-cache-recovery.py` 在 LSPosed 关闭且微信处于测试登录页时验证损坏缓存自动重建；不会清除数据。企业微信已登录时不要运行会强制进入登录页的旧开关对照脚本。

`python tests/native-resolver.py` 在 JVM 验证混淆名称改变、多参数签名、提速提示不替代语义验证、伪锚点、歧义、截断、非法指令及协议枚举变化。解析格式依据 [AOSP DEX 格式](https://source.android.com/docs/core/runtime/dex-format) 和 [字节码规范](https://source.android.com/docs/core/runtime/dalvik-bytecode)。

APatch 环境使用管理器或 `apd module disable/enable zygisk_lsposed` 切换框架；不要仅手工放置停用标记。实机测试会核实停用标记和 `lspd` 状态，并检查捕获的前台应用与状态文件 PID。
