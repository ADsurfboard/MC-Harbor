import Foundation

struct HarborSettingItem:Identifiable {
    let title:String,section:String,anchor:String,keywords:String
    var id:String{section+"/"+anchor+"/"+title}
}
enum HarborSettingsIndex {
    static let items:[HarborSettingItem]=[
        .init(title:"主题色与调色盘",section:"外观",anchor:"主题色",keywords:"主题 配色 颜色 调色盘"),
        .init(title:"主题范围与反色",section:"外观",anchor:"主题范围与反色",keywords:"反色 亮度 饱和度 文字 字体 对比度 按钮 图标 强调文字 辅助文字 背景 边框 染色 自定义"),
        .init(title:"深色、浅色与主题外观",section:"外观",anchor:"外观",keywords:"深色 浅色 通透 模式"),
        .init(title:"毛玻璃与玻璃通透",section:"外观",anchor:"背景",keywords:"磨砂 材质 透明 通透度"),
        .init(title:"壁纸库与流体背景",section:"外观",anchor:"背景",keywords:"图片 视频 动态 壁纸柔化 窗口透明 后景材质"),
        .init(title:"模组夹信息显示",section:"外观",anchor:"模组夹信息显示",keywords:"图标 名称 加载器 Forge Fabric 模组版本 Minecraft 收藏时间 简介 作者 仅名称"),
        .init(title:"独家优化",section:"外观",anchor:"动态与声音",keywords:"性能 轻量 流畅 卡顿 静态 无动画 关闭动效"),
        .init(title:"减少动态效果",section:"外观",anchor:"动态与声音",keywords:"动画 流畅 性能 动效"),
        .init(title:"界面音效与音量",section:"外观",anchor:"动态与声音",keywords:"试听 声音"),
        .init(title:"欢迎动画与显示名字",section:"欢迎动画",anchor:"启动欢迎",keywords:"用户名 动画时长 启动 预览"),
        .init(title:"欢迎播报与声音选择",section:"欢迎动画",anchor:"启动欢迎",keywords:"男声 女声 Clara Adam Morgan 音量 试听"),
        .init(title:"翻译来源与阿里密钥",section:"运行",anchor:"翻译与账号授权",keywords:"汉化 在线 国内 B站 MyMemory Google Qwen 阿里 API 测试翻译 备选"),
        .init(title:"账号凭据授权",section:"运行",anchor:"翻译与账号授权",keywords:"钥匙串 密码 记住 凭据 始终允许"),
        .init(title:"游戏库与 Java",section:"运行",anchor:"游戏",keywords:"路径 目录 运行时 最大内存 RAM"),
        .init(title:"前置补全",section:"运行",anchor:"前置补全",keywords:"依赖 模组 安装 启动前 缺失"),
        .init(title:"下载来源与并发数",section:"运行",anchor:"下载",keywords:"镜像 国内 官方 自动 超时 线程 加速"),
        .init(title:"连接检测与数据目录",section:"维护",anchor:"维护",keywords:"诊断 日志 应用数据 账号导入"),
        .init(title:"存档备份",section:"维护",anchor:"维护",keywords:"游戏 存档 备份"),
        .init(title:"贡献者",section:"维护",anchor:"贡献者",keywords:"jiekee 花圆银行 贡献名单"),
        .init(title:"关于与作者主页",section:"维护",anchor:"关于",keywords:"作者 ADsurfboard GPT 版本 HMCL GitHub Issues issue B站 反馈 功能建议 许可 便携模式")
    ]
    static func search(_ query:String)->[HarborSettingItem]{let tokens=query.split(whereSeparator:{$0.isWhitespace}).map(String.init);guard !tokens.isEmpty else{return []};return items.filter{item in let text=item.title+" "+item.section+" "+item.keywords;return tokens.allSatisfy{text.localizedCaseInsensitiveContains($0)}}}
}
