# MC Harbor Windows 移植参考文档

更新于 2026 年 11 月 14 日。本文记录 Windows 版的源码基线、首版实施路线、配套参考和实机验收条件。

## 1. 源码基线与目标平台

- 从官方 `windows` 分支的 `a9b242c` 开始。该分支目前仍是 macOS 源码，README 标为 1.6.1，`SOURCE.json` 标为 1.6.0。以源码提交确定实际能力，以 macOS 1.6.2 的 Apple Silicon 和 Intel 发行版核对功能、外观与素材。公开发行记录中没有需要兼容的旧版 MC Harbor Windows 安装包。 [Windows 分支](https://github.com/ADsurfboard/MC-Harbor/tree/a9b242cf577649ebb1f101172e04cc57d96fddc7) · [源码清单](https://github.com/ADsurfboard/MC-Harbor/blob/a9b242cf577649ebb1f101172e04cc57d96fddc7/SOURCE.json) · [发布记录](https://github.com/ADsurfboard/MC-Harbor/releases)
- 首版以 **Windows 10 22H2 x64 和 Windows 11 x64** 为目标，先交付便携 ZIP。Windows ARM64 单独构建和验收。首轮需在 Windows 10／11 x64 设备上验证，并记录兼容性与资源占用。Windows App SDK 的基础兼容范围到 Windows 10 1809。在 Windows 7／8.1 上直接运行客户端需要另行评估框架，旧机 HMCL 数据的导入方式见第 3.3 节。 [Windows App SDK](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/) · [Windows 材质](https://learn.microsoft.com/en-us/windows/apps/develop/ui/materials)
- 按上游分工，由时咨月. 负责 Windows 移植。Windows 提交进入 `windows`，专用发布标签用 `windows-*`。需要同步公共后端修复时，由上游按现有流程审阅。 [移植入口](https://github.com/ADsurfboard/MC-Harbor/blob/windows/docs/WINDOWS_PORT.md) · [项目分工](https://github.com/ADsurfboard/MC-Harbor/blob/windows/GOVERNANCE.md)

实现路线采用 **C#／WinUI 3 桌面客户端 + 原 HMCL Java 后端**。客户端负责界面、工作队列、Windows 文件和凭据接口。Java 子进程继续负责游戏与文件格式逻辑。皮肤预览使用本地 WebView2 页面。本机翻译模型在独立进程中按需加载。 [WinUI Gallery](https://github.com/microsoft/WinUI-Gallery) · [Windows App SDK 示例](https://github.com/microsoft/WindowsAppSDK-Samples) · [原项目技术说明](https://github.com/ADsurfboard/MC-Harbor/blob/windows/docs/TECH.md)

## 2. 原样复用的源码、资产与协议

以下模块保留原有算法、格式或协议。涉及 Windows 路径、进程和系统接口的调用点按后面的方案适配。

| 模块 | 复用内容 |
| --- | --- |
| **HMCL 内核与桥接** | 继续使用仓库固定的 HMCL 3.16.4（`fbcc174`）、`vendor/HMCLCore.jar` 和 `backend/corepatch`。复用游戏版本清单、安装修复、加载器、依赖校验、启动参数、三类游戏账号和选用的服务器地址。保留按任务启动 JVM、标准输入一条 UTF‑8 JSON、标准输出 JSON Lines 的进程协议。 [HMCL 固定版本](https://github.com/HMCL-dev/HMCL/releases/tag/v3.16.4) · [桥接源码](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeBridge.java) |
| **下载、整合包、前置补全** | 复用 HMCL 安装任务、Mojang/BMCLAPI 源选择、CurseForge Java 查询和下载候选逻辑。沿用 ZIP／MRPACK 导入、MultiMC 整合包选择性导出、归档校验、递归必需前置、真实 mod ID 与内嵌前置识别。保留下载平台的版本和加载器筛选、哈希校验及失败回滚语义。 [后端目录](https://github.com/ADsurfboard/MC-Harbor/tree/windows/backend/net/morben/shenggan) · [前置补全源码](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeDependencies.java) |
| **实例资源识别** | 复用 `NativeResourceFiles`、`NativeModMetadata`、`NativeWorldImport`，识别模组、资源包、光影、地图和存档。优先使用素材原图、`pack.png`、世界图标及真实平台版本匹配。沿用 Modrinth SHA‑1 与 CurseForge 文件指纹查源。 [实例资源源码](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeResourceFiles.java) |
| **存档编辑和备份** | 复用 NBT 读取和写回、世界与玩家状态字段、未知标签及原数值类型、会话锁、修订校验、原字节备份和回滚逻辑。保留世界名称、模式、时间、难度、生命、饱食、经验等已有编辑字段，覆盖 `level.dat` 和独立玩家文件等已支持结构。 [存档编辑源码](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeWorldEditor.java) |
| **汉化工作区** | 复用语言文件提取、CFPA 社区补全、源文修订、手工草稿、格式校验、AI 模板和译文 ZIP 导入。普通资源产出标准 JSON／LANG 资源包，实际客户端 JAR 的资源包格式号优先。复用 FTB Quests 的 SNBT／JSON5、KubeJS 和数据包的文本提取与应用逻辑，包括进度、Patchouli 书页和命令中的已识别显示文本。 [汉化后端](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeLocalization.java) · [任务与数据包后端](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeTextAssets.java) · [CFPA](https://github.com/CFPAOrg/Minecraft-Mod-Language-Package) · [译库版本索引](https://github.com/CFPAOrg/I18nUpdateMod3) |
| **好友与聊天服务** | 复用 `social-cloud` 的 Workers/D1/Durable Objects 和 `social-server` 的 Python/SQLite 自建服务，以及现有 HTTPS、WebSocket、恢复密钥、分享和邀请协议。服务端无需为 Windows 单独部署。自建服务的身份和好友关系随其服务端保存。 [云端源码](https://github.com/ADsurfboard/MC-Harbor/tree/windows/social-cloud) · [自建服务源码](https://github.com/ADsurfboard/MC-Harbor/tree/windows/social-server) · [服务说明](https://github.com/ADsurfboard/MC-Harbor/blob/windows/docs/SERVICES.md) |
| **皮肤和视觉素材** | 复用本地 `Assets/SkinViewer` 的 `skinview3d`、Three.js、皮肤 UV 和披风渲染，以及原品牌矢量设计、加载器图标、自定义实例和模组图标。保留仓库里四段欢迎 MP3 的原始素材和音量设置，按来源保留相关许可和署名。 [皮肤资源](https://github.com/ADsurfboard/MC-Harbor/tree/windows/Assets/SkinViewer) · [欢迎语音](https://github.com/ADsurfboard/MC-Harbor/tree/windows/Assets/Voice) · [素材来源](https://github.com/ADsurfboard/MC-Harbor/blob/windows/docs/ASSET-PROVENANCE.md) |

## 3. 用 Windows 接口重做的部分

### 3.1 Java、游戏启动和关闭

1. **构建和打包 Java。** 用 Windows x64 JDK 21 编译桥接的 Java 17 字节码，准备 x64 JavaFX 21.0.8 的 base、graphics、controls 三个构件。用 Windows JDK 上的 `jlink` 生成随包运行时，保留 HMCL 原 JAR 及其校验值。ARM64 用对应 JDK 另行构建，验证固定 HMCL 已配置的 `18.0.2+1-arm64` JavaFX 和桥接补丁组合。Windows 11 的 x64 模拟可作过渡兼容性测试，游戏 Java 和原生库的架构配对也要单独验证。 [现有构建脚本](https://github.com/ADsurfboard/MC-Harbor/blob/windows/tools/build-backend.py) · [Temurin 21](https://github.com/adoptium/temurin21-binaries) · [OpenJFX 21](https://github.com/openjdk/jfx21u) · [固定 HMCL 的 JavaFX 配置](https://github.com/HMCL-dev/HMCL/blob/fbcc17472f08e877d60d6b715734e8054e9e61ee/HMCL/src/main/resources/assets/openjfx-dependencies.json) · [Windows ARM 模拟](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation)
2. **适配进程协议。** WinUI 端直接启动 `java.exe`，按参数列表传递 Java 路径、类路径和应用目录。类路径用平台分隔符，补丁 JAR 先于 HMCL 和 JavaFX。异步收取 `progress`、`device`、`accountUpdated`、`launched`、`result` 和 `error` 等事件。单独处理 stderr，记录脱敏的诊断信息。实例启动进入队列时标记进行中，收到 `launched` 后记住对应进程，实际退出时更新运行状态。 [现有启动与桥接实现](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/AppModel.swift#L119-L147) · [进程接口](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo)
3. **适配游戏 Java 选择。** 移除 Windows 路径中的 `/usr/libexec/java_home` 调用，读取显式选用的 `java.exe`、应用和 HMCL 缓存、可用的本机 Java。按实例版本、加载器和架构检查适配条件，未命中时复用 HMCL 的运行时下载。分别对待启动器内置 Java 和 Minecraft 游戏 Java。 [当前选择逻辑](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeBridge.java#L144-L159) · [HMCL 游戏 Java 定义](https://github.com/HMCL-dev/HMCL/blob/fbcc17472f08e877d60d6b715734e8054e9e61ee/HMCLCore/src/main/java/org/jackhuang/hmcl/game/GameJavaVersion.java)
4. **给游戏保存和退出的机会。** 用启动时记录的进程身份查找其主窗口，发送普通关闭请求并等待退出。超时提示回游戏保存或由用户决定是否强制关闭。Java 的 Windows `Process.destroy()` 会调用强制终止，所以普通关闭、启动器退出和任务取消三条路径都要核对。翻译、联机等辅助进程按各自所有权清理。 [现有游戏控制](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeGameControl.java) · [OpenJDK Windows 实现](https://github.com/openjdk/jdk21u/blob/master/src/java.base/windows/native/libjava/ProcessImpl_md.c) · [普通关闭窗口](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.closemainwindow)

### 3.2 Windows 数据目录、实例与文件事务

- **目录和便携模式。** 普通运行使用 `%LOCALAPPDATA%\MCHarbor`。解压版同目录存在 `MCHarbor.portable` 时使用旁边的 `MCHarborData`。提供选择已有游戏目录的入口，并识别 HMCL 自带的共享与工作区配置。分别记录游戏库、每个实例的运行目录和共享库，沿用版本隔离规则与既有存档位置。对旧配置中的绝对路径提供重新定位入口。 [现有目录定义](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/Models.swift#L111-L150) · [HMCL 目录覆盖项](https://docs.hmcl.net/launcher/jvm-options-and-env.html)
- **归档和路径。** Java 和 C# 内部使用原生路径对象。把从可信本机根目录计算出的相对路径转换为 `/` 后再用作 ZIP 条目、跨平台索引或语言路径。收到的外部 ZIP 先校验条目，再解析到目标根内。针对汉化扫描、备份、补丁导出和地图解压验证大小写碰撞、Windows 保留名、盘符、长路径、中文与空格、目录联接点。`NativeLocalization` 和 `NativeTextAssets` 的 `relativize()` 路径，以及 `NativeBridge` 生成备份 ZIP 的路径是明确的改点。 [语言扫描](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeLocalization.java#L43-L50) · [备份 ZIP](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeBridge.java#L199-L210) · [Windows 命名](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file) · [目录联接点](https://learn.microsoft.com/en-us/windows/win32/fileio/hard-links-and-junctions)
- **文件事务。** 下载先进入暂存目录，在提交前校验大小、哈希、来源和目标修订。共享同一运行目录的实例使用同一个写入门槛。文件被游戏、同步软件或其他进程占用时保留原件并提示重试。替换优先在目标同卷暂存，用目标文件系统支持的提交方式处理，测试 `ATOMIC_MOVE` 和覆盖语义。存档与 FTB／数据包继续检查 `session.lock`、制作原始字节备份，在中途失败时回滚已写入项。 [现有资源安装](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/ResourceInstall.swift) · [Java 文件操作语义](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/nio/file/Files.html) · [Windows 文件替换接口](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew)
- **资源管理和系统集成。** 保留本地导入、批量启停、收藏、图标更换、打开目录与项目页。删除前验证实例归属、版本继承与共享目录，调用 Windows 回收站，目标位置无法回收时给出明确结果。用 `.lnk` 指向启动器并传递实例标识，启动器冷启动先恢复数据和扫描实例，热启动把请求转给现有窗口。占用空间通过 Windows 文件分配大小和卷内文件 ID 统计，硬链接去重。 [快捷方式](https://learn.microsoft.com/en-us/windows/win32/shell/links) · [单实例启动](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/applifecycle/applifecycle-instancing) · [回收站标志](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperation-setoperationflags) · [文件分配](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_standard_info) · [文件 ID](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info)

### 3.3 账号、旧版 HMCL 迁移与凭据

| 来源 | 读取和导入方式 |
| --- | --- |
| **旧 HMCL 格式** | 已核对 Windows HMCL 3.15.3，另查过 3.11.1 的同类入口。共享账号取 `%APPDATA%\.hmcl\accounts.json` 的顶层数组，便携账号取 HMCL 工作区 `.hmcl\hmcl.json`、程序旁或工作目录的 `hmcl.json` 的 `accounts`。从用户选定目录或文件读取，参考固定内核的 `LegacyConfigMigrator` 转换字段。采用只读导入入口，避免启动 HMCL 的全局设置写入流程。 [旧版账号文件](https://github.com/HMCL-dev/HMCL/blob/v3.15.3/HMCL/src/main/java/org/jackhuang/hmcl/setting/Accounts.java#L140-L175) · [旧配置发现](https://github.com/HMCL-dev/HMCL/blob/v3.15.3/HMCL/src/main/java/org/jackhuang/hmcl/setting/ConfigHolder.java#L119-L153) · [旧账号转换](https://github.com/HMCL-dev/HMCL/blob/v3.16.4/HMCL/src/main/java/org/jackhuang/hmcl/setting/LegacyConfigMigrator.java#L460-L522) |
| **拆分格式** | 已核对 HMCL 3.16.1–3.16.4。共享目录配对 `config/user-accounts.json` 和 `private/user-account-private-data.json`，工作区配对 `.hmcl/config/accounts.json` 和 `.hmcl/private/account-private-data.json`。尊重手动指定的目录和 HMCL 的 `hmcl.home`／`hmcl.dir` 覆盖。复用 `NativeAccountMigration` 读取私有封装，按账号 ID 配对。现有 `migrate` 命令的 macOS 目录改为明确传入来源。 [HMCL 路径定义](https://github.com/HMCL-dev/HMCL/blob/v3.16.4/HMCL/src/main/java/org/jackhuang/hmcl/setting/SettingsManager.java#L118-L132) · [MC Harbor 导入](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeBridge.java#L246-L254) · [私有数据适配器](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/org/jackhuang/hmcl/setting/NativeAccountMigration.java) |

- 识别同一来源的两种格式时，优先使用能正确配对的新格式记录，再收录尚未迁移的旧账号。离线账号保留昵称和 UUID。Microsoft 保留玩家身份，刷新令牌仍有效且 OAuth 客户端身份兼容时续用，服务明确拒绝时提示用设备码重新登录，临时网络失败提供重试。外置认证保留服务地址、角色和登录身份，以服务地址与角色身份判断重复。凭据缺失或格式不受当前工厂支持时，把可识别的账号标记为需要认证或重新绑定。Windows 7／8.1 旧电脑上的 HMCL 文件也可以复制到支持的 Windows 系统后，通过同一流程导入。 [Microsoft 刷新令牌](https://learn.microsoft.com/en-us/entra/identity-platform/refresh-tokens) · [HMCL OAuth 实现](https://github.com/HMCL-dev/HMCL/blob/v3.16.4/HMCLCore/src/main/java/org/jackhuang/hmcl/auth/OAuth.java#L169-L220) · [外置登录工厂](https://github.com/HMCL-dev/HMCL/blob/v3.16.4/HMCLCore/src/main/java/org/jackhuang/hmcl/auth/authlibinjector/AuthlibInjectorAccountFactory.java#L65-L103)
- Windows 新保存的会话、好友恢复密钥、Sakura 密钥和翻译密钥写入当前用户 DPAPI 保护的存储。普通账号列表保留显示元数据，凭据经 Java 与客户端的管道处理。写入成功后更新账号索引，重复导入沿用已有身份并按结果更新。导入回执记录来源和结果，原 HMCL 文件作为只读输入，常规日志、导出包和迁移回执仅记录脱敏内容。便携数据移到新机器后由用户重新认证或通过对应服务恢复凭据。 [DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata) · [.NET ProtectedData 源码](https://github.com/dotnet/runtime/tree/main/src/libraries/System.Security.Cryptography.ProtectedData)

### 3.4 客户端页面、资源下载与皮肤

- **窗口和导航。** 参照 `LauncherViews`、`Pages`、`InstanceWorkspace` 和设置搜索，重建游戏、下载、模组夹、账号、联机、好友、设置及汉化工作区。保留多选、键盘操作、输入法、拖放 ZIP／MRPACK、进度和取消、前景弹层、窗口恢复、实例详情和可缩放对照编辑。列表使用虚拟化，缩略图与语言数据在后台解码，只按批次更新界面。 [现有客户端](https://github.com/ADsurfboard/MC-Harbor/tree/windows/Sources) · [WinUI Gallery](https://github.com/microsoft/WinUI-Gallery) · [窗口管理](https://learn.microsoft.com/en-us/windows/apps/develop/ui/manage-app-windows)
- **下载和模组夹。** 按 `ModDiscovery`、`ResourceMirror`、`ResourceServices`、`ResourceInstall` 和 `ModCollections` 移植客户端编排。Mojang、BMCLAPI、MCIM、Modrinth、CurseForge 按原配置选择顺序和回退。保留双语搜索、离线中文名索引、简介翻译、分类、推荐、个人备注及原文预览。游戏中允许暂存下载，应用等目标运行目录空闲。本地收藏存独立副本并按内容哈希去重，在线收藏存项目 ID 并在导入时匹配目标版本和加载器。下载文件校验后批量提交，冲突交给原有事务处理；CurseForge 下载限制沿用平台返回的结果。 [模组发现说明](https://github.com/ADsurfboard/MC-Harbor/blob/windows/docs/MOD-DISCOVERY.md) · [模组夹源码](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/ModCollections.swift) · [Modrinth API](https://docs.modrinth.com/api/) · [CurseForge API](https://docs.curseforge.com/rest-api/)
- **皮肤。** WebView2 用虚拟主机映射加载本地预览页，限制页面导航范围，只向页面传入皮肤、披风及预览状态。保留标准与纤细模型、头像、暂停动画和释放 WebGL 资源的行为。LittleSkin 继续支持公开皮肤搜索、排序、翻页和收藏，下载先核对 SHA‑256 与 PNG 尺寸。更换皮肤沿用 `NativeProfiles`，由账号能力决定本地应用或上传。运行时检测 WebView2 可用性，缺失时提供安装入口并保留静态头像。 [原皮肤实现](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/Skins.swift) · [LittleSkin 源码](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/LittleSkin.swift) · [WebView2 示例仓库](https://github.com/MicrosoftEdge/WebView2Samples) · [本地资源加载](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/working-with-local-content)

### 3.5 好友客户端和联机

| 功能 | Windows 实现与参考 |
| --- | --- |
| **好友与聊天** | 用 Windows 客户端重写好友页和聊天页，按现有 HTTPS 与 WebSocket 契约对接原服务。保留好友码与恢复密钥、申请确认、撤销分享、离线未读、按好友区分草稿和聊天、断线重连与轮询回退、重试复用消息 ID。好友皮肤和游玩历史由用户开启共享。记录现有邀请的三类目标及有效期。 [服务协议说明](https://github.com/ADsurfboard/MC-Harbor/blob/windows/docs/SERVICES.md) · [当前好友客户端](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/Friends.swift) · [当前聊天客户端](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/Chat.swift) |
| **直接加入服务器** | 保留地址验证、选择兼容实例和 Minecraft Quick Play 请求。对接收到的邀请可打开联机页并填入目标，由玩家选实例和加入。 [启动桥接](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeBridge.java#L160-L173) |
| **陶瓦房间** | 从上游选 Windows x64 或 ARM64 的正式包，按上游清单验证归档和包内的 `.exe`、运行时 DLL。参照 HMCL 的 `--hmcl` 临时文件握手取端口，控制请求限本机回环。复用房间创建、加入、状态、日志和退出协议。进程归属随启动记录，只结束本客户端管理的进程。测试公网 NAT 和公共节点，记录实际连通条件。 [陶瓦正式包](https://github.com/burningtnt/Terracotta/releases/tag/v0.4.2) · [HMCL 启动示例](https://github.com/HMCL-dev/HMCL/blob/fbcc17472f08e877d60d6b715734e8054e9e61ee/HMCL/src/main/java/org/jackhuang/hmcl/terracotta/provider/GeneralProvider.java) · [HMCL 包文件清单](https://github.com/HMCL-dev/HMCL/blob/fbcc17472f08e877d60d6b715734e8054e9e61ee/HMCL/src/main/resources/assets/terracotta.json) · [EasyTier](https://github.com/EasyTier/EasyTier) |
| **Sakura Frp 隧道** | 用官方 Windows `frpc.exe` 替代 Mac 客户端，依据官方元数据选架构并校验体积与摘要。保留 LAN 端口输入或日志识别、节点选择及 TCP 隧道流程。用当前用户可访问的 ACL 写临时配置，进程结束后清理，等成功状态再展示地址。用用户自己的 Sakura 密钥和节点验证。 [MC Harbor Sakura 实现](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/Multiplayer.swift) · [Sakura 官方 Windows 文档](https://doc.natfrp.com/frpc/usage.html) · [Windows ACL](https://learn.microsoft.com/en-us/windows/win32/secauthz/access-control-lists) |

### 3.6 发布、安装和卸载

- **首发包。** Windows x64 便携 ZIP 包含对应架构的客户端、JDK、JavaFX、后端 JAR 和便携标记。启动时检测 Windows App SDK 与 WebView2 运行时等依赖。用同一发行 ZIP 验证解压启动、覆盖升级、快捷方式和用户数据保留。 [发布方式比较](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/choose-distribution-path) · [WebView2 分发](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)
- **安装版参考。** MSIX 路线参考微软的打包、签名与更新流程。需要传统安装器时，通过 WiX 生成 MSI，分别验证首次安装、升级、卸载、快捷方式和用户数据处理。两种安装方式都用 `%LOCALAPPDATA%\MCHarbor` 保存普通应用数据。 [Windows 打包文档](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/choose-distribution-path) · [WiX Toolset](https://github.com/wixtoolset/wix)
- 发布记录保留对应源码、上游固定版本与摘要、第三方通知。核对 MC Harbor/HMCL GPL、WinHarbor 与皮肤预览的 MIT 声明、运行时许可证、CFPA 社区译文的署名和许可条件，以及陶瓦原二进制 IPC 的上游条款和可见署名。选择随包分发模型或媒体组件时，一并记录它们的权重或二进制来源与许可。 [第三方声明](https://github.com/ADsurfboard/MC-Harbor/blob/windows/THIRD_PARTY_NOTICES.md) · [许可目录](https://github.com/ADsurfboard/MC-Harbor/tree/windows/Licenses) · [陶瓦上游许可说明](https://github.com/burningtnt/Terracotta/blob/master/LICENSE)

## 4. Windows 平替实现与参考仓库

### 4.1 玻璃、光学动效与系统图标

与 macOS 参考图对齐的窗口布局、窗口内左上三色按钮、透明 3D 皮肤、视频壁纸合成和验收条件见 [Windows x64 视觉还原计划](_upstream/docs/WINDOWS_VISUAL_PLAN.md)。

| 实现范围 | 方法与参考 |
| --- | --- |
| **首版玻璃采用 Mac Intel 版的窗口内磨砂** | WinUI 3 的 `AcrylicBrush` 用于模糊窗口内的壁纸和叠层，在其上叠主题色和清晰文字。保留亮暗主题、主题反色、三层叠片、0–100 通透度、毛玻璃开关和减少动态效果。滑杆映射到透明度与染色。可调模糊半径可通过 Composition／Win2D 对背景加高斯模糊实现。系统降低透明度或使用高对比主题时采用相应实色。Mica 可作为 Windows 11 窗口底色参考。 [Intel 版材质](https://github.com/ADsurfboard/MC-Harbor/blob/codex/intel-release/Sources/FrostedSurface.swift) · [WinUI Gallery](https://github.com/microsoft/WinUI-Gallery) · [窗口内 Acrylic](https://learn.microsoft.com/en-us/windows/apps/develop/ui/in-app-acrylic) · [Win2D](https://github.com/microsoft/Win2D) |
| **动态折射的扩展实现** | 用 Direct2D 或 Win2D 的独立渲染层处理启动器自己的图片／视频帧，对圆角材质遮罩内的背景做局部位移、模糊、边缘高光与按压响应。文字放在前景，几何状态、粒子和动效参照原界面。用动效暂停、缓存和纯磨砂降级控制开销，验收时比较壁纸和游戏同时运行时的帧时间。原版 1.6.2 已移除彩虹角。 [Apple Silicon 材质源码](https://github.com/ADsurfboard/MC-Harbor/blob/codex/apple-release/Sources/HarborTheme.swift) · [同源设计参考 WinHarbor](https://github.com/ADsurfboard/WinHarbor) · [Direct2D 位移效果](https://learn.microsoft.com/en-us/windows/win32/direct2d/displacement-map) · [视频帧合成入口](https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer.copyframetovideosurface) |
| **首版系统图标采用 Fluent System Icons** | 使用 MIT 授权的图标，按操作用途映射下载、目录、存档、账号等入口。项目品牌、加载器和资源原图继续沿用。系统图标可按原用途和视觉风格自绘扩展。用 Windows 焦点、缩放和高对比状态验收。 [Fluent System Icons](https://github.com/microsoft/fluentui-system-icons) · [SF Symbols 原风格参考](https://developer.apple.com/sf-symbols/) |

### 4.2 壁纸、欢迎播报和界面音效

- **首版使用 Windows 原生解码。** 壁纸库保留导入、命名、预览和缩略图。图片用 WinUI 图像控件显示，视频用 `MediaPlayerElement` 静音循环播放，缩略图用系统媒体接口后台生成。以 MP4／H.264 作为首轮验收格式，其他文件按系统实际解码能力识别。记录受管理的副本，删除条目只操作该副本。动态背景在最小化、减少动态效果或性能模式下根据原行为暂停。扩展格式覆盖时，参考 FFmpeg 把旧视频转成兼容副本，保留原文件并支持取消转码。 [原壁纸库](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/WallpaperLibrary.swift) · [Windows 媒体播放](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/media-playback) · [编码支持](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/supported-codecs) · [FFmpeg](https://github.com/FFmpeg/FFmpeg)
- 欢迎动画用 WinUI／Composition 的时间线和过渡重做，四段原 MP3 按原音播放。界面音效从 JDSherbert 官方 FREE 包取得，复用现有 Python／FFmpeg 脚本生成 `Interface.soundbank`，新客户端按原事件、音量和开关播放。成品内嵌音效银行并署名，源码交付记录获取和构建方法。若发行时选用其他音效，保留原有的事件对应关系和音量开关，可用自有录音或授权素材替换，也可让用户选择静音。 [欢迎页面](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/Welcome.swift) · [音效银行脚本](https://github.com/ADsurfboard/MC-Harbor/blob/windows/tools/make-soundbank.py) · [素材包](https://jdsherbert.itch.io/ultimate-ui-sfx-pack) · [作者条款](https://jdsherbert.itch.io/terms-and-conditions)

### 4.3 Apple Translation 离线补译

首版的机器补译默认用 **OPUS‑MT + CTranslate2 INT8**，权重按需下载。沿用原工作区流程，先取资源内中文、CFPA 社区译文和匹配的本机缓存，再调用翻译引擎。已有人工译文优先。长文本按合适边界分段，将占位符、颜色码、链接、任务／物品 ID 等交给现有保护逻辑，回填时复查原文修订和格式。批量保存已完成项，失败或取消的条目保留为待翻译。中文模组搜索先用本地名称索引，未命中时可通过反向模型翻译。 [工作区分批保存](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/LocalizationWorkspace.swift#L106-L155) · [原格式保护](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/LocalTranslation.swift) · [模组搜索说明](https://github.com/ADsurfboard/MC-Harbor/blob/windows/docs/MOD-DISCOVERY.md)

| 方案 | 实现与适用范围 |
| --- | --- |
| **在线补译作为手动来源** | 移植现有 HTTP 接口与超时、重试、取消流程。保留 B 站 Index‑Translate 和用户自备密钥的 Qwen‑MT，MyMemory 与 Google 公共接口为手动备选。按用户选择的服务发送待译文本，显示数据去向和失败状态。 [Index‑Translate 仓库](https://github.com/bilibili/Index-Translate) · [Qwen‑MT](https://help.aliyun.com/zh/model-studio/qwen-mt-api) · [现有在线实现](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/LocalTranslation.swift) |
| **轻量离线，OPUS‑MT + CTranslate2 INT8** | Windows x64 优先验证。下载或转换固定版本的英译中模型，配对应 tokenizer，按需启动纯 CPU 进程，针对简体中文输出设置目标语言。适合物品名、短提示和少量简介。需要离线处理中译英搜索时再接反向模型。针对项目词表比较译文和占位符通过率。公开 benchmark 的语言对和硬件与本项目不同，Windows 吞吐和峰值内存由实测填写。 [OPUS‑MT](https://github.com/Helsinki-NLP/OPUS-MT-train) · [英译中模型](https://huggingface.co/Helsinki-NLP/opus-mt-en-zh) · [中译英模型](https://huggingface.co/Helsinki-NLP/opus-mt-zh-en) · [CTranslate2](https://github.com/OpenNMT/CTranslate2) · [OPUS‑MT 转换说明](https://opennmt.net/CTranslate2/guides/opus_mt.html) |
| **进阶离线，Index‑Translate 2B + llama.cpp** | 已接入为按需可选引擎。用户确认后通过 WinGet 安装 llama.cpp，并从固定模型提交下载 Q4_K_M 权重（1,312,164,352 字节），以官方 SHA‑256 清单校验后运行。仅监听 `127.0.0.1`，CPU 推理使用两个线程和低于正常的进程优先级；游戏运行时暂停并在退出后续跑。当前尚未测量目标硬件吞吐、峰值内存和游戏帧时间，也未完成完整模组文本的译文审校。 [2B 模型卡与 Windows 用法](https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF) · [固定版本 SHA‑256 清单](https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/blob/0a622669d15a139787818187e6263d19e4a1ffb5/SHA256SUMS.txt) · [llama.cpp 服务参数](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) |
| **Edge 本机翻译实验** | 官方 Translator API 可在 Edge 下载语言模型后本机运行。若尝试在启动器内复用，需先在拟发行的 WebView2 Runtime 上验证 API 暴露、目标语言对、首次下载、离线恢复和兼容范围，再决定是否列入支持矩阵。 [Edge Translator API](https://learn.microsoft.com/en-us/microsoft-edge/web-platform/translator-api) · [WebView2 示例](https://github.com/MicrosoftEdge/WebView2Samples) · [Edge 与 WebView2 差异](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/browser-features) |

游戏运行期间默认使用 **帧率优先**。低优先级边玩边译在通过实机性能验收后作为可开启选项。

- **帧率优先。** 游戏启动前暂停派发推理，保存已完成译文和任务进度，释放模型占用。游戏中可立即展示已有中文、缓存和已保存结果。游戏退出后从未译项续跑。
- **允许边玩边译。** 小批短句用独立低优先级进程、单 CPU 推理线程、CPU 模式运行。按需评估为该进程加 Windows Job Object CPU 上限。游戏启动阶段、可检测的加载阶段或可用内存吃紧时停止派发，已完成批次保存，长文与整包扫描等待空闲。模型首次下载、加载和缓存写盘也纳入性能评估。 [Windows 后台进程调度](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setpriorityclass) · [CPU 限额](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_cpu_rate_control_information) · [CTranslate2 线程控制](https://opennmt.net/CTranslate2/parallel.html)

启动器里可以逐批看到新译文。游戏内普通语言文本通过资源包启用或资源重载生效，提示玩家在合适时机操作。FTB 任务与存档数据包可以先生成译文，按现有流程在世界关闭后备份和应用。若以后需要把游戏中刚出现的聊天或提示逐条即时回显，另行设计 Fabric／NeoForge 游戏端 Mod 的异步接入。 [Minecraft 资源重载](https://help.minecraft.net/hc/es-mx/articles/360059148111-Hotkeys-in-Minecraft-Java-Edition) · [游戏语言资源格式](https://docs.neoforged.net/docs/1.21.10/resources/client/i18n/) · [数据包写回锁](https://github.com/ADsurfboard/MC-Harbor/blob/windows/backend/net/morben/shenggan/NativeTextAssets.java#L156-L169)

### 4.4 Mac 到 Windows 的会话切换

Mac 用户迁移到 Windows 后仍可用原恢复密钥续接好友身份，Sakura 与翻译密钥按原服务重新输入。Windows 上已有的 HMCL 账号可按第 3.3 节只读导入两代文件格式。对于 MC Harbor 已授权读取的 Mac Microsoft 与外置认证账号，账号页面会按用户选择把 HMCL 凭据写入 AES‑GCM 加密迁移包。包使用 PBKDF2‑SHA256 派生密钥，口令仅用于导出和导入。Windows 导入端解密后将凭据转入 DPAPI 当前用户保护的数据目录，并保留 HMCL 账号标识和角色数据。迁移不包含 Friends、Sakura 或翻译服务密钥。微软令牌刷新结果仍由认证服务决定，认证失败时可在 Windows 端重新登录。 [Mac 钥匙串读取实现](https://github.com/ADsurfboard/MC-Harbor/blob/windows/Sources/AppModel.swift#L201-L221) · [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services) · [好友恢复密钥](https://github.com/ADsurfboard/MC-Harbor/blob/windows/docs/SERVICES.md)

## 5. 实施顺序与阶段验收

### 当前实现状态

Windows x64 已形成可编译并可生成便携 ZIP 的 WinUI 客户端。游戏库、HMCL 版本与加载器管理、HMCL 账号导入、Microsoft 与外置登录、离线账号、实例 Java 和运行目录设置、资源市场与模组夹、地图与存档 NBT、汉化工作区、OPUS-MT INT8 与 Index-Translate 2B 本机补译、在线补译、好友及聊天、服务器直连、Terracotta、Sakura、皮肤、主题、壁纸、欢迎语音、快捷方式与本地游玩记录已经接入相应页面。Mac 在线游戏账号的加密迁移导入与导出入口已写入客户端。

Windows 10 22H2 x64 已确认便携包窗口启动、单实例重复启动转发与正常关闭。隔离实例通过固定 HMCL 后端安装 Minecraft 1.20.1、自动选择 Java 17 并成功显示 Minecraft 窗口。后端完成 NBT 与语言资源数据夹具验证。此状态不等于所有服务账号、跨公网联机、Windows 11、Apple Keychain 迁移回环或翻译对游戏帧时间的性能测试已经通过。Index‑Translate 2B 已接入但仍需完成运行时、模型下载、真实文本与硬件性能验收；动态折射效果、完整界面音效、MSIX／MSI 和 ARM64 继续列为后续工作。

| 阶段 | 工作与可验收结果 |
| --- | --- |
| **一、打通 Java 链路** | 固定分支与依赖，先验证 Windows x64 上的无窗口桥接、UTF‑8 协议、Java 自动选择和窗口正常退出。在隔离目录由同一条链路安装一个原版实例，离线启动，进入测试世界、保存退出、再次进入验证。再用一个加载器实例验证原生依赖和错误回报。 |
| **二、交付启动器基本操作** | 接入最小 Windows 壳、游戏库、任务与下载、账号、设置和安全存储。实现三类账号、两代 HMCL 导入、实例目录选择、快捷方式、原版和加载器安装、退出后提交下载。验证真实启动和导入回环。 |
| **三、补齐资源、汉化与存档** | 接回下载搜索、模组夹、整合包、资源管理、NBT 编辑、汉化工作区和 FTB／数据包。先验收社区补全和人工编辑，再接入轻量离线与手动在线补译。用文件占用、坏归档、路径冲突和中途失败夹具验证原状态可恢复。 |
| **四、恢复完整视听与服务** | 加入皮肤、好友、聊天、直连、陶瓦与 Sakura，完成窗口内磨砂、Fluent System Icons、原生壁纸和声音。以两台设备验证房间和跨系统好友流程，测量玻璃、壁纸和翻译同时启用时的开销。 |
| **五、发行验收** | 在 Windows 10 22H2 x64 和 Windows 11 x64 的干净用户环境验证便携 ZIP。检查首次运行、升级、快捷方式、游戏和存档回环。为安装版保留安装、更新与卸载用例。记录实际通过验收的系统、架构、游戏版本、加载器和可选组件。 |

### 实机与回归验证

| 验证项 | 覆盖场景 |
| --- | --- |
| **启动和关闭** | 覆盖待发布架构、原版与所支持的主要加载器、不同游戏 Java 需求、官方与镜像回退、多个实例并行及窗口关闭后的存档保存。用真实游戏验证关闭行为，协议夹具用于测试任务状态和异常。 [已有启动检查](https://github.com/ADsurfboard/MC-Harbor/blob/windows/tools/check-game-launch.py) · [加载器检查](https://github.com/ADsurfboard/MC-Harbor/blob/windows/tools/check-loader-install.py) |
| **现有数据导入** | 用两代 HMCL 隔离夹具及用户指定的自定义目录，验证离线 UUID、不同外置服务、微软会话成功续用／需要重新登录、重复导入、缺失凭据及原 HMCL 文件保持原样。实机联网只用明确用于验收的账号、好友身份和节点。 [HMCL 迁移测试](https://github.com/HMCL-dev/HMCL/blob/v3.16.4/HMCL/src/test/java/org/jackhuang/hmcl/setting/LauncherSettingsMigrationTest.java) |
| **写盘与回滚** | 用 NTFS 和计划支持的便携介质，验证资源启停、跨盘导入、目录联接、同名 ZIP 条目、共享运行目录、占用文件与中途失败。检查原文件字节、备份完整性、`session.lock` 和多实例间隔离。 [存档检查](https://github.com/ADsurfboard/MC-Harbor/blob/windows/tools/check-world-editor.py) · [资源检查](https://github.com/ADsurfboard/MC-Harbor/blob/windows/tools/check-instance-resources.py) |
| **汉化与游戏性能** | 用短物品名、长 FTB 文本、占位符和格式码夹具对比已有译库、轻量模型与 2B 的产出。分别测冷启动、缓存命中、热模型短句 P95、整包吞吐、峰值内存。固定整合包、场景、画质和显卡设置，比较关闭翻译、限速补译和退出续译，记录 P99 帧时间、帧时间尖峰、CPU／显存及占用内存。以实测结果校准默认线程、限额和自动暂停条件。 [汉化检查](https://github.com/ADsurfboard/MC-Harbor/blob/windows/tools/check-language-pipeline.py) · [任务与数据包检查](https://github.com/ADsurfboard/MC-Harbor/blob/windows/tools/check-text-assets.py) · [PresentMon](https://github.com/GameTechDev/PresentMon) |
| **界面、联机与分发** | 验证不同 DPI、键盘与中文输入、深浅色、减少动效、关闭透明度、多显示器、壁纸编码和 WebView2 缺失场景。验证 Mac 与 Windows 好友互通、不同网络的陶瓦房间、Sakura 隧道和终止清理。对干净安装与更新测一遍运行时、配置路径、快捷方式和卸载。 [WinUI 示例](https://github.com/microsoft/WinUI-Gallery) · [陶瓦验证参考](https://github.com/ADsurfboard/MC-Harbor/blob/windows/tools/check-terracotta.py) |

当前证据来自源码、上游发行记录、官方接口文档与工作机信息。Windows 安装启动、账号会话续用、视觉效果、翻译并发和 ARM64 均需完成上述实机验证后才能写入发布说明。
