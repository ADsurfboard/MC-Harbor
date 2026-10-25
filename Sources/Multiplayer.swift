import AppKit
import CryptoKit
import SwiftUI

struct MinecraftAddress:Equatable,Sendable {
    let host:String;let port:Int
    var string:String{(host.contains(":") ? "[\(host)]":host)+":\(port)"}
    init(_ text:String)throws {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.count<=260,!value.contains(where:{$0.isWhitespace || $0.isNewline}),!value.contains("/"),!value.contains("@"),!value.contains("?"),!value.contains("#") else{throw FileTransactions.error("请输入服务器地址，例如 play.example.com:25565。")}
        let h:String,p:String
        if value.hasPrefix("["),let close=value.firstIndex(of:"]"){h=String(value[value.index(after:value.startIndex)..<close]);let tail=String(value[value.index(after:close)...]);guard tail.isEmpty || tail.hasPrefix(":") else{throw FileTransactions.error("IPv6 地址格式无效。")};p=tail.isEmpty ? "25565":String(tail.dropFirst());guard h.contains(":"),h.range(of:"^[0-9a-fA-F:.]+$",options:.regularExpression) != nil else{throw FileTransactions.error("IPv6 地址格式无效。")}}
        else {let pieces=value.split(separator:":",omittingEmptySubsequences:false);guard pieces.count<=2 else{throw FileTransactions.error("IPv6 请使用 [地址]:端口。")};h=String(pieces[0]);p=pieces.count==2 ? String(pieces[1]):"25565";guard h.range(of:"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$",options:.regularExpression) != nil,!h.contains("..") else{throw FileTransactions.error("服务器域名或 IP 无效。")}}
        guard let number=Int(p),(1...65535).contains(number) else{throw FileTransactions.error("端口应为 1—65535。")};host=h;port=number
    }
}
struct SakuraNode:Identifiable,Sendable {let id:Int;let name:String;let host:String;let flag:Int;var available:Bool{flag&4 != 0 && flag&512==0};var publicGames:Bool{flag&2048 != 0 || name.contains("多线")}}
struct SakuraTunnel:Identifiable,Sendable {let id:Int;let name:String;let node:Int;let type:String;let localPort:Int;let remote:String;let localIP:String;let status:Int}
struct SakuraAPI {
    var base=URL(string:"https://api.natfrp.com/v4")!
    let token:String
    func request(_ path:String,body:[String:Any]?=nil)async throws->Any{try await HarborHTTP.json(base.appendingPathComponent(path),method:body==nil ? "GET":"POST",body:body,token:token)}
    func snapshot()async throws->(String,[SakuraNode],[SakuraTunnel]){
        async let user=request("user/info");async let nodes=request("nodes");async let tunnels=request("tunnels")
        guard let info=try await user as? [String:Any],let name=info["name"] as? String,info["ban"]==nil else{throw FileTransactions.error("Sakura Frp 账号不可用。")}
        return(name,try Self.nodes(await nodes),try Self.tunnels(await tunnels))
    }
    static func nodes(_ raw:Any)throws->[SakuraNode]{guard let values=raw as? [String:[String:Any]] else{throw FileTransactions.error("节点格式无法识别。")};return values.compactMap{key,value in guard let id=Int(key),let name=value["name"] as? String,let host=value["host"] as? String,let flag=value["flag"] as? Int else{return nil};return SakuraNode(id:id,name:name,host:host,flag:flag)}.sorted{$0.name<$1.name}}
    static func tunnels(_ raw:Any)throws->[SakuraTunnel]{guard let values=raw as? [[String:Any]] else{throw FileTransactions.error("隧道格式无法识别。")};return values.compactMap{value in guard let id=value["id"] as? Int,let name=value["name"] as? String,let node=value["node"] as? Int,let type=value["type"] as? String,let port=value["local_port"] as? Int,let remote=value["remote"] as? String else{return nil};return SakuraTunnel(id:id,name:name,node:node,type:type,localPort:port,remote:remote,localIP:value["local_ip"] as? String ?? "",status:value["status"] as? Int ?? 0)}}
    func configuration(_ id:Int,version:String)async throws->Data {let body=try JSONSerialization.data(withJSONObject:["query":String(id),"frpc":version]);return try await HarborHTTP.data(base.appendingPathComponent("tunnel/config"),method:"POST",body:body,token:token,limit:1_000_000)}
}
enum SakuraBinary {
    static func obtain()async throws->(URL,String){
        guard let metadata=try await HarborHTTP.json(URL(string:"https://api.natfrp.com/v4/system/clients")!) as? [String:Any],let frpc=metadata["frpc"] as? [String:Any],let version=frpc["ver"] as? String,let archs=frpc["archs"] as? [String:[String:Any]],let arch=archs["darwin_arm64"],let link=arch["url"] as? String,let url=URL(string:link),url.scheme=="https",let digest=arch["hash"] as? String,digest.range(of:"^[a-fA-F0-9]{32}$",options:.regularExpression) != nil,let size=arch["size"] as? Int,size>0,size<50_000_000 else{throw FileTransactions.error("Sakura Frp 官方客户端信息无法识别。")}
        let folder=NativePaths.root.appendingPathComponent("network/client",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let target=folder.appendingPathComponent("frpc-"+digest)
        func valid(_ file:URL)->Bool{guard let data=try? Data(contentsOf:file,options:.mappedIfSafe),data.count==size else{return false};return Insecure.MD5.hash(data:data).map{String(format:"%02x",$0)}.joined()==digest.lowercased()}
        if !valid(target){let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=180;let session=URLSession(configuration:config);defer{session.invalidateAndCancel()};let(file,response)=try await session.download(from:url);defer{try? FileManager.default.removeItem(at:file)};guard (response as? HTTPURLResponse)?.statusCode==200,valid(file) else{throw FileTransactions.error("Sakura Frp 客户端下载校验失败。")};try Task.checkCancellation();if FileManager.default.fileExists(atPath:target.path){try FileManager.default.removeItem(at:target)};try FileManager.default.moveItem(at:file,to:target)}
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:target.path);return(target,version)
    }
}
@MainActor final class SakuraConnection:ObservableObject {
    @Published var name=""
    @Published var nodes:[SakuraNode]=[]
    @Published var tunnels:[SakuraTunnel]=[]
    @Published var busy=false
    @Published var status="尚未连接 Sakura Frp"
    @Published var address=""
    @Published var logs:[String]=[]
    @Published var active=false
    @Published var ready=false
    private var process:Process?
    private var privateFile:URL?
    private var secret=""
    private var operation:Task<Void,Never>?
    private var operationID=UUID()
    private var generation=UUID()
    private static let credential="mc-harbor-sakura-frp"
    var hasCredential:Bool{KeychainStore.read(Self.credential) != nil}
    func refresh(token:String="") {guard !busy else{return};if !token.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,active{stop()};perform{
        let key=token.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? String(data:KeychainStore.read(Self.credential) ?? Data(),encoding:.utf8) ?? "":token.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty,key.count<=512,!key.contains(where:{$0.isWhitespace}) else{throw FileTransactions.error("请输入 Sakura Frp 的访问密钥。")};let result=try await SakuraAPI(token:key).snapshot();try Task.checkCancellation();try KeychainStore.write(Data(key.utf8),id:Self.credential);self.secret=key;self.name=result.0;self.nodes=result.1;self.tunnels=result.2;self.status="已登录 "+result.0
    }}
    func create(node:SakuraNode,port:Int,publicGame:Bool){guard node.available,(!publicGame || node.publicGames),(1...65535).contains(port) else{status="请选择可用节点和正确端口。";return};perform{let key=try self.key();_ = try await SakuraAPI(token:key).request("tunnels",body:["name":"MC-Harbor-"+String(port),"type":"tcp","node":node.id,"local_ip":"127.0.0.1","local_port":port]);try Task.checkCancellation();let snapshot=try await SakuraAPI(token:key).snapshot();try Task.checkCancellation();self.nodes=snapshot.1;self.tunnels=snapshot.2;self.status="隧道已创建，请选择并开启。"}}
    func start(_ tunnel:SakuraTunnel){guard !active,tunnel.type=="tcp",["127.0.0.1","localhost","::1"].contains(tunnel.localIP),tunnel.status==0,let node=nodes.first(where:{$0.id==tunnel.node}) else{status="请选择正常的本机 TCP 隧道。";return};perform{
        let key=try self.key();self.secret=key;self.status="正在校验官方 frpc 客户端…";let(binary,version)=try await SakuraBinary.obtain();let config=try await SakuraAPI(token:key).configuration(tunnel.id,version:version);try Task.checkCancellation();guard let text=String(data:config,encoding:.utf8),!text.isEmpty else{throw FileTransactions.error("隧道配置为空。")}
        let folder=NativePaths.root.appendingPathComponent("network/sessions",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let file=folder.appendingPathComponent(UUID().uuidString+(text.contains("[common]") ? ".ini":".toml"));try config.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let p=Process(),pipe=Pipe();p.executableURL=binary;p.arguments=["-c",file.path];p.standardOutput=pipe;p.standardError=pipe;p.standardInput=FileHandle.nullDevice
        let id=UUID();self.generation=id;self.logs=[];self.address="";self.ready=false;self.privateFile=file
        pipe.fileHandleForReading.readabilityHandler={handle in let data=handle.availableData;guard !data.isEmpty else{handle.readabilityHandler=nil;return};let text=String(decoding:data,as:UTF8.self);Task{@MainActor [weak self] in guard let self,self.generation==id else{return};self.append(text);if text.localizedCaseInsensitiveContains("start proxy success"){self.ready=true;self.status="隧道已连接";self.address=(try? MinecraftAddress(node.host+":"+tunnel.remote).string) ?? ""}}}
        p.terminationHandler={p in pipe.fileHandleForReading.readabilityHandler=nil;try? FileManager.default.removeItem(at:file);Task{@MainActor [weak self] in guard let self,self.generation==id else{return};self.active=false;self.ready=false;self.address="";self.privateFile=nil;self.process=nil;self.status="隧道已停止（\(p.terminationStatus)）"}}
        do{try p.run();self.process=p;self.active=true;self.status="正在连接隧道…"}catch{pipe.fileHandleForReading.readabilityHandler=nil;try? FileManager.default.removeItem(at:file);throw error}
    }}
    func stop(){generation=UUID();operationID=UUID();operation?.cancel();operation=nil;busy=false;process?.terminate();process=nil;active=false;ready=false;address="";if let privateFile{try? FileManager.default.removeItem(at:privateFile)};privateFile=nil;status="隧道已停止"}
    func logout(){stop();KeychainStore.remove(Self.credential);secret="";name="";nodes=[];tunnels=[];logs=[];status="已退出 Sakura Frp"}
    private func key()throws->String{guard let data=KeychainStore.read(Self.credential),let key=String(data:data,encoding:.utf8),!key.isEmpty else{throw FileTransactions.error("请先登录 Sakura Frp。")};return key}
    private func append(_ text:String){let safe=text.replacingOccurrences(of:secret.isEmpty ? UUID().uuidString:secret,with:"[密钥]");logs += safe.components(separatedBy:.newlines).filter{!$0.isEmpty}.map{String($0.prefix(500))};if logs.count>80{logs.removeFirst(logs.count-80)}}
    private func perform(_ action:@escaping()async throws->Void){guard !busy else{return};busy=true;let id=UUID();operationID=id;operation=Task{defer{if operationID==id{busy=false}};do{try await action()}catch{if !Task.isCancelled,operationID==id{status=error.localizedDescription}}}}
}

struct NativeMultiplayerView:View {
    @ObservedObject var model:LauncherModel
    @ObservedObject var connection:SakuraConnection
    @State private var token=""
    @State private var server=""
    @State private var gameID=""
    @State private var nodeID=0
    @State private var tunnelID=0
    @State private var port="25565"
    @State private var publicGame=false
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:24){Text("联机").font(.system(size:34,weight:.semibold));TerracottaPanel(model:model,connection:model.terracotta);group("加入游戏"){
        Text("使用标准 Minecraft 地址，好友可以从其他启动器加入。游戏版本、模组和服务器认证仍须匹配。").font(.system(size:12)).foregroundStyle(.secondary)
        HStack{TextField("服务器地址，例如 play.example.com:25565",text:$server).textFieldStyle(.roundedBorder);Button("复制地址"){copy(server)}.buttonStyle(HarborButtonStyle()).disabled((try? MinecraftAddress(server))==nil)}
        HStack{Picker("使用实例",selection:$gameID){Text("请选择实例").tag("");ForEach(model.games){game in Text(model.displayName(game)+" · "+game.version+" · "+game.loader).tag(game.id)}};Spacer();Button("启动并加入"){join()}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(gameID.isEmpty || (try? MinecraftAddress(server))==nil)}
    };group("Sakura Frp 内网穿透"){
        HStack{SecureField(connection.hasCredential ? "已保存在钥匙串，输入可更换":"Sakura Frp 访问密钥",text:$token).textFieldStyle(.roundedBorder);Button(connection.name.isEmpty ? "登录":"刷新"){connection.refresh(token:token);token=""}.buttonStyle(HarborButtonStyle()).disabled(connection.busy);if connection.hasCredential{Button("退出"){connection.logout()}.buttonStyle(HarborButtonStyle())};Button("访问官网"){NSWorkspace.shared.open(URL(string:"https://www.natfrp.com/user/")!)}.buttonStyle(HarborButtonStyle())}
        Text("在游戏里打开存档并选择“对局域网开放”，填写游戏显示的端口，再创建 TCP 隧道。官方 frpc 按需下载并校验，密钥仅存钥匙串。").font(.system(size:12)).foregroundStyle(.secondary)
        if !connection.name.isEmpty{HStack{TextField("局域网端口",text:$port).textFieldStyle(.roundedBorder).frame(width:110);Button("读取游戏端口"){detectPort()}.buttonStyle(HarborButtonStyle());Toggle("公开服务器",isOn:$publicGame)};Picker("节点",selection:$nodeID){Text("请选择节点").tag(0);ForEach(connection.nodes.filter{$0.available && (!publicGame || $0.publicGames)}){node in Text(node.name).tag(node.id)}};HStack{Button("创建隧道"){if let node=connection.nodes.first(where:{$0.id==nodeID}),let p=Int(port){connection.create(node:node,port:p,publicGame:publicGame)}}.buttonStyle(HarborButtonStyle()).disabled(connection.busy || nodeID==0 || !(Int(port).map{(1...65535).contains($0)} ?? false));Spacer()};Picker("已有隧道",selection:$tunnelID){Text("请选择隧道").tag(0);ForEach(connection.tunnels.filter{$0.type=="tcp"}){t in Text(t.name+" · 本机端口 \(t.localPort)").tag(t.id)}};HStack{Button(connection.busy ? "处理中…":"开启隧道"){if let t=connection.tunnels.first(where:{$0.id==tunnelID}){connection.start(t)}}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(connection.busy || connection.active || tunnelID==0);Button("停止"){connection.stop()}.buttonStyle(HarborButtonStyle()).disabled(!connection.active && !connection.busy);if !connection.address.isEmpty{Text(connection.address).font(.system(size:12,design:.monospaced)).textSelection(.enabled);Button("复制联机地址"){copy(connection.address)}.buttonStyle(HarborButtonStyle())}}}
        HStack{if connection.busy{ProgressView().controlSize(.small)};Circle().fill(connection.ready ? Color.green:Color.secondary.opacity(0.3)).frame(width:7,height:7);Text(connection.status).font(.system(size:12)).textSelection(.enabled)}
        Text("好友私密联机按账号额度使用；公开服务器仅列出服务允许的游戏节点。其他启动器只需填写复制的地址，无需安装 MC Harbor。").font(.system(size:11)).foregroundStyle(.secondary)
        if !connection.logs.isEmpty{DisclosureGroup("连接日志"){ScrollView{Text(connection.logs.joined(separator:"\n")).font(.system(size:10,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(height:160)}}
    }}.padding(28)}.onAppear{gameID=model.selected?.id ?? "";if !model.invitedServer.isEmpty{server=model.invitedServer;model.invitedServer=""};if connection.hasCredential,connection.name.isEmpty{connection.refresh()}}.onChange(of:publicGame){_,_ in nodeID=0}}
    private func group<C:View>(_ title:String,@ViewBuilder content:()->C)->some View{VStack(alignment:.leading,spacing:17){Text(title).font(.system(size:19,weight:.semibold));content()}.padding(24).frame(maxWidth:.infinity,alignment:.leading).harborGlass(appearance:model.appearance,radius:24)}
    private func copy(_ text:String){do{let address=try MinecraftAddress(text);NSPasteboard.general.clearContents();NSPasteboard.general.setString(address.string,forType:.string);model.toast("联机地址已复制")}catch{model.errorMessage=error.localizedDescription}}
    private func join(){do{let address=try MinecraftAddress(server);if let game=model.games.first(where:{$0.id==gameID}){model.launch(game,server:address.string)}}catch{model.errorMessage=error.localizedDescription}}
    private func detectPort(){guard let game=model.games.first(where:{$0.id==gameID}) ?? model.selected else{return};let file=URL(fileURLWithPath:game.runDirectory).appendingPathComponent("logs/latest.log");guard let values=try? file.resourceValues(forKeys:[.contentModificationDateKey]),let date=values.contentModificationDate,Date().timeIntervalSince(date)<7200,let handle=try? FileHandle(forReadingFrom:file) else{model.errorMessage="未找到近期游戏日志。请先在游戏中对局域网开放。";return};defer{try? handle.close()};let length=(try? handle.seekToEnd()) ?? 0;try? handle.seek(toOffset:length>65536 ? length-65536:0);let text=String(decoding:(try? handle.readToEnd()) ?? Data(),as:UTF8.self);let regex=try! NSRegularExpression(pattern:"(?:Started serving on |Local game hosted on port )(\\d{1,5})");guard let match=regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).last,let range=Range(match.range(at:1),in:text),let p=Int(text[range]),(1...65535).contains(p) else{model.errorMessage="日志中没有局域网端口，请在游戏中开放局域网后重试。";return};port=String(p)}
}
