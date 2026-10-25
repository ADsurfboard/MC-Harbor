# 构建 MC Harbor

Apple Silicon Mac，macOS 26 及以上、相应 Xcode 命令行工具、JDK 21、Python 3。PDF 工具另需 ReportLab、Arial Unicode 字体；音效转换另需 FFmpeg。

```sh
mkdir -p build
export JAVA_HOME="$(/usr/libexec/java_home -v 21)"
python3 tools/build-native.py
```

输出 `build/MC Harbor.app`，使用本机临时签名，未 Apple 公证。源码包包含固定的 HMCL 3.16.4 内核、对应干净源码归档与三个 OpenJFX 21.0.8 ARM64 JAR；`backend/corepatch` 为无窗口桥接补丁。`HMCL_CORE_JAR`、`HMCL_FX_DIR` 可指定依赖。需要下载的 Java 游戏运行时仍由启动流程按实例要求处理。

界面音效使用 JDSherbert，许可不允许将原始音效或音效银行公开放入源码包。从 [官方页面](https://jdsherbert.itch.io/ultimate-ui-sfx-pack) 获取 FREE 包并遵守[作者条款](https://jdsherbert.itch.io/terms-and-conditions)，将 `JDS_WAV_DIR` 指向 `Stereo/wav (HD)` 后运行：

```sh
python3 tools/make-soundbank.py
```

完成版 App 已含署名音效银行。四份用户提供的欢迎 MP3 不变速、不变调；设置 → 欢迎动画中选择声音。原始音频及图形素材仍须按各自权利分发。

好友默认地址来自 `Assets/Services.json`。正常玩家无需部署；可替换为自己的服务，源码同时包含 Cloudflare Workers / D1 / SQLite Durable Objects 与 Python / SQLite 实现。只在本机回环地址测试可使用 HTTP，线上必须使用 HTTPS。详见 [服务说明](docs/SERVICES.md)。

PDF 与 README 正文由 `tools/make-introduction.py` 同源生成。源码交付用 `tools/package-delivery.py` 的允许列表生成，排除玩家数据、凭据、测试数据库、研究下载、音效银行、node_modules 与构建缓存。不要直接压缩整个开发目录。

验证工具运行隔离数据，严禁将真实存档作为夹具。实际覆盖与未覆盖边界见 [QA](docs/QA-1.5.md)。
