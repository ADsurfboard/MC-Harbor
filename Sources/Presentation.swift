import SwiftUI

/// Every in-app panel shares the same optical surface and transition. System file pickers stay native.
struct HarborModalHost:View {
    @ObservedObject var model:LauncherModel
    let modal:HarborModal
    let available:CGSize
    var body:some View{
        Group{switch modal{
        case .collection(let id):ModCollectionPanel(model:model,folderID:id).frame(width:min(850,available.width-70),height:min(710,available.height-96))
        case .install(let version):InstallSheet(model:model,version:version).frame(width:min(480,available.width-70))
        case .offline:OfflineAccountPanel(model:model).frame(width:min(410,available.width-70))
        case .externalAccount:ExternalAccountPanel(model:model).frame(width:min(480,available.width-70))
        case .addons(let game,let kind):AddonBrowser(model:model,game:game,kind:kind).frame(width:min(1040,available.width-70),height:min(690,available.height-96))
        case .worldEditor(let game,let world):WorldEditorPanel(model:model,game:game,world:world).frame(width:min(760,available.width-70),height:min(770,available.height-96))
        case .wallpapers:WallpaperLibraryPanel(model:model).frame(width:min(1080,available.width-70),height:min(710,available.height-96))
        case .skinLibrary:LittleSkinLibraryPanel(model:model).frame(width:min(1080,available.width-70),height:min(730,available.height-96))
        }}
        .harborGlass(appearance:model.appearance,radius:28)

        .clipShape(RoundedRectangle(cornerRadius:28))
        .onExitCommand{if case .worldEditor = modal {}else{model.modal=nil}}
    }
}

struct ModalFluidBackdrop:View {
    let color:Color
    let dark:Bool
    @Environment(\.scenePhase) private var phase
    @Environment(\.harborReduceMotion) private var reduceMotion
    var body:some View{ZStack{Color.black.opacity(dark ? 0.20:0.08);FluidField(dark:dark,color:color,active:phase == .active && !reduceMotion).opacity(dark ? 0.19:0.15).blur(radius:35)}.allowsHitTesting(false).accessibilityHidden(true)}
}

struct OfflineAccountPanel:View {
    @ObservedObject var model:LauncherModel
    @State private var name=""
    var body:some View{VStack(alignment:.leading,spacing:24){HStack{Text("离线账号").font(.system(size:26,weight:.semibold));Spacer();Button{model.modal=nil}label:{HarborSymbol(systemName:"xmark")}.buttonStyle(HarborButtonStyle())};TextField("用户名",text:$name).textFieldStyle(.roundedBorder).onSubmit{add()};HStack{Spacer();Button("添加"){add()}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(name.isEmpty)}}.padding(30)}
    private func add(){model.addOffline(name);if model.errorMessage==nil{model.modal=nil;HarborAudio.shared.play(.success)}}
}

struct ExternalAccountPanel:View {
    @ObservedObject var model:LauncherModel
    @State private var server=""
    @State private var username=""
    @State private var password=""
    @State private var selected=""
    @State private var profiles:[[String:String]]=[]
    private var busy:Bool{model.works.contains{$0.title=="外置登录" && $0.active}}
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack{Text("外置登录").font(.system(size:26,weight:.semibold));Spacer();Button{password="";model.modal=nil}label:{HarborSymbol(systemName:"xmark")}.buttonStyle(HarborButtonStyle())}
        Text("填写支持 authlib-injector / Yggdrasil 协议的认证服务器 API。账号凭据仅提交给该服务器，登录会话保存在本机钥匙串。使用 HTTP 时密码可能被网络窃听。") .font(.system(size:11)).harborSecondaryText()
        TextField("认证服务器 API 地址",text:$server).textFieldStyle(.roundedBorder)
        TextField("邮箱或用户名",text:$username).textFieldStyle(.roundedBorder)
        SecureField("密码",text:$password).textFieldStyle(.roundedBorder)
        if !profiles.isEmpty{Picker("选择角色",selection:$selected){ForEach(profiles,id:\.self){profile in Text(profile["name"] ?? "角色").tag(profile["id"] ?? "")}}}
        HStack{Spacer();Button("取消"){password="";model.modal=nil}.buttonStyle(HarborButtonStyle());Button(busy ? "正在登录…":"登录"){login()}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty || (!profiles.isEmpty && selected.isEmpty))}
    }.padding(30)}
    private func login(){let address=server,loginName=username,secret=password,profile=selected
        model.backend("externalLogin",title:"外置登录",arguments:["server":address,"username":loginName,"password":secret,"profile":profile]){result in
            if let items=result["profiles"] as? [[String:String]]{profiles=items;selected=items.first?["id"] ?? "";return}
            do{try model.saveExternalAccount(result);password="";model.modal=nil;HarborAudio.shared.play(.success)}catch{model.errorMessage=error.localizedDescription}
        }
    }
}
