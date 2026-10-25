import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct SkinProfile:Codable,Sendable {
    let name:String;let uuid:String;let model:String;let skinPath:String;let capePath:String?;let canUpload:Bool;let isDefault:Bool
}
enum SkinStorage {
    static func record(_ id:String)->URL{NativePaths.root.appendingPathComponent("skins/profiles/"+SHA256.hash(data:Data(id.utf8)).map{String(format:"%02x",$0)}.joined()+".json")}
    static func cached(_ id:String)->SkinProfile?{guard let data=try? Data(contentsOf:record(id)),let value=try? JSONDecoder().decode(SkinProfile.self,from:data),FileManager.default.fileExists(atPath:value.skinPath) else{return nil};return value}
    static func save(_ profile:SkinProfile,id:String)throws{let file=record(id);try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try JSONEncoder().encode(profile).write(to:file,options:.atomic)}
    static var defaultSkin:URL{NativePaths.resources.appendingPathComponent("Skins/wide/steve.png")}
    static func validate(_ file:URL)throws{
        let data=try Data(contentsOf:file);guard data.count<=4_000_000,data.starts(with:[137,80,78,71,13,10,26,10]),let source=CGImageSourceCreateWithData(data as CFData,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,width==64,(height==64 || height==32) else{throw FileTransactions.error("请选择 64×64 或 64×32 的 Minecraft PNG 皮肤（不超过 4 MB）。")}
    }
    static func importFile(_ file:URL)throws->URL{try validate(file);let data=try Data(contentsOf:file);let hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined();let target=NativePaths.root.appendingPathComponent("skins/imported/"+hash+".png");try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);if !FileManager.default.fileExists(atPath:target.path){try data.write(to:target,options:.atomic)};return target}
    static func dataURL(_ path:String?)->String?{guard let path,let data=try? Data(contentsOf:URL(fileURLWithPath:path)),data.count<=4_000_000 else{return nil};return "data:image/png;base64,"+data.base64EncodedString()}
}
private final class SkinResponseBox:@unchecked Sendable {let lock=NSLock();var account:Data?}
enum SkinService {
    static func load(_ account:LauncherAccount,refresh:Bool=false,file:URL?=nil,slim:Bool=false)async throws->(SkinProfile,Data?){
        let stored=await Task.detached{KeychainStore.read(account.id)}.value
        var raw:[String:Any]
        if let stored,let value=(try? JSONSerialization.jsonObject(with:stored)) as? [String:Any]{raw=value}
        else if account.kind=="offline"{var metadata:[String:Any]=["accountID":account.id.hasPrefix("account:") ? account.id:"account:"+account.id,"profileName":account.name];if !account.uuid.isEmpty{metadata["profileID"]=account.uuid};raw=["hmclMetadata":metadata,"privateData":[:]]}
        else{throw FileTransactions.error("请先解锁此账号的钥匙串凭据，或重新登录。")}
        var input:[String:Any]=["command":file==nil ? "profile":"applySkin","account":raw,"accountType":account.kind,"refresh":refresh]
        if let file{input["skinFile"]=file.path;input["slim"]=slim}
        let box=SkinResponseBox()
        let result:[String:Any]=try await withCheckedThrowingContinuation{continuation in
            do{_ = try JavaBridge.start(input:input,event:{event in if event["event"] as? String=="accountUpdated",let updated=event["data"],let bytes=try? JSONSerialization.data(withJSONObject:updated){box.lock.lock();box.account=bytes;box.lock.unlock()}},completion:{continuation.resume(with:$0)})}catch{continuation.resume(throwing:error)}
        }
        let profile=try JSONDecoder().decode(SkinProfile.self,from:JSONSerialization.data(withJSONObject:result));return (profile,box.account)
    }
}
@MainActor extension LauncherModel {
    func loadSkin(_ account:LauncherAccount,refresh:Bool=false){
        guard !skinLoading.contains(account.id),(refresh || skinProfiles[account.id]==nil) else{return};skinLoading.insert(account.id);skinErrors[account.id]=nil
        Task{defer{skinLoading.remove(account.id)};do{let (profile,stored)=try await SkinService.load(account,refresh:refresh);guard accounts.contains(where:{$0.id==account.id}) else{return};if let stored{try KeychainStore.write(stored,id:account.id)};try SkinStorage.save(profile,id:account.id);skinProfiles[account.id]=profile;if let index=accounts.firstIndex(where:{$0.id==account.id}),accounts[index].uuid.isEmpty{accounts[index].uuid=profile.uuid;saveAccounts()}}catch{if accounts.contains(where:{$0.id==account.id}){skinErrors[account.id]=error.localizedDescription}}}
    }
    func applySkin(_ file:URL,slim:Bool,account:LauncherAccount){
        guard !skinLoading.contains(account.id) else{return};skinLoading.insert(account.id);skinErrors[account.id]=nil
        Task{defer{skinLoading.remove(account.id)};do{let (profile,stored)=try await SkinService.load(account,file:file,slim:slim);guard accounts.contains(where:{$0.id==account.id}) else{return};if let stored{try KeychainStore.write(stored,id:account.id)};try SkinStorage.save(profile,id:account.id);skinProfiles[account.id]=profile;if let index=accounts.firstIndex(where:{$0.id==account.id}){accounts[index].uuid=profile.uuid;saveAccounts()};toast("皮肤已更新");HarborAudio.shared.play(.success)}catch{skinErrors[account.id]=error.localizedDescription;HarborAudio.shared.play(.error)}}
    }
}
private enum MinecraftHeads {
    static var cache:[String:NSImage]=[:]
    static func image(_ path:String)->NSImage?{
        let revision=(try? URL(fileURLWithPath:path).resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0;let key=path+String(revision);if let image=cache[key]{return image};guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),let skin=CGImageSourceCreateImageAtIndex(source,0,nil) else{return nil}
        let unit=CGFloat(skin.width)/64;guard let face=skin.cropping(to:CGRect(x:8*unit,y:8*unit,width:8*unit,height:8*unit)),let context=CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil};context.interpolationQuality = .none;context.draw(face,in:CGRect(x:0,y:0,width:64,height:64));if let hat=skin.cropping(to:CGRect(x:40*unit,y:8*unit,width:8*unit,height:8*unit)){context.draw(hat,in:CGRect(x:0,y:0,width:64,height:64))};guard let bitmap=context.makeImage() else{return nil};let image=NSImage(cgImage:bitmap,size:NSSize(width:64,height:64));cache[key]=image;return image
    }
}
struct MinecraftAvatar:View {
    @ObservedObject var model:LauncherModel;let account:LauncherAccount
    var body:some View{Group{if let image=MinecraftHeads.image(model.skinProfiles[account.id]?.skinPath ?? SkinStorage.defaultSkin.path){Image(nsImage:image).resizable().interpolation(.none).scaledToFit()}}.clipShape(RoundedRectangle(cornerRadius:7)).accessibilityLabel(account.name+" 的 Minecraft 头像").task(id:account.id+String(model.showIntro)){if !model.showIntro{model.loadSkin(account)}}}
}
struct MinecraftSkinPreview:NSViewRepresentable {
    let skinPath:String;let capePath:String?;let model:String;let motion:String;let active:Bool
    var onError:(String)->Void={_ in}
    func makeCoordinator()->Coordinator{Coordinator()}
    func makeNSView(context:Context)->WKWebView{let configuration=WKWebViewConfiguration();configuration.userContentController.add(context.coordinator,name:"harborSkin");let web=WKWebView(frame:.zero,configuration:configuration);web.setValue(false,forKey:"drawsBackground");web.underPageBackgroundColor = .clear;web.navigationDelegate=context.coordinator;context.coordinator.web=web;let folder=NativePaths.resources.appendingPathComponent("SkinViewer");web.loadFileURL(folder.appendingPathComponent("index.html"),allowingReadAccessTo:folder);return web}
    func updateNSView(_ web:WKWebView,context:Context){context.coordinator.onError=onError;context.coordinator.skin=skinPath;context.coordinator.cape=capePath;context.coordinator.model=model;context.coordinator.motion=motion;context.coordinator.active=active;context.coordinator.update()}
    static func dismantleNSView(_ view:WKWebView,coordinator:Coordinator){view.evaluateJavaScript("window.harborDispose?.()");view.stopLoading();view.configuration.userContentController.removeScriptMessageHandler(forName:"harborSkin");view.navigationDelegate=nil}
    final class Coordinator:NSObject,WKNavigationDelegate,WKScriptMessageHandler {
        weak var web:WKWebView?;var ready=false;var skin="";var cape:String?;var model="default";var motion="none";var active=true;var last="";var lastMotion="";var onError:(String)->Void={_ in}
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){ready=true;update()}
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){let scheme=navigationAction.request.url?.scheme;decisionHandler(scheme=="file" || scheme=="about" ? .allow:.cancel)}
        func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage){if let data=message.body as? [String:String],let error=data["error"]{onError(error)}}
        func update(){guard ready,let web else{return};let timestamp=(try? URL(fileURLWithPath:skin).resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0;let signature=skin+"|"+(cape ?? "")+"|"+model+String(timestamp);if signature != last{last=signature;let payload:[String:Any]=["skin":SkinStorage.dataURL(skin) ?? "","cape":SkinStorage.dataURL(cape) as Any? ?? NSNull(),"model":model];if let data=try? JSONSerialization.data(withJSONObject:payload),let text=String(data:data,encoding:.utf8){web.evaluateJavaScript("window.harborSetSkin("+text+")")}};let motionKey=motion+String(active);guard motionKey != lastMotion else{return};lastMotion=motionKey;if let data=try? JSONSerialization.data(withJSONObject:["motion":motion,"active":active]),let text=String(data:data,encoding:.utf8){web.evaluateJavaScript("window.harborSetMotion("+text+")")}}
    }
}
