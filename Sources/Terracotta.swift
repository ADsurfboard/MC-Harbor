import AppKit
import CryptoKit
import SwiftUI

struct TerracottaMember:Identifiable,Sendable {let id:String;let name:String;let vendor:String;let kind:String}
struct TerracottaSnapshot:Sendable {
    let state:String;let index:Int;let room:String;let address:String;let exception:Int?;let members:[TerracottaMember]
    var ready:Bool{state=="host-ok" || state=="guest-ok"}
    static func decode(_ data:Data)throws->TerracottaSnapshot{guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],let state=value["state"] as? String,let index=value["index"] as? Int else{throw FileTransactions.error("陶瓦返回的房间状态无效。")};let room=String((value["room"] as? String ?? "").prefix(256));let address=(try? MinecraftAddress(value["url"] as? String ?? "").string) ?? "";var seen:Set<String>=[];let members=(value["profiles"] as? [[String:Any]] ?? []).prefix(64).compactMap{row->TerracottaMember? in guard let id=row["machine_id"] as? String,!id.isEmpty,id.count<=128,seen.insert(id).inserted else{return nil};return TerracottaMember(id:id,name:String((row["name"] as? String ?? "Player").prefix(64)),vendor:String((row["vendor"] as? String ?? "Terracotta").prefix(128)),kind:row["kind"] as? String ?? "GUEST")};return TerracottaSnapshot(state:state,index:index,room:room,address:address,exception:value["type"] as? Int,members:members)}
}
enum TerracottaModule {
    private static func extract(_ archive:URL,name:String)throws->Data {
        let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/tar");process.arguments=["-xzOf",archive.path,name];process.standardOutput=pipe;process.standardError=FileHandle.nullDevice;try process.run();var bytes=Data()
        while let part=try pipe.fileHandleForReading.read(upToCount:1_048_576),!part.isEmpty{bytes.append(part);if bytes.count>40_000_000 || Task.isCancelled{process.terminate();throw FileTransactions.error("陶瓦模块解包已停止或超出大小限制。")}}
        process.waitUntilExit();guard process.terminationStatus==0,bytes.count>1024,Array(bytes.prefix(8))==[207,250,237,254,12,0,0,1] else{throw FileTransactions.error("陶瓦模块不是有效的 Apple Silicon 可执行文件。")};return bytes
    }
    static func obtain()async throws->URL {
        let folder=NativePaths.root.appendingPathComponent("network/terracotta",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let metadata=folder.appendingPathComponent("release.json");let modified=(try? metadata.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        var raw:Data
        if Date().timeIntervalSince(modified)<86400,let cached=try? Data(contentsOf:metadata){raw=cached}else{do{raw=try await HarborHTTP.data(URL(string:"https://api.github.com/repos/burningtnt/Terracotta/releases/latest")!);try raw.write(to:metadata,options:.atomic)}catch{guard let cached=try? Data(contentsOf:metadata) else{throw error};raw=cached}}
        guard let release=try JSONSerialization.jsonObject(with:raw) as? [String:Any],let tag=release["tag_name"] as? String,tag.range(of:"^v?[0-9]+\\.[0-9]+\\.[0-9]+(?:[-.A-Za-z0-9]+)?$",options:.regularExpression) != nil,let assets=release["assets"] as? [[String:Any]],let asset=assets.first(where:{($0["name"] as? String)?.hasSuffix("-macos-arm64-pkg.tar.gz")==true}),let name=asset["name"] as? String,let link=asset["browser_download_url"] as? String,let url=URL(string:link),url.scheme=="https",url.host=="github.com",let published=asset["digest"] as? String,published.range(of:"^sha256:[a-f0-9]{64}$",options:.regularExpression) != nil,let size=asset["size"] as? Int,size>0,size<40_000_000 else{throw FileTransactions.error("无法取得带发布者 SHA256 的官方 macOS 陶瓦模块。")}
        let hash=String(published.dropFirst(7)),target=folder.appendingPathComponent("terracotta-"+hash),manifest=folder.appendingPathComponent(hash+".json")
        if let record=try? JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:String],let bytes=try? Data(contentsOf:target,options:.mappedIfSafe),record["sha256"]==SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined(){try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:target.path);return target}
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=180;let session=URLSession(configuration:config);defer{session.invalidateAndCancel()};let(file,response)=try await session.download(from:url);defer{try? FileManager.default.removeItem(at:file)}
        guard (response as? HTTPURLResponse)?.statusCode==200,response.url?.scheme=="https",let bytes=try? Data(contentsOf:file,options:.mappedIfSafe),bytes.count==size,SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==hash else{throw FileTransactions.error("陶瓦模块下载校验失败。")}
        let executableName=String(name.dropLast("-pkg.tar.gz".count));try Task.checkCancellation();let binary=try await Task.detached(priority:.userInitiated){try extract(file,name:executableName)}.value;try Task.checkCancellation();try binary.write(to:target,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:target.path);try JSONSerialization.data(withJSONObject:["sha256":SHA256.hash(data:binary).map{String(format:"%02x",$0)}.joined(),"version":tag,"publisherArchiveSHA256":hash]).write(to:manifest,options:.atomic);return target
    }
}

/// Official control service stays on loopback; no system proxy or persistent service is installed.
enum TerracottaControl {
    static func data(_ url:URL)async throws->Data{guard url.scheme=="http",url.host=="127.0.0.1",let port=url.port,(1...65535).contains(port) else{throw FileTransactions.error("陶瓦端口无效。")};let config=URLSessionConfiguration.ephemeral;config.connectionProxyDictionary=[:];config.timeoutIntervalForRequest=2;config.timeoutIntervalForResource=3;let session=URLSession(configuration:config);defer{session.invalidateAndCancel()};let(data,response)=try await session.data(from:url);guard (response as? HTTPURLResponse)?.statusCode==200,data.count<=131072 else{throw FileTransactions.error("陶瓦本机响应无效。")};return data}
    static func json(port:Int,path:String)async throws->[String:Any]{guard let value=try JSONSerialization.jsonObject(with:await data(URL(string:"http://127.0.0.1:\(port)"+path)!)) as? [String:Any] else{throw FileTransactions.error("陶瓦本机资料无效。")};return value}
}

@MainActor final class TerracottaConnection:ObservableObject {
    @Published var busy=false
    @Published var state="waiting"
    @Published var status="用房间码连接，优先使用点对点网络。"
    @Published var room=""
    @Published var address=""
    @Published var members:[TerracottaMember]=[]
    @Published var version=""
    private var process:Process?
    private var port=0
    private var controlled=false
    private var poll:Task<Void,Never>?
    private var operation:Task<Void,Never>?
    private var generation=UUID()
    private var index = -1
    var ready:Bool{state=="host-ok" || state=="guest-ok"}
    func host(name:String){start(path:"/state/scanning",query:[URLQueryItem(name:"player",value:String(name.prefix(64)))])}
    func join(_ code:String,name:String){let code=code.trimmingCharacters(in:.whitespacesAndNewlines);guard !code.isEmpty,code.count<=256,!code.contains(where:{$0.isNewline || $0.asciiValue.map{$0<32}==true}) else{status="请输入完整房间码。";return};start(path:"/state/guesting",query:[URLQueryItem(name:"room",value:code),URLQueryItem(name:"player",value:String(name.prefix(64)))])}
    private func start(path:String,query:[URLQueryItem]){guard !busy,!controlled else{return};busy=true;let id=UUID();generation=id;operation=Task{defer{if generation==id{busy=false}};do{
        status="正在校验陶瓦官方模块…";let binary=try await TerracottaModule.obtain();try Task.checkCancellation();guard generation==id else{return}
        let folder=NativePaths.root.appendingPathComponent("network/terracotta",isDirectory:true)
        var discovered=Self.corePort()
        if discovered>0{let meta=try? await TerracottaControl.json(port:discovered,path:"/meta");if meta?["target_os"] as? String != "macos"{discovered=0}}
        if discovered==0 {
            let p=Process(),pipe=Pipe();p.executableURL=binary;p.currentDirectoryURL=folder;p.arguments=["--daemon"];p.standardOutput=pipe;p.standardError=pipe;p.standardInput=FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler={handle in if handle.availableData.isEmpty{handle.readabilityHandler=nil}}
            try p.run();self.process=p
            for _ in 0..<160{try Task.checkCancellation();let candidate=Self.corePort();if candidate>0,let meta=try? await TerracottaControl.json(port:candidate,path:"/meta"),meta["target_os"] as? String=="macos"{discovered=candidate;break};if !p.isRunning{throw FileTransactions.error("陶瓦在发布本机端口前退出。")};try await Task.sleep(for:.milliseconds(100))}
        }
        guard discovered>0 else{throw FileTransactions.error("陶瓦启动超时。")};port=discovered
        let meta=try await TerracottaControl.json(port:port,path:"/meta");guard let v=meta["version"] as? String,meta["target_os"] as? String=="macos" else{throw FileTransactions.error("本机陶瓦端口身份校验失败。")};version=v
        let current=try TerracottaSnapshot.decode(await TerracottaControl.data(endpoint("/state")));guard current.state=="waiting" else{throw FileTransactions.error("陶瓦正在被其他启动器使用，请先退出那个房间。")}
        try Task.checkCancellation();guard generation==id else{return};index = -1;_ = try await TerracottaControl.data(endpoint(path,query:query));controlled=true;status="正在连接房间…";beginPolling(id)
    }catch{if generation==id{status=error.localizedDescription;state="exception";controlled=false;if let process,process.isRunning{process.terminate()};process=nil;port=0}}}}
    private func endpoint(_ path:String,query:[URLQueryItem]=[])->URL{var url=URLComponents();url.scheme="http";url.host="127.0.0.1";url.port=port;url.path=path;url.queryItems=query.isEmpty ? nil:query;return url.url!}
    private func beginPolling(_ id:UUID){poll?.cancel();poll=Task{var failures=0;while !Task.isCancelled,generation==id,controlled{do{let snapshot=try TerracottaSnapshot.decode(await TerracottaControl.data(endpoint("/state")));try Task.checkCancellation();guard generation==id else{return};failures=0;if snapshot.index>index{index=snapshot.index;state=snapshot.state;room=snapshot.room;address=snapshot.address;members=snapshot.members;switch state{case "host-scanning":status="等待发现本机游戏，请在存档中开放局域网。";case "host-starting":status="正在创建房间…";case "host-ok":status="房间已创建，复制房间码邀请好友。";case "guest-connecting","guest-starting":status="正在与房主建立连接…";case "guest-ok":status="已加入，可从游戏多人列表或本机地址进入。";case "exception":status=Self.error(snapshot.exception);default:status="陶瓦："+state}}}catch{if Task.isCancelled{return};failures += 1;if failures>=5{status="陶瓦本机连接已中断。";state="exception";return}};try? await Task.sleep(for:.seconds(NSApp.isActive ? 0.75:8))}}}
    static func error(_ code:Int?)->String{switch code{case 0:return "无法连接房主，请检查房间码与房主网络。";case 1:return "与房主的连接已中断。";case 2,3:return "陶瓦网络引擎异常，请退出房间后重试。";case 4:return "房主已退出游戏存档。";default:return "房间连接异常，请退出后重试。"}}
    private static func corePort()->Int{let url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("terracotta/terracotta.lock");guard let file=try? FileHandle(forReadingFrom:url) else{return 0};defer{try? file.close()};guard let bytes=try? file.read(upToCount:3),bytes.count==2 else{return 0};return Int(bytes[0])*256+Int(bytes[1])}
    func stop(synchronous:Bool=false){let oldPort=port,wasControlled=controlled,p=process;generation=UUID();operation?.cancel();poll?.cancel();operation=nil;poll=nil;controlled=false;process=nil;port=0;state="waiting";room="";address="";members=[];busy=false;status="已退出房间"
        if wasControlled,oldPort>0{let url=URL(string:"http://127.0.0.1:\(oldPort)/state/ide")!;let configuration=URLSessionConfiguration.ephemeral;configuration.connectionProxyDictionary=[:];configuration.timeoutIntervalForRequest=2;configuration.timeoutIntervalForResource=2;let session=URLSession(configuration:configuration);let done=DispatchSemaphore(value:0);session.dataTask(with:url){_,_,_ in if let p,p.isRunning{p.terminate()};session.finishTasksAndInvalidate();done.signal()}.resume();if synchronous{_ = done.wait(timeout:.now()+2.2);if let p,p.isRunning{p.terminate()}}}else if let p,p.isRunning{p.terminate()}}

}

struct TerracottaPanel:View {
    @ObservedObject var model:LauncherModel
    @ObservedObject var connection:TerracottaConnection
    @State private var code=""
    var body:some View{VStack(alignment:.leading,spacing:17){HStack{Text("房间联机").font(.system(size:19,weight:.semibold));Spacer();if !connection.version.isEmpty{Text(connection.version).font(.system(size:10)).foregroundStyle(.secondary)}};Text("先用任意启动器进入存档并开放局域网，再创建房间。好友可用支持陶瓦的启动器或独立陶瓦客户端加入，游戏内会出现局域网房间。").font(.system(size:12)).foregroundStyle(.secondary)
        HStack{Button("创建房间"){connection.host(name:model.selectedAccount?.name ?? model.preferences.username)}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(connection.busy || connection.state != "waiting");TextField("粘贴陶瓦房间码",text:$code).textFieldStyle(.roundedBorder);Button("加入房间"){connection.join(code,name:model.selectedAccount?.name ?? model.preferences.username)}.buttonStyle(HarborButtonStyle()).disabled(connection.busy || connection.state != "waiting" || code.isEmpty);Button("退出房间"){connection.stop()}.buttonStyle(HarborButtonStyle()).disabled(connection.state=="waiting" && !connection.busy)}
        HStack{if connection.busy{ProgressView().controlSize(.small)};Text(connection.status).font(.system(size:12)).textSelection(.enabled)}
        if !connection.room.isEmpty{HStack{Text(connection.room).font(.system(size:16,weight:.medium,design:.monospaced)).textSelection(.enabled);Button("复制房间码"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(connection.room,forType:.string);model.toast("房间码已复制")}.buttonStyle(HarborButtonStyle())}}
        if !connection.address.isEmpty{HStack{Text(connection.address).font(.system(size:12,design:.monospaced)).textSelection(.enabled);Button("启动并进入"){if let game=model.selected{model.launch(game,server:connection.address)}}.buttonStyle(HarborButtonStyle()).disabled(model.selected==nil)}}
        if !connection.members.isEmpty{ForEach(connection.members){member in HStack{Image(systemName:member.kind=="HOST" ? "crown":"person.fill");Text(member.name);Spacer();Text(member.vendor).foregroundStyle(.secondary)}.font(.system(size:12))}}
        HStack{Link("陶瓦联机 © burningtnt · AGPL-3.0",destination:URL(string:"https://github.com/burningtnt/Terracotta")!);Spacer();Link("独立客户端下载",destination:URL(string:"https://github.com/burningtnt/Terracotta/releases/latest")!)}.font(.system(size:11));Text("基于 EasyTier，优先 P2P；公共节点由社区提供，也可接入自建节点。版本、模组和网络条件仍需匹配。").font(.system(size:10)).foregroundStyle(.secondary)
    }.padding(24).frame(maxWidth:.infinity,alignment:.leading).harborGlass(appearance:model.appearance,radius:24)}
}
