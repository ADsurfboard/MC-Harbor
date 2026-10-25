import AppKit
import CryptoKit
import SwiftUI

struct HarborInvitation:Codable,Equatable,Sendable {
    let transport:String
    let target:String
    let instance:String
    let version:String
    let loader:String
    var details:String{[instance,version,loader].filter{!$0.isEmpty}.joined(separator:" · ")}
    func validate()throws{guard ["terracotta","address"].contains(transport),!target.isEmpty,target.count<=260,!target.contains(where:{$0.isWhitespace || $0.isNewline}),instance.count<=200,version.count<=80,loader.count<=80 else{throw FileTransactions.error("邀请内容无效。")};if transport=="address"{_ = try MinecraftAddress(target)}}
}
struct HarborMessage:Codable,Identifiable,Equatable,Sendable {
    let id:String
    let sender:String
    let kind:String
    let text:String
    let invite:HarborInvitation?
    let created:Double
    let expires:Double
    var expired:Bool{expires<Date().timeIntervalSince1970}
    static func parse(_ raw:Any)throws->HarborMessage{let value=try JSONDecoder().decode(HarborMessage.self,from:JSONSerialization.data(withJSONObject:raw));guard UUID(uuidString:value.id) != nil,UUID(uuidString:value.sender) != nil,["text","invite"].contains(value.kind),value.text.count<=2000,value.created.isFinite,value.expires.isFinite,value.kind=="invite" || value.invite==nil else{throw FileTransactions.error("消息格式无效。")};if value.kind=="invite"{guard let invite=value.invite else{throw FileTransactions.error("邀请内容缺失。")};try invite.validate()};return value}
}
private final class ChatOriginGuard:NSObject,URLSessionTaskDelegate {
    let origin:URL
    init(_ origin:URL){self.origin=origin}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){guard let url=request.url,url.host==origin.host,url.port==origin.port,["https","wss"].contains(url.scheme ?? "") || (["127.0.0.1","localhost","::1"].contains(url.host ?? "") && ["http","ws"].contains(url.scheme ?? "")) else{completionHandler(nil);return};completionHandler(request)}
}
@MainActor final class HarborChat:ObservableObject {
    @Published var messages:[String:[HarborMessage]]=[:]
    @Published var unread:Set<String>=[]
    @Published var selected=""
    @Published var drafts:[String:String]=[:]
    @Published var sending=false
    @Published var loading=false
    @Published var live=false
    @Published var status=""
    private weak var social:HarborSocial?
    private var generation=UUID()
    private var connection:Task<Void,Never>?
    private var fallback:Task<Void,Never>?
    private var ping:Task<Void,Never>?
    private var socket:URLSessionWebSocketTask?
    private var session:URLSession?
    private var context=""
    private var pending:[String:(String,String)]=[:]
    private var refreshing:Set<String>=[]
    private var readTimes:[String:Double]=[:]
    private var inboxLoading=false
    private var inboxAgain=false
    private var readFile:URL{NativePaths.root.appendingPathComponent("social/chat-read-state.json")}
    init(social:HarborSocial){self.social=social}
    private var identityContext:String{guard let social,let me=social.me else{return ""};return social.endpoint+"/"+me.id}
    func connect(){let value=identityContext;guard !value.isEmpty,value != context else{return};disconnect();context=value;let saved=NativeScanner.readJSON(readFile);readTimes=saved["context"] as? String==value ? saved["read"] as? [String:Double] ?? [:]:[:];let id=generation;connection=Task{await refreshInbox();var delay=3.0;while !Task.isCancelled,generation==id{
        do{guard let social else{return};let root=URL(string:social.endpoint)!;let health=try await HarborHTTP.json(root.appendingPathComponent("health")) as? [String:Any];guard generation==id else{return};if health?["chat"] as? Bool != true{status="当前自建服务未支持聊天，请更新服务端。";return};if health?["realtime"] as? Bool != true{status="消息可用，实时通知暂不可用。";startFallback(id);return}
            guard let request=social.chatSocketRequest(),let url=request.url else{return};let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=25;let transport=URLSession(configuration:config,delegate:ChatOriginGuard(url),delegateQueue:nil);session=transport;let ws=transport.webSocketTask(with:request);ws.maximumMessageSize=4096;socket=ws;ws.resume();startPing(ws,id:id)
            while !Task.isCancelled,generation==id{let frame=try await ws.receive();let data:Data;switch frame{case .string(let text):data=Data(text.utf8);case .data(let bytes):data=bytes;@unknown default:continue};guard data.count<=4096,let event=try JSONSerialization.jsonObject(with:data) as? [String:Any],generation==id else{continue};live=true;status="实时消息已连接";delay=3;fallback?.cancel();fallback=nil;handle(event)}
        }catch{if Task.isCancelled || generation != id{return};live=false;status="实时连接暂时中断，可继续发送和刷新消息。";startFallback(id)}
        socket?.cancel(with:.goingAway,reason:nil);socket=nil;session?.invalidateAndCancel();session=nil;ping?.cancel();ping=nil;try? await Task.sleep(for:.seconds(delay));delay=min(60,delay*2)
    }}}
    func disconnect(){generation=UUID();connection?.cancel();connection=nil;fallback?.cancel();fallback=nil;ping?.cancel();ping=nil;socket?.cancel(with:.goingAway,reason:nil);socket=nil;session?.invalidateAndCancel();session=nil;context="";live=false;messages=[:];unread=[];selected="";pending=[:];drafts=[:];refreshing=[];readTimes=[:];inboxLoading=false;inboxAgain=false;sending=false;loading=false}
    func reconcile(_ allowed:Set<String>){messages=messages.filter{allowed.contains($0.key)};drafts=drafts.filter{allowed.contains($0.key)};readTimes=readTimes.filter{allowed.contains($0.key)};pending=pending.filter{allowed.contains($0.key)};unread=unread.intersection(allowed);if !selected.isEmpty,!allowed.contains(selected){selected=""}}
    private func startPing(_ ws:URLSessionWebSocketTask,id:UUID){ping?.cancel();ping=Task{while !Task.isCancelled,generation==id{try? await Task.sleep(for:.seconds(45));guard !Task.isCancelled,generation==id else{return};ws.sendPing{_ in}}}}
    private func startFallback(_ id:UUID){guard fallback==nil else{return};fallback=Task{while !Task.isCancelled,generation==id{try? await Task.sleep(for:.seconds(30));guard !Task.isCancelled,generation==id else{return};if NSApp.isActive{await refreshInbox();if !selected.isEmpty{await refresh(selected)}}}}}
    private func handle(_ event:[String:Any]){let type=event["type"] as? String ?? "";if type=="ready"{Task{await refreshInbox()};return};if type=="deleted"{disconnect();status="好友身份已删除。";social?.refreshFromLive();return};if type=="friends"{social?.refreshFromLive();return};guard type=="chat",let peer=event["peer"] as? String,social?.friends.contains(where:{$0.id==peer})==true else{return};if selected==peer,NSApp.isActive{Task{await refresh(peer)}}else{Task{await refreshInbox()}}}
    func select(_ friend:HarborFriend){selected=friend.id;Task{await refresh(friend.id)}}
    func refreshInbox()async{if inboxLoading{inboxAgain=true;return};guard !context.isEmpty,let social else{return};let id=generation;inboxLoading=true;defer{if id==generation{inboxLoading=false;if inboxAgain{inboxAgain=false;Task{guard id==generation else{return};await refreshInbox()}}}};do{guard let rows=try await social.chatRequest("inbox") as? [[String:Any]],id==generation else{return};let allowed=Set(social.friends.map(\.id));var value=Set<String>();for row in rows{guard let peer=row["peer"] as? String,allowed.contains(peer),let sender=row["sender"] as? String,sender != social.me?.id,let time=row["created"] as? Double,time.isFinite,time>(readTimes[peer] ?? 0) else{continue};value.insert(peer)};unread=value;if NSApp.isActive,!selected.isEmpty,unread.contains(selected){await refresh(selected)}}catch{if id==generation,!Task.isCancelled{status="未读提示暂不可用，可打开好友直接读取消息。"}}}
    private func markRead(_ peer:String,_ values:[HarborMessage]){guard let latest=values.last else{unread.remove(peer);return};readTimes[peer]=max(readTimes[peer] ?? 0,latest.created);unread.remove(peer);try? JSONSerialization.data(withJSONObject:["context":context,"read":readTimes]).write(to:readFile,options:.atomic)}
    func refresh(_ peer:String)async{guard !refreshing.contains(peer),social?.friends.contains(where:{$0.id==peer})==true else{return};let scope=identityContext;let id=generation;refreshing.insert(peer);loading=true;defer{if generation==id{refreshing.remove(peer);loading = !refreshing.isEmpty}}
        do{guard let rows=try await social?.chatRequest("messages/"+peer) as? [Any] else{throw FileTransactions.error("消息列表无法识别。")};let values=try rows.map(HarborMessage.parse);guard generation==id,identityContext==scope,social?.friends.contains(where:{$0.id==peer})==true else{return};let current=values.filter{!$0.expired};messages[peer]=current;if selected==peer,NSApp.isActive{markRead(peer,current)}}catch{if !Task.isCancelled,generation==id{if error.localizedDescription.contains("HTTP 403"){messages[peer]=nil;social?.refreshFromLive()};status=error.localizedDescription}}
    }
    func send(_ text:String,to friend:HarborFriend,invite:HarborInvitation?=nil)async throws{guard !sending,let social,social.friends.contains(where:{$0.id==friend.id}) else{throw FileTransactions.error("请等待当前消息发送完成，或重新确认好友关系。")};let text=text.trimmingCharacters(in:.whitespacesAndNewlines);guard text.utf16.count<=2000,invite != nil || !text.isEmpty else{throw FileTransactions.error("消息需为 1—2000 个字符。")};try invite?.validate();sending=true;let id=generation,scope=identityContext;defer{if generation==id{sending=false}}
        var body:[String:Any]=["kind":invite==nil ? "text":"invite","text":text];if let invite{body["invite"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(invite))};let signature=SHA256.hash(data:try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)).map{String(format:"%02x",$0)}.joined();let messageID=pending[friend.id].flatMap{$0.0==signature ? $0.1:nil} ?? UUID().uuidString;pending[friend.id]=(signature,messageID);body["id"]=messageID
        let raw=try await social.chatRequest("messages/"+friend.id,method:"POST",body:body);let message=try HarborMessage.parse(raw);guard generation==id,identityContext==scope,social.friends.contains(where:{$0.id==friend.id}) else{return};var values=messages[friend.id] ?? [];values.removeAll{$0.id==message.id};values.append(message);messages[friend.id]=Array(values.sorted{$0.created<$1.created}.suffix(100));pending[friend.id]=nil;status="消息已发送"
    }
}

struct NativeFriendConversation:View {
    @ObservedObject var model:LauncherModel
    @ObservedObject var chat:HarborChat
    let friend:HarborFriend
    private var draft:String{get{chat.drafts[friend.id] ?? ""} nonmutating set{chat.drafts[friend.id]=newValue}}
    private var draftBinding:Binding<String>{Binding(get:{draft},set:{draft=$0})}
    @State private var address=""
    @State private var askingAddress=false
    private var rows:[HarborMessage]{chat.messages[friend.id] ?? []}
    var body:some View{VStack(alignment:.leading,spacing:14){HStack{Text("聊天").font(.system(size:18,weight:.semibold));Circle().fill(chat.live ? Color.green:Color.secondary).frame(width:6,height:6);Spacer();Menu{Button("邀请加入当前房间"){invite("terracotta",model.terracotta.room)}.disabled(model.terracotta.state != "host-ok" || model.terracotta.room.isEmpty);Button("邀请加入 Sakura 隧道"){invite("address",model.sakura.address)}.disabled(!model.sakura.ready);Button("发送服务器地址…"){askingAddress=true};Button("前往创建房间"){model.section = .multiplayer}}label:{Label("邀请联机",systemImage:"gamecontroller")}.buttonStyle(HarborButtonStyle()).disabled(chat.sending);Button{Task{await chat.refresh(friend.id)}}label:{Image(systemName:"arrow.clockwise")}.buttonStyle(HarborButtonStyle()).accessibilityLabel("刷新聊天")}
        ScrollViewReader{proxy in ScrollView{LazyVStack(alignment:.leading,spacing:12){if rows.isEmpty{Text(chat.loading ? "正在读取消息…":"暂无消息").font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:110)};ForEach(rows){message in messageView(message).id(message.id)}}.padding(4)}.frame(height:245).onChange(of:rows.last?.id){_,id in if let id{withAnimation(.easeOut(duration:0.2)){proxy.scrollTo(id,anchor:.bottom)}}}}
        HStack(alignment:.bottom,spacing:10){TextField("发送消息",text:draftBinding,axis:.vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).onSubmit{send()};Button("发送"){send()}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || chat.sending)}
        Text(chat.status.isEmpty ? "仅双方好友可聊天。服务保留 30 天消息，当前显示最近 100 条；邀请 30 分钟后失效。":chat.status).font(.system(size:10)).foregroundStyle(.secondary)
    }.padding(20).harborGlass(appearance:model.appearance,radius:22).task(id:friend.id){chat.select(friend)}.onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in chat.select(friend);Task{await chat.refreshInbox()}}.onDisappear{if chat.selected==friend.id{chat.selected=""}}.popover(isPresented:$askingAddress){VStack(alignment:.leading,spacing:16){Text("邀请加入服务器").font(.system(size:17,weight:.semibold));TextField("服务器地址:端口",text:$address).textFieldStyle(.roundedBorder).frame(width:330);HStack{Button("取消"){askingAddress=false};Spacer();Button("发送邀请"){do{let value=try MinecraftAddress(address).string;invite("address",value);askingAddress=false}catch{model.errorMessage=error.localizedDescription}}.disabled((try? MinecraftAddress(address))==nil)}}.padding(22).buttonStyle(HarborButtonStyle())}}
    private func messageView(_ message:HarborMessage)->some View{let own=message.sender==model.social.me?.id;return HStack{if own{Spacer(minLength:60)};VStack(alignment:.leading,spacing:8){if let invitation=message.invite{Label("联机邀请",systemImage:"gamecontroller.fill").font(.system(size:13,weight:.semibold));if !invitation.details.isEmpty{Text(invitation.details).font(.system(size:11)).foregroundStyle(.secondary)};Text(invitation.target).font(.system(size:11,design:.monospaced)).textSelection(.enabled);if !own{Button(message.expired ? "邀请已过期":"加入联机"){join(invitation,message:message)}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(message.expired)}}else{Text(message.text).font(.system(size:13)).textSelection(.enabled)};Text(Date(timeIntervalSince1970:message.created),format:.dateTime.hour().minute()).font(.system(size:9)).foregroundStyle(.secondary)}.padding(12).background(model.themeColor.opacity(own ? 0.16:0.055),in:RoundedRectangle(cornerRadius:15));if !own{Spacer(minLength:60)}}}
    private func send(){let value=draft;Task{do{try await chat.send(value,to:friend);if draft==value{draft=""}}catch{model.errorMessage=error.localizedDescription}}}
    private func invite(_ transport:String,_ target:String){let game=model.selected;let invitation=HarborInvitation(transport:transport,target:target,instance:game.map(model.displayName) ?? "",version:game?.version ?? "",loader:game?.loader ?? "");Task{do{try await chat.send("一起游玩",to:friend,invite:invitation);model.toast("联机邀请已发送")}catch{model.errorMessage=error.localizedDescription}}}
    private func join(_ invitation:HarborInvitation,message:HarborMessage){guard !message.expired else{return};do{try invitation.validate();if invitation.transport=="terracotta"{guard model.terracotta.state=="waiting",!model.terracotta.busy else{throw FileTransactions.error("请先退出当前房间后再接受邀请。")};model.terracotta.join(invitation.target,name:model.selectedAccount?.name ?? model.preferences.username)}else{model.invitedServer=try MinecraftAddress(invitation.target).string};model.social.launchFriends=[friend.id];model.section = .multiplayer;model.toast(invitation.version.isEmpty ? "已打开联机":"请使用 Minecraft "+invitation.version+" 及相同模组进入")}catch{model.errorMessage=error.localizedDescription}}
}

struct FriendUnreadBadge:View {
    @ObservedObject var chat:HarborChat
    var peer:String?=nil
    private var count:Int{peer.map{chat.unread.contains($0) ? 1:0} ?? chat.unread.count}
    var body:some View{if count>0{Text(peer==nil ? String(min(99,count)):"●").font(.system(size:peer==nil ? 10:8,weight:.semibold)).foregroundStyle(.white).padding(peer==nil ? 4:3).background(Color(hex:0x36865D),in:Capsule()).accessibilityLabel("有未读消息")}}
}
