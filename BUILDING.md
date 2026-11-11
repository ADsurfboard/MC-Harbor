# 构建 MC Harbor Intel 兼容版

此分支面向 **Intel x86_64、macOS 12 及以上**，使用 SwiftUI / AppKit 原生磨砂替代 Liquid Glass。开发需安装相应 Xcode 命令行工具、JDK 21、Python 3.12；在 Apple Silicon 上构建并运行 Intel 检查需要 Rosetta。PDF 生成另需 ReportLab 和 Arial Unicode 字体。

```sh
python3 tools/setup-intel-deps.py
python3 tools/build-native.py
python3 tools/check-intel-bundle.py
python3 tools/check-intel-swift.py
python3 tools/check-intel-backend.py
```

依赖脚本从官方 Adoptium 和 Maven Central 地址下载固定版本的 Intel Temurin 21 运行时及 OpenJFX 21.0.8，按 `tools/intel-deps.lock.json` 中的大小与 SHA256 校验，并安全解压到 `build/`。`JAVA_HOME` 指向构建用 JDK，`HARBOR_RUNTIME_HOME` 与 `HMCL_FX_DIR` 可在需要时指定 Intel 运行时和 JavaFX 路径。发布 App 要求实际的界面音效银行：从 [JDSherbert 官方页面](https://jdsherbert.itch.io/ultimate-ui-sfx-pack) 获取 FREE 包，遵守[作者条款](https://jdsherbert.itch.io/terms-and-conditions)，设置 `JDS_WAV_DIR` 指向 `Stereo/wav (HD)`；原始音效和银行不进入源码。`HARBOR_TEST_WITHOUT_SFX=1` 仅用于 CI 测试构建，不可用于发布。

输出 `build/MC Harbor.app`，采用临时签名，未 Apple 公证。源码中的 `vendor/HMCLCore.jar` 与 `upstream/HMCL-3.16.4-source.tar.gz` 对应原 HMCL GPL 内核，`backend/corepatch` 是无窗口桥接补丁。游戏本身需要的 Java 仍按实例版本处理，老显卡、模组和认证服务可能有额外要求。

macOS 15 及以上使用 Apple Translation；各版本可在用户确认后选择国内 B站 Index-Translate 在线补全，或配置自己的阿里云 Qwen-MT 密钥，未完成内容保留并可手动翻译 / 提取给 AI。发送内容、额度和第三方边界在应用中说明。好友服务默认已内置；Sakura、陶瓦及服务额度见 [docs/SERVICES.md](docs/SERVICES.md)。

测试使用新建隔离夹具，严禁用真实存档或真实身份测试。目标系统、实际运行环境、未覆盖部分见 [docs/QA-INTEL.md](docs/QA-INTEL.md)。`tools/package-delivery.py` 在提交干净后生成安装包、对应源码 ZIP、介绍 PDF 和 SHA256 清单，不包含玩家数据、凭据或原始音效。
