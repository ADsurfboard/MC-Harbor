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

/// Shared bounded work; cancelling a row never cancels another row's identical request.
actor TranslationRequestGate {
    static let shared=TranslationRequestGate()
    private var active=0
    private let limit:Int
    init(limit:Int=3){self.limit=max(1,limit)}
    private var waiting:[(UUID,CheckedContinuation<Void,Error>)]=[]
    private func cancel(_ id:UUID){if let index=waiting.firstIndex(where:{$0.0==id}){waiting.remove(at:index).1.resume(throwing:CancellationError())}}
    private func acquire()async throws {
        let id=UUID()
        try await withTaskCancellationHandler{
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
                if Task.isCancelled{continuation.resume(throwing:CancellationError())}
                else if active<limit{active+=1;continuation.resume()}
                else{waiting.append((id,continuation))}
            }
        }onCancel:{Task{await self.cancel(id)}}
    }
    private func release(){if waiting.isEmpty{active-=1}else{waiting.removeFirst().1.resume()}}
    func run<T:Sendable>(_ operation:@escaping @Sendable ()async throws->T)async throws->T {
        try await acquire();defer{release()};try Task.checkCancellation();return try await operation()
    }
}
private actor TranslationCacheDisk {
    static let shared=TranslationCacheDisk()
    func read(_ file:URL)->[String:String]{guard let size=(try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<8_000_000,let data=try? Data(contentsOf:file) else{return [:]};return (try? JSONDecoder().decode([String:String].self,from:data)) ?? [:]}
    func write(_ value:[String:String],file:URL){try? FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try? JSONEncoder().encode(value).write(to:file,options:.atomic)}
}
actor ModTextTranslation {
    static let shared=ModTextTranslation()
    private var cache:[String:String]=[:]
    private var order:[String]=[]
    private var loading:Task<[String:String],Never>?
    private struct Flight {let id:UUID;let task:Task<String,Error>;var consumers:Set<UUID>}
    private var flights:[String:Flight]=[:]
    private var loaded=false
    private var flushTask:Task<Void,Never>?
    private let file:URL
    private let lookup:@Sendable (String,Bool,String)async throws->String
    init(file:URL=NativePaths.root.appendingPathComponent("cache/mod-text-translations.json"),lookup:@escaping @Sendable (String,Bool,String)async throws->String={try await DomesticTranslation.query($0,toChinese:$1,provider:$2)}){self.file=file;self.lookup=lookup}
    private func load()async {
        if loaded{return}
        if loading==nil{let file=file;loading=Task{await TranslationCacheDisk.shared.read(file)}}
        let saved=await loading!.value
        guard !loaded else{return};loaded=true;cache=saved;order=Array(saved.keys).sorted();trim()
    }
    private func trim(){while order.count>2000{cache.removeValue(forKey:order.removeFirst())}}
    private func persist(){flushTask?.cancel();flushTask=Task{do{try await Task.sleep(nanoseconds:500_000_000);try Task.checkCancellation();await TranslationCacheDisk.shared.write(cache,file:file)}catch{}}}
    func cached(_ text:String,provider:String)async->String?{await load();guard let value=cache[provider+"|en|zh-CN|"+text],value.range(of:"[\\p{Han}]",options:.regularExpression) != nil else{return nil};return value}
    private func leave(_ key:String,flightID:UUID,consumer:UUID,cancel:Bool){guard var flight=flights[key],flight.id==flightID else{return};flight.consumers.remove(consumer);if flight.consumers.isEmpty{if cancel{flight.task.cancel()};flights.removeValue(forKey:key)}else{flights[key]=flight}}
    func translate(_ text:String,toChinese:Bool=true,provider:String=DomesticTranslation.provider)async throws->String {
        if ModDiscovery.identifierOnly(text){return text}
        await load();try Task.checkCancellation()
        let pair=toChinese ? "en|zh-CN":"zh-CN|en",key=provider+"|"+pair+"|"+text
        if let saved=cache[key],saved.range(of:toChinese ? "[\\p{Han}]":"[A-Za-z]",options:.regularExpression) != nil{return saved}
        let consumer=UUID()
        let flightID:UUID,task:Task<String,Error>
        if var flight=flights[key]{flight.consumers.insert(consumer);flights[key]=flight;flightID=flight.id;task=flight.task}
        else{
        flightID=UUID();let lookup=lookup
        task=Task<String,Error>{
            try await TranslationRequestGate.shared.run{
                let parsed=TranslationText.parts(text,toChinese:toChinese);var values:[String:String]=[:]
                for part in parsed where part.translate && values[part.text]==nil {
                    let chunks=try LegacyLanguageTranslation.chunks(part.text,limit:provider=="mymemory" ? 400:3600)
                    var value=""
                    for chunk in chunks {try Task.checkCancellation();value+=chunk.translate ? try await lookup(chunk.text,toChinese,provider):chunk.text}
                    values[part.text]=value
                }
                let result=try TranslationText.restore(parsed,values:values)
                guard result.range(of:toChinese ? "[\\p{Han}]":"[A-Za-z]",options:.regularExpression) != nil else{throw LegacyLanguageTranslation.Failure.unchanged}
                return result
            }
        }
        flights[key]=Flight(id:flightID,task:task,consumers:[consumer])
        }
        do{
            let value=try await withTaskCancellationHandler{try await task.value}onCancel:{Task{await self.leave(key,flightID:flightID,consumer:consumer,cancel:true)}}
            try Task.checkCancellation()
            if cache[key] != value{cache[key]=value;order.removeAll{$0==key};order.append(key);trim();persist()}
            leave(key,flightID:flightID,consumer:consumer,cancel:false);return value
        }catch{leave(key,flightID:flightID,consumer:consumer,cancel:true);throw error}
    }
    static func searchQuery(_ original:String)async->String {
        guard original.range(of:"[\\p{Han}]",options:.regularExpression) != nil else{return original}
        if let known=ModDiscovery.knownQuery(original){return known}
        if let indexed=await ModNameIndex.shared.query(original){return indexed}
        return (try? await shared.translate(original,toChinese:false)) ?? original
    }
}

enum OnlineLanguageTranslation {
    struct Result:Sendable {var changes:[[String:String]]=[];var failures:[String:String]=[:]}
    static func translate(_ entries:[PendingLanguageEntry],provider:String=DomesticTranslation.provider,lookup:@escaping @Sendable (String,String)async throws->String={try await ModTextTranslation.shared.translate($0,provider:$1)})async throws->Result {
        try Task.checkCancellation()
        let result=await withTaskGroup(of:Result.self,returning:Result.self){group in
            // The shared gate limits remote work; each failed row stays independently retryable.
            for entry in entries{group.addTask{
                do{try Task.checkCancellation();let value=try await lookup(entry.source,provider);try Task.checkCancellation();return Result(changes:[["resource":entry.resource,"entry":entry.id,"source":entry.source,"translation":value]])}
                catch{return Result(failures:[entry.identity:error.localizedDescription])}
            }}
            var result=Result();for await row in group{result.changes+=row.changes;result.failures.merge(row.failures,uniquingKeysWith:{$1})};return result
        }
        try Task.checkCancellation();return result
    }
}

/// Public descriptions only. A provider's quota never disables later pages.
actor PublicModTranslation {
    static let shared=PublicModTranslation()
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
