# Windows 移植开发入口

正式负责人：**时咨月.**（[shiziyueyuan](https://github.com/shiziyueyuan)）。项目作者：**ADsurfboard**。

开发分支：本仓库 [`windows`](https://github.com/ADsurfboard/MC-Harbor/tree/windows)。该分支从当前 macOS 正式源码建立，属于移植起点，尚不是可用的 Windows 成品。

```sh
git clone --branch windows https://github.com/ADsurfboard/MC-Harbor.git
cd MC-Harbor
```

## 后续工作范围

Windows 端需要适配原生窗口、文件与快捷方式、凭证保存、Java 运行时、下载和加载器安装、实例管理及交互。现有 SwiftUI / AppKit 界面不能直接在 Windows 上运行；HMCL 内核、数据格式、服务协议与可复用资源应保留来源并按许可复用。

实现时保护玩家账号、实例、存档和配置；在 Windows 实机验证下载、启动、停止、导入导出与卸载流程，再发布对应版本。测试、兼容范围、限制与构建方式应随实际实现更新，不能把 macOS 的通过结果当作 Windows 验证。

只在 `windows` 分支提交 Windows 工作。跨平台公共改动通过 Pull Request 交由 ADsurfboard 审核。Windows 专用标签使用 `windows-*`；其他平台的直接修改和发布由作者负责。平台分工与署名见 [GOVERNANCE.md](../GOVERNANCE.md)。
