import SwiftUI

/// Every in-app panel shares the same optical surface and transition. System file pickers stay native.
struct HarborModalHost:View {
    @ObservedObject var model:LauncherModel
    let modal:HarborModal
    let available:CGSize
    var body:some View{
        Group{switch modal{
        case .install(let version):InstallSheet(model:model,version:version).frame(width:min(480,available.width-70))
        case .offline:OfflineAccountPanel(model:model).frame(width:min(410,available.width-70))
        case .addons(let game,let kind):AddonBrowser(model:model,game:game,kind:kind).frame(width:min(1040,available.width-70),height:min(690,available.height-96))
        case .worldEditor(let game,let world):WorldEditorPanel(model:model,game:game,world:world).frame(width:min(760,available.width-70),height:min(770,available.height-96))
        }}
        .harborGlass(appearance:model.appearance,radius:28)
        .overlay(OpticalRim(radius:28,strength:0.35,color:model.themeColor,clarity:model.surfaceClarity).allowsHitTesting(false))
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
    var body:some View{VStack(alignment:.leading,spacing:24){HStack{Text("离线账号").font(.system(size:26,weight:.semibold));Spacer();Button{model.modal=nil}label:{Image(systemName:"xmark")}.buttonStyle(HarborButtonStyle())};TextField("用户名",text:$name).textFieldStyle(.roundedBorder).onSubmit{add()};HStack{Spacer();Button("添加"){add()}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(name.isEmpty)}}.padding(30)}
    private func add(){model.addOffline(name);if model.errorMessage==nil{model.modal=nil;HarborAudio.shared.play(.success)}}
}
