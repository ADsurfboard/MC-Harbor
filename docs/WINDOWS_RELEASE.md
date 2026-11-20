# Windows 1.7.1 x64 发行说明

本页记录已发布的 x64 1.7.1 附件。后续 ARM64 开发与测试构建见 [WINDOWS_ARM64.md](WINDOWS_ARM64.md)，不改变本页原 x64 发行附件的校验值或验证结论。

项目作者为 ADsurfboard，Windows 移植负责人为时咨月.（shiziyueyuan）。本版以普通版 1.7.1 源码为公共基线，提交到上游 `windows` 分支审核；Windows 专用标签使用 `windows-*`。

## 内容与下载

- `MC-Harbor-Windows-1.7.1-x64-Setup.msi`：中文安装器，包含运行库，安装到 Program Files，并创建开始菜单入口。
- `MC-Harbor-Windows-1.7.1-x64-portable.zip`：包含运行库的便携版，解压后打开 `MC Harbor.exe`，数据保存在该目录的 `MCHarborData`。
- `MC-Harbor-Windows-1.7.1-source.zip`：从对应提交导出的完整源码、构建脚本、许可证和必要素材，包含固定 HMCL 内核对应源码归档。
- `SHA256SUMS-windows-1.7.1.txt`：上述附件的 SHA-256 校验清单。

安装版数据保存在 `%LOCALAPPDATA%\MCHarbor`。发行附件不包含账号、游戏、存档、个人壁纸、翻译模型或玩家配置。需要在使用时安装或下载的模型与外部服务仍由用户选择。

本次程序和 MSI **未使用公开可信证书签名**。免费开源签名服务需要另行申请和审核；本发行版不宣称已获该服务批准。

## 功能与验证边界

Windows 实现游戏库、版本和资源安装、账号与皮肤、实例资源和存档管理、汉化工作区、好友及联机、主题和图片／视频壁纸。界面使用应用内三色窗口按钮、分层磨砂、可调通透与阴影、Fluent System Icons。普通 1.7.1 的壁纸预览和快捷启动交接也已接入。

已完成 Windows x64 构建；之前的隔离回归覆盖 23 项壁纸索引与快捷启动交接场景。发行包经过文件清单及 SHA-256 检查。安装器的管理解包测试只验证载荷，不代表已验证普通安装、升级和卸载。在线账号、跨设备迁移、Windows 11、跨公网联机、真实模型资源占用以及最新玻璃和视频预览观感仍需实机验收。ARM64 不在本发行版范围内。

## 隐私与源码整理

源码由独立发布副本整理。只提交产品源码、公开文档、合法分发的素材、固定依赖和许可证。保留上游已经公开的作者署名、贡献记录及素材来源说明。

排除本地 AI 会话、代理配置、编辑器偏好、日志、缓存、账号凭据、恢复密钥、私人游戏与壁纸，以及工作机硬件信息。构建脚本使用相对位置与环境变量；C# 编译路径映射为统一的源码路径，发行附件不携带调试符号或可能记录编译路径的 Python 字节码缓存。

`tools/check-source-privacy.py` 检查 Git 候选文件及 ZIP 的禁用路径、个人路径和常见凭据格式，输出仅含文件名、行号和风险类型。它是发布前的辅助检查，不能证明不存在所有形式的个人信息。上游原有公开 Git 历史不改写；本次提交使用 GitHub 隐私邮箱。

发布前审查修复了进阶本机翻译的代理转发风险：2B 的本地 HTTP 连接显式禁止代理、重定向及 Cookie，避免系统代理将待译文本转发离机。`tests/windows-local-transport` 使用真实客户端工厂与临时回环端口，验证默认客户端的代理转发对照、修复后的直接连接及拒绝重定向；测试不启动模型，也不访问账号或游戏数据。

## 构建与附件生成

按照 [Windows 构建说明](WINDOWS_PORT.md) 准备 .NET SDK、JDK 21 和 Python 3。若需界面事件音效，先从作者官方渠道取得 JDSherbert 音效包并按条款放入本地 `voice-assets/jds-ui-free`；原始音效与 soundbank 不进入源码归档。未提供音效素材的源码构建会跳过该可选组件。

```powershell
python tools/check-source-privacy.py
tools/build-windows.ps1 -Mode Publish
tools/build-windows.ps1 -Mode Installer
# 提交干净后，从对应 Git 提交生成源码归档。
python tools/package-windows-source.py
```

MSI 需要 WiX 5.0.2 及 `WixToolset.UI.wixext` 5.0.2。可用 `dotnet tool install wix --version 5.0.2 --tool-path <工具目录>` 安装 WiX，再运行 `wix extension add -g WixToolset.UI.wixext/5.0.2`；也可通过打包脚本的 `Wix`、`WixUiExtension` 参数提供同版本工具。WiX 运行时若只装有新版 .NET，可设置 `DOTNET_ROLL_FORWARD=Major`，打包脚本调用期间也会设置该值。

`.github/workflows/windows-build.yml` 提供不带私人凭据的 Windows 构建检查，产物明确标记为未签名测试构建；可选授权音效不在 CI 中下载或分发。发布 MSI、便携 ZIP、源码 ZIP 和校验清单应作为 GitHub Release 附件上传，避免将大型安装器提交到 Git 历史。
