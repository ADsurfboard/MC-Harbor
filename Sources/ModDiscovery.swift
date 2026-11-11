import Foundation
import CryptoKit

struct ModSuggestion:Identifiable,Sendable {
    let slug:String;let chinese:String;let reason:String;let modIDs:[String]
    var id:String{slug}
}
struct RecommendedMod:Identifiable,Sendable {
    let project:AddonProject;let suggestion:ModSuggestion
    var id:String{project.id}
}
enum ModDiscovery {
    static let catalog:[ModSuggestion]=[
        .init(slug:"sodium",chinese:"钠",reason:"优化区块渲染，提高帧率",modIDs:["sodium"]),
        .init(slug:"lithium",chinese:"锂",reason:"优化游戏逻辑，减轻运行负担",modIDs:["lithium"]),
        .init(slug:"ferrite-core",chinese:"铁氧体磁芯",reason:"降低内存占用",modIDs:["ferritecore"]),
        .init(slug:"modernfix",chinese:"现代化修复",reason:"改善加载速度与内存使用",modIDs:["modernfix"]),
        .init(slug:"jei",chinese:"JEI 物品管理器",reason:"查看物品合成与用途",modIDs:["jei"]),
        .init(slug:"rei",chinese:"REI 物品管理器",reason:"查询配方和物品用途，可替代 JEI",modIDs:["roughlyenoughitems"]),
        .init(slug:"jade",chinese:"玉",reason:"查看准星指向的方块与实体信息",modIDs:["jade"]),
        .init(slug:"appleskin",chinese:"苹果皮",reason:"直观查看饥饿值与食物恢复量",modIDs:["appleskin"]),
        .init(slug:"mouse-tweaks",chinese:"鼠标手势",reason:"更方便地整理背包和转移物品",modIDs:["mousetweaks"]),
        .init(slug:"modmenu",chinese:"模组菜单",reason:"查看已装模组并打开设置",modIDs:["modmenu"]),
        .init(slug:"controlling",chinese:"按键冲突显示",reason:"搜索按键并排查快捷键冲突",modIDs:["controlling"]),
        .init(slug:"entityculling",chinese:"实体渲染机制优化",reason:"跳过被遮挡实体的渲染",modIDs:["entityculling"])
    ]
    static func chineseName(_ mod:ModFile)->String {
        let id=mod.modID.lowercased()
        if let item=catalog.first(where:{$0.modIDs.contains(id) || $0.slug==id}){return item.chinese}
        if let entry=aliases.first(where:{$0.value.lowercased().replacingOccurrences(of:" ",with:"")==mod.name.lowercased().replacingOccurrences(of:" ",with:"")}){return entry.key}
        return ""
    }
    static let aliases:[String:String]=[
        "钠":"sodium","锂":"lithium","铁氧体磁芯":"ferritecore","现代化修复":"ModernFix",
        "物品管理器":"JEI","jei物品管理器":"JEI","配方查询":"JEI","苹果皮":"AppleSkin","玉":"Jade",
        "模组菜单":"Mod Menu","鼠标手势":"Mouse Tweaks","按键冲突":"Controlling","高清修复":"OptiFine",
        "凿子与比特":"Chisels & Bits","机械动力":"Create","暮色森林":"Twilight Forest","匠魂":"Tinkers Construct","植物魔法":"Botania",
        "应用能源":"Applied Energistics","精妙背包":"Sophisticated Backpacks","旅行地图":"JourneyMap",
        "小地图":"minimap","光影":"shader","动态帧率":"Dynamic FPS","实体渲染":"Entity Culling",
        "布料":"Fabric API","布料接口":"Fabric API","樱花":"Sakura","农夫乐事":"Farmers Delight"
    ]
    static func identifierOnly(_ text:String)->Bool{text.range(of:"^(?:[#@][A-Za-z0-9_]+|[A-Z0-9_.:+/\\-]+)$",options:.regularExpression) != nil}
    static func knownQuery(_ query:String)->String?{aliases[query.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()]}
    static func installed(_ suggestion:ModSuggestion,mods:[ModFile])->Bool {
        mods.contains{mod in suggestion.modIDs.contains(mod.modID.lowercased()) || suggestion.modIDs.contains{mod.path.lastPathComponent.lowercased().hasPrefix($0+"-")}}
    }
    private struct Project:Decodable {
        let id:String;let slug:String;let title:String;let description:String;let iconUrl:String?;let downloads:Int
    }
    static func recommendations(game:GameInstance)async throws->[RecommendedMod] {
        try await RecommendationCache.shared.load(game:game)
    }
    static func fetchRecommendations(game:GameInstance)async throws->[RecommendedMod] {
        guard game.loader != "Minecraft" else{return []}
        // Four requests at a time, with exact game and loader filtering before display.
        var values:[String:RecommendedMod]=[:]
        for start in stride(from:0,to:catalog.count,by:4) {
            try Task.checkCancellation()
            let batch=Array(catalog[start..<min(start+4,catalog.count)])
            await withTaskGroup(of:RecommendedMod?.self){group in
                for item in batch{group.addTask{
                    do{
                        let versions=try await AddonService.versions(item.slug,game:game,kind:.mods)
                        guard versions.contains(where:{$0.gameVersions.contains(game.version) && $0.loaders.contains(AddonService.loader(game))}) else{return nil}
                        let p:Project=try await AddonService.request("/project/"+item.slug)
                        return RecommendedMod(project:AddonProject(projectId:p.id,title:p.title,description:p.description,author:"Modrinth",iconUrl:p.iconUrl,downloads:p.downloads,pageUrl:"https://modrinth.com/mod/"+p.slug),suggestion:item)
                    }catch{return nil}
                }}
                for await value in group{if let value{values[value.suggestion.slug]=value}}
            }
        }
        try Task.checkCancellation()
        return catalog.compactMap{values[$0.slug]}
    }
}

private actor RecommendationCache {
    static let shared=RecommendationCache()
    private var values:[String:(Date,[RecommendedMod])]=[:]
    func load(game:GameInstance)async throws->[RecommendedMod] {
        let key=game.version+"/"+AddonService.loader(game)
        if let (date,items)=values[key],Date().timeIntervalSince(date)<1800{return items}
        let items=try await ModDiscovery.fetchRecommendations(game:game)
        if !items.isEmpty{values[key]=(Date(),items)}
        return items
    }
}

actor ModTextTranslation {
    static let shared=ModTextTranslation()
    private var cache:[String:String]=[:]
    private var loaded=false
    private var activeRequests=0
    private let file=NativePaths.root.appendingPathComponent("cache/mod-text-translations.json")
    func translate(_ text:String,toChinese:Bool=true)async throws->String {
        if ModDiscovery.identifierOnly(text){return text}
        if !loaded{loaded=true;cache=(try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:file))) ?? [:]}
        let pair=toChinese ? "en|zh-CN":"zh-CN|en",key=DomesticTranslation.provider+"|"+pair+"|"+text
        if let saved=cache[key]{return saved}
        // Limit simultaneous visible-row translations and check the cache again
        // after waiting, so duplicate summaries do not consume remote quota.
        while activeRequests>=2{try await HarborDelay.sleep(seconds:0.15);if let saved=cache[key]{return saved}}
        try Task.checkCancellation()
        if let saved=cache[key]{return saved}
        activeRequests+=1;defer{activeRequests-=1}
        var translated=""
        for part in try LegacyLanguageTranslation.chunks(text) {
            try Task.checkCancellation()
            if !part.translate{translated+=part.text;continue}
            do{translated+=try await PublicModTranslation.shared.translate(part.text,toChinese:toChinese)}catch LegacyLanguageTranslation.Failure.unchanged{translated+=part.text}
        }
        guard !toChinese || translated.range(of:"[\\p{Han}]",options:.regularExpression) != nil else{throw LegacyLanguageTranslation.Failure.unchanged}
        try Task.checkCancellation()
        if cache.count>2000{cache.removeAll(keepingCapacity:true)}
        cache[key]=translated
        try? FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try? JSONEncoder().encode(cache).write(to:file,options:.atomic)
        return translated
    }
    static func searchQuery(_ original:String)async->String {
        guard original.range(of:"[\\p{Han}]",options:.regularExpression) != nil else{return original}
        if let known=ModDiscovery.knownQuery(original){return known}
        if let indexed=await ModNameIndex.shared.query(original){return indexed}
        return (try? await shared.translate(original,toChinese:false)) ?? original
    }
}

/// Public descriptions only. A provider's quota never disables later pages.
actor PublicModTranslation {
    static let shared=PublicModTranslation()
    private var primaryRetryAfter=Date.distantPast
    static func parseBackup(_ data:Data,source:String)throws->String {
        guard let root=try JSONSerialization.jsonObject(with:data) as? [Any],let segments=root.first as? [[Any]] else{throw LegacyLanguageTranslation.Failure.unchanged}
        let result=segments.compactMap{$0.first as? String}.joined()
        guard !result.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,result.caseInsensitiveCompare(source) != .orderedSame else{throw LegacyLanguageTranslation.Failure.unchanged}
        return result
    }
    func translate(_ text:String,toChinese:Bool)async throws->String {
        try await DomesticTranslation.query(text,toChinese:toChinese)
    }
}

enum ModSection:String,CaseIterable,Identifiable {
    case all,optimization,pvp,utility,adventure
    var id:String{rawValue}
    var title:String{switch self{case .all:return "全部分区";case .optimization:return "优化分区";case .pvp:return "PVP 分区";case .utility:return "实用分区";case .adventure:return "冒险分区"}}
    var facet:String?{switch self{case .all,.pvp:return nil;case .optimization:return "optimization";case .utility:return "utility";case .adventure:return "adventure"}}
    func query(_ original:String,source:AddonSource)->String {
        let keyword:String
        switch self{case .all:return original;case .pvp:keyword="pvp";case .optimization:keyword="performance";case .utility:keyword="utility";case .adventure:keyword="adventure"}
        if source == .modrinth && self != .pvp{return original}
        return original.isEmpty ? keyword:original+" "+keyword
    }
}
