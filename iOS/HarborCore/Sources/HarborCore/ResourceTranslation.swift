import Foundation

public enum ResourceTranslationProvider: String, CaseIterable, Sendable {
    case bilibili, aliyun, mymemory, google
    public var title: String {
        switch self {
        case .bilibili: "B站 Index-Translate（国内）"
        case .aliyun: "阿里云 Qwen-MT（自备密钥）"
        case .mymemory: "MyMemory（国外备选）"
        case .google: "Google（国外备选）"
        }
    }
}

/// Common community names are usable offline. Unknown Chinese searches use the
/// selected translation provider; they are never silently sent as English-only
/// keywords and then presented as a successful empty result.
public enum ResourceNames {
    private static let values: [(String, String)] = [
        ("钠", "Sodium"), ("锂", "Lithium"), ("磷", "Phosphor"), ("星光", "Starlight"),
        ("铟", "Indium"), ("铱", "Iris Shaders"), ("光影加载器", "Iris Shaders"),
        ("实体渲染机制优化", "Entity Culling"), ("铁氧体磁芯", "FerriteCore"),
        ("现代化修复", "ModernFix"), ("现代化界面", "Modern UI"), ("懒人厨房", "Cooking for Blockheads"),
        ("苹果皮", "AppleSkin"), ("玉", "Jade"), ("旅行地图", "JourneyMap"),
        ("小地图", "Xaero's Minimap"), ("世界地图", "Xaero's World Map"), ("物品管理器", "Just Enough Items"),
        ("JEI物品管理器", "Just Enough Items"), ("REI物品管理器", "Roughly Enough Items"),
        ("EMI物品管理器", "EMI"), ("机械动力", "Create"), ("农夫乐事", "Farmer's Delight"),
        ("暮色森林", "The Twilight Forest"), ("天境", "The Aether"), ("工业时代2", "Industrial Craft 2"),
        ("建筑", "BuildCraft"), ("林业", "Forestry"), ("热力膨胀", "Thermal Expansion"),
        ("植物魔法", "Botania"), ("应用能源2", "Applied Energistics 2"), ("精致存储", "Refined Storage"),
        ("通用机械", "Mekanism"), ("匠魂", "Tinkers' Construct"), ("更多生物群系", "Biomes O' Plenty"),
        ("你将去的生物群系", "Oh The Biomes You'll Go"), ("FTB任务", "FTB Quests"),
        ("游戏内输入法", "IMBlocker"), ("连锁挖矿", "FTB Ultimine"), ("旅行者背包", "Traveler's Backpack"),
        ("自然罗盘", "Nature's Compass"), ("探索者指南针", "Explorer's Compass"), ("鼠标手势", "Mouse Tweaks"),
        ("落叶", "Falling Leaves"), ("更好的第三人称", "Better Third Person"), ("动态光源", "LambDynamicLights"),
        ("布料配置", "Cloth Config API"), ("模组菜单", "Mod Menu"), ("服务端核心", "ServerCore")
    ]
    private static func normalize(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    public static func english(_ chinese: String) -> String? {
        let key = normalize(chinese); return values.first { normalize($0.0) == key }?.1
    }
    public static func chinese(_ title: String) -> String? {
        let key = normalize(title); return values.first { normalize($0.1) == key }?.0
    }
    public static func containsChinese(_ value: String) -> Bool { value.range(of: "[\\p{Han}]", options: .regularExpression) != nil }
}

public actor ResourceTextService {
    public static let shared = ResourceTextService()
    private let transport: ResourceTransport
    private var active = 0
    private var cache: [String: String] = [:]
    private var order: [String] = []
    public init(transport: @escaping ResourceTransport = ResourceNetwork.fetch) { self.transport = transport }
    public func translate(_ text: String, toChinese: Bool = true, provider: ResourceTranslationProvider, aliKey: String? = nil, forceTranslation: Bool = false) async throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 8_000 else { throw ResourceError.invalid("翻译文本为空或过长。") }
        if toChinese && !forceTranslation && ResourceNames.containsChinese(text) { return text }
        let key = provider.rawValue + "/" + String(toChinese) + "/" + text
        if let value = cache[key] { return value }
        // At most three translation requests, even if many rows enter the
        // viewport together. Waiting tasks remain cancellable.
        while active >= 3 { try await Task.sleep(for: .milliseconds(80)) }
        try Task.checkCancellation(); active += 1; defer { active -= 1 }
        if let value = cache[key] { return value }
        var request: URLRequest
        if provider == .google {
            var url = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
            url.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: "auto"), .init(name: "tl", value: toChinese ? "zh-CN" : "en"), .init(name: "dt", value: "t"), .init(name: "q", value: text)]
            request = URLRequest(url: url.url!, timeoutInterval: 15)
        } else if provider == .mymemory {
            guard text.utf8.count <= 500 else { throw ResourceError.unavailable("MyMemory 单段限 500 字节，请改用国内翻译源。") }
            var url = URLComponents(string: "https://api.mymemory.translated.net/get")!
            url.queryItems = [.init(name: "q", value: text), .init(name: "langpair", value: toChinese ? "en|zh-CN" : "zh-CN|en")]
            request = URLRequest(url: url.url!, timeoutInterval: 15)
        } else {
            var body: [String: Any]
            if provider == .aliyun {
                guard let aliKey, !aliKey.isEmpty else { throw ResourceError.unavailable("请先在资源与翻译设置中保存自己的阿里云 API Key。") }
                request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!, timeoutInterval: 20)
                request.setValue("Bearer " + aliKey, forHTTPHeaderField: "Authorization")
                body = ["model": "qwen-mt-plus", "messages": [["role": "user", "content": text]], "translation_options": ["source_lang": "auto", "target_lang": toChinese ? "Chinese" : "English"]]
            } else {
                request = URLRequest(url: URL(string: "https://index-translate.bilibili.com/v1/chat/completions")!, timeoutInterval: 20)
                body = ["model": "Index-Translate-35B-A3B", "messages": [["role": "user", "content": "Translate this Minecraft mod text to " + (toChinese ? "Simplified Chinese" : "English") + ". Return only the translation. Preserve proper names, identifiers and placeholders.\n\n" + text]], "stream": false, "max_tokens": 2048, "chat_template_kwargs": ["enable_thinking": false]]
            }
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.setValue(ResourceNetwork.userAgent, forHTTPHeaderField: "User-Agent")
        let result = try await transport(request, 160_000)
        try Task.checkCancellation()
        guard result.status == 200 else { throw ResourceError.http(result.status) }
        guard result.data.count <= 160_000 else { throw ResourceError.invalid("翻译结果过大。") }
        let value = try Self.parse(result.data, provider: provider, source: text, toChinese: toChinese)
        if cache.count >= 256, !order.isEmpty { cache.removeValue(forKey: order.removeFirst()) }
        cache[key] = value; order.append(key); return value
    }
    public static func parse(_ data: Data, provider: ResourceTranslationProvider, source: String, toChinese: Bool) throws -> String {
        let root = try JSONSerialization.jsonObject(with: data)
        let value: String
        if provider == .google, let values = root as? [Any], let segments = values.first as? [[Any]] {
            value = segments.compactMap { $0.first as? String }.joined()
        } else if provider == .mymemory, let object = root as? [String: Any], object["responseStatus"] as? Int == 200,
                  let response = object["responseData"] as? [String: Any], let text = response["translatedText"] as? String { value = text }
        else if let object = root as? [String: Any], let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
                choice["finish_reason"] as? String == "stop", let message = choice["message"] as? [String: Any], let text = message["content"] as? String { value = text }
        else { throw ResourceError.unavailable("翻译服务没有返回完整译文，请重试或切换翻译源。") }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare(source) != .orderedSame,
              !toChinese || ResourceNames.containsChinese(trimmed), toChinese || !ResourceNames.containsChinese(trimmed) else { throw ResourceError.unavailable("翻译服务没有生成有效译文，请重试或切换来源。") }
        return trimmed
    }
}
