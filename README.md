# 微信与企业微信平板登录（纯 Zygisk）

v3.0.0 已实现独立 Zygisk 模块，让手机上的微信、企业微信出现平板扫码登录入口。无需 LSPosed 或配套 APK；其他 LSPosed 模块可继续使用。仅替换两个应用主进程的平板判定，不修改全局 DPI、分辨率或应用数据。

## 下载与安装

从 [最新 Release](https://github.com/2909272751/tablet-spoof/releases/latest) 下载 `tablet-spoof-pure-v3.0.0.zip`，在 root 管理器安装，确认 Zygisk 已启用，然后重启。

当前支持 **微信 8.0.78、企业微信 5.0.3、arm64**。其他应用版本会保留原判定并记录 `UNSUPPORTED_VERSION`，需重新适配。

1. 停用旧的 `io.github.tabletspoof` LSPosed 模块，避免重复替换；其他 LSPosed 模块无需关闭。
2. 打开应用登录页，点击「平板和手机同时登录」，用已登录账号的主手机扫码并授权。
3. root 管理器「操作」按钮可开关模块。开关后强停并重新打开应用即可，不清除数据。
4. 停用或卸载本模块并重启即可恢复。

## 验证结果

实测小米 9 / Android 16、APatch 114027、Zygisk Next 1.5.0。最终 ZIP 已通过 APatch 安装器安装并重启，关闭整个 LSPosed 后完成两个应用各两轮「关 → 开」对照：关时无平板入口，开时入口恢复，当前进程的方法实际被调用。

两个应用均已进入真实二维码页面，用户已反馈可用。系统维持 1080 × 2340、440 DPI、SELinux Enforcing；设置应用没有加载新引擎。自动验证不代表所有账号的双端在线或长期稳定性已经覆盖。

应用可能依据平板判定自行调整部分页面，保持系统 DPI 不等于保证所有内部界面布局相同。

## 源码与排查

- [完整使用、构建与排查说明](native/README.md)
- [实机开关对照结果](docs/evidence/native/behavior-results.json)
- `native/` 是 v3.0.0 的独立引擎，内置 LSPlant、Dobby 和 C++ 运行库，依赖来源与许可证随源码和发布包提供。
- `app/`、`src/`、`module/` 保留旧方案用于历史参考；旧版本说明在 [历史文档](docs/legacy-v0.1.0.md)。它们不描述当前 Release 的实现。

发布提供可直接安装的模块 ZIP、可编辑源码 ZIP，以及各自 SHA256 校验文件。没有复用第三方示例中的二进制或混淆安装脚本。
