import AppKit
import SwiftUI

struct WorldPlayer: Decodable, Identifiable { let id:String;let label:String }
struct WorldSnapshot: Decodable {
    let revision:String
    let world:String
    let version:String
    let player:String
    let players:[WorldPlayer]
    let values:[String:WorldValue]
    let backup:String?
}
enum WorldValue:Decodable,Equatable {
    case text(String), number(Double)
    init(from decoder:Decoder)throws{let c=try decoder.singleValueContainer();if let s=try? c.decode(String.self){self = .text(s)}else{self = .number(try c.decode(Double.self))}}
    var string:String{switch self{case .text(let s):return s;case .number(let n):return n==n.rounded() ? String(format:"%.0f",n):String(format:"%.6g",n)}}
    var numeric:Double{if case .number(let n)=self{return n};return 0}
}

/// A single staged form. Nothing is written until Save; the backend checks locks and revision again.
struct WorldEditorPanel:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    let world:LocalContent
    @State private var snapshot:WorldSnapshot?
    @State private var draft:[String:String]=[:]
    @State private var busy=false
    @State private var error=""
    @State private var status=""
    @State private var backup:String?
    @State private var pendingPlayer:String?
    @State private var confirmDiscard=false
    private var dirty:Bool{!changes.isEmpty}
    private var changes:[String:String]{draft.filter{key,value in snapshot?.values[key]?.string != value}}
    var body:some View {
        VStack(spacing:0){
            HStack(spacing:14){Image(systemName:"square.and.pencil").font(.system(size:23,weight:.light)).foregroundStyle(model.controlTint);VStack(alignment:.leading,spacing:4){Text("编辑存档").font(.system(size:24,weight:.semibold));Text(world.name+" · "+(snapshot?.version ?? game.version)).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)};Spacer();Button{close()}label:{Image(systemName:"xmark").frame(width:16,height:18)}.buttonStyle(HarborButtonStyle()).disabled(busy).help("关闭存档编辑")}.padding(26)
            Divider().opacity(0.25)
            if let snapshot {
                ScrollView{VStack(alignment:.leading,spacing:20){
                    group("世界") {
                        field("存档名称",key:"name",numeric:false)
                        HStack(spacing:24){choice("游戏模式",key:"gameMode",items:["生存","创造","冒险","旁观"]);choice("难度",key:"difficulty",items:["和平","简单","普通","困难"])}
                        HStack(spacing:24){flag("极限模式",key:"hardcore");flag("允许作弊",key:"cheats");Spacer()}
                        HStack(spacing:24){field("游戏天数",key:"day",note:"从第 0 天开始");field("当日时间",key:"dayTick",note:"0–23999 tick")}
                        field("世界累计时间",key:"ageTicks",note:"tick · 独立于昼夜时间")
                    }
                    group("玩家") {
                        if snapshot.players.isEmpty{Text("此存档尚无玩家数据，进入游戏保存后即可编辑。").font(.system(size:12)).foregroundStyle(.secondary)}else{
                            HStack{Text("所选玩家").font(.system(size:12));Spacer();Picker("所选玩家",selection:Binding(get:{snapshot.player},set:{value in if dirty{pendingPlayer=value;confirmDiscard=true}else{load(player:value)}})){ForEach(snapshot.players){player in Text(player.label).tag(player.id)}}.labelsHidden().frame(maxWidth:340).disabled(busy)}
                            HStack(spacing:24){field("生命值",key:"health",note:"通常 20 = 10 颗心");field("饱食度",key:"hunger",note:"0–20")}
                            HStack(spacing:24){field("饱和度",key:"saturation",note:"0–20");field("经验等级",key:"xpLevel",note:"保存时同步总经验")}
                            HStack(spacing:24){field("经验进度",key:"xpProgress",note:"0–0.999999");VStack(alignment:.leading,spacing:7){Text("预计总经验").font(.system(size:11)).foregroundStyle(.secondary);Text(estimatedXP).font(.system(size:20,weight:.medium,design:.rounded))}.frame(maxWidth:.infinity,alignment:.leading)}
                        }
                    }
                }.padding(24)}.disabled(busy)
            }else{VStack(spacing:15){if busy{ProgressView();Text("正在读取存档").font(.system(size:12))}else{Image(systemName:"exclamationmark.triangle").font(.system(size:28,weight:.light));Text(error.isEmpty ? "未能读取存档":error).font(.system(size:12)).multilineTextAlignment(.center);Button("重新读取"){load()}.buttonStyle(HarborButtonStyle())}}.padding(30).frame(maxWidth:.infinity,maxHeight:.infinity)}
            Divider().opacity(0.25)
            HStack(spacing:12){VStack(alignment:.leading,spacing:4){Text(error.isEmpty ? status.isEmpty ? "保存前自动备份修改涉及的 NBT 文件":status:error).font(.system(size:11)).foregroundStyle(error.isEmpty ? Color.secondary:Color.orange).lineLimit(2);if let backup{Button("查看本次备份"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:backup)])}.font(.system(size:10)).buttonStyle(HarborBareButtonStyle())}};Spacer();if busy{ProgressView().controlSize(.small)};Button("重新读取"){if dirty{pendingPlayer=snapshot?.player;confirmDiscard=true}else{load(player:snapshot?.player)}}.buttonStyle(HarborButtonStyle()).disabled(busy || snapshot==nil);Button("保存修改"){save()}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(busy || !dirty).keyboardShortcut("s",modifiers:.command)}.padding(.horizontal,24).padding(.vertical,17)
        }
        .task{load()}
        .confirmationDialog("放弃尚未保存的修改？",isPresented:$confirmDiscard,titleVisibility:.visible){Button("放弃修改",role:.destructive){if let pendingPlayer{load(player:pendingPlayer);self.pendingPlayer=nil}else{model.modal=nil}};Button("继续编辑",role:.cancel){pendingPlayer=nil}}
        .onExitCommand{close()}
    }
    private var estimatedXP:String{guard let n=Double(draft["xpLevel"] ?? ""),let p=Double(draft["xpProgress"] ?? ""),n>=0,n<=21863,p>=0,p<1 else{return "—"};let base=n<=16 ? n*n+6*n:n<=31 ? 2.5*n*n-40.5*n+360:4.5*n*n-162.5*n+2220;let next=n>=30 ? 112+(n-30)*9:n>=15 ? 37+(n-15)*5:7+2*n;return String(format:"%.0f",base+floor(next*p))}
    private func group<C:View>(_ title:String,@ViewBuilder content:()->C)->some View{VStack(alignment:.leading,spacing:18){Text(title).font(.system(size:16,weight:.semibold));content()}.padding(21).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:19))}
    @ViewBuilder private func field(_ title:String,key:String,numeric:Bool=true,note:String="")->some View {
        if snapshot?.values[key] != nil{VStack(alignment:.leading,spacing:7){HStack{Text(title).font(.system(size:12));if !note.isEmpty{Text(note).font(.system(size:10)).foregroundStyle(.secondary)}};TextField(title,text:binding(key)).textFieldStyle(.roundedBorder).font(.system(size:13,design:numeric ? .monospaced:.default)).accessibilityIdentifier("world-"+key)}.frame(maxWidth:.infinity,alignment:.leading)}
    }
    @ViewBuilder private func choice(_ title:String,key:String,items:[String])->some View{if snapshot?.values[key] != nil{VStack(alignment:.leading,spacing:7){Text(title).font(.system(size:12));Picker(title,selection:binding(key)){ForEach(Array(items.enumerated()),id:\.offset){index,name in Text(name).tag(String(index))}}.labelsHidden().frame(maxWidth:.infinity)}.frame(maxWidth:.infinity)}}
    @ViewBuilder private func flag(_ title:String,key:String)->some View{if snapshot?.values[key] != nil{Toggle(title,isOn:Binding(get:{draft[key]=="1"},set:{draft[key]=$0 ? "1":"0"})).font(.system(size:12)).toggleStyle(.switch).controlSize(.small)}}
    private func binding(_ key:String)->Binding<String>{Binding(get:{draft[key] ?? ""},set:{draft[key]=$0})}
    private func close(){guard !busy else{return};if dirty{pendingPlayer=nil;confirmDiscard=true}else{model.modal=nil}}
    private func input(_ command:String,player:String?=nil)->[String:Any]{var value:[String:Any]=["command":command,"runDirectory":game.runDirectory,"world":world.name];if let player{value["player"]=player};return value}
    private func load(player:String?=nil){guard !busy else{return};busy=true;error="";Task{@MainActor in defer{busy=false};do{let result=try await BackendQuery.run(input("worldRead",player:player));let value:WorldSnapshot=try ResourceService.decode(result);snapshot=value;draft=value.values.mapValues(\.string);status=""}catch{self.error=error.localizedDescription}}}
    private func save(){
        guard !busy,let snapshot else{return};guard !model.running.contains(game.id) else{error="请退出此实例后再编辑存档。";return}
        var values:[String:Any]=[:];for(key,text)in changes{if key=="name"{values[key]=text}else{guard let n=Double(text),n.isFinite else{error="请填写有效数字："+key;return};values[key]=n}}
        var request=input("worldSave",player:snapshot.player);request["revision"]=snapshot.revision;request["changes"]=values;busy=true;error=""
        Task{@MainActor in defer{busy=false};do{let result=try await BackendQuery.run(request);let value:WorldSnapshot=try ResourceService.decode(result);self.snapshot=value;draft=value.values.mapValues(\.string);backup=value.backup;status="修改已保存，备份已校验";model.contentChanged.send();HarborAudio.shared.play(.success)}catch{self.error=error.localizedDescription;HarborAudio.shared.play(.error)}}
    }
}
