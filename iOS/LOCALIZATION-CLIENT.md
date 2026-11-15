# iOS 实例资源汉化

这是原生 SwiftUI 编辑器和 Swift / Objective-C 文件管线，未通过 WebView 仿制桌面界面。入口在“设置 → 实例资源一键汉化”，选定实例后的资源下载页也有入口。完整 App 与隔离 UI 宿主共用页面；测试夹具只存在于宿主。

## 已实现的范围

- 读取 JAR / ZIP 中 `assets/<namespace>/lang` 的 JSON / LANG，优先 en_us，其次 en_gb；已有中文中格式匹配的值会自动保留。提取给 AI 时另存归档中所有地区语言原件，不只保留英文。
- 读取 KubeJS 的 `kubejs/assets/.../lang`、实例 resources、目录形式资源包中的同结构语言文件。
- 读取 config / defaultconfigs / 各存档 serverconfig 中的 FTB Quests 任务；SNBT / JSON5 / JSON 支持注释、可省略逗号、类型数组和多行字符串。只提取 title、subtitle、description、text、hover、fallback 等可见文本，不猜测任务 ID、依赖关系、奖励或物品标识符。
- 读取实例及存档目录形式数据包的进度 / 任务 / Patchouli 可见文本，以及 mcfunction 的 tellraw / title 文本组件。保留执行前缀、clickEvent 指令、criteria、translate 键和其他字段。
- 选资源、搜索、逐条对照编辑、保存草稿、仅补全缺失译文；默认使用现有国内翻译来源，阿里自备密钥与国外备选沿用资源设置。三路并发，分批保存成功值，取消与部分失败不会冒充完成。
- 校验 printf / Java 编号占位符、变量、格式代码和标签的多重集合。格式不符拒绝保存 / 应用；原文其他条目变化时，未变化行的草稿仍可继承。
- 资源包命名与格式号；汉化 ZIP、未汉化原文 ZIP、AI 索引 JSON；导回同结构中文资源包 ZIP，或在 AI 索引中填写 translation 后导回 JSON。iOS 原生分享和 Files 负责文件交接。
- 任务 / 数据包另行确认应用。取得原生实例修改令牌、核对源 SHA-256、先写 ZIP 备份，再原子写入；失败仅回滚本次写入。已有中文 FTB 原生语言文件会阻止自动覆盖，提示先导出合并。

## 当前边界

任意 KubeJS 脚本中的硬编码文本尚未自动提取。ZIP 形式存档数据包当前明确提示先解包，不假称已完成处理。已有中文 FTB 原生语言文件的结构合并仍需补充；资源包格式未知版本由用户明确填写，默认 15 对应 1.20–1.20.1。FTB 和数据包的 overrides 不能靠游戏启用资源包自动生效。

解析错误、符号链接、读取失败、翻译失败和占位符问题有处理记录。单文本 4 MB、单次扫描原文 24 MB、扫描 30000 文件、目录 16 层；ZIP 输出文本总量 96 MB。限制触发时有明确提示，不能把遗漏资源当作全部汉化。

## 证据

`LocalizationTests.swift` 使用实际临时文件验证语言解析、Unicode、任务 / 指令保护、草稿、全地区原文保留、KubeJS / FTB / 存档数据包扫描、源变化拒绝、已有中文保护和 ZIP 不覆盖。`test-resources.py --suite localization` 运行相同测试体的 Foundation 断言，不能代替云端 XCTest。

`test-localization-zip.py` 用独立 Python ZIP 解码器读取实际 Swift 输出，验证 CRC、UTF-8 路径、译文、未汉化值与备份原件。云端另外执行真正 XCTest，以及 iPhone / iPad 的扫描、编辑和重启后恢复草稿的 UI 测试。真实设备进入 Minecraft 后的资源包效果和任务显示仍需实玩验收。
