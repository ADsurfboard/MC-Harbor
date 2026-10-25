import AppKit
import CryptoKit
import SwiftUI

private final class CredentialOriginGuard:NSObject,URLSessionTaskDelegate {
    let origin:URL
    init(_ origin:URL){self.origin=origin}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){guard let url=request.url,url.scheme==origin.scheme,url.host==origin.host,url.port==origin.port else{completionHandler(nil);return};completionHandler(request)}
}
enum HarborHTTP {
    static func data(_ url:URL,method:String="GET",body:Data?=nil,token:String?=nil,limit:Int=4_000_000)async throws->Data {
        guard url.scheme=="https" || (url.scheme=="http" && ["127.0.0.1","localhost","::1"].contains(url.host ?? "")) else{throw FileTransactions.error("连接必须使用 HTTPS。")}
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=25;config.timeoutIntervalForResource=60
        let session=URLSession(configuration:config,delegate:token==nil ? nil:CredentialOriginGuard(url),delegateQueue:nil);defer{session.invalidateAndCancel()}
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=body;request.setValue("MC-Harbor/1.5 (+https://github.com/ADsurfboard/MC-Harbor)",forHTTPHeaderField:"User-Agent")
        if body != nil{request.setValue("application/json",forHTTPHeaderField:"Content-Type")};if let token{request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
        let (bytes,response)=try await session.bytes(for:request)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else{
            var fragment=Data();for try await byte in bytes{fragment.append(byte);if fragment.count>=4096{break}}
            let object=(try? JSONSerialization.jsonObject(with:fragment)) as? [String:Any]
            var detail=object?["error"] as? String ?? object?["message"] as? String ?? "请检查网络、凭据或服务额度。"
            if let token{detail=detail.replacingOccurrences(of:token,with:"[密钥]")}
            throw FileTransactions.error("服务请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）："+String(detail.prefix(240)))
        }
        guard response.expectedContentLength<=limit else{throw FileTransactions.error("服务返回的文件过大。")}
        var data=Data();for try await byte in bytes{if data.count>=limit{throw FileTransactions.error("服务返回的文件过大。")};data.append(byte)};try Task.checkCancellation();return data
    }
    static func json(_ url:URL,method:String="GET",body:[String:Any]?=nil,token:String?=nil)async throws->Any {try JSONSerialization.jsonObject(with:await data(url,method:method,body:try body.map{try JSONSerialization.data(withJSONObject:$0)},token:token))}
}
struct LittleSkinEntry:Codable,Identifiable,Equatable,Sendable {
    let id:Int;let name:String;let author:String;let type:String;let hd:Bool
    var original:URL{URL(string:"https://littleskin.cn/skinlib/show/\(id)")!}
    var slim:Bool{type=="alex"}
    static func parse(_ value:[String:Any])->LittleSkinEntry?{guard let id=value["tid"] as? Int,id>0,let name=value["name"] as? String,let type=value["type"] as? String,["alex","steve"].contains(type) else{return nil};return LittleSkinEntry(id:id,name:name,author:value["nickname"] as? String ?? "LittleSkin 用户",type:type,hd:value["hd"] as? Bool ?? false)}
}
enum LittleSkinService {
    static func search(_ keyword:String,page:Int,sort:String)async throws->([LittleSkinEntry],Int){var url=URLComponents(string:"https://littleskin.cn/skinlib/list")!;url.queryItems=[URLQueryItem(name:"filter",value:"skin"),URLQueryItem(name:"keyword",value:keyword),URLQueryItem(name:"page",value:String(page)),URLQueryItem(name:"sort",value:sort=="likes" ? "likes":"time")];guard let object=try await HarborHTTP.json(url.url!) as? [String:Any],let rows=object["data"] as? [[String:Any]] else{throw FileTransactions.error("LittleSkin 返回了无法识别的列表。")};return(rows.compactMap(LittleSkinEntry.parse),object["last_page"] as? Int ?? page)}
    static func skin(_ entry:LittleSkinEntry)async throws->URL {
        guard !entry.hd else{throw FileTransactions.error("此为高清皮肤；Minecraft 标准账号上传需要 64×64 或 64×32 皮肤。请选择标准皮肤。")}
        guard let info=try await HarborHTTP.json(URL(string:"https://littleskin.cn/texture/\(entry.id)")!) as? [String:Any],let hash=info["hash"] as? String,hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,info["type"] as? String==entry.type else{throw FileTransactions.error("皮肤信息无效或模型已改变，请刷新列表。")}
        let target=NativePaths.root.appendingPathComponent("skins/littleskin/"+hash+".png")
        if let cached=try? Data(contentsOf:target),SHA256.hash(data:cached).map({String(format:"%02x",$0)}).joined()==hash{try SkinStorage.validate(target);return target}
        let data=try await HarborHTTP.data(URL(string:"https://littleskin.cn/textures/"+hash)!)
        guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==hash else{throw FileTransactions.error("皮肤文件校验失败。")}
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:target,options:.atomic)
        do{try SkinStorage.validate(target)}catch{try? FileManager.default.removeItem(at:target);throw error};return target
    }
    static func favorites()->[LittleSkinEntry]{(try? JSONDecoder().decode([LittleSkinEntry].self,from:Data(contentsOf:NativePaths.root.appendingPathComponent("skins/littleskin-favorites.json")))) ?? []}
    static func save(_ entries:[LittleSkinEntry])throws{let file=NativePaths.root.appendingPathComponent("skins/littleskin-favorites.json");try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(entries).write(to:file,options:.atomic)}
}
private struct LittleSkinThumbnail:View {
    let entry:LittleSkinEntry
    @State private var image:NSImage?
    var body:some View{ZStack{Color.primary.opacity(0.025);if let image{Image(nsImage:image).resizable().scaledToFit()}else{Image(systemName:"person.fill").foregroundStyle(.secondary)}}.frame(height:126).clipShape(RoundedRectangle(cornerRadius:12)).task(id:entry.id){do{let data=try await HarborHTTP.data(URL(string:"https://littleskin.cn/preview/\(entry.id)?width=256&height=256")!,limit:2_000_000);image=NSImage(data:data)}catch{}}}
}
struct LittleSkinLibraryPanel:View {
    @ObservedObject var model:LauncherModel
    @Environment(\.scenePhase) private var phase
    @State private var query=""
    @State private var keyword=""
    @State private var sort="likes"
    @State private var page=1
    @State private var lastPage=1
    @State private var entries:[LittleSkinEntry]=[]
    @State private var favorites=LittleSkinService.favorites()
    @State private var favoritesOnly=false
    @State private var loading=false
    @State private var loadingSkin=false
    @State private var selected:LittleSkinEntry?
    @State private var file:URL?
    @State private var error=""
    private var shown:[LittleSkinEntry]{favoritesOnly ? favorites:entries}
    var body:some View{VStack(spacing:18){
        HStack{Text("皮肤库").font(.system(size:27,weight:.semibold));Text("LittleSkin").font(.system(size:12)).foregroundStyle(.secondary);Spacer();Button{model.modal=nil}label:{Image(systemName:"xmark")}.buttonStyle(HarborButtonStyle())}
        HStack{TextField("搜索皮肤名称或作者",text:$query).textFieldStyle(.roundedBorder).onSubmit{search()};Button("搜索"){search()}.buttonStyle(HarborButtonStyle());Picker("排序",selection:$sort){Text("最多收藏").tag("likes");Text("最新上传").tag("time")}.frame(width:155);Toggle("我的收藏",isOn:$favoritesOnly).toggleStyle(.button)}
        HStack(alignment:.top,spacing:22){VStack(spacing:12){ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:134),spacing:12)],spacing:14){ForEach(shown){entry in Button{selected=entry}label:{VStack(alignment:.leading,spacing:7){LittleSkinThumbnail(entry:entry);Text(entry.name).font(.system(size:12,weight:.medium)).lineLimit(1);Text(entry.author+(entry.hd ? " · 高清":"")).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)}.padding(9).frame(maxWidth:.infinity,alignment:.leading).background(selected?.id==entry.id ? model.themeColor.opacity(0.15):Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:18)).contentShape(RoundedRectangle(cornerRadius:18))}.buttonStyle(HarborPressButtonStyle(pressedScale:0.98,pressedOffset:0))}}}.overlay{if loading{ProgressView()}else if shown.isEmpty{ContentUnavailableView("暂无皮肤",systemImage:"person.crop.square")}};if !favoritesOnly{HStack{Button("上一页"){page -= 1}.disabled(page<=1 || loading);Text("\(page) / \(lastPage)").font(.system(size:12));Button("下一页"){page += 1}.disabled(page>=lastPage || loading)}.buttonStyle(HarborButtonStyle())}}
            VStack(alignment:.leading,spacing:13){if let selected{Group{if let file{MinecraftSkinPreview(skinPath:file.path,capePath:nil,model:selected.slim ? "slim":"default",motion:"rotate",active:phase == .active && !model.preferences.reduceMotion)}else{ZStack{Color.primary.opacity(0.025);if loadingSkin{ProgressView()}else{Image(systemName:"person.crop.square").font(.system(size:35)).foregroundStyle(.secondary)}}}}.frame(height:315);Text(selected.name).font(.system(size:20,weight:.semibold)).lineLimit(2);Text("作者："+selected.author).font(.system(size:12)).foregroundStyle(.secondary);HStack{Button(favorites.contains(where:{$0.id==selected.id}) ? "取消收藏":"收藏"){favorite(selected)}.buttonStyle(HarborButtonStyle());Button("原网页"){NSWorkspace.shared.open(selected.original)}.buttonStyle(HarborButtonStyle())};if let account=model.selectedAccount{Button("应用到 "+account.name){if let file{model.applySkin(file,slim:selected.slim,account:account)}}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(file==nil || model.skinLoading.contains(account.id) || (account.kind != "offline" && model.skinProfiles[account.id]?.canUpload==false));if let message=model.skinErrors[account.id]{Text(message).font(.system(size:11)).foregroundStyle(.secondary)}}else{Text("请先添加账号后再应用皮肤。").font(.system(size:12)).foregroundStyle(.secondary)}}else{ContentUnavailableView("选择皮肤",systemImage:"person.crop.square",description:Text("可旋转预览真实 Minecraft 角色。"))};Spacer()}.frame(width:290)
        }.frame(maxHeight:.infinity)
        if !error.isEmpty{Text(error).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)}
    }.padding(25).task(id:"\(keyword)|\(page)|\(sort)"){guard !favoritesOnly else{return};loading=true;error="";defer{loading=false};do{let result=try await LittleSkinService.search(keyword,page:page,sort:sort);try Task.checkCancellation();entries=result.0;lastPage=result.1}catch{if !Task.isCancelled{self.error=error.localizedDescription}}}.task(id:selected?.id){file=nil;guard let selected else{return};loadingSkin=true;defer{loadingSkin=false};do{let url=try await LittleSkinService.skin(selected);try Task.checkCancellation();file=url}catch{if !Task.isCancelled{self.error=error.localizedDescription}}}.onChange(of:sort){_,_ in page=1}.onChange(of:model.selectedAccount?.id){_,_ in if let account=model.selectedAccount{model.loadSkin(account)}}.onAppear{if let account=model.selectedAccount{model.loadSkin(account)}}}
    private func search(){favoritesOnly=false;keyword=query.trimmingCharacters(in:.whitespacesAndNewlines);page=1}
    private func favorite(_ item:LittleSkinEntry){let old=favorites;if favorites.contains(where:{$0.id==item.id}){favorites.removeAll{$0.id==item.id}}else{favorites.insert(item,at:0)};do{try LittleSkinService.save(favorites)}catch{favorites=old;self.error=error.localizedDescription}}
}
