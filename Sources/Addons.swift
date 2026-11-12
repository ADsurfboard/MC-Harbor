import AppKit
import CryptoKit
import SwiftUI

struct AddonProject:Codable,Identifiable,Sendable {
    let projectId:String
    let title:String
    let description:String
    let author:String
    let iconUrl:String?
    let downloads:Int
    let pageUrl:String?
    var slug:String?=nil
    var id:String{projectId}
}
struct AddonSearch:Decodable,Sendable{let hits:[AddonProject];let totalHits:Int}
struct AddonVersion:Decodable,Identifiable,Sendable {
    let id:String
    let projectId:String
    let name:String
    let versionNumber:String
    let gameVersions:[String]
    let loaders:[String]
    let files:[AddonFile]
    let dependencies:[AddonDependency]
}
struct AddonFile:Decodable,Sendable {let filename:String;let url:String;let size:Int64;let hashes:[String:String];let primary:Bool}
struct AddonDependency:Decodable,Sendable{let versionId:String?;let projectId:String?;let dependencyType:String;let fileName:String?}
struct AddonPlanItem:Identifiable,Sendable{let version:AddonVersion;let file:AddonFile;var id:String{version.projectId}}
private struct AddonReceipt:Codable{let projectId:String;let versionId:String;let filename:String;let kind:String}

enum AddonService {
    static let session:URLSession={let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=20;c.timeoutIntervalForResource=180;c.httpAdditionalHeaders=["User-Agent":"MC-Harbor/1.6.1 (+https://github.com/ADsurfboard/MC-Harbor)"];return URLSession(configuration:c)}()
    static func loader(_ game:GameInstance)->String{game.loader == "Legacy Fabric" ? "fabric":game.loader == "Cleanroom" ? "forge":game.loader.lowercased()}
    static func request<T:Decodable>(_ path:String,query:[URLQueryItem]=[])async throws->T{
        var last:Error=FileTransactions.error("资源来源暂不可用。")
        for base in ResourceMirror.metadataBases {
            var components=URLComponents(string:base+path)!;components.queryItems=query
            do{
                let url=components.url!
                let data=try await ResourceMetadataCache.shared.data(url.absoluteString){
                    let (data,response)=try await session.data(from:url);let status=(response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status==200,data.count<24_000_000 else{throw FileTransactions.error("资源来源返回 HTTP \(status)。")};return data
                }
                try Task.checkCancellation();let decoder=JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase;return try decoder.decode(T.self,from:data)
            }catch{last=error;try Task.checkCancellation()}
        }
        throw last
    }

    static func search(_ query:String,game:GameInstance,kind:ContentKind,offset:Int=0,section:ModSection = .all)async throws->AddonSearch{
        var facets=[["project_type:"+kind.projectType]];if !game.version.isEmpty{facets.append(["versions:"+game.version])}
        if kind == .mods {guard game.loader != "Minecraft" else{return AddonSearch(hits:[],totalHits:0)};facets.append(["categories:"+loader(game)])}
        if kind == .mods,let category=section.facet{facets.append(["categories:"+category])}
        let facet=String(decoding:try JSONEncoder().encode(facets),as:UTF8.self)
        return try await request("/search",query:[.init(name:"query",value:query),.init(name:"facets",value:facet),.init(name:"limit",value:"30"),.init(name:"offset",value:String(offset)),.init(name:"index",value:query.isEmpty ? "downloads":"relevance")])
    }
    static func versions(_ project:String,game:GameInstance,kind:ContentKind)async throws->[AddonVersion]{
        guard project.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else{throw FileTransactions.error("项目 ID 无效。")}
        var query=[URLQueryItem(name:"include_changelog",value:"false")];if !game.version.isEmpty{query.append(.init(name:"game_versions",value:String(decoding:try JSONEncoder().encode([game.version]),as:UTF8.self)))}
        if kind == .mods {query.append(.init(name:"loaders",value:String(decoding:try JSONEncoder().encode([loader(game)]),as:UTF8.self)))}
        return try await request("/project/"+project+"/version",query:query)
    }
    static func plan(_ chosen:AddonVersion,game:GameInstance,kind:ContentKind)async throws->[AddonPlanItem]{
        var seen:Set<String>=[];var items:[AddonPlanItem]=[]
        func visit(_ version:AddonVersion)async throws{
            try Task.checkCancellation();guard !seen.contains(version.projectId) else{return};seen.insert(version.projectId)
            guard seen.count<=40 else{throw FileTransactions.error("必要依赖超过本次安装上限。")}
            guard game.version.isEmpty || version.gameVersions.contains(game.version),kind != .mods || version.loaders.contains(loader(game)) else{throw FileTransactions.error("依赖与此实例的版本或加载器不兼容。")}
            for dependency in version.dependencies where dependency.dependencyType=="required" && kind != .modpacks && kind != .worlds {
                let next:AddonVersion
                if let id=dependency.versionId{guard id.range(of:"^[A-Za-z0-9]+$",options:.regularExpression) != nil else{throw FileTransactions.error("依赖版本无效。")};next=try await request("/version/"+id)}
                else if let id=dependency.projectId,let value=try await versions(id,game:game,kind:kind).first{next=value}
                else{throw FileTransactions.error("无法自动获取必要依赖："+(dependency.fileName ?? "未知依赖"))}
                try await visit(next)
            }
            guard let file=version.files.first(where:{$0.primary}) ?? version.files.first else{throw FileTransactions.error("该版本没有可下载文件。")}
            guard !file.filename.contains("/"),!file.filename.contains("\\"),!file.filename.hasPrefix("."),["jar","zip","mrpack"].contains(URL(fileURLWithPath:file.filename).pathExtension.lowercased()),file.size>0,file.size<2_000_000_000 else{throw FileTransactions.error("下载文件名或大小无效。")}
            items.append(AddonPlanItem(version:version,file:file))
        }
        try await visit(chosen);return items
    }
    static func verify(_ url:URL,file:AddonFile)throws->Bool{
        guard let value=try? url.resourceValues(forKeys:[.fileSizeKey]),Int64(value.fileSize ?? -1)==file.size else{return false}
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()};var sha512=SHA512();var sha1=Insecure.SHA1();var md5=Insecure.MD5()
        while let data=try handle.read(upToCount:512*1024),!data.isEmpty{sha512.update(data:data);sha1.update(data:data);md5.update(data:data)}
        if let expected=file.hashes["sha512"]{return sha512.finalize().map{String(format:"%02x",$0)}.joined()==expected.lowercased()}
        if let expected=file.hashes["sha1"]{return sha1.finalize().map{String(format:"%02x",$0)}.joined()==expected.lowercased()}
        if let expected=file.hashes["md5"]{return md5.finalize().map{String(format:"%02x",$0)}.joined()==expected.lowercased()}
        return false
    }
    private static func modIndex(_ run:URL,game:GameInstance)async throws->[[String:Any]]{
        let root=URL(fileURLWithPath:game.directory).deletingLastPathComponent().deletingLastPathComponent()
        return try await withCheckedThrowingContinuation{continuation in
            do{_ = try JavaBridge.start(input:["command":"mods","root":root.path,"id":game.id,"runDirectory":run.path],event:{_ in},completion:{result in switch result{case .success(let data):continuation.resume(returning:data["mods"] as? [[String:Any]] ?? []);case .failure(let error):continuation.resume(throwing:error)}})}catch{continuation.resume(throwing:error)}
        }
    }
    /// All files are checked before the instance is changed. Replaced versions stay in .harbor/previous.
    static func install(_ plan:[AddonPlanItem],game:GameInstance,kind:ContentKind,source:String="auto",beforeCommit:@escaping @Sendable()async throws->Void={},willCommit:@escaping @Sendable()async throws->Void={},progress:@escaping @Sendable(Double,String)async->Void)async throws{
        let fm=FileManager.default;let run=URL(fileURLWithPath:game.runDirectory);let destination=run.appendingPathComponent(kind.rawValue);try fm.createDirectory(at:destination,withIntermediateDirectories:true)
        let total=plan.reduce(Int64(0)){$0+$1.file.size};let free=(try destination.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])).volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard free>total+64*1024*1024 else{throw FileTransactions.error("可用磁盘空间不足。")}
        let stage=run.appendingPathComponent(".harbor-download-"+UUID().uuidString);try fm.createDirectory(at:stage,withIntermediateDirectories:false);defer{try? fm.removeItem(at:stage)}
        let receiptURL=run.appendingPathComponent(".harbor/modrinth-installed.json")
        var toCommit:[AddonPlanItem]=[]
        let stagedFiles=stage.appendingPathComponent(kind == .mods ? "mods":"content");try fm.createDirectory(at:stagedFiles,withIntermediateDirectories:true)
        for (index,item) in plan.enumerated(){
            try Task.checkCancellation();await progress(Double(index)/Double(max(plan.count,1)),item.file.filename)
            let target=destination.appendingPathComponent(item.file.filename)
            if fm.fileExists(atPath:target.path),try await Task.detached(operation:{try verify(target,file:item.file)}).value{continue}
            guard let url=URL(string:item.file.url) else{throw FileTransactions.error("资源地址无效。")}
            let local=stagedFiles.appendingPathComponent(item.file.filename)
            if url.isFileURL {
                let allowed=NativePaths.root.appendingPathComponent("mod-collections/files").standardizedFileURL.resolvingSymlinksInPath().path+"/"
                guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(allowed),(try url.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else{throw FileTransactions.error("本地收藏不属于此启动器的模组夹。")}
                try await Task.detached{try fm.copyItem(at:url,to:local)}.value
            }else{
                guard url.scheme=="https" else{throw FileTransactions.error("下载地址无效。")}
                _ = try await ResourceTransfer.download(item.file,to:local,source:source){fraction,message in await progress((Double(index)+fraction)/Double(max(plan.count,1)),message)}
            }
            guard try await Task.detached(operation:{try verify(local,file:item.file)}).value else{throw FileTransactions.error("文件完整性校验失败："+item.file.filename)}
            toCommit.append(item)
        }
        try Task.checkCancellation()
        try await beforeCommit()
        let commitKey=run.standardizedFileURL.resolvingSymlinksInPath().path
        try await ResourceCommitGate.shared.acquire(commitKey);defer{Task{await ResourceCommitGate.shared.release(commitKey)}}
        try await beforeCommit()
        var receipts=(try? JSONDecoder().decode([AddonReceipt].self,from:Data(contentsOf:receiptURL))) ?? []
        var replacementPaths:Set<URL>=[]
        for item in toCommit{for old in receipts where old.projectId==item.version.projectId && old.kind==kind.rawValue{let url=destination.appendingPathComponent(old.filename);if fm.fileExists(atPath:url.path){replacementPaths.insert(url)}}}
        if kind == .mods,!toCommit.isEmpty{
            let incoming=try await modIndex(stage,game:game)
            let incomingIDs=incoming.compactMap{$0["modId"] as? String}.filter{!$0.isEmpty}
            guard Set(incomingIDs).count==incomingIDs.count else{throw FileTransactions.error("所选模组中包含同一模组的多个版本，请先移除重复项。")}
            let ids=Set(incomingIDs)
            let existing=try await modIndex(run,game:game)
            for file in existing{if let id=file["modId"] as? String,ids.contains(id),let path=file["path"] as? String{replacementPaths.insert(URL(fileURLWithPath:path))}}
        }
        for item in toCommit{let target=destination.appendingPathComponent(item.file.filename);if fm.fileExists(atPath:target.path),!replacementPaths.contains(target){throw FileTransactions.error("同名文件属于不同内容，未覆盖："+item.file.filename)}}
        try await willCommit()
        var replaced:[(URL,URL)]=[];var installed:[URL]=[]
        let previous=run.appendingPathComponent(".harbor/previous/"+UUID().uuidString)
        do{
            for oldURL in replacementPaths{
                let prefix=destination.standardizedFileURL.path+"/";guard oldURL.standardizedFileURL.path.hasPrefix(prefix) else{throw FileTransactions.error("旧版本文件不在此实例目录中。")}
                let relative=String(oldURL.standardizedFileURL.path.dropFirst(run.standardizedFileURL.path.count+1));let saved=previous.appendingPathComponent(relative)
                try fm.createDirectory(at:saved.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.moveItem(at:oldURL,to:saved);replaced.append((oldURL,saved))
            }
            for item in toCommit{
                let target=destination.appendingPathComponent(item.file.filename);try fm.moveItem(at:stagedFiles.appendingPathComponent(item.file.filename),to:target);installed.append(target)
            }
            for item in plan{receipts.removeAll{$0.projectId==item.version.projectId && $0.kind==kind.rawValue};receipts.append(AddonReceipt(projectId:item.version.projectId,versionId:item.version.id,filename:item.file.filename,kind:kind.rawValue))}
            try fm.createDirectory(at:receiptURL.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(receipts).write(to:receiptURL,options:.atomic)
        }catch{for path in installed{try? fm.moveItem(at:path,to:stagedFiles.appendingPathComponent(path.lastPathComponent))};for pair in replaced.reversed(){try? fm.moveItem(at:pair.1,to:pair.0)};throw error}
        await progress(1,"安装完成")
    }
}

@MainActor extension LauncherModel {
    func installAddon(_ plan:[AddonPlanItem],game:GameInstance,kind:ContentKind,title:String){
        if kind == .worlds || kind == .modpacks{if let selected=plan.last{installArchiveResource(selected,game:game,kind:kind,title:title)};return}
        resourceDownloadNotice(title:title,game:game)
        let job=WorkItem(title:"安装 "+title);works.insert(job,at:0)
        let task=Task{defer{finishResourceCommit(game,jobID:job.id)};do{try await AddonService.install(plan,game:game,kind:kind,source:preferences.downloadSource,beforeCommit:{try await self.waitForResourceInstall(game,jobID:job.id)},willCommit:{try await self.beginResourceCommit(game,jobID:job.id)}){value,message in await MainActor.run{if let index=self.works.firstIndex(where:{$0.id==job.id}){self.works[index].progress=value;self.works[index].detail=message}}};contentDidChange(game);toast(title+" 已安装");HarborAudio.shared.play(.success)}catch{if let index=works.firstIndex(where:{$0.id==job.id}){works[index].error=true;works[index].detail=error is CancellationError ? "已取消":error.localizedDescription};if !(error is CancellationError){errorMessage=error.localizedDescription}};if let index=works.firstIndex(where:{$0.id==job.id}){works[index].active=false};nativeTasks.removeValue(forKey:job.id)}
        nativeTasks[job.id]=task
    }
}

struct AddonBrowser:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    let kind:ContentKind
    var embedded=false
    @State private var section:ModSection = .all
    @State private var source:AddonSource = .modrinth
    @State private var page=0
    @State private var query=""
    @State private var queryUsed=""
    @State private var result:AddonSearch?
    @State private var selected:AddonProject?
    @State private var versions:[AddonVersion]=[]
    @State private var versionID=""
    @State private var plan:[AddonPlanItem]=[]
    @State private var loading=false
    @State private var preparing=false
    @State private var failure=""
    @State private var searchTask:Task<Void,Never>?
    @State private var showingRecommendations=true
    @State private var recommendations:[RecommendedMod]=[]
    @State private var recommending=false
    @ObservedObject private var remarks=ModRemarkStore.shared
    @State private var remarkListFilter=""
    @State private var remarkListID="personal"
    @State private var remarkName=""
    @State private var newListName=""
    @State private var creatingList=false
    @State private var editingRemark=false
    @State private var pendingRemark:ModRemark?
    private var localRemarks:[ModRemark]{remarks.matches(query,listID:remarkListFilter)}
    private var canRecommend:Bool{kind == .mods && source == .modrinth}
    private var selectedVersion:AddonVersion?{versions.first{$0.id==versionID}}
    private var installedMods:[ModFile]{model.modMetadata[game.id] ?? NativeScanner.mods(game)}
    private var selectedSuggestion:ModSuggestion?{recommendations.first{$0.project.id==selected?.id}?.suggestion}
    var body:some View{
        VStack(spacing:0){
            if !embedded{HStack{VStack(alignment:.leading,spacing:5){Text("下载"+kind.title).font(.system(size:25,weight:.semibold));Text(game.version+" · "+game.loader).font(.system(size:11)).harborSecondaryText()};Spacer();Button{model.modal=nil}label:{HarborSymbol(systemName:"xmark")}.buttonStyle(HarborButtonStyle())}.padding(25)}
            browserToolbar
            Divider().opacity(0.25)
            HStack(spacing:0){
                VStack(spacing:8){
                    if canRecommend && showingRecommendations && remarkListFilter.isEmpty{
                        if recommending{HarborActivityIndicator().controlSize(.small)}
                        ScrollView{LazyVStack(spacing:7){ForEach(recommendations){item in projectButton(item.project,suggestion:item.suggestion)};if !recommending && recommendations.isEmpty{Text("此版本暂未找到适配推荐，可搜索全部模组。").font(.system(size:12)).harborSecondaryText().padding()}}}.harborHideScrollIndicators()
                    }else{
                        if loading{HarborActivityIndicator().controlSize(.small)}
                        ScrollView{LazyVStack(spacing:5){
                            if kind == .mods && !localRemarks.isEmpty{Text("我的备注").font(.system(size:11,weight:.semibold)).frame(maxWidth:.infinity,alignment:.leading);ForEach(localRemarks){remark in remarkButton(remark)};Divider()}
                            if remarkListFilter.isEmpty{ForEach(result?.hits ?? []){project in projectButton(project)}}else if localRemarks.isEmpty{Text("此列表暂无匹配备注。选择模组后可保存到这里。").font(.system(size:11)).harborSecondaryText().padding()}
                        }}.harborHideScrollIndicators()
                        if let result,remarkListFilter.isEmpty{HStack{Text("平台 \(result.totalHits) 个结果");Spacer();Button{page=max(0,page-1);search()}label:{HarborSymbol(systemName:"chevron.left").frame(width:28,height:28)}.disabled(page==0);Text("\(page+1)");Button{page+=1;search()}label:{HarborSymbol(systemName:"chevron.right").frame(width:28,height:28)}.disabled((page+1)*30>=result.totalHits)}.buttonStyle(HarborBareButtonStyle()).font(.system(size:10)).foregroundStyle(.secondary)}
                    }
                }.padding(12).frame(minWidth:310,maxWidth:400)
                Divider().opacity(0.35)
                detail.frame(maxWidth:.infinity,maxHeight:.infinity)
            }.frame(maxHeight:.infinity)
        }
        .task{if kind == .worlds{source = .curseforge};if kind == .mods{model.loadMods(game)};search()}
        .task(id:canRecommend ? game.id+game.version+game.loader:""){if canRecommend{recommending=true;defer{recommending=false};do{recommendations=try await ModDiscovery.recommendations(game:game)}catch{if !Task.isCancelled{failure=error.localizedDescription}}}}
        .harborOnChange(of:section){_,_ in page=0;showingRecommendations=false;search()}
        .harborOnChange(of:source){_,_ in page=0;result=nil;selected=pendingRemark?.project;pendingRemark=nil;search()}
        .harborOnChange(of:remarkListFilter){_,value in if !value.isEmpty{showingRecommendations=false};search()}
        .task(id:source.rawValue+":"+(selected?.id ?? "")){await loadVersions()}.task(id:versionID){await prepare()}
        .onReceive(model.contentChanged){_ in if kind == .mods{model.loadMods(game,force:true)}}
        .onDisappear{searchTask?.cancel()}
    }
    private var browserToolbar:some View {
        VStack(spacing:9){
            HStack(spacing:12){
                Picker("来源",selection:$source){Text("Modrinth").tag(AddonSource.modrinth).disabled(kind == .worlds);Text("CurseForge").tag(AddonSource.curseforge)}.pickerStyle(.segmented).labelsHidden().frame(width:200)
                if canRecommend{Picker("浏览方式",selection:$showingRecommendations){Text("精选推荐").tag(true);Text("搜索全部").tag(false)}.pickerStyle(.segmented).labelsHidden().frame(width:160)}
                if kind == .mods{Picker("分区",selection:$section){ForEach(ModSection.allCases){Text($0.title).tag($0)}}.labelsHidden().frame(width:100)}
                Spacer(minLength:0)
                Toggle("简介汉化",isOn:$model.preferences.translateModDescriptions).toggleStyle(.switch).controlSize(.mini).font(.system(size:11)).fixedSize().help("开启后只显示完成的中文简介；等待时加载中，失败可重试。")
            }
            HStack(spacing:12){
                SearchBox(prompt:remarkListFilter.isEmpty ? "中英文名称、关键词或备注":"搜索此列表的备注或模组",query:$query).onSubmit{showingRecommendations=false;search()}.harborOnChange(of:query){_,_ in if !query.isEmpty{showingRecommendations=false};search(debounce:true)}.help(queryUsed != query && !queryUsed.isEmpty ? "平台搜索词："+queryUsed:"中英文名称与自定义备注均可搜索")
                if kind == .mods{remarkLists.frame(width:240)}
            }
        }.padding(.horizontal,16).padding(.vertical,12)
    }
    private var remarkLists:some View{
        VStack(spacing:8){HStack{Picker("备注列表",selection:$remarkListFilter){Text("全部列表").tag("");ForEach(remarks.lists){Text($0.name).tag($0.id)}}.labelsHidden();Button{creatingList.toggle()}label:{HarborSymbol(systemName:"plus").frame(width:25,height:25)}.buttonStyle(HarborBareButtonStyle()).help("新建备注列表")}
            if creatingList{HStack{TextField("新列表名称",text:$newListName).textFieldStyle(.roundedBorder);Button("创建"){do{let id=try remarks.createList(newListName);remarkListFilter=id;remarkListID=id;newListName="";creatingList=false}catch{failure=error.localizedDescription}}.buttonStyle(HarborButtonStyle())}}
        }
    }
    private func remarkButton(_ remark:ModRemark)->some View{
        Button{remarkName=remark.name;remarkListID=remark.listID;if source != remark.source{pendingRemark=remark;source=remark.source}else{selected=remark.project}}label:{HStack(spacing:10){AddonIcon(url:remark.project.iconUrl).frame(width:34,height:34);VStack(alignment:.leading,spacing:4){Text(remark.name).font(.system(size:13,weight:.semibold));Text(remark.project.title+" · "+remarks.listName(remark.listID)+" · "+remark.source.title).font(.system(size:10)).harborSecondaryText().lineLimit(2)};Spacer()}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:14)).contentShape(RoundedRectangle(cornerRadius:14))}.buttonStyle(HarborBareButtonStyle())
    }
    private func remarkEditor(_ project:AddonProject)->some View{
        VStack(alignment:.leading,spacing:9){Text("我的备注").font(.system(size:12,weight:.semibold));TextField("输入以后想用来搜索的备注名",text:$remarkName).textFieldStyle(.roundedBorder);HStack{Picker("保存到",selection:$remarkListID){ForEach(remarks.lists){Text($0.name).tag($0.id)}};Button("保存"){do{try remarks.save(project:project,source:source,name:remarkName,listID:remarkListID);model.toast("备注已保存，可用备注名搜索")}catch{failure=error.localizedDescription}}.buttonStyle(HarborButtonStyle());if remarks.entry(project.id,source:source,listID:remarkListID) != nil{Button("移除备注"){do{try remarks.remove(project.id,source:source,listID:remarkListID);remarkName=""}catch{failure=error.localizedDescription}}.buttonStyle(HarborBareButtonStyle())}}}.padding(14).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
    }
    private func projectButton(_ project:AddonProject,suggestion:ModSuggestion?=nil)->some View{
        Button{selected=project;HarborAudio.shared.play(.navigate)}label:{
            HStack(alignment:.top,spacing:12){AddonIcon(url:project.iconUrl).frame(width:43,height:43);VStack(alignment:.leading,spacing:5){
                HStack{ModProjectName(project:project,enabled:kind == .mods,preferred:suggestion?.chinese).font(.system(size:13,weight:.medium)).lineLimit(1);if let suggestion,ModDiscovery.installed(suggestion,mods:installedMods){Text("已安装").font(.system(size:9)).foregroundStyle(model.accentTextColor)}}
                Text(suggestion == nil ? project.author:project.title).font(.system(size:10)).harborSecondaryText()
                if let suggestion{Text(suggestion.reason).font(.system(size:11)).harborSecondaryText().lineLimit(2)}else{ModSummaryText(text:project.description,enabled:model.preferences.translateModDescriptions,compact:true,projectID:project.id,source:source)}
            };Spacer(minLength:0)}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(model.controlTint.opacity(selected?.id==project.id ? 0.11:0.025),in:RoundedRectangle(cornerRadius:16)).contentShape(RoundedRectangle(cornerRadius:16))
        }.buttonStyle(HarborBareButtonStyle())
    }
    @ViewBuilder private var detail:some View{
        if let project=selected{ScrollView{VStack(alignment:.leading,spacing:20){
            HStack(spacing:16){AddonIcon(url:project.iconUrl).frame(width:56,height:56);ModProjectName(project:project,enabled:kind == .mods).font(.system(size:26,weight:.semibold));Spacer(minLength:0)}
            if kind == .mods{HStack{Button("备注…"){editingRemark=true}.buttonStyle(HarborButtonStyle()).popover(isPresented:$editingRemark){remarkEditor(project).frame(width:360).padding(12)};Menu("收藏到模组夹"){ForEach(ModCollectionStore.shared.folders){folder in Button(folder.name){do{try ModCollectionStore.shared.add(project,source:source,to:folder.id,version:selectedVersion);model.toast("已收藏")}catch{failure=error.localizedDescription}}};Button("新建模组夹…"){do{if let id=try ModCollectionStore.shared.promptCreate(){try ModCollectionStore.shared.add(project,source:source,to:id,version:selectedVersion)}}catch{failure=error.localizedDescription}}}.buttonStyle(HarborButtonStyle())}}
            if let suggestion=selectedSuggestion{Text(suggestion.chinese+" · "+suggestion.reason).font(.system(size:13)).foregroundStyle(model.accentTextColor)}
            ModSummaryText(text:project.description,enabled:model.preferences.translateModDescriptions,compact:false,projectID:project.id,source:source)
            HStack{Text(project.author);Spacer();Text(project.downloads,format:.number.notation(.compactName));HarborSymbol(systemName:"arrow.down")}.font(.system(size:11)).foregroundStyle(.secondary)
            if preparing{HarborActivityIndicator().controlSize(.small)}
            if !versions.isEmpty{Picker("版本",selection:$versionID){ForEach(versions){Text($0.versionNumber).tag($0.id)}}}
            if !plan.isEmpty{Divider().opacity(0.35);ForEach(plan){item in HStack(alignment:.top){Image(systemName:item.version.id==versionID ? "shippingbox":"link").foregroundStyle(model.accentTextColor);VStack(alignment:.leading,spacing:4){Text(item.version.name).font(.system(size:12));Text(item.file.filename).font(.system(size:9,design:.monospaced)).harborSecondaryText().lineLimit(2)};Spacer();Text(ByteCountFormatter.string(fromByteCount:item.file.size,countStyle:.file)).font(.system(size:10)).harborSecondaryText()}};Button{model.installAddon(plan,game:game,kind:kind,title:project.title);if !embedded{model.modal=nil}}label:{Label("安装到 "+model.displayName(game),systemImage:"arrow.down.circle.fill").frame(maxWidth:.infinity)}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(preparing)}
            if !failure.isEmpty{Text(failure).font(.system(size:12)).harborSecondaryText()}
            Button("查看项目页面"){if let url=URL(string:project.pageUrl ?? "https://modrinth.com/"+kind.projectType+"/"+project.id){NSWorkspace.shared.open(url)}}.buttonStyle(HarborBareButtonStyle()).font(.system(size:11))
        }.padding(28)}}else{VStack(spacing:14){Image(systemName:kind.symbol).font(.system(size:42,weight:.ultraLight)).foregroundStyle(model.themeColor.opacity(0.65));Text(failure.isEmpty ? (game.loader=="Minecraft" && kind == .mods ? "此实例尚未安装模组加载器":"选择"+kind.title+"，查看用途与安装依赖"):failure).font(.system(size:15)).harborSecondaryText()}}
    }
    private func search(debounce:Bool=false){
        searchTask?.cancel();if debounce{page=0};if !remarkListFilter.isEmpty{loading=false;result=nil;return};let value=query;let chosenSource=source;let currentPage=page;let currentSection=section
        searchTask=Task{if debounce{try? await HarborDelay.sleep(seconds:0.6);guard !Task.isCancelled else{return}};loading=true;defer{if !Task.isCancelled{loading=false}}
            let effective=await ModTextTranslation.searchQuery(value);guard !Task.isCancelled else{return};queryUsed=effective
            do{let response=try await ResourceService.search(currentSection.query(effective,source:chosenSource),game:game,kind:kind,source:chosenSource,page:currentPage,section:currentSection);guard !Task.isCancelled else{return};result=response;failure=""}catch{if !Task.isCancelled{failure=error.localizedDescription}}
        }
    }
    private func loadVersions()async{versions=[];versionID="";plan=[];guard let selected else{return};let saved=remarks.entry(selected.id,source:source,listID:remarkListFilter.isEmpty ? remarkListID:remarkListFilter) ?? remarks.entry(selected.id,source:source);remarkName=saved?.name ?? "";remarkListID=saved?.listID ?? remarks.lists.first?.id ?? "personal";preparing=true;defer{preparing=false};do{let values=try await ResourceService.versions(selected.id,game:game,kind:kind,source:source);try Task.checkCancellation();versions=values;versionID=values.first?.id ?? "";failure=values.isEmpty ? "暂无适配此实例的版本。":""}catch{if !Task.isCancelled{failure=error.localizedDescription}}}
    private func prepare()async{plan=[];guard let version=selectedVersion else{return};preparing=true;defer{preparing=false};do{let result=try await ResourceService.plan(version,game:game,kind:kind,source:source);try Task.checkCancellation();plan=result;failure=""}catch{if !Task.isCancelled{failure=error.localizedDescription}}}
}
/// The same name path is used by recommendations, all search pages and project details.
struct ModProjectName:View {
    let project:AddonProject
    var enabled=true
    var preferred:String?=nil
    @AppStorage("harbor.translationProvider") private var provider="bilibili"
    @State private var chinese:String?
    @State private var completedKey=""
    private var key:String{project.id+"/"+project.title+"/"+provider}
    var body:some View {
        Text(preferred ?? (completedKey==key ? chinese:nil) ?? project.title)
            .help(project.title)
            .task(id:key+String(enabled)){
                guard enabled else{return}
                let requestKey=key
                let value=await ModNameIndex.projectName(project,provider:provider)
                guard !Task.isCancelled,requestKey==key else{return};chinese=value;completedKey=requestKey
            }
    }
}

enum ModSummaryPresentation:Equatable {
    case original(String),loading,translated(String),failed
    static func state(text:String,enabled:Bool,original:Bool,value:String?,failed:Bool)->Self {
        guard enabled,needsTranslation(text),!original else{return .original(text)}
        if let value{return .translated(value)}
        return failed ? .failed:.loading
    }
    static func needsTranslation(_ text:String)->Bool{!text.isEmpty && !ModDiscovery.identifierOnly(text) && text.range(of:"[A-Za-z]",options:.regularExpression) != nil}
}
struct ModSummaryText:View {
    let text:String;let enabled:Bool;let compact:Bool
    var projectID:String?=nil
    var source:AddonSource = .modrinth
    @AppStorage("harbor.translationProvider") private var provider="bilibili"
    @State private var translated:String?
    @State private var original=false
    @State private var failed=false
    @State private var retry=0
    @State private var completedKey=""
    private var key:String{source.rawValue+"/"+(projectID ?? "")+"/"+provider+"/"+text+String(enabled)+String(retry)}
    private var needsTranslation:Bool{enabled && ModSummaryPresentation.needsTranslation(text)}
    private var presentation:ModSummaryPresentation{ModSummaryPresentation.state(text:text,enabled:enabled,original:completedKey==key && original,value:completedKey==key ? translated:nil,failed:completedKey==key && failed)}
    var body:some View{
        VStack(alignment:.leading,spacing:6){
            switch presentation {
            case .original(let value),.translated(let value):Text(value).font(.system(size:compact ? 11:12)).harborSecondaryText().lineLimit(compact ? 2:nil)
            case .loading:HStack(spacing:6){HarborActivityIndicator().controlSize(.mini);Text("加载中…").font(.system(size:compact ? 11:12)).harborSecondaryText()}.frame(minHeight:compact ? 28:38,alignment:.leading).accessibilityLabel("中文简介加载中")
            case .failed:Button("简介汉化未完成 · 点击重试"){retry+=1}.font(.system(size:11)).buttonStyle(HarborBareButtonStyle())
            }
            if !compact && needsTranslation,completedKey==key,translated != nil{
                HStack{Button(original ? "查看中文译文":"查看原文"){original.toggle()}.buttonStyle(HarborBareButtonStyle());Text("在线机器翻译").foregroundStyle(.tertiary)}.font(.system(size:10))
            }
        }.task(id:key){
            let requestKey=key,selectedProvider=provider
            translated=nil;original=false;failed=false
            guard needsTranslation else{return}
            do{
                let cached=await ModTextTranslation.shared.cached(text,provider:selectedProvider)
                let mirror:String?
                if let cached{mirror=cached}else{mirror=await MCIMSummaryStore.shared.translation(project:projectID,source:source,original:text)}
                let value:String
                if let mirror{value=mirror}else{value=try await ModTextTranslation.shared.translate(text,provider:selectedProvider)}
                try Task.checkCancellation();guard requestKey==key else{return};translated=value;completedKey=requestKey
            }catch{if !Task.isCancelled,requestKey==key{failed=true;completedKey=requestKey}}
        }
    }
}
private struct AddonIcon:View {
    let url:String?
    var body:some View{AsyncImage(url:ResourceMirror.artworkURL(url ?? "")){image in image.resizable().scaledToFit()}placeholder:{RoundedRectangle(cornerRadius:12).fill(Color.primary.opacity(0.045)).overlay(Image(systemName:"shippingbox").foregroundStyle(.secondary))}.clipShape(RoundedRectangle(cornerRadius:12))}
}

private actor ResourceCommitGate {
    static let shared=ResourceCommitGate()
    private var active:Set<String>=[]
    func acquire(_ key:String)async throws{while active.contains(key){try await HarborDelay.sleep(seconds:0.1)};try Task.checkCancellation();active.insert(key)}
    func release(_ key:String){active.remove(key)}
}
struct InstalledModTranslation:View {
    @ObservedObject var model:LauncherModel
    let mod:ModFile
    var body:some View{VStack(alignment:.leading,spacing:5){ModProjectName(project:AddonProject(projectId:mod.modID,title:mod.name,description:mod.summary,author:"",iconUrl:nil,downloads:0,pageUrl:nil),preferred:ModDiscovery.chineseName(mod).isEmpty ? nil:ModDiscovery.chineseName(mod)).font(.system(size:13,weight:.medium));if !mod.summary.isEmpty{ModSummaryText(text:mod.summary,enabled:true,compact:true)}else{ModSummaryText(text:mod.name,enabled:true,compact:true)}}.id(mod.id)}
}
