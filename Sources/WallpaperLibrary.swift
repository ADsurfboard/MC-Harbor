import AppKit
import AVKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct LibraryWallpaper:Codable,Identifiable,Equatable,Sendable {
    let id:String
    var name:String
    let path:String
    let kind:WallpaperKind
    let owned:Bool
}

@MainActor final class WallpaperLibrary:ObservableObject {
    @Published var items:[LibraryWallpaper]=[]
    @Published var busy=false
    @Published var error:String?
    static var directory:URL{NativePaths.root.appendingPathComponent("wallpapers",isDirectory:true)}
    init(current:WallpaperSettings){
        items=(try? JSONDecoder().decode([LibraryWallpaper].self,from:Data(contentsOf:Self.directory.appendingPathComponent("catalog.json")))) ?? []
        if current.kind != .harbor,let path=current.filePath,!items.contains(where:{$0.path==path}) {
            items.insert(LibraryWallpaper(id:UUID().uuidString,name:URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent,path:path,kind:current.kind,owned:false),at:0)
            do{try save()}catch{self.error=error.localizedDescription}
        }
    }
    func save()throws{try FileManager.default.createDirectory(at:Self.directory,withIntermediateDirectories:true);try JSONEncoder().encode(items).write(to:Self.directory.appendingPathComponent("catalog.json"),options:.atomic)}
    func rename(_ item:LibraryWallpaper,to name:String){let name=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty,name.count<=100,let index=items.firstIndex(where:{$0.id==item.id}) else{return};let old=items;items[index].name=name;do{try save()}catch{items=old;self.error=error.localizedDescription}}
    func remove(_ item:LibraryWallpaper){let old=items;items.removeAll{$0.id==item.id};do{try save();let url=URL(fileURLWithPath:item.path).standardizedFileURL;if item.owned,url.deletingLastPathComponent()==Self.directory.standardizedFileURL{try? FileManager.default.removeItem(at:url)}}catch{items=old;self.error=error.localizedDescription}}
    func choose(){
        guard !busy else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[.image,.movie];panel.allowsMultipleSelection=true;panel.prompt="导入壁纸"
        guard panel.runModal() == .OK else{return};let urls=panel.urls;busy=true;error=nil
        Task{defer{busy=false};var failures:[String]=[]
            for url in urls {do{let item=try await Self.copy(url);items.insert(item,at:0);do{try save()}catch{items.removeAll{$0.id==item.id};try? FileManager.default.removeItem(atPath:item.path);throw error}}catch{failures.append(url.lastPathComponent+"："+error.localizedDescription)}}
            if !failures.isEmpty{error=failures.joined(separator:"\n")}
        }
    }
    nonisolated static func copy(_ source:URL)async throws->LibraryWallpaper {
        let values=try source.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.contentTypeKey]);guard values.isRegularFile==true,let size=values.fileSize,size>0,size<=4_000_000_000 else{throw FileTransactions.error("文件无效或超过 4 GB。")}
        let kind:WallpaperKind
        if values.contentType?.conforms(to:.movie)==true {guard !(try await AVURLAsset(url:source).loadTracks(withMediaType:.video)).isEmpty else{throw FileTransactions.error("视频中没有画面。")};kind = .video}
        else {guard size<=100_000_000,let image=CGImageSourceCreateWithURL(source as CFURL,nil),CGImageSourceGetCount(image)>0 else{throw FileTransactions.error("无法读取这张图片。")};kind = .image}
        let folder=NativePaths.root.appendingPathComponent("wallpapers",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let available=(try? folder.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        guard available>Int64(size)+100_000_000 else{throw FileTransactions.error("磁盘空间不足，请先释放空间。")}
        let id=UUID().uuidString,target=folder.appendingPathComponent(id+"."+source.pathExtension.lowercased()),staging=folder.appendingPathComponent(id+".partial")
        do{try await Task.detached(priority:.userInitiated){try FileManager.default.copyItem(at:source,to:staging)}.value;try Task.checkCancellation();try FileManager.default.moveItem(at:staging,to:target)}catch{try? FileManager.default.removeItem(at:staging);throw error}
        return LibraryWallpaper(id:id,name:source.deletingPathExtension().lastPathComponent,path:target.path,kind:kind,owned:true)
    }
}

enum WallpaperThumbnails {
    static func image(_ item:LibraryWallpaper)async->NSImage? {
        let url=URL(fileURLWithPath:item.path)
        if item.kind == .video {let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:640,height:400);guard let image=try? await generator.image(at:.zero).image else{return nil};return NSImage(cgImage:image,size:.zero)}
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:640,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{return nil};return NSImage(cgImage:image,size:.zero)
    }
}
private struct WallpaperThumbnail:View {
    let item:LibraryWallpaper
    @State private var image:NSImage?
    var body:some View{ZStack{Color.primary.opacity(0.06);if let image{Image(nsImage:image).resizable().scaledToFill()}else{Image(systemName:"photo").foregroundStyle(.secondary)}}.frame(height:112).clipped().overlay(alignment:.bottomTrailing){if item.kind == .video{Image(systemName:"video.fill").font(.system(size:11,weight:.semibold)).foregroundStyle(.white).padding(7).background(.black.opacity(0.5),in:RoundedRectangle(cornerRadius:8)).padding(7)}}.clipShape(RoundedRectangle(cornerRadius:14)).task(id:item.id){image=await Task.detached(priority:.utility){await WallpaperThumbnails.image(item)}.value}}

}

struct WallpaperLibraryPanel:View {
    @ObservedObject var model:LauncherModel
    @Environment(\.scenePhase) private var phase
    @StateObject private var library:WallpaperLibrary
    @State private var selected:String?
    @State private var name=""
    @State private var preview:NSImage?
    @State private var player:AVPlayer?
    @State private var removing=false
    init(model:LauncherModel){self.model=model;_library=StateObject(wrappedValue:WallpaperLibrary(current:model.preferences.wallpaper))}
    private var current:LibraryWallpaper?{library.items.first{$0.id==selected}}
    var body:some View{VStack(spacing:18){
        HStack{Text("壁纸库").font(.system(size:27,weight:.semibold));Spacer();if library.busy{ProgressView().controlSize(.small)};Button("导入图片或视频…"){library.choose()}.buttonStyle(HarborButtonStyle()).disabled(library.busy);Button{model.modal=nil}label:{Image(systemName:"xmark")}.buttonStyle(HarborButtonStyle())}
        HStack(alignment:.top,spacing:20){ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:155),spacing:12)],spacing:14){ForEach(library.items){item in Button{select(item)}label:{VStack(alignment:.leading,spacing:8){WallpaperThumbnail(item:item);HStack{Text(item.name).lineLimit(1);Spacer(minLength:2);if model.preferences.wallpaper.filePath==item.path{Image(systemName:"checkmark.circle.fill").foregroundStyle(model.controlTint)}}.font(.system(size:12)).padding(.horizontal,4)}.padding(7).background(selected==item.id ? model.themeColor.opacity(0.18):Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:19)).contentShape(RoundedRectangle(cornerRadius:19))}.buttonStyle(HarborPressButtonStyle(pressedScale:0.98,pressedOffset:0))}}}.frame(maxWidth:.infinity,maxHeight:.infinity)
            VStack(alignment:.leading,spacing:16){if let item=current{ZStack{Color.primary.opacity(0.04);if let player{VideoPlayer(player:player)}else if let preview{Image(nsImage:preview).resizable().scaledToFit()}else{Image(systemName:"photo")}}.frame(height:220).clipShape(RoundedRectangle(cornerRadius:18));HStack{TextField("壁纸名称",text:$name).textFieldStyle(.roundedBorder).onSubmit{library.rename(item,to:name)};Button("保存"){library.rename(item,to:name)}.buttonStyle(HarborButtonStyle()).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)};Text(item.kind == .video ? "动态壁纸 · 无声播放":"静态壁纸").font(.system(size:12)).foregroundStyle(.secondary);HStack{Button("使用壁纸"){model.preferences.wallpaper.kind=item.kind;model.preferences.wallpaper.filePath=item.path;model.toast("壁纸已切换")}.buttonStyle(HarborButtonStyle(prominent:true));Button("移除"){removing=true}.buttonStyle(HarborButtonStyle())}}else{ContentUnavailableView("选择壁纸",systemImage:"photo.on.rectangle",description:Text("导入后可命名、预览和切换。"))};Spacer()}.frame(width:320)
        }
        if let error=library.error{Text(error).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)}
    }.padding(25).onDisappear{player?.pause();player=nil}.onChange(of:phase){_,value in if value == .active{player?.play()}else{player?.pause()}}.onChange(of:library.items.count){_,_ in if current==nil,let first=library.items.first{select(first)}}.onAppear{if let item=library.items.first(where:{$0.path==model.preferences.wallpaper.filePath}) ?? library.items.first{select(item)}}.alert("从壁纸库移除？",isPresented:$removing){Button("取消",role:.cancel){};Button("移除",role:.destructive){if let item=current{if model.preferences.wallpaper.filePath==item.path{model.preferences.wallpaper.kind = .harbor;model.preferences.wallpaper.filePath=nil};player?.pause();player=nil;library.remove(item);selected=nil;preview=nil}}}message:{Text("导入的副本将被移除，原始文件保留。")}}
    private func select(_ item:LibraryWallpaper){selected=item.id;name=item.name;player?.pause();player=nil;preview=nil;if item.kind == .video{let p=AVPlayer(url:URL(fileURLWithPath:item.path));p.isMuted=true;player=p;p.play()}else{Task{let image=await Task.detached(priority:.utility){await WallpaperThumbnails.image(item)}.value;if selected==item.id{preview=image}}}}
}
