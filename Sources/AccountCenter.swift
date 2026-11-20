import AppKit
import SwiftUI
import CryptoKit
import CommonCrypto
import Security
import UniformTypeIdentifiers

struct NativeAccountsView:View {
    @ObservedObject var model:LauncherModel
    @State private var migrationExportOpen=false
    @State private var migrationPassphrase=""
    @State private var migrationConfirmation=""
    @State private var migrationAccountIDs:Set<String>=[]
    @State private var migrationStatus=""
    @State private var migrationBusy=false
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:24){
        HStack{Text("账号").font(.system(size:34,weight:.semibold));Spacer();Button("皮肤库"){model.modal = .skinLibrary}.buttonStyle(HarborButtonStyle());Button("导出 Windows 登录包"){migrationAccountIDs=Set(model.accounts.filter{$0.kind != "offline"}.map(\.id));migrationExportOpen=true}.buttonStyle(HarborButtonStyle()).disabled(model.accounts.allSatisfy{$0.kind=="offline"});Button(model.migrating ? "导入中…":"导入 HMCL 账号"){model.migrateHMCL()}.buttonStyle(HarborButtonStyle()).disabled(model.migrating)}
        if !model.accounts.isEmpty{HStack(alignment:.top,spacing:22){VStack(spacing:9){ForEach(model.accounts){account in Button{model.preferences.selectedAccount=account.id}label:{HStack(spacing:12){MinecraftAvatar(model:model,account:account).frame(width:40,height:40);VStack(alignment:.leading,spacing:5){Text(account.name).font(.system(size:14,weight:.medium)).lineLimit(1);Text(account.kind=="microsoft" ? "Microsoft":account.kind=="authlibInjector" ? "第三方认证":"离线账号").font(.system(size:10)).harborSecondaryText()};Spacer(minLength:4);if model.selectedAccount?.id==account.id{Image(systemName:"checkmark.circle.fill").foregroundStyle(model.controlTint).font(.system(size:12))}}.padding(15).frame(maxWidth:.infinity,alignment:.leading).background(model.selectedAccount?.id==account.id ? model.themeColor.opacity(0.10):Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:18))}.buttonStyle(HarborPressButtonStyle(pressedScale:0.98,pressedOffset:0))}}.padding(10).frame(width:240).harborGlass(appearance:model.appearance,radius:24)
            if let account=model.selectedAccount{AccountSkinDetails(model:model,account:account).id(account.id).frame(maxWidth:.infinity)}
        }}
        AccountLoginControls(model:model)
    }.padding(28)}.harborHideScrollIndicators().sheet(isPresented:$migrationExportOpen){migrationExportPanel}}
    private var migrationExportPanel:some View{VStack(alignment:.leading,spacing:14){
        Text("导出 Windows 登录包").font(.system(size:22,weight:.semibold))
        Text("选择要迁移的在线账号，设置至少 12 个字符的口令。Windows 导入后会使用目标 Windows 用户的凭据保护保存会话。").font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        List(model.accounts.filter{$0.kind != "offline"}){account in
            Toggle(isOn:Binding(get:{migrationAccountIDs.contains(account.id)},set:{enabled in if enabled{migrationAccountIDs.insert(account.id)}else{migrationAccountIDs.remove(account.id)}})){
                VStack(alignment:.leading,spacing:3){Text(account.name);Text(account.kind=="microsoft" ? "Microsoft":"外置认证").font(.system(size:10)).foregroundStyle(.secondary)}
            }
        }.frame(minHeight:120,maxHeight:220)
        SecureField("迁移口令",text:$migrationPassphrase)
        SecureField("再次输入迁移口令",text:$migrationConfirmation)
        if !migrationStatus.isEmpty{Text(migrationStatus).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        HStack{Spacer();Button("取消"){migrationPassphrase="";migrationConfirmation="";migrationExportOpen=false};Button(migrationBusy ? "正在读取钥匙串…" : "导出加密文件"){exportMigrationBundle()}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(migrationBusy || migrationAccountIDs.isEmpty)}
    }.padding(22).frame(width:520,height:500)}
    private func exportMigrationBundle(){
        let passphrase=migrationPassphrase.precomposedStringWithCanonicalMapping
        guard passphrase.count >= 12 else{migrationStatus="迁移口令至少需要 12 个字符。";return}
        guard passphrase == migrationConfirmation.precomposedStringWithCanonicalMapping else{migrationStatus="两次输入的迁移口令不一致。";return}
        let selected=model.accounts.filter{migrationAccountIDs.contains($0.id) && $0.kind != "offline"}
        guard !selected.isEmpty else{migrationStatus="请选择至少一个在线账号。";return}
        let panel=NSSavePanel();panel.nameFieldStringValue="MC-Harbor-Windows-Migration.json";panel.allowedContentTypes=[.json]
        guard panel.runModal() == .OK,let destination=panel.url else{return}
        migrationBusy=true;migrationStatus="正在读取所选账号的钥匙串状态…"
        do{
            var rows:[[String:Any]]=[]
            for account in selected{
                guard let secret=KeychainStore.read(account.id),
                      let value=try JSONSerialization.jsonObject(with:secret) as? [String:Any],
                      let metadata=value["metadata"] as? [String:Any],
                      let hmcl=value["hmclMetadata"] as? [String:Any],
                      let privateData=value["privateData"] as? [String:Any],
                      metadata["id"] as? String != nil,
                      hmcl.isEmpty == false,privateData.isEmpty == false else{continue}
                rows.append(["metadata":metadata,"hmclMetadata":hmcl,"privateData":privateData])
            }
            guard !rows.isEmpty else{migrationStatus="所选账号没有可导出的登录状态。";migrationBusy=false;return}
            let data=try MacAccountMigrationBundle.encrypt(rows,passphrase:passphrase)
            try data.write(to:destination,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            migrationStatus="已加密导出 \(rows.count) 个账号。将此文件与迁移口令分别保存。"
            migrationPassphrase="";migrationConfirmation=""
            migrationBusy=false
        }catch{migrationStatus="导出失败：\(error.localizedDescription)";migrationBusy=false}
    }
}

private enum MacAccountMigrationBundle {
    private static let iterations:UInt32=600_000
    private static let associatedData=Data("mc-harbor/account-migration/v1".utf8)

    static func encrypt(_ accounts:[[String:Any]],passphrase:String)throws->Data{
        let payload:[String:Any]=["schema":"mc-harbor/account-migration","version":1,"accounts":accounts]
        var clear=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys])
        defer{clear.resetBytes(in:0..<clear.count)}
        var salt=Data(count:16);var nonce=Data(count:12)
        let saltLength=salt.count;let nonceLength=nonce.count
        let saltStatus=salt.withUnsafeMutableBytes{SecRandomCopyBytes(kSecRandomDefault,saltLength,$0.baseAddress!)}
        let nonceStatus=nonce.withUnsafeMutableBytes{SecRandomCopyBytes(kSecRandomDefault,nonceLength,$0.baseAddress!)}
        guard saltStatus==errSecSuccess,nonceStatus==errSecSuccess else{throw NSError(domain:"MC Harbor",code:1,userInfo:[NSLocalizedDescriptionKey:"无法生成迁移加密随机数。"])}
        var key=try deriveKey(passphrase:passphrase,salt:salt)
        defer{key.resetBytes(in:0..<key.count)}
        let sealed=try AES.GCM.seal(clear,using:SymmetricKey(data:key),nonce:AES.GCM.Nonce(data:nonce),authenticating:associatedData)
        let envelope:[String:Any]=["schema":"mc-harbor/account-migration","version":1,"kdf":"PBKDF2-HMAC-SHA256","iterations":iterations,"salt":salt.base64EncodedString(),"nonce":nonce.base64EncodedString(),"ciphertext":sealed.ciphertext.base64EncodedString(),"tag":sealed.tag.base64EncodedString()]
        return try JSONSerialization.data(withJSONObject:envelope,options:[.prettyPrinted,.sortedKeys])
    }

    private static func deriveKey(passphrase:String,salt:Data)throws->Data{
        let password=Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var key=Data(count:32)
        let keyLength=key.count
        let status=password.withUnsafeBytes{passwordBytes in
            salt.withUnsafeBytes{saltBytes in
                key.withUnsafeMutableBytes{keyBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to:Int8.self).baseAddress!,password.count,
                        saltBytes.bindMemory(to:UInt8.self).baseAddress!,salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),iterations,
                        keyBytes.bindMemory(to:UInt8.self).baseAddress!,keyLength)
                }
            }
        }
        guard status==kCCSuccess else{throw NSError(domain:"MC Harbor",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"无法生成迁移加密密钥。"])}
        return key
    }
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
        HStack(alignment:.top){VStack(alignment:.leading,spacing:5){Text(account.name).font(.system(size:27,weight:.semibold)).lineLimit(1);Text(account.kind=="microsoft" ? "Microsoft":account.kind=="authlibInjector" ? "第三方认证":"离线账号").font(.system(size:11)).harborSecondaryText()};Spacer();Button{model.loadSkin(account,refresh:true)}label:{HarborSymbol(systemName:"arrow.clockwise")}.buttonStyle(HarborButtonStyle()).disabled(loading).help("刷新皮肤");Menu{Button("移除账号",role:.destructive){model.removeAccount(account)}}label:{HarborSymbol(systemName:"ellipsis").frame(width:32,height:32).contentShape(Circle())}.menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(loading).frame(width:32,height:32).contentShape(Circle())}
        MinecraftSkinPreview(skinPath:draft?.path ?? profile?.skinPath ?? SkinStorage.defaultSkin.path,capePath:profile?.capePath,model:draftModel,motion:motion,active:phase == .active && !reduceMotion,onError:{rendererError=$0}).frame(height:335).accessibilityLabel("Minecraft 三维皮肤预览，可拖拽旋转").overlay(alignment:.bottom){if loading{HarborActivityIndicator().controlSize(.small).padding(12)}}
        Picker("预览",selection:$motion){Text("静止").tag("none");Text("旋转").tag("rotate");Text("行走").tag("walk")}.pickerStyle(.segmented).labelsHidden()
        HStack{Text("模型").font(.system(size:12)).harborSecondaryText();Picker("模型",selection:$draftModel){Text("标准").tag("default");Text("纤细").tag("slim")}.pickerStyle(.segmented).labelsHidden().frame(width:170);Spacer()}
        HStack(spacing:10){Button{chooseSkin()}label:{Label("导入皮肤",systemImage:"square.and.arrow.down")}.buttonStyle(HarborButtonStyle());Spacer();if pending{Button("取消预览"){draft=nil;draftModel=profile?.model ?? "default"}.buttonStyle(HarborBareButtonStyle()).font(.system(size:11));Button("应用皮肤"){if let path=draft ?? profile.map({URL(fileURLWithPath:$0.skinPath)}){applying=true;model.applySkin(path,slim:draftModel=="slim",account:account)}}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(loading || (account.kind != "offline" && profile?.canUpload == false))}}
        if let error=model.skinErrors[account.id]{Text(error).font(.system(size:11)).harborSecondaryText().textSelection(.enabled)}else if !rendererError.isEmpty{Text(rendererError).font(.system(size:11)).harborSecondaryText()}else if pending{Text("预览尚未应用").font(.system(size:10)).harborSecondaryText()}else if profile?.isDefault == true{Text("默认 Minecraft 皮肤").font(.system(size:10)).harborSecondaryText()}
        if let uuid=profile?.uuid ?? (account.uuid.isEmpty ? nil:account.uuid){Text(uuid).font(.system(size:9,design:.monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)}
    }.padding(24).harborGlass(appearance:model.appearance,radius:26).task{draftModel=profile?.model ?? "default";model.loadSkin(account)}.harborOnChange(of:profile?.skinPath){_,path in if draft==nil || draft?.path==path{draft=nil;draftModel=profile?.model ?? "default"}}.harborOnChange(of:loading){_,value in if !value && applying{applying=false;if model.skinErrors[account.id]==nil{draft=nil;draftModel=profile?.model ?? "default"}}}}
    private func chooseSkin(){let panel=NSOpenPanel();panel.allowedContentTypes=[.png];panel.canChooseDirectories=false;if panel.runModal() == .OK,let file=panel.url{do{draft=try SkinStorage.importFile(file);rendererError=""}catch{model.skinErrors[account.id]=error.localizedDescription}}}
}
