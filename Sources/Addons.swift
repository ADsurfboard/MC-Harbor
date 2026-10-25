import AppKit
import CryptoKit
import SwiftUI

struct AddonProject:Decodable,Identifiable,Sendable {
    let projectId:String
    let title:String
    let description:String
    let author:String
    let iconUrl:String?
    let downloads:Int
    let pageUrl:String?
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
    static let session:URLSession={let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=20;c.timeoutIntervalForResource=180;c.httpAdditionalHeaders=["User-Agent":"MC-harbor/1.0 (native macOS launcher; local personal build)"];return URLSession(configuration:c)}()
    private static let decoder:JSONDecoder={let d=JSONDecoder();d.keyDecodingStrategy = .convertFromSnakeCase;return d}()
    static func loader(_ game:GameInstance)->String{game.loader == "Legacy Fabric" ? "fabric":game.loader == "Cleanroom" ? "forge":game.loader.lowercased()}
    static func request<T:Decodable>(_ path:String,query:[URLQueryItem]=[])async throws->T{
        var components=URLComponents(string:"https://api.modrinth.com/v2"+path)!;components.queryItems=query
        let (data,response)=try await session.data(from:components.url!)
        guard let http=response as? HTTPURLResponse,http.statusCode==200 else{throw FileTransactions.error("Modrinth 暂不可用，请稍后重试。")}
        guard data.count<24_000_000 else{throw FileTransactions.error("服务返回的数据过大。")}
        return try decoder.decode(T.self,from:data)
    }
    static func search(_ query:String,game:GameInstance,kind:ContentKind,offset:Int=0)async throws->AddonSearch{
        var facets=[["project_type:"+kind.projectType]];if !game.version.isEmpty{facets.append(["versions:"+game.version])}
        if kind == .mods {guard game.loader != "Minecraft" else{return AddonSearch(hits:[],totalHits:0)};facets.append(["categories:"+loader(game)])}
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
    static func install(_ plan:[AddonPlanItem],game:GameInstance,kind:ContentKind,progress:@escaping @Sendable(Double,String)async->Void)async throws{
        let fm=FileManager.default;let run=URL(fileURLWithPath:game.runDirectory);let destination=run.appendingPathComponent(kind.rawValue);try fm.createDirectory(at:destination,withIntermediateDirectories:true)
        let total=plan.reduce(Int64(0)){$0+$1.file.size};let free=(try destination.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])).volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard free>total+64*1024*1024 else{throw FileTransactions.error("可用磁盘空间不足。")}
        let stage=run.appendingPathComponent(".harbor-download-"+UUID().uuidString);try fm.createDirectory(at:stage,withIntermediateDirectories:false);defer{try? fm.removeItem(at:stage)}
        let receiptURL=run.appendingPathComponent(".harbor/modrinth-installed.json");var receipts=(try? JSONDecoder().decode([AddonReceipt].self,from:Data(contentsOf:receiptURL))) ?? []
        var toCommit:[AddonPlanItem]=[]
        let stagedFiles=stage.appendingPathComponent(kind == .mods ? "mods":"content");try fm.createDirectory(at:stagedFiles,withIntermediateDirectories:true)
        for (index,item) in plan.enumerated(){
            try Task.checkCancellation();await progress(Double(index)/Double(max(plan.count,1)),item.file.filename)
            let target=destination.appendingPathComponent(item.file.filename)
            if fm.fileExists(atPath:target.path),try await Task.detached(operation:{try verify(target,file:item.file)}).value{continue}
            guard let url=URL(string:item.file.url),url.scheme=="https" else{throw FileTransactions.error("下载地址无效。")}
            let (temporary,response)=try await session.download(from:url)
            guard (response as? HTTPURLResponse)?.statusCode==200 else{throw FileTransactions.error("文件下载失败："+item.file.filename)}
            let local=stagedFiles.appendingPathComponent(item.file.filename);try fm.moveItem(at:temporary,to:local)
            guard try await Task.detached(operation:{try verify(local,file:item.file)}).value else{throw FileTransactions.error("文件完整性校验失败："+item.file.filename)}
            toCommit.append(item)
        }
        try Task.checkCancellation()
        var replacementPaths:Set<URL>=[]
        for item in toCommit{for old in receipts where old.projectId==item.version.projectId && old.kind==kind.rawValue{let url=destination.appendingPathComponent(old.filename);if fm.fileExists(atPath:url.path){replacementPaths.insert(url)}}}
        if kind == .mods,!toCommit.isEmpty{
            let incoming=try await modIndex(stage,game:game)
            let ids=Set(incoming.compactMap{$0["modId"] as? String}.filter{!$0.isEmpty})
            let existing=try await modIndex(run,game:game)
            for file in existing{if let id=file["modId"] as? String,ids.contains(id),let path=file["path"] as? String{replacementPaths.insert(URL(fileURLWithPath:path))}}
        }
        for item in toCommit{let target=destination.appendingPathComponent(item.file.filename);if fm.fileExists(atPath:target.path),!replacementPaths.contains(target){throw FileTransactions.error("同名文件属于不同内容，未覆盖："+item.file.filename)}}
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
        guard !running.contains(game.id) else{errorMessage="请退出此实例后再安装。";return}
        if kind == .worlds || kind == .modpacks{if let selected=plan.last{installArchiveResource(selected,game:game,kind:kind,title:title)};return}
        let job=WorkItem(title:"安装 "+title);works.insert(job,at:0)
        let task=Task{do{try await AddonService.install(plan,game:game,kind:kind){value,message in await MainActor.run{if let index=self.works.firstIndex(where:{$0.id==job.id}){self.works[index].progress=value;self.works[index].detail=message}}};contentDidChange(game);toast(title+" 已安装");HarborAudio.shared.play(.success)}catch{if let index=works.firstIndex(where:{$0.id==job.id}){works[index].error=true;works[index].detail=error is CancellationError ? "已取消":error.localizedDescription};if !(error is CancellationError){errorMessage=error.localizedDescription}};if let index=works.firstIndex(where:{$0.id==job.id}){works[index].active=false};nativeTasks.removeValue(forKey:job.id)}
        nativeTasks[job.id]=task
    }
}

struct AddonBrowser:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    let kind:ContentKind
    var embedded=false
    @State private var source:AddonSource = .modrinth
    @State private var page=0
    @State private var query=""
    @State private var result:AddonSearch?
    @State private var selected:AddonProject?
    @State private var versions:[AddonVersion]=[]
    @State private var versionID=""
    @State private var plan:[AddonPlanItem]=[]
    @State private var loading=false
    @State private var preparing=false
    @State private var failure=""
    @State private var searchTask:Task<Void,Never>?
    private var selectedVersion:AddonVersion?{versions.first{$0.id==versionID}}
    var body:some View{
        VStack(spacing:0){if !embedded{HStack{VStack(alignment:.leading,spacing:5){Text("下载"+kind.title).font(.system(size:25,weight:.semibold));Text(game.version+" · "+(kind == .mods ? game.loader:"Modrinth")).font(.system(size:11)).foregroundStyle(.secondary)};Spacer();Button{model.modal=nil}label:{Image(systemName:"xmark")}.buttonStyle(HarborButtonStyle())}.padding(25)}
            HStack(spacing:0){VStack(spacing:12){Picker("来源",selection:$source){Text("Modrinth").tag(AddonSource.modrinth).disabled(kind == .worlds);Text("CurseForge").tag(AddonSource.curseforge)}.pickerStyle(.segmented).labelsHidden();SearchBox(prompt:"搜索 "+source.title,query:$query).onSubmit{search()}.onChange(of:query){_,_ in search(debounce:true)};if loading{ProgressView().controlSize(.small)};ScrollView{LazyVStack(spacing:5){ForEach(result?.hits ?? []){project in Button{selected=project;HarborAudio.shared.play(.navigate)}label:{HStack(alignment:.top,spacing:12){AddonIcon(url:project.iconUrl).frame(width:43,height:43);VStack(alignment:.leading,spacing:5){Text(project.title).font(.system(size:13,weight:.medium)).lineLimit(1);Text(project.author).font(.system(size:10)).foregroundStyle(.secondary);Text(project.description).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)};Spacer(minLength:0)}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(model.themeColor.opacity(selected?.id==project.id ? 0.11:0.025),in:RoundedRectangle(cornerRadius:16)).contentShape(RoundedRectangle(cornerRadius:16))}.buttonStyle(HarborBareButtonStyle())}}}.scrollIndicators(.hidden);if let result{HStack{Text("\(result.totalHits) 个结果");Spacer();Button{page=max(0,page-1);search()}label:{Image(systemName:"chevron.left")}.disabled(page==0);Text("\(page+1)");Button{page+=1;search()}label:{Image(systemName:"chevron.right")}.disabled((page+1)*30>=result.totalHits)}.buttonStyle(HarborBareButtonStyle()).font(.system(size:10)).foregroundStyle(.secondary)}}.padding(18).frame(minWidth:310,maxWidth:420)
                Divider().opacity(0.35)
                detail.frame(maxWidth:.infinity,maxHeight:.infinity)
            }.frame(maxHeight:.infinity)
        }
        .task{if kind == .worlds{source = .curseforge};search()}.onChange(of:source){_,_ in page=0;result=nil;selected=nil;search()}.task(id:selected?.id){await loadVersions()}.task(id:versionID){await prepare()}
        .onDisappear{searchTask?.cancel()}
    }
    @ViewBuilder private var detail:some View{
        if let project=selected{ScrollView{VStack(alignment:.leading,spacing:20){AddonIcon(url:project.iconUrl).frame(width:72,height:72);Text(project.title).font(.system(size:28,weight:.semibold));Text(project.description).font(.system(size:12)).foregroundStyle(.secondary);HStack{Text(project.author);Spacer();Text(project.downloads,format:.number.notation(.compactName));Image(systemName:"arrow.down")}.font(.system(size:11)).foregroundStyle(.secondary)
            if preparing{ProgressView().controlSize(.small)}
            if !versions.isEmpty{Picker("版本",selection:$versionID){ForEach(versions){Text($0.versionNumber).tag($0.id)}}}
            if !plan.isEmpty{Divider().opacity(0.35);ForEach(plan){item in HStack(alignment:.top){Image(systemName:item.version.id==versionID ? "shippingbox":"link").foregroundStyle(model.themeColor);VStack(alignment:.leading,spacing:4){Text(item.version.name).font(.system(size:12));Text(item.file.filename).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).lineLimit(2)};Spacer();Text(ByteCountFormatter.string(fromByteCount:item.file.size,countStyle:.file)).font(.system(size:10)).foregroundStyle(.secondary)}};Button{model.installAddon(plan,game:game,kind:kind,title:project.title);model.modal=nil}label:{Label("安装",systemImage:"arrow.down.circle.fill").frame(maxWidth:.infinity)}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(preparing || model.running.contains(game.id))}
            if !failure.isEmpty{Text(failure).font(.system(size:12)).foregroundStyle(.secondary)}
            Button("查看项目页面"){NSWorkspace.shared.open(URL(string:project.pageUrl ?? "https://modrinth.com/"+kind.projectType+"/"+project.id)!)}.buttonStyle(HarborBareButtonStyle()).font(.system(size:11))
        }.padding(28)}}else{VStack(spacing:14){Image(systemName:kind.symbol).font(.system(size:42,weight:.ultraLight)).foregroundStyle(model.themeColor.opacity(0.65));Text(failure.isEmpty ? (game.loader=="Minecraft" && kind == .mods ? "此实例尚未安装模组加载器":"选择"+kind.title):failure).font(.system(size:15)).foregroundStyle(.secondary)}}
    }
    private func search(debounce:Bool=false){searchTask?.cancel();if debounce{page=0};let value=query;let chosenSource=source;let currentPage=page;searchTask=Task{if debounce{try? await Task.sleep(for:.milliseconds(350));guard !Task.isCancelled else{return}};loading=true;defer{if !Task.isCancelled{loading=false}};do{let response=try await ResourceService.search(value,game:game,kind:kind,source:chosenSource,page:currentPage);guard !Task.isCancelled else{return};result=response;failure=""}catch{if !Task.isCancelled{failure=error.localizedDescription}}}}
    private func loadVersions()async{versions=[];versionID="";plan=[];guard let selected else{return};preparing=true;defer{preparing=false};do{let values=try await ResourceService.versions(selected.id,game:game,kind:kind,source:source);try Task.checkCancellation();versions=values;versionID=values.first?.id ?? "";failure=values.isEmpty ? "暂无适配此实例的版本。":""}catch{if !Task.isCancelled{failure=error.localizedDescription}}}
    private func prepare()async{plan=[];guard let version=selectedVersion else{return};preparing=true;defer{preparing=false};do{let result=try await ResourceService.plan(version,game:game,kind:kind,source:source);try Task.checkCancellation();plan=result;failure=""}catch{if !Task.isCancelled{failure=error.localizedDescription}}}
}
private struct AddonIcon:View {
    let url:String?
    var body:some View{AsyncImage(url:URL(string:url ?? "")){image in image.resizable().scaledToFit()}placeholder:{RoundedRectangle(cornerRadius:12).fill(Color.primary.opacity(0.045)).overlay(Image(systemName:"shippingbox").foregroundStyle(.secondary))}.clipShape(RoundedRectangle(cornerRadius:12))}
}
