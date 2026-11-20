# Windows 移植开发入口

正式负责人：**时咨月.**（[shiziyueyuan](https://github.com/shiziyueyuan)）。项目作者：**ADsurfboard**。

本分支以原项目 windows 分支的 macOS 源码为基线，新增 WinUI 3 / .NET 10 Windows x64 客户端，并沿用仓库固定的 HMCL Java 后端。当前构建目标为 Windows 10 22H2 和 Windows 11 x64。窗口启动修复和便携发布已在 Windows 10 22H2 x64 上确认。账号续期、外置服务和不同网络环境下的联机仍须由用户实际账号验收。

开发分支为 [windows](https://github.com/ADsurfboard/MC-Harbor/tree/windows)。逐项移植决策、替代方案和验收范围见 [WINDOWS_PORT_PLAN.md](WINDOWS_PORT_PLAN.md)，视觉布局见 [WINDOWS_VISUAL_PLAN.md](WINDOWS_VISUAL_PLAN.md)，源码与发行附件的发布流程见 [WINDOWS_RELEASE.md](WINDOWS_RELEASE.md)。

## 本地构建

- Windows x64 与 PowerShell 5.1 或更新版本。
- .NET SDK 10.0.404。global.json 固定 SDK 系列，可运行 tools/setup-dotnet-sdk.ps1 安装到仓库父目录 _tools/dotnet。
- Eclipse Temurin JDK 21 x64。设置 JAVA_HOME 后，由 tools/build-windows.ps1 编译 Java 后端并使用 jlink 准备随包运行时。
- OpenJFX 21.0.8 Windows x64。构建脚本优先使用 HMCL 缓存，否则按 tools/windows-javafx.lock.json 下载并校验。
- 可选的 JDSherbert 免费 UI 音效包；如需在本机构建版本中启用界面音效，将其 Mono/mp3 音频文件放入 voice-assets/jds-ui-free。原始音频不会进入源码包或发行包，构建时只嵌入 soundbank。
- vendor/HMCLCore.jar 需由仓库固定文件提供。Python 3 用于执行现有 Java 后端打包脚本。

开发构建与便携发行包的命令如下。

    tools\setup-dotnet-sdk.ps1
    $env:JAVA_HOME = "C:\Path\To\jdk-21"
    tools\build-windows.ps1
    tools\build-windows.ps1 -Mode Publish
    tools\build-windows.ps1 -Mode Installer

`Publish` 生成便携 ZIP，`Installer` 生成中文 x64 MSI。MSI 构建使用 WiX 5.0.2 与同版本 `WixToolset.UI.wixext`，可以通过 `tools/package-windows.ps1` 的 `Wix` 和 `WixUiExtension` 参数指定本机工具路径。安装器默认将程序放到 `Program Files\MC Harbor`，创建开始菜单快捷方式，并支持 Windows 的修复与卸载入口。安装版数据放在 `%LOCALAPPDATA%\MCHarbor`。现有便携版数据可通过原便携目录继续使用。

已有自包含发布目录时，可直接生成两种发行包。

    tools\package-windows.ps1 -PublishDirectory build\MC-Harbor-Windows
    tools\package-windows.ps1 -PublishDirectory build\MC-Harbor-Windows -Format Installer

打包使用独立的文件副本，包含 Java、.NET、WinUI 和本机翻译运行库。脚本排除玩家数据与调试符号，并检查启动资源、程序图标和包内文件数量。便携 ZIP 带有 `MCHarbor.portable` 标记。程序与窗口图标由仓库 `Assets/Brand/Icon.png` 生成多尺寸 ICO，侧栏使用同一份正式图稿。

发行包位于 build/MC-Harbor-Windows-x64-portable.zip。解压后运行 MC Harbor.exe。首次使用本机 OPUS-MT 英译中补译时，程序会在用户选择后下载约 289 MB 的模型和运行库；“进阶本机补译 2B”会另行安装 llama.cpp 并下载约 1.31 GB 的量化模型。普通安装模式将模型保存在 `%LOCALAPPDATA%\MCHarbor\translation`；带有 MCHarbor.portable 标记的发行目录会保存在 `MCHarborData\translation`。模型均不预置在便携包中。

## 已接入功能

本地 Windows 源码已同步上游 1.7.1，基线提交为 2e101df72dd97618f5cdab44bf9145c830867d1f。新增功能接入 WinUI 界面和 Windows Java 后端。

| 上游更新 | Windows 实现 |
| --- | --- |
| 1.7.0 壁纸库原生视频预览与生命周期修复 | 设置中的“壁纸库…”打开缩略图库，右侧使用 WinUI 原生播放器静音预览。切换、关闭和窗口失活时暂停或释放播放器，提供重命名、应用及移除操作 |
| 快捷启动交接确认 | 同一用户数据目录使用独立请求与接收回执，主窗口轮询接收并恢复窗口。每个请求消费一次，辅助进程等待接收确认并在 60 秒内结束 |
| 1.7.1 普通版背景调整 | 默认采用静态 Harbor 渐变，支持图片和视频壁纸 |
| 版本和发布信息 | Windows 程序、网络请求和 MSI 版本统一为 1.7.1，沿用稳定的安装升级标识 |

上述同步通过 x64 调试构建及 23 项隔离回归，包含旧壁纸索引、并发导入、文件保留、快捷启动接收、重复通知和超时清理。原生预览的实际播放观感及完整快捷启动流程仍需在窗口中确认。上游记录见 [1.7.0 验收说明](https://github.com/ADsurfboard/MC-Harbor/blob/2e101df72dd97618f5cdab44bf9145c830867d1f/docs/QA-1.7.0.md) 和 [1.7.1 发布说明](https://github.com/ADsurfboard/MC-Harbor/blob/2e101df72dd97618f5cdab44bf9145c830867d1f/RELEASE_NOTES.md)。

- WinUI 游戏库、实例扫描、版本与加载器安装、实例重定位、专用运行目录、游戏 Java 选择、快捷方式和普通窗口关闭。
- Microsoft、外置认证和离线账号。导入旧 HMCL 配置时，按已选目录或文件只读解析两代配置，可恢复旧凭据或标注需要重新登录。Mac 客户端可导出加密登录迁移包，Windows 客户端解密后将凭据转入 DPAPI。
- 实例模组、资源包、光影、地图和存档操作。地图和世界 ZIP 导入会验证 Windows 文件名、大小写冲突、条目路径、CRC 与解压容量。存档读取、NBT 编辑和原字节备份按世界目录执行。
- Modrinth 与 CurseForge 搜索、排序、兼容文件选择、哈希校验、必要依赖及下载暂存。实例模组可收藏为本地副本或在线项目，并在模组夹间批量管理及导入。
- 汉化工作区包含 CFPA 社区补全、人工编辑、格式校验、导入导出和 FTB／数据包文本应用。默认机器补译为按需加载的 CPU INT8 OPUS-MT 英译中；另提供可选的 Index-Translate 2B Q4_K_M。2B 首次使用按用户确认后通过 WinGet 安装 llama.cpp，并下载固定版本模型；模型会校验 SHA-256，只绑定本机回环地址。所有本机补译都要求游戏退出，游戏启动时停止推理并在游戏退出后续跑。
- 好友服务、聊天、恢复密钥、邀请及动态。联网后可使用服务器直连、Terracotta 房间和 Sakura Frp。
- 本地皮肤预览与 LittleSkin 浏览、主题、分层 GPU 磨砂与可调模糊半径、指针视差折射高光、Fluent System Icons、壁纸、欢迎语音与 JDSherbert 界面音效、性能模式、配置导入导出与游玩记录。

## Windows 启动故障修复

便携发布构建缺少 WinUI 资源索引和启动 XAML 页面会导致窗口无法激活。项目发布目标将 PRI 资源索引、App.xbf 和 MainWindow.xbf 写入自包含发布目录，并在打包时校验关键文件。应用激活失败时另外提供 Windows 原生错误对话框和日志。

## 验收范围

现有证据包括 Windows 10 22H2 x64 上 WinUI 主窗口正常显示、同一便携应用重复打开转到已运行窗口、正常关闭进程，以及固定 HMCL 后端的版本安装、实例扫描和 Minecraft 1.20.1 离线启动。独立后端检查覆盖 NBT 读写、原件备份、路径与哈希校验、翻译占位符、CFPA 导入和 Modrinth / CurseForge 文件计划。

当前提供 x64 便携 ZIP 和中文 MSI。在线账号、Mac 钥匙串迁移、Windows 11、ARM64、跨公网联机和翻译对游戏帧时间的影响仍需在目标设备验收。2B 翻译已经接入，其首次下载、译文效果和模型资源占用需要真实硬件测试。玻璃滚动修复采用固定窗口底图，并校正卡片越过窗口边缘时的壁纸取样比例。小按钮和主操作按钮具有磨砂底层、边缘高光及可调阴影。最新界面仍需人工核验滚动观感。MSI 已通过 Windows Installer 管理解包，全部程序与许可证文件均按 SHA-256 核对；便携 ZIP 的全部程序文件也已通过逐项 SHA-256 校验。发布整理另外排除了 Python 字节码缓存和本机构建路径，2B 回环连接显式禁止代理与重定向。普通安装、升级和卸载流程需要另行验收。当前本地生成的程序与安装包尚无发行证书签名。

只在 windows 分支提交 Windows 工作。跨平台公共改动按上游流程交由 ADsurfboard 审核。Windows 专用标签使用 windows-*。项目分工与署名见 [GOVERNANCE.md](../GOVERNANCE.md)。
