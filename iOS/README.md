# MC Harbor for iOS / iPadOS

独立移植分支：`codex/ios-port`。macOS 正式版本与用户数据保持独立。

## 当前状态

这是正在开发的移植工程，尚未发布可供玩家使用的 iOS 正式版。只有通过实际构建、运行和验证的条目才会标为完成；触控核心检查不等于 Minecraft 游戏实玩通过。

- 已建立独立、可在 iOS / macOS 测试的 `HarborCore`：多点输入归属、八方向摇杆、疾跑阈值、潜行开关、视角灵敏度 / 反向、按键尺寸与透明度、左右镜像、布局导入 / 导出 / 原子保存。
- 所有布局至少保留一个可见暂停入口；按键最小 44pt。触摸取消、应用切后台、布局切换与覆盖层关闭必须释放全部输入，避免卡住行走 / 挖掘。
- 实例与整合包导入的预检查拒绝路径越界、符号链接、大小写 / Unicode 重名、超量文件、磁盘空间不足和异常解压膨胀。预检查需要接入实际解压器后再验收完整导入流程。
- 原生 Java / OpenGL / Vulkan、现有触屏、键鼠与手柄实现以 GPL 开源项目 [AngelAura Amethyst iOS](https://github.com/AngelAuraMC/Amethyst-iOS) 为基础，固定提交 `f98c4133c72d39e06ceac42b57cc4477c52105fc`，作为 `vendor/AmethystIOS` 子模块保留其源码与许可证。

## 工具链

工程采用 XcodeGen / Swift Package Manager；可以在 VS Code / SweetPad 编辑和运行任务。Apple SDK、签名、Instruments 和 iPhone 模拟器仍由 Xcode 提供。开源工程工具不替代这些系统组件。

```sh
git clone --recurse-submodules --branch codex/ios-port https://github.com/ADsurfboard/MC-Harbor.git
cd MC-Harbor/iOS/HarborCore
swift test
```

最低系统目标暂定 iOS / iPadOS 16，后续以实际引擎与真机验证为准。

## 平台边界

Minecraft Java 的 iOS 运行依赖原生 JVM 和图形适配，不能把 macOS 的 Java 进程直接搬到 iPhone。真机 JIT、可用内存、签名和设备 / 系统版本会影响支持范围；开发者签名或受支持的 JIT 启用流程需要玩家自己的设备授权。本工程不承诺从 App Store 安装后无条件运行任意 Java 模组，也不自动修改用户设备的安全设置。

模拟器中的界面、触控路由和文件操作测试，与真机游戏性能、JIT 和所有模组兼容性分别记录。公共 CI 不使用作者或玩家的账号、登录凭证与真实存档。

完整功能移植、原生引擎集成、模拟器及真机验收仍在进行中。正式交付前需要逐项完成 `PORTING.md` 的验收矩阵。
