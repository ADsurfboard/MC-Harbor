# 技术说明

`LauncherViews / Pages / InstanceWorkspace` 为原生界面；`HarborTheme / WallpaperView / Components` 为真实 WinHarbor 适配；`Optics / Audio / Welcome / Presentation` 为光学、声音与过渡；`Models / AppModel` 处理偏好、扫描、任务和 Keychain；`Migration / ContentActions / Addons` 处理迁移与文件事务。

原 HMCL 稳定 JAR 不改写，classpath 前置 Task / Scheduler / ObservableCache / AuthlibInjectorServer 补丁，只在 `shenggan.headless=true` 时直接分派。认证、依赖、下载、启动复用原内核。按需启动 JVM，空闲主界面不常驻 JVM。

标准输入一条 JSON，stdout 紧凑 JSON Lines，必须 UGLY_GSON。stderr 不混入协议。下载前初始化 CacheRepository。凭据不写 UI、日志或交付包。

App 内带精简 JDK 21，游戏按实例最小 Java 版本选择系统和 HMCL 缓存；Mojang JRE release 文件缺字段时回退 JavaInfoUtils.fromExecutable，原 Java 25 运行时已识别验证。

迁移读取本地 .hmcl 与共享 HMCL/config、HMCL/private，使用原账户保护适配器；身份元数据存 JSON，完整会话写当前 Mac Keychain。更新先 SecItemUpdate，避免先删旧凭据。迁移快照目录 0700、文件 0600。原游戏以目录接入，保留隔离、运行路径、UUID 与共享库。

偏好默认合并旧 JSON，串行队列合并写盘。模组开关仅重命名 .disabled 并更新元数据，不为每次点击起 JVM。本地导入先暂存、冲突检查、整体提交与回滚；删除进系统废纸篓。

Modrinth 与 CurseForge 按版本 / 加载器过滤、递归必要依赖，SHA-512 / SHA-1 / MD5 验证后整体提交。真实 mod ID 识别手动改名的旧模组，被替换件保存在实例 .harbor/previous，收据 .harbor/modrinth-installed.json。CurseForge API 身份沿用原稳定内核，只发送给官方 API 域；作者关闭直接下载时不猜测 CDN 地址。

DownloadCenter / ResourceServices / ResourceInstall 共用搜索、版本、计划与下载事务。地图 ZIP 隔离解压，检查入口、大小、CRC 和路径后移入 saves；整合包调用原 ModpackHelper / InstallTask，避免覆盖已有实例。取消会停止 URLSession 与后端进程。

Skins / AccountCenter 从原 Account 接口获取真实皮肤与披风；NativeProfiles 复用 Mojang / Yggdrasil 上传，OfflineAccount.setSkin 保留本地游戏皮肤链。原 Account.invalidate 增加 headless 条件分派。HMCL 新账户 ID 带 account: 前缀，离线回退规范化该元数据但不改 Keychain 主键。

skinview3d 3.4.2 bundle 与 MIT 许可证随包。WKWebView 只加载本地网页与 data PNG，无网络权限或凭据；默认停止渲染循环，OrbitControls 的 change 合并至一帧，避免同步 render 的重入。销毁页面释放渲染器，后台 / 减少动态效果时暂停运动。

实例资源由 NativeResourceFiles 统一读取：Forge / Fabric / Quilt 元数据声明的 logo、pack.png、世界 icon.png 优先；经 ImageIO 头部尺寸限制后缓存，SwiftUI 异步缩略。无图标才回退系统符号。SHA-1 批量调用 Modrinth version_files，CF 指纹为排除空白后的 MurmurHash2，精确匹配项目后才提供来源，未匹配置灰。来源索引按修订与一日 TTL 缓存。

NativeLocalization 提取所有语言原字节至私人工作区，扫描已下载的原版语言对象、JAR / ZIP / 文件夹及 KubeJS / resources。原文件只读；手动草稿与条目分开持久化。CFPA 官方发布整包按 I18nUpdateMod3 元数据选版本 / 加载器，限流下载并校验 MD5。社区补全只填缺失 / 无效译文，保留已有中文与手工内容。源包包含相关完整许可文本。

汉化输出合并所选命名空间，校验 printf 与命名占位符，支持旧 LANG / 新 JSON；实际客户端 version.json 中的 pack_version 优先决定格式号，新版写 min_format / max_format。AI 模式生成英文模板、逐资源原始 lang 与语言目录，不混入用户绝对路径。ZIP 暂存后逐项 CRC 校验再落盘，不覆盖已有文件。原生编辑器支持全部 / 部分选择、过滤、手动编辑、译文 ZIP / JSON / LANG 导入、命名导出。

欢迎播报固定使用用户提供的 Clara MP3 原字节，不变速或变调；旧 WAV 从新 App 中移除。App 只有一份 bundled AppIcon.icns，取消 NSApp.applicationIconImage 运行时覆盖，构建升级注册当前 /Applications 路径，避免开 / 关使用不同资源。所有自定义按钮的 contentShape 放在最终 frame / padding 之后；卡片更多按钮为覆盖层中的独立控件，避免嵌套 Button。

世界备份检查 session.lock、前后文件快照和 ZIP CRC。导出调用原 MultiMCModpackExportTask，验证 manifest / CRC 后原子落盘，不向实例内部递归导出或覆盖已有目标。

ARM64 App 内含 Backend、原内核、固定三个 OpenJFX JAR、Runtime、加载器图标、欢迎语音与打包音效，由内到外临时签名并严格验证。源包排除用户数据与受限音频素材；保留旧 bundle ID / 数据目录只为兼容，所有可见品牌为 MC Harbor。

1.4.0 运行优化不改变视听配置：资源索引以本地 / 网络两个批次发布，避免每个条目触发整窗更新；原图与缩略图用带文件修订的有界 NSCache 复用，原壁纸不重采样。语言条目 JSON 在后台解码，初次扫描避免重复 langRead；视频 play / pause 和流体颜色仅状态改变时提交，既有轨迹、时长、粒子数、shader、音效 bank 与原 MP3 均保持。

内标为标准 h 的原生矢量轮廓，无底、白色折面；主应用继续使用黑磨砂 PNG / ICNS。全名 MC Harbor，界面简称 MC Harbor；bundle ID、Keychain 服务和原数据目录保留。通透度负区间使用背景扩散，raw >= 0 的既有参数不变；系统“减少透明度”继续优先。


1.4.0 存档编辑使用原 HMCL 内含 org.glavo NBTCodec，读写 gzip / zlib / raw 原压缩类型，保留未知 tag 与 numeric 类型。level.dat / Player、playerdata UUID、26.x players/data 分离结构均走统一快照；session.lock 贯穿每次读写，revision SHA-256 检测陈旧表单。保存前生成逐字节 metadata ZIP 并验证；暂存序列化回读一致后写回，失败时补偿。备份位于应用数据 backups/world-edits，不复制整个 region；完整存档备份入口保留。

前置补全由 completeDependencies 布尔偏好控制，默认 false，位于原 launch 的认证 / 游戏启动之前。NativeModMetadata 解析 Fabric / Quilt JSON、Forge / NeoForge TOML、旧 mcmod.info、声明内嵌 jars / JarJar 及 provides，客户端必需项与可选项分开；版本语法不能确认时明确停止。NativeDependencies 按已安装文件 SHA-1 / CF 精确指纹获得平台版本，再递归处理 required；未映射的本地必需 ID 查询候选后，必须下载并验证实际 mod ID / 版本 / loader，不凭名称安装。全部候选先暂存并验证大小 / 哈希 / 元数据，原文件快照未变后优先以 createLink 原子加入新 JAR（不支持硬链接的卷退回不覆盖的 move），不覆盖现有路径；提交失败撤回已新增项。检查重复补全锁、同实例游戏进程、停用文件和不兼容版本；最多 60 新前置 / 80 候选，私有已校验缓存 384 MB 上限。没有发布元数据或下载受限的前置会明确报出，不能承诺任意私有包自动完整。

磨砂改用 NSVisualEffectView popover / withinWindow 原生扩散，清除负区间逐渐加深的填充；最低端保留柔化色块，文字前景不参与模糊并调整对比。正通透区间的既有 Glass 分支、三层叠片、Metal 色散、流体、视频、粒子和声音仍保留。CALayer.backgroundFilters 的早期独立试验在 SwiftUI 层级中未生效，已排除，未作为产品结果。

API 依据：[Apple NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)、[Modrinth versions from hashes](https://docs.modrinth.com/api/operations/versionsfromhashes/)。软件所有可见名称统一 MC Harbor；原数据身份保持兼容。
