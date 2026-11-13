# MC Harbor for iOS / iPadOS

独立移植分支：`codex/ios-port`。macOS 正式版本与用户数据保持独立。

## 当前状态

这是正在开发的移植工程，尚未发布可供玩家使用的 iOS 正式版。只有通过实际构建、运行和验证的条目才会标为完成；触控核心检查不等于 Minecraft 游戏实玩通过。

- 已建立独立、可在 iOS / macOS 测试的 `HarborCore`：多点输入归属、八方向摇杆、疾跑阈值、潜行开关、视角灵敏度 / 反向、按键尺寸与透明度、左右镜像、布局导入 / 导出 / 原子保存。
- 所有布局至少保留一个可见暂停入口；按键最小 44pt。触摸取消、应用切后台、布局切换与覆盖层关闭必须释放全部输入，避免卡住行走 / 挖掘。
- 实例与整合包导入的预检查拒绝路径越界、符号链接、大小写 / Unicode 重名、超量文件、磁盘空间不足和异常解压膨胀。预检查需要接入实际解压器后再验收完整导入流程。
- 原生 Java / OpenGL / Vulkan、现有触屏、键鼠与手柄实现以 GPL 开源项目 [AngelAura Amethyst iOS](https://github.com/AngelAuraMC/Amethyst-iOS) 为基础，固定提交 `f98c4133c72d39e06ceac42b57cc4477c52105fc`，作为 `vendor/AmethystIOS` 子模块保留其源码与许可证。

## 已完成的验证与下载边界

16 项触控与存储核心检查已通过。iPhone、iPad 的横竖屏启动按钮和布局编辑 / 保存 / 再读取共四项真实模拟器 UI 检查已通过。完整原生引擎的 iPhone ARM64 与 ARM64 模拟器目标均已完成构建和签名检查；完整 App 的安装、冷启动和游戏运行仍按独立步骤验收。

凭证存储另有 23 项原生回归检查，使用生产编码 / 解码代码及替代的 Security 调用，绝不访问开发者或 CI 的真实钥匙串。覆盖安全解码、无效凭证、写入失败保留旧值、并发新增冲突和显式删除。真实 Microsoft 登录及设备钥匙串权限仍需单独验收。实例编辑采用工作副本，取消不会写回；完整 App 的取消、保存、重启持久化进入独立 UI 检查，结果以对应 CI 为准。

根界面使用统一的弹窗状态，避免 iPad 上独立展示入口竞争。资源入口分别连接 Modrinth 整合包、Fabric / Quilt、Forge / NeoForge 与 JAR 文件选择器；先初始化真正的下载控制器及进度监听，再进入相应页面。页面进入、取消和保存属于业务检查范围；这些入口接入不等于所有加载器、网络和整合包安装流程已经验收。

整合包后台校验另有 85 项仅使用临时文件的原生回归，覆盖损坏 / 缺失索引、依赖与名称、中文本地版本名、同名实例保留、HTTPS 域名、哈希格式及客户端 / 服务端声明。新导入使用独立 UUID 目录，不再把项目标题拼进路径；显示名称冲突时保留旧实例并自动编号。索引按 [Modrinth 官方格式](https://support.modrinth.com/en/articles/8802351-modrinth-modpack-format-mrpack) 校验，文件数据使用 SHA-512，旧 Minecraft 元数据保留 SHA-1 兼容；校验分块为 64 KiB，避免整份 JAR 驻留内存。

当前 Forge / NeoForge 整合包要求已安装匹配的游戏及加载器，按实际库坐标匹配原版或自定义中文版本目录；缺失时先报出所需版本，不创建不可启动的实例。自动串联这些加载器的安装、完整导入事务及所有真实网络情形仍需继续接入和验收。独立后台回归不能替代完整整合包下载与 Minecraft 实玩。

CI 先将设备 ARM64 交叉构建放在 Intel 执行器，模拟器与界面检查复用一台 ARM 执行器，以减少 GitHub ARM 容量不足造成的排队取消。每个测试的断言仍保留。对应结果以 [最新 iOS Actions](https://github.com/ADsurfboard/MC-Harbor/actions/workflows/ios-compat.yml?query=branch%3Acodex%2Fios-port) 的具体提交为准；旧失败记录不删除。

构建输出包含保留执行权限的 IPA 与模拟器 ZIP，并记录 SHA-256。当前为工程预览：IPA 是临时签名，需要个人开发签名和受支持的 JIT 授权；模拟器 ZIP 需要 Apple 模拟器，不是可直接在 macOS 双击运行的 App。这些产物不等于已经通过 Minecraft 实玩或完整功能验收的正式 iOS 发行版。

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
