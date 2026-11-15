# iOS 壁纸与欢迎音频

壁纸库使用原生 SwiftUI 列表和前景预览、Image I/O 缩略解码、AVFoundation 视频，持久化由独立 WallpaperLibrary actor 管理。Files 原件只读，先复制到随机暂存目录再验证，保存副本和预览成功后才登记。可以命名、预览、使用、移除；动态壁纸的缩略图右下角有视频标识。

静态图下采样后使用，不用 UIImage 一次解码任意尺寸原图。照片上限 50 MB / 1 亿像素，视频上限 512 MB；PNG / JPEG / HEIC / WebP 与 MP4 / MOV / M4V 均先实际解码 / 读取视频轨道，失败显示错误。预览缓存有 8 MB / 40 项上限，内存警告清除缓存。缺失文件、坏索引、链接和不支持格式不会强制解包 URL 或图片。

所有页面共用一个动态背景播放器，静音循环；切后台、进入游戏、预览另一视频或开启独家优化时暂停。独家优化显示静态首帧，保留 Liquid Glass 材质。默认背景仍为既有静态背景，不加入普通版已被取消的全局流体选项。

欢迎音频使用仓库已有四份 MP3：welcome、welcome-female2、welcome-male、welcome-male2。原生音频设置可以选择声音、音量、启停和试听；一次进程只欢迎一次，切后台停止，遵循静音开关并与其他应用音频混合。隔离 UI 测试不自动播放，解码由独立工具验证；不把解码通过等同于真机扬声器试听。

打包器核对完整 App 内四份 MP3 的 SHA-256 与源码素材一致，漏带 / 改写任一文件会让构建失败。设备安装签名 / JIT 的原有边界保持不变。

验证入口：WallpaperTests 的真实临时目录、WallpaperMediaTests 的实际 PNG / 生成短视频及坏文件、test-welcome-audio.py 的四 MP3 实际解码、iPhone / iPad 的壁纸预览与选择持久化 / 四音色选择回归。全套 XCTest 与真实 iOS UI 结果由云端记录；Mac 上的 Foundation 独立检查不能代替 iPhone 游戏实玩。

Apple API 依据：[AVAssetImageGenerator.image(at:)](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image(at:))，iOS 16 起提供异步图像提取。
