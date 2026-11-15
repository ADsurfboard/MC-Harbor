# iOS 实例资源客户端

资源页使用 SwiftUI 原生列表与前景详情页，保留原生 Liquid Glass 和独家优化设置。头部横向排列资源类型、安装菜单与设置入口，不用绘图模拟系统控件。原生 JAR / 整合包导入保留在安装菜单中。

## 实际链路

1. Modrinth / CurseForge 查询模组、资源包和光影，可按实例 Minecraft 版本、Fabric / Forge / Quilt / NeoForge 筛选。
2. 默认优先 MCIM 国内镜像；Modrinth 元数据和文件下载可回退原站。官方优先可以单独选择。CurseForge 资料走公开镜像，不复制其他启动器的 API Key；未提供下载 URL 的文件显示原项目链接，不推测 CDN 地址。
3. 常用中文名离线匹配；其余中文关键词由用户选择的翻译服务转换成英文再搜索。每页30项，页码独立，旧搜索取消后不覆盖新结果。
4. 名称与简介可汉化。简介默认加载完成后显示中文，加载期间显示进度，失败明确提示；只有主动选择“查看原文”才展示英文简介。默认国内 B站 Index-Translate；阿里云自备 Key、MyMemory、Google 是明确备选，不偷偷回退国外服务。阿里密钥只存 iOS 本机钥匙串。
5. 选择兼容版本后解析必需前置，检测循环、版本冲突和同名文件，最多40项。三路并发下载到独立 UUID 暂存目录，校验 SHA-512 / SHA-1 / MD5 后才提交实例；取消、坏文件和预检冲突不改原文件。已有同名且同内容的文件去重，已有不同内容的文件不覆盖。
6. 原生桥接提供资源目录访问令牌，游戏运行或其他模组操作期间不改写实例；持有令牌期间不能同时启动游戏。iOS 进入后台取消本次下载。已有文件和 Files 原件不会删除。

## 已有证据与边界

`HarborCoreTests/ResourceTests.swift` 包含来源切换、第七页参数、前置解析、损坏文件、三路并发、取消、同名冲突、符号链接、中文及翻译响应等实际检查。`tools/test-resources.py` 在 CLT 环境复用同一批测试函数，明确区分 Foundation 检查与云端 XCTest。

`tools/test-resource-network.py --allow-network` 通过生产客户端真实查询两个平台，并下载、安装及再次校验 FerriteCore 6.0.1 Fabric（125197字节）。仅使用新建临时目录，退出删除。此证据属于本机 HTTPS / Foundation，不代表中国大陆直连、iPhone 实际安装流程或游戏实玩。服务可用性受第三方接口限制，阿里服务按用户套餐计费。

资源收藏到模组夹、世界 / 数据包的安装、完整一键汉化和其他平台功能仍按 PORTING.md 继续移植，不能以本页代替完整发布验收。

接口依据：

- https://docs.modrinth.com/api/operations/searchprojects/
- https://docs.modrinth.com/api/operations/getprojectversions/
- https://www.mcimirror.top/

国内 / 官方搜索与 CF 镜像无密钥请求已得到200响应；不以文档推断代替实际响应。API、翻译服务和网络环境不受启动器控制。
