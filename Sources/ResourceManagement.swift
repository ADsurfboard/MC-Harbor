import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct InstanceResourceRecord:Decodable,Identifiable,Sendable {
    let path:String;let name:String;let kind:String;let enabled:Bool;let iconPath:String?;let links:[String:String];let languageFiles:Int;let revision:String
    var id:String{path}
}
struct ResourceArtwork:View {
    let iconPath:String?;let fallback:String
    @State private var image:NSImage?
    var body:some View{Group{if let image{Image(nsImage:image).resizable().scaledToFit()}else{Image(systemName:fallback).resizable().scaledToFit().foregroundStyle(.secondary).padding(3)}}.task(id:iconPath){let path=iconPath;let loaded=await Task.detached{path.flatMap{HarborImageCache.thumbnail($0)}}.value;if !Task.isCancelled{image=loaded}}}
}
struct ResourceSourceButton:View {
    @ObservedObject var model:LauncherModel;let path:String
    private var links:[String:String]{model.resourceRecords[path]?.links ?? [:]}
    var body:some View{Menu{ForEach(["curseforge","modrinth"],id:\.self){source in Button(source == "curseforge" ? "CurseForge 原项目":"Modrinth 原项目"){if let address=links[source],let url=URL(string:address){NSWorkspace.shared.open(url)}}.disabled(links[source]==nil)}}label:{Image(systemName:"link").font(.system(size:12)).frame(width:28,height:28).contentShape(Circle())}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:28).harborPrism(radius:14).disabled(links.isEmpty).opacity(links.isEmpty ? 0.35:1).help(links.isEmpty ? "未找到实例资源的原项目":"打开实例资源原项目")}
}
struct InstanceMoreButton:View {
    let action:()->Void
    var body:some View{Button(action:action){Image(systemName:"ellipsis").font(.system(size:15,weight:.semibold)).frame(width:38,height:38).background(Color.primary.opacity(0.055),in:Circle()).overlay(Circle().stroke(.white.opacity(0.14),lineWidth:0.6)).contentShape(Circle())}.buttonStyle(HarborBareButtonStyle()).help("管理实例")}
}
@MainActor extension LauncherModel {
    func loadResourceIndex(_ game:GameInstance,force:Bool=false){
        guard !resourceIndexing.contains(game.id),force || !resourceIndexed.contains(game.id) else{return}
        resourceIndexing.insert(game.id)
        Task{defer{resourceIndexing.remove(game.id)};let base:[String:Any]=["command":"resources","root":preferences.gameRoot,"id":game.id,"runDirectory":game.runDirectory]
            do{for resolve in [false,true]{var input=base;input["resolve"]=resolve;let result=try await BackendQuery.run(input);let records:[InstanceResourceRecord]=try ResourceService.decode(["resources":result["resources"] ?? []]).resources;var merged=resourceRecords;for record in records{merged[record.path]=record};resourceRecords=merged;resourceLookupStatus[game.id]=(result["warnings"] as? [String] ?? []).joined(separator:" · ")};resourceIndexed.insert(game.id)}catch{resourceLookupStatus[game.id]="来源索引暂不可用"}
        }
    }
    func artworkGame(_ game:GameInstance)->GameInstance{guard let path=preferences.instanceIcons[game.id],FileManager.default.fileExists(atPath:path) else{return game};return GameInstance(id:game.id,version:game.version,loader:game.loader,directory:game.directory,runDirectory:game.runDirectory,iconPath:path,modified:game.modified)}
    func chooseInstanceIcon(_ game:GameInstance){let panel=NSOpenPanel();panel.allowedContentTypes=[.image];panel.prompt="更换实例图标";guard panel.runModal() == .OK,let file=panel.url else{return};do{preferences.instanceIcons[game.id]=try InstanceIconStore.importFile(file,for:game.id).path;toast("实例图标已更换")}catch{errorMessage=error.localizedDescription}}
    func resetInstanceIcon(_ game:GameInstance){preferences.instanceIcons.removeValue(forKey:game.id)}
}
private struct ResourceIndexResponse:Decodable{let resources:[InstanceResourceRecord]}
private extension ResourceService {
    static func decode(_ object:[String:Any])throws->ResourceIndexResponse{let decoder=JSONDecoder();return try decoder.decode(ResourceIndexResponse.self,from:JSONSerialization.data(withJSONObject:object))}
}
enum InstanceIconStore {
    static func importFile(_ file:URL,for id:String)throws->URL{let values=try file.resourceValues(forKeys:[.fileSizeKey]);guard (values.fileSize ?? 0)<16_000_000,let source=CGImageSourceCreateWithURL(file as CFURL,nil),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{throw FileTransactions.error("无法读取这张图片，请选择有效的 PNG、JPEG 或其他系统支持的图片。")};let folder=NativePaths.root.appendingPathComponent("instance-icons");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let key=SHA256.hash(data:Data(id.utf8)).map{String(format:"%02x",$0)}.joined();let target=folder.appendingPathComponent(key+"-"+UUID().uuidString+".png");let image=NSBitmapImageRep(cgImage:cg);guard let bytes=image.representation(using:.png,properties:[:]) else{throw FileTransactions.error("无法保存实例图标。")};try bytes.write(to:target,options:.atomic);return target}
}
