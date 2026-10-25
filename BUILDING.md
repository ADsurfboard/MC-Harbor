# MC Harbor

1.4.0 · Apple Silicon · macOS 26 及以上，本机 macOS 27 验证。

原生 SwiftUI / AppKit，采用用户提供的真实 WinHarbor 主题、壁纸与交互组件，系统 Liquid Glass 材质；HMCL 3.16.4 稳定内核处理认证、下载、依赖和游戏启动。

软件显示名称统一为 **MC Harbor**，H 大写。

## 功能

- 游戏库、原 HMCL 加载器图标、收藏、搜索、实例设置、依赖修复。
- 可视化模组名称 / ID / 版本 / 作者 / 大小、搜索排序、多选、批量启停、拖放导入与废纸篓删除。
- Modrinth / CurseForge 资源中心：模组、资源包、光影、地图与整合包；版本与加载器筛选、必要依赖、哈希、原子提交、旧版本备份和失败回滚。地图来源为 CurseForge，整合包独立导入新实例。
- 原生存档编辑：名称、游戏模式、难度、作弊 / 极限、天数与日内时间、累计时间、生命、饱食度、饱和度、经验等级 / 进度；主玩家与 UUID 文件同步。修改前自动保存原字节备份，取得会话锁并检查修订，保留未知模组标签。
- 可选“前置补全”：设置 → 运行中开启，默认关闭。启动前递归检查必需前置，按 Minecraft / 加载器 / 版本范围验证并补入，再启动；不自动启用停用项或覆盖冲突模组，失败时停止启动并说明原因。
- 存档、截图、日志；世界备份、真实 MultiMC 整合包导入 / 导出。
- 官方 / BMCLAPI 自动源、重试、校验、缓存、游戏 Java 版本选择与运行时复用。
- 原 HMCL 共享账户迁移，Microsoft / 第三方认证 / 离线身份，凭据存 macOS 钥匙串。
- 真实 Minecraft 皮肤头部头像；skinview3d 三维角色预览、拖拽旋转 / 行走，导入 PNG 后预览并应用。在线身份调用原认证服务上传，离线身份复用 HMCL 本地皮肤机制。
- 三层磨砂叠片、−100…+100 通透度（最低档为保留柔和背景色块的密磨砂）、全局彩虹角开关、主题调色盘、图片 / 视频背景。
- 粒子欢迎、可设用户名、用户提供的 ElevenLabs Clara 原音播报、JDSherbert 立体声界面音效。
- 弹层弹簧过渡、背景渐变模糊、合成器流体；减少动态效果与低电量适配。
- 标准折面 h 改为透明背景原生矢量图标，App / Finder / Dock 使用唯一 HarborMark.icns；不烘焙黑色底框，外围由 macOS 呈现。内部继续使用无底白色 h；彩虹角保留小范围、低饱和边缘色散。

- 实例资源保留原图标；按文件哈希 / 指纹索引 Modrinth / CurseForge 原页面，未匹配的来源按钮置灰。实例可更换图标并恢复默认。
- 原生实例资源汉化：读取本体、模组、资源包、KubeJS / resources 语言文件，全部 / 部分选择、对照编辑、草稿保存、社区补全、AI 原文打包和译文回导。新增 FTB Quests 核心任务文本（旧 SNBT、新 JSON5 / 独立语言表）与存档数据包的说明、书页和指令文字组件。普通 lang 使用资源包；任务 / 数据包已有译文通过“应用任务 / 数据包”校验后备份写回，失败回滚。原 JAR 不改，未翻译项保留原文并计数。
- 按钮按完整外形命中；实例更多按钮为 38pt 圆形，下载搜索结果整个圆角矩形可选。Dock 与 Finder 统一使用 bundled ICNS，运行时不覆盖图标。

## 数据

迁移先备份 HMCL 配置，再接入原游戏目录，避免两份世界分叉。原 JAR、游戏、模组、存档均保留；保留账户 UUID 和已有会话，过期会话仍须正常刷新或登录。

默认数据沿用 `~/Library/Application Support/ShengganLauncher`，兼容旧开发版。普通账户 JSON 不含令牌。便携模式在应用旁放空文件 `MCHarbor.portable`，使用旁边 `MCHarborData`；旧标记兼容。跨 Mac 使用需要重新授权账户。

## 构建

需要 Apple Silicon Mac、支持 macOS 26 SDK 的 Xcode 工具、Python 3、JDK 21；转换声音另需 FFmpeg。

源包 `vendor/HMCLCore.jar` 为原稳定版，`vendor/javafx` 固定三个 OpenJFX 21.0.8 macOS ARM64 JAR，`upstream/HMCL-3.16.4-source.tar.gz` 为原内核干净基线。`backend/corepatch` 为无窗口补丁，没有被否决的 JavaFX 外观。

```sh
mkdir -p build
export JAVA_HOME="$(/usr/libexec/java_home -v 21)"
python3 tools/build-native.py
```

构建需要 `build/Interface.soundbank`。音效条款不允许公开源码包附原始素材或音效银行，因此仅附转换器。从 [JDSherbert 官方页](https://jdsherbert.itch.io/ultimate-ui-sfx-pack) 获取 FREE 包并遵守[作者条款](https://jdsherbert.itch.io/terms-and-conditions)，令 `JDS_WAV_DIR` 指向其中 `Stereo/wav (HD)` 后运行 `python3 tools/make-soundbank.py`。完成版 App 已含打包音效与署名。

`HMCL_CORE_JAR`、`HMCL_FX_DIR` 可指定依赖。输出 `build/MC Harbor.app`，本机临时签名，未 Apple 公证。

## 汉化

打开实例管理 → 汉化。读取本体 / 已安装实例资源 / KubeJS 与 resources 的语言目录（包含原版已下载的语言资产）；默认选择启用项，也能逐项选择。社区一键汉化从官方 CFPA 发布整包按游戏版本与加载器下载并校验 MD5，只补有效缺失译文，不修改已有手动译文。无法覆盖的键会显示“待翻译”，可对照编辑或“提取给 AI”后导入同结构 ZIP。导出前验证 printf 与命名占位符，格式号优先读取实际本体 JAR。

社区译文是 CC BY-NC-SA 4.0，导出包附来源与许可说明；首次一键需要联网。此版本不内置付费 AI 账户或云翻译密钥。

## 来源

- HMCL © huangyuhui and contributors，GPL-3.0-or-later：[项目](https://github.com/HMCL-dev/HMCL)、[对应源码](https://github.com/HMCL-dev/HMCL/tree/fbcc17472f08e877d60d6b715734e8054e9e61ee)。原加载器图标同源。
- OpenJFX 21.0.8，GPLv2 + Classpath Exception：[源码](https://github.com/openjdk/jfx21u/tree/21.0.8-ga)。
- BellSoft OpenJDK 21，GPLv2 + Classpath Exception：[发行与源码](https://bell-sw.com/pages/downloads/)。具体声明随 App `Runtime/legal` 保留。
- WinHarbor 为用户提供的实际 SwiftUI / AppKit 源码；光学效果参考 [ReactDrops](https://reactdrops.dev/components)，以原生 SwiftUI / Metal 实现。
- 界面音效 by JDSherbert，仅完成版 App 打包使用；欢迎播报使用用户提供的 ElevenLabs Clara MP3，不变速、不变调。
- [skinview3d 3.4.2](https://github.com/bs-community/skinview3d)，MIT；离线加载 Three.js 渲染器，保留对应许可证。只将皮肤图像传入本地 WebView，账号凭据不进入网页。
- 资源接口：[Modrinth](https://docs.modrinth.com/api/)、[CurseForge](https://docs.curseforge.com/rest-api/)。作者关闭第三方下载时显示项目页面入口。

- 汉化资料：[CFPAOrg 社区译库](https://github.com/CFPAOrg/Minecraft-Mod-Language-Package)，CC BY-NC-SA 4.0；[I18nUpdateMod3](https://github.com/xfl03/I18nUpdateMod3) 更新元数据，AGPL-3.0；[Habier 提取工具](https://github.com/Habier/minecraft-modpack-translator)，MIT。许可文本位于 Assets/Localization。

本工程源码 GPL-3.0-or-later；第三方素材分别按其许可使用。验证范围见 docs/QA.md。

## FTB 任务与存档数据包

FTB 提取涵盖章节 / 组标题、任务标题 / 副标题 / 说明、任务与奖励的自定义标题、图片悬浮说明；优先英文原文并保留现有中文。支持内联 SNBT、独立 SNBT 语言表及当前按章节拆分的 JSON5。存档数据包支持 ZIP / 文件夹，识别进度显示、Patchouli 书页和 tellraw / title 的文字组件，不猜测任意自定义字段或修改命令本身。

这些内容复用同一套选择、草稿、手动编辑、AI 模板和译文导回。自写任务没有现成社区译文时仍显示待翻译。一键社区补全不等同于内置云端 AI。导出包里的 overrides 是任务与数据补丁；普通资源包不能替代任务配置。“应用任务 / 数据包”会检查源文件修订、拒绝活动存档、保存原字节 ZIP 备份并原子提交，失败回滚。该操作由用户在工作区主动触发，不自动修改真实玩家资料。

格式依据：[FTB Quests 官方变更记录](https://github.com/FTBTeam/FTB-Quests/blob/main/CHANGELOG.md)、[旧版文本字段](https://github.com/FTBTeam/FTB-Quests/blob/1.20.1/main/common/src/main/java/dev/ftb/mods/ftbquests/quest/QuestObjectBase.java)、[新版语言表](https://github.com/FTBTeam/FTB-Quests/blob/main/common/src/main/java/dev/ftb/mods/ftbquests/quest/translation/TranslationTable.java)。独立实现结构化解析，没有引入 FTB 游戏运行时。
