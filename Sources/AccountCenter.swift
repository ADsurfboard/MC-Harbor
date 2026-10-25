import AppKit
import SwiftUI

struct NativeAccountsView:View {
    @ObservedObject var model:LauncherModel
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:24){
        HStack{Text("账号").font(.system(size:34,weight:.semibold));Spacer();Button("皮肤库"){model.modal = .skinLibrary}.buttonStyle(HarborButtonStyle());Button(model.migrating ? "导入中…":"导入 HMCL 账号"){model.migrateHMCL()}.buttonStyle(HarborButtonStyle()).disabled(model.migrating)}
        if !model.accounts.isEmpty{HStack(alignment:.top,spacing:22){VStack(spacing:9){ForEach(model.accounts){account in Button{model.preferences.selectedAccount=account.id}label:{HStack(spacing:12){MinecraftAvatar(model:model,account:account).frame(width:40,height:40);VStack(alignment:.leading,spacing:5){Text(account.name).font(.system(size:14,weight:.medium)).lineLimit(1);Text(account.kind=="microsoft" ? "Microsoft":account.kind=="authlibInjector" ? "第三方认证":"离线账号").font(.system(size:10)).foregroundStyle(.secondary)};Spacer(minLength:4);if model.selectedAccount?.id==account.id{Image(systemName:"checkmark.circle.fill").foregroundStyle(model.controlTint).font(.system(size:12))}}.padding(15).frame(maxWidth:.infinity,alignment:.leading).background(model.selectedAccount?.id==account.id ? model.themeColor.opacity(0.10):Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:18))}.buttonStyle(HarborPressButtonStyle(pressedScale:0.98,pressedOffset:0))}}.padding(10).frame(width:240).harborGlass(appearance:model.appearance,radius:24)
            if let account=model.selectedAccount{AccountSkinDetails(model:model,account:account).id(account.id).frame(maxWidth:.infinity)}
        }}
        AccountLoginControls(model:model)
    }.padding(28)}.scrollIndicators(.hidden)}
}
private struct AccountSkinDetails:View {
    @ObservedObject var model:LauncherModel;let account:LauncherAccount
    @Environment(\.scenePhase) private var phase
    @Environment(\.harborReduceMotion) private var reduceMotion
    @State private var draft:URL?
    @State private var draftModel="default"
    @State private var motion="none"
    @State private var rendererError=""
    @State private var applying=false
    private var profile:SkinProfile?{model.skinProfiles[account.id]}
    private var loading:Bool{model.skinLoading.contains(account.id)}
    private var pending:Bool{draft != nil || (profile != nil && draftModel != profile?.model)}
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack(alignment:.top){VStack(alignment:.leading,spacing:5){Text(account.name).font(.system(size:27,weight:.semibold)).lineLimit(1);Text(account.kind=="microsoft" ? "Microsoft":account.kind=="authlibInjector" ? "第三方认证":"离线账号").font(.system(size:11)).foregroundStyle(.secondary)};Spacer();Button{model.loadSkin(account,refresh:true)}label:{Image(systemName:"arrow.clockwise")}.buttonStyle(HarborButtonStyle()).disabled(loading).help("刷新皮肤");Menu{Button("移除账号",role:.destructive){model.removeAccount(account)}}label:{Image(systemName:"ellipsis").frame(width:32,height:32).contentShape(Circle())}.menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(loading).frame(width:32,height:32).contentShape(Circle()).harborPrism(radius:16)}
        MinecraftSkinPreview(skinPath:draft?.path ?? profile?.skinPath ?? SkinStorage.defaultSkin.path,capePath:profile?.capePath,model:draftModel,motion:motion,active:phase == .active && !reduceMotion,onError:{rendererError=$0}).frame(height:335).accessibilityLabel("Minecraft 三维皮肤预览，可拖拽旋转").overlay(alignment:.bottom){if loading{ProgressView().controlSize(.small).padding(12)}}
        Picker("预览",selection:$motion){Text("静止").tag("none");Text("旋转").tag("rotate");Text("行走").tag("walk")}.pickerStyle(.segmented).labelsHidden()
        HStack{Text("模型").font(.system(size:12)).foregroundStyle(.secondary);Picker("模型",selection:$draftModel){Text("标准").tag("default");Text("纤细").tag("slim")}.pickerStyle(.segmented).labelsHidden().frame(width:170);Spacer()}
        HStack(spacing:10){Button{chooseSkin()}label:{Label("导入皮肤",systemImage:"square.and.arrow.down")}.buttonStyle(HarborButtonStyle());Spacer();if pending{Button("取消预览"){draft=nil;draftModel=profile?.model ?? "default"}.buttonStyle(HarborBareButtonStyle()).font(.system(size:11));Button("应用皮肤"){if let path=draft ?? profile.map({URL(fileURLWithPath:$0.skinPath)}){applying=true;model.applySkin(path,slim:draftModel=="slim",account:account)}}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(loading || (account.kind != "offline" && profile?.canUpload == false))}}
        if let error=model.skinErrors[account.id]{Text(error).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled)}else if !rendererError.isEmpty{Text(rendererError).font(.system(size:11)).foregroundStyle(.secondary)}else if pending{Text("预览尚未应用").font(.system(size:10)).foregroundStyle(.secondary)}else if profile?.isDefault == true{Text("默认 Minecraft 皮肤").font(.system(size:10)).foregroundStyle(.secondary)}
        if let uuid=profile?.uuid ?? (account.uuid.isEmpty ? nil:account.uuid){Text(uuid).font(.system(size:9,design:.monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)}
    }.padding(24).harborGlass(appearance:model.appearance,radius:26).task{draftModel=profile?.model ?? "default";model.loadSkin(account)}.onChange(of:profile?.skinPath){_,path in if draft==nil || draft?.path==path{draft=nil;draftModel=profile?.model ?? "default"}}.onChange(of:loading){_,value in if !value && applying{applying=false;if model.skinErrors[account.id]==nil{draft=nil;draftModel=profile?.model ?? "default"}}}}
    private func chooseSkin(){let panel=NSOpenPanel();panel.allowedContentTypes=[.png];panel.canChooseDirectories=false;if panel.runModal() == .OK,let file=panel.url{do{draft=try SkinStorage.importFile(file);rendererError=""}catch{model.skinErrors[account.id]=error.localizedDescription}}}
}
