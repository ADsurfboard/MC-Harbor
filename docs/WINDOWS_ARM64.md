# Windows ARM64 开发与兼容说明

ARM64 目标为 Windows 11 24H2（内部版本 26100）或更新版本。主程序使用 ARM64 WinUI 3 / .NET 10，保留相同页面、玻璃效果、账号数据格式和汉化工作区。ARM64 是独立构建目标，不通过修改 x64 包的文件名生成。

## 组件架构

| 组件 | ARM64 版的实现 |
| --- | --- |
| 窗口、玻璃、图片与视频、角色预览、音效 | ARM64 .NET、Windows App SDK、Win2D；共用现有界面源码 |
| 账号、迁移、资源、汉化、存档的 Java 后台 | ARM64 Liberica 21.0.13.1+5，内置原生 JavaFX 模块 |
| Minecraft 安装、修复、导入、Java 检查及游戏启动 | 独立 x64 Java 后台，利用 Windows 的 x64 兼容层；游戏 Java 和本地库均选择 x64 |
| 默认 OPUS-MT 离线补译 | 独立 x64 Python 3.12 / CTranslate2 CPU 工作进程；保持游戏运行时停止推理的策略 |
| 可选 Index-Translate 2B | 优先选择 ARM64 llama.cpp；WinGet 显式请求 ARM64，已有可用 x64 程序可继续兼容运行 |
| Sakura Frp、Terracotta 0.4.2 | 根据 Windows 原生架构下载 ARM64 客户端；校验下载大小、哈希与可执行文件架构 |

游戏使用兼容进程是为了保留旧版 Minecraft、LWJGL 与现有模组的 x64 原生依赖。当前版本不提供原生 ARM64 Minecraft 启动模式，也不把现有 x64 游戏实例批量转换为 ARM64。用户选择游戏 Java 时应选择 x64；不匹配的 Java 会被拒绝，并显示原因。游戏兼容性的实际范围仍受具体游戏版本、模组、显卡驱动和 Windows 兼容层限制。

CTranslate2 官方目前不提供 Windows ARM64 预编译包，因此 OPUS-MT 不宣称原生 ARM64 推理。原生 2B 引擎同样需要模型内存和 CPU 资源；尚未给出特定 ARM 设备的速度或帧率承诺。模型仍按用户选择下载，不随安装包预置。

运行环境依据 `Backend/runtime.json` 选择：普通后台使用 `Runtime/` 与模块化 JavaFX；游戏操作使用 `Compatibility/JavaX64/` 与 `Backend/javafx/`；OPUS-MT 使用 `Translation/Python/`。不会将 x64 JavaFX DLL 加载进 ARM64 JVM。

## 构建

准备 PowerShell、.NET SDK 10.0.404、可在开发机执行的 JDK 21 和 Python 3。ARM64 机器可运行 x64 编译 JDK；安装脚本默认选择开发机原生 .NET SDK。运行时下载均有版本、长度和 SHA-256 固定记录，见 `tools/windows-arm64.lock.json`。

```powershell
tools/setup-dotnet-sdk.ps1
$env:JAVA_HOME = 'C:\Path\To\jdk-21'
tools/build-windows.ps1 -Architecture arm64 -Mode Publish
tools/package-windows.ps1 -PublishDirectory build/MC-Harbor-Windows-arm64 -Architecture arm64 -Format Installer
```

生成 `build/MC-Harbor-Windows-arm64-portable.zip` 与 `build/MC-Harbor-Windows-arm64-Setup.msi`。ARM64 MSI 使用 ARM64 安装模板并检查 Windows 版本；便携版也在启动前检查最低系统版本。未签名测试构建不会标注为已获得受信任证书签名。

`tools/setup-windows-arm64.ps1` 从 BellSoft Full JDK 的 ARM64 jmods 交叉链接精简运行时；开发机运行的 jlink 与目标模块均使用 Java 21。`tools/setup-windows-game-compat.ps1` 准备固定 x64 JRE，并保留其许可证。JavaFX 的 x64 JAR 仅供游戏兼容后台及编译使用。

固定 Full JDK 附带一个未被其他原生二进制引用的 x64 `vcruntime140_1.dll`。准备脚本仅在其 SHA-256 与记录一致、且未发现其他 EXE/DLL 引用时，从生成的 ARM64 运行时排除该文件。其余 ARM64 VC 运行库与许可证完整保留；最终文件架构检查不为该目录放宽限制。

x64 继续使用 `-Architecture x64`，两个目标分别使用独立的构建中间目录和发布目录，可在同一检出中连续构建。MSI 升级标识沿用既有 Windows 版；同版本架构替换按主要升级处理。ARM64 和 x64 安装版使用相同安装目录，不支持并排安装。便携版可解压到不同目录，各自保留自己的 `MCHarborData`。

## 数据与升级

安装版仍使用 `%LOCALAPPDATA%\MCHarbor`，DPAPI 仍绑定当前 Windows 用户。换架构不改变凭据格式，也不自动获得另一用户或另一台设备的凭据解密权限。模型、游戏、个人壁纸和账号不会打进发行包。外部联机程序按架构使用独立缓存，防止沿用另一架构的下载文件。

切换架构前关闭游戏、翻译任务和启动器。普通安装、跨架构升级、回滚和卸载仍需在目标设备验收；安装器管理解包只能验证包内文件。

## 检查方法与边界

```powershell
python tools/test-source-privacy.py
python tools/check-source-privacy.py
dotnet run --project tests/windows-platform-checks/PlatformChecks.csproj -c Release
dotnet run --project tests/windows-local-transport/LocalTransportChecks.csproj -c Release
python tools/check-windows-payload.py --directory build/MC-Harbor-Windows-arm64 --architecture arm64
# 以下命令必须在 ARM64 Windows 上执行；只使用临时空目录，不读取玩家数据。
python tools/check-windows-backend.py --directory build/MC-Harbor-Windows-arm64 --architecture arm64
```

平台测试使用生产环境选择代码和真实子进程管道，验证模块化后台、x64 游戏后台的分流以及缺失兼容环境时的错误。文件检查读取 PE 头，逐项验证主程序、.NET、WinUI、Java、Python 与本地 DLL；只允许两个明确隔离的 x64 目录以及 pip 自带的脚本模板包含兼容架构。

Windows App SDK 的 `Microsoft.Windows.Workloads.Resources_ec.dll` 是 ARM64X 双 ABI 组件，会同时出现在 x64 发行目录中。文件检查读取混合元数据和 ARM64X 动态重定位表识别它；不会仅凭文件名放行普通 ARM64 DLL。[ARM64X 的加载规则见微软说明](https://learn.microsoft.com/en-us/windows/arm/arm64x-pe)。

持续构建同时包含 x64 `windows-2022` 与原生 ARM64 `windows-11-arm`。ARM64 后台检查执行实际打包的原生 Java、兼容 Java 和空资源扫描。自动检查不代表已验证 GUI、真实账号登录、Minecraft 显卡及模组、联网房间、模型推理速度和安装升级流程；这些仍须使用目标设备验收。

ARM64 构建机另外使用实际 x64 Python 调用生产环境的依赖安装逻辑，按固定哈希安装并导入 CTranslate2、NumPy、SentencePiece 和 PyYAML，检查 INT8 能力与基础数值运算。该检查不下载翻译模型，不代表已测量真实翻译速度；运行时仍需要支持对应兼容指令的 Windows 更新及硬件。

## 官方参考

- [BellSoft 支持平台](https://bell-sw.com/pages/supported-configurations/) 与 [Liberica Java 21.0.13.1+5](https://github.com/bell-sw/Liberica/releases/tag/21.0.13.1%2B5)
- [CTranslate2 预编译包支持范围](https://opennmt.net/CTranslate2/installation.html)
- [Windows on Arm 的 x86/x64 兼容运行](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation)
- [llama.cpp WinGet 安装清单](https://github.com/microsoft/winget-pkgs/tree/master/manifests/g/ggml/llamacpp)
- [Sakura Frp 官方客户端元数据](https://api.natfrp.com/v4/system/clients) 与 [Terracotta 0.4.2](https://github.com/burningtnt/Terracotta/releases/tag/v0.4.2)
- [GitHub Windows 11 ARM64 构建机](https://github.com/actions/runner-images/blob/main/images/windows/Windows11-Arm64-Readme.md)
