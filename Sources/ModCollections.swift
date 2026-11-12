import AppKit
import SwiftUI
import CryptoKit
import Combine

struct ModCollectionEntry:Codable,Identifiable,Equatable {
    let id:String;var title:String;var icon:String?;var file:String?;var project:AddonProject?;var source:AddonSource?
    static func ==(a:Self,b:Self)->Bool{a.id==b.id && a.title==b.title && a.file==b.file && a.icon==b.icon}
}
struct ModCollection:Codable,Identifiable,Equatable {let id:String;var name:String;var color:String;var entries:[ModCollectionEntry]}
@MainActor final class ModCollectionStore:ObservableObject {
    static let shared=ModCollectionStore()
    @Published private(set) var folders:[ModCollection]
    let root:URL
    init(root:URL=NativePaths.root.appendingPathComponent("mod-collections")){self.root=root;folders=(try? JSONDecoder().decode([ModCollection].self,from:Data(contentsOf:root.appendingPathComponent("folders.json")))) ?? []}
    private func save(_ value:[ModCollection])throws{try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try JSONEncoder().encode(value).write(to:root.appendingPathComponent("folders.json"),options:.atomic);folders=value}
    @discardableResult func create(_ name:String,color:String="#A7CDBB")throws->String{let title=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !title.isEmpty,title.count<=60 else{throw FileTransactions.error("模组夹名称需为 1–60 字。")};let id=UUID().uuidString;var value=folders;value.append(.init(id:id,name:title,color:color,entries:[]));try save(value);return id}
    func update(_ id:String,name:String,color:String)throws{let title=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !title.isEmpty,title.count<=60,color.range(of:"^#[A-Fa-f0-9]{6}$",options:.regularExpression) != nil else{throw FileTransactions.error("请填写有效的名称与颜色。")};var value=folders;guard let i=value.firstIndex(where:{$0.id==id}) else{return};value[i].name=title;value[i].color=color;try save(value)}
    func delete(_ id:String)throws{try save(folders.filter{$0.id != id})} // Cached files retained for recovery / other folders.
    func remove(_ ids:Set<String>,folder:String)throws{var value=folders;guard let i=value.firstIndex(where:{$0.id==folder}) else{return};value[i].entries.removeAll{ids.contains($0.id)};try save(value)}
    func add(_ project:AddonProject,source:AddonSource,to folder:String)throws{var value=folders;guard let i=value.firstIndex(where:{$0.id==folder}) else{throw FileTransactions.error("模组夹已不存在。")};let id=source.rawValue+":"+project.id;guard !value[i].entries.contains(where:{$0.id==id}) else{return};value[i].entries.append(.init(id:id,title:project.title,icon:project.iconUrl,file:nil,project:project,source:source));try save(value)}
    func addLocal(_ mods:[ModFile],to folder:String)async throws{
        let directory=root.appendingPathComponent("files");let icons=root.appendingPathComponent("icons")
        let added=try await Task.detached(priority:.userInitiated){()->[ModCollectionEntry] in
            let fm=FileManager.default;try fm.createDirectory(at:directory,withIntermediateDirectories:true);try fm.createDirectory(at:icons,withIntermediateDirectories:true)
            return try mods.map{mod in
                let values=try mod.path.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey]);guard values.isSymbolicLink != true,(values.fileSize ?? 0)<1_000_000_000 else{throw FileTransactions.error("不能收藏符号链接或过大的模组。")}
                let bytes=try Data(contentsOf:mod.path,options:.mappedIfSafe);let key=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined();let destination=directory.appendingPathComponent(key+".jar");if !fm.fileExists(atPath:destination.path){try bytes.write(to:destination,options:.atomic)}
                var icon:String?;if let path=mod.iconPath,let data=try? Data(contentsOf:URL(fileURLWithPath:path)),data.count<8_000_000{let target=icons.appendingPathComponent(key+".png");try data.write(to:target,options:.atomic);icon=target.path}
                return .init(id:key,title:mod.name,icon:icon,file:destination.path,project:nil,source:nil)
            }
        }.value
        var value=folders;guard let i=value.firstIndex(where:{$0.id==folder}) else{throw FileTransactions.error("模组夹已不存在。")};for item in added where !value[i].entries.contains(where:{$0.id==item.id}){value[i].entries.append(item)};try save(value)
    }
    func promptCreate()throws->String?{let alert=NSAlert();alert.messageText="新建模组夹";let input=NSTextField(string:"我的模组夹");input.frame=NSRect(x:0,y:0,width:300,height:26);alert.accessoryView=input;alert.addButton(withTitle:"创建");alert.addButton(withTitle:"取消");guard alert.runModal() == .alertFirstButtonReturn else{return nil};return try create(input.stringValue)}
}

struct CollectionArtwork:View {
    let entry:ModCollectionEntry?
    var feathered=false
    var onColors:((FolderColorPair?)->Void)?=nil
    @State private var image:NSImage?
    private static let landscape=NSImage(contentsOf:NativePaths.resources.appendingPathComponent("Brand/CollectionLandscape.png"))
    var body:some View{Group{if let image{
        if feathered{Image(nsImage:image).resizable().scaledToFit().mask(Image(nsImage:image).resizable().scaledToFit().blur(radius:0.65)).mask{Rectangle().fill(LinearGradient(stops:[.init(color:.clear,location:0),.init(color:.white,location:0.065),.init(color:.white,location:0.935),.init(color:.clear,location:1)],startPoint:.leading,endPoint:.trailing)).mask(LinearGradient(stops:[.init(color:.clear,location:0),.init(color:.white,location:0.065),.init(color:.white,location:0.935),.init(color:.clear,location:1)],startPoint:.top,endPoint:.bottom))}}
        else{Image(nsImage:image).resizable().scaledToFit()}
    }else{fallback}}.clipped().task(id:entry?.icon){
        image=nil
        let fallbackPath=NativePaths.resources.appendingPathComponent("Brand/CollectionLandscape.png").path
        var visual:CollectionVisual?
        if let icon=entry?.icon{visual=await CollectionArtworkLoader.shared.visual(icon)}
        if visual==nil{visual=await CollectionArtworkLoader.shared.visual(fallbackPath)}
        guard !Task.isCancelled else{return}
        image=visual.map{NSImage(cgImage:$0.bitmap.image,size:.zero)};onColors?(visual?.colors)
    }}
    private var fallback:some View{Group{if let image=Self.landscape{Image(nsImage:image).resizable().scaledToFill()}else{Color.gray.opacity(0.2).overlay(Image(systemName:"photo"))}}}
}
private struct CollectionDocumentTile:View {
    let entry:ModCollectionEntry?
    @State private var colors:FolderColorPair?
    var body:some View{ZStack{if let colors{FolderFlowBackdrop(colors:colors)};CollectionArtwork(entry:entry,feathered:true,onColors:{colors=$0}).padding(4)}}
}
private struct CollectionFolderShape:Shape {
    func path(in rect:CGRect)->Path{var p=Path();let w=rect.width,h=rect.height;p.move(to:.init(x:14,y:0));p.addLine(to:.init(x:w*0.36,y:0));p.addCurve(to:.init(x:w*0.56,y:12),control1:.init(x:w*0.44,y:0),control2:.init(x:w*0.47,y:12));p.addLine(to:.init(x:w-14,y:12));p.addQuadCurve(to:.init(x:w,y:26),control:.init(x:w,y:12));p.addLine(to:.init(x:w,y:h-14));p.addQuadCurve(to:.init(x:w-14,y:h),control:.init(x:w,y:h));p.addLine(to:.init(x:14,y:h));p.addQuadCurve(to:.init(x:0,y:h-14),control:.init(x:0,y:h));p.addLine(to:.init(x:0,y:14));p.addQuadCurve(to:.init(x:14,y:0),control:.zero);p.closeSubpath();return p}
}
/// A projected thin pocket, animated as geometry so text, clipping and materials share one plane.
private struct CollectionPocketShape:Shape {
    var opening:CGFloat
    var animatableData:CGFloat{get{opening}set{opening=newValue}}
    func path(in rect:CGRect)->Path {
        let w=rect.width,h=rect.height,inset:CGFloat=0.8+opening*3.2,lip:CGFloat=12+opening*5
        var p=Path();p.move(to:CGPoint(x:14+inset,y:0));p.addLine(to:CGPoint(x:w*0.36,y:0))
        p.addCurve(to:CGPoint(x:w*0.56,y:lip),control1:CGPoint(x:w*0.44,y:0),control2:CGPoint(x:w*0.47,y:lip));p.addLine(to:CGPoint(x:w-14-inset,y:lip));p.addQuadCurve(to:CGPoint(x:w-inset,y:lip+14),control:CGPoint(x:w-inset,y:lip))
        p.addLine(to:CGPoint(x:w,y:h-14));p.addQuadCurve(to:CGPoint(x:w-14,y:h),control:CGPoint(x:w,y:h));p.addLine(to:CGPoint(x:14,y:h));p.addQuadCurve(to:CGPoint(x:0,y:h-14),control:CGPoint(x:0,y:h));p.addLine(to:CGPoint(x:inset,y:14));p.addQuadCurve(to:CGPoint(x:14+inset,y:0),control:CGPoint(x:inset,y:0));p.closeSubpath();return p
    }
}
struct ModFolderCard:View {
    let folder:ModCollection;let action:()->Void
    @State private var hovering=false
    @Environment(\.harborReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var open:Bool{hovering && !reduceMotion}
    private static let grain=NSImage(contentsOf:NativePaths.resources.appendingPathComponent("Brand/FrostGrain.png")) ?? NSImage(size:NSSize(width:1,height:1))
    private var tint:Color{Color(hexString:folder.color)}
    private var dark:Bool{colorScheme == .dark}
    private var entries:[ModCollectionEntry?]{folder.entries.prefix(3).map{Optional($0)}}
    private func documents(time:Double)->some View {
        ZStack(alignment:.bottom){ForEach(Array(entries.enumerated()),id:\.offset){index,entry in
            CollectionDocumentTile(entry:entry).frame(width:154,height:110)
                .clipShape(RoundedRectangle(cornerRadius:11))
                .shadow(color:.black.opacity(0.12),radius:4,x:0,y:3)
                .rotationEffect(.degrees(open ? Double(index-1)*11:Double(index-1)*3))
                .scaleEffect(x:open ? 0.99:1,y:1,anchor:.bottom)
                .offset(x:open ? CGFloat(index-1)*35:CGFloat(index-1)*6,y:open ? -52-abs(CGFloat(index-1))*7:-23-CGFloat(index)*7)
        }}.frame(width:238,height:203,alignment:.bottom)
    }
    private func shell(time:Double)->some View {
        ZStack(alignment:.bottom){
            // The pocket transmits softened document colours; it is not a solid tinted tile.
            CollectionPocketShape(opening:open ? 1:0).fill((dark ? Color(white:0.34):Color.white).opacity(dark ? 0.17:0.13))
            documents(time:time).compositingGroup().blur(radius:11).saturation(1.12).opacity(dark ? 0.5:0.44)
                .frame(width:210,height:112,alignment:.bottom)
            CollectionPocketShape(opening:open ? 1:0).fill(tint.opacity(dark ? 0.12:0.10))
            Image(nsImage:Self.grain).resizable(resizingMode:.tile).opacity(dark ? 0.022:0.016)
            CollectionPocketShape(opening:open ? 1:0).fill(LinearGradient(colors:[.white.opacity(dark ? 0.16:0.38),.white.opacity(0.05),.white.opacity(dark ? 0.04:0.22)],startPoint:.topLeading,endPoint:.bottomTrailing))
            CollectionPocketShape(opening:open ? 1:0).fill(LinearGradient(colors:[.clear,(dark ? Color.black:Color.white).opacity(dark ? 0.12:0.26)],startPoint:.top,endPoint:.bottom))
        }.frame(width:210,height:112).clipShape(CollectionPocketShape(opening:open ? 1:0))
        // A narrow glint along the mouth only, rather than an outlined perimeter.
        .overlay(CollectionPocketShape(opening:open ? 1:0).trim(from:0,to:0.32).stroke(LinearGradient(colors:[.white.opacity(0.65),.white.opacity(0.12),.clear],startPoint:.topLeading,endPoint:.bottomTrailing),style:StrokeStyle(lineWidth:0.7,lineCap:.round)))
        .overlay(alignment:.bottomLeading){VStack(alignment:.leading,spacing:5){Text(folder.name).font(.system(size:14,weight:.semibold)).lineLimit(1);Text("\(folder.entries.count) 个模组").font(.system(size:10)).harborSecondaryText()}.padding(16).padding(.trailing,25)}
        .overlay(alignment:.bottomTrailing){Image(systemName:"arrow.up.right").font(.system(size:11,weight:.medium)).frame(width:26,height:26).background(.white.opacity(dark ? 0.10:0.3),in:Circle()).padding(13)}
        .shadow(color:.black.opacity(dark ? 0.18:0.065),radius:5,x:0,y:4)
        .scaleEffect(x:1,y:open ? 0.955:1,anchor:.bottom)
        .offset(y:open ? 3:0)
    }
    var body:some View{
        card(time:0)
    }
    private func card(time:Double)->some View{Button(action:action){
        ZStack(alignment:.bottom){
            CollectionFolderShape().fill((dark ? Color(white:0.46):Color.white).opacity(dark ? 0.13:0.19))
                .overlay(CollectionFolderShape().fill(tint.opacity(0.075)))
                .overlay(CollectionFolderShape().fill(LinearGradient(colors:[.white.opacity(0.24),.clear,.black.opacity(0.035)],startPoint:.topLeading,endPoint:.bottomTrailing)))
                .frame(width:200,height:141).offset(y:-9)
                .scaleEffect(x:1,y:open ? 1.015:1,anchor:.bottom)
            documents(time:time)
            // Contact shadow at the pocket opening separates the shell from its contents.
            Ellipse().fill(.black.opacity(dark ? 0.16:0.055)).frame(width:166,height:7).blur(radius:3).offset(y:-92)
            shell(time:time)
        }.frame(width:238,height:203)
            .background(alignment:.bottom){Ellipse().fill(.black.opacity(dark ? 0.14:0.07)).frame(width:180,height:13).blur(radius:open ? 13:8).offset(y:8)}
            .frame(maxWidth:.infinity).contentShape(RoundedRectangle(cornerRadius:24))
    }.buttonStyle(HarborPressButtonStyle(pressedScale:0.98,pressedOffset:0))
        .onHover{hovering=$0}.animation(reduceMotion ? nil:.spring(response:0.44,dampingFraction:0.78),value:hovering)
    }
}
struct ModCollectionsView:View {
    @ObservedObject var model:LauncherModel
    @ObservedObject private var store=ModCollectionStore.shared
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:24){HStack{VStack(alignment:.leading,spacing:7){Text("模组夹").font(.system(size:34,weight:.semibold));Text("收藏常用模组，按实例版本导入。").font(.system(size:12)).harborSecondaryText()};Spacer();Button{do{if let id=try store.promptCreate(){model.modal = .collection(id)}}catch{model.errorMessage=error.localizedDescription}}label:{Label("新建模组夹",systemImage:"folder.badge.plus")}.buttonStyle(HarborButtonStyle(prominent:true))};if store.folders.isEmpty{HarborEmptyView("从下载详情收藏模组，或在实例内批量收藏",systemImage:"folder")};LazyVGrid(columns:[GridItem(.adaptive(minimum:250),spacing:20)],spacing:24){ForEach(store.folders){folder in ModFolderCard(folder:folder){model.modal = .collection(folder.id)}}}}.padding(28)}}
}
struct ModCollectionPanel:View {
    @ObservedObject var model:LauncherModel
    let folderID:String
    @ObservedObject private var store=ModCollectionStore.shared
    @State private var name=""
    @State private var color="#A7CDBB"
    @State private var query=""
    @State private var target=""
    @State private var status=""
    @State private var selection:Set<String>=[]
    @State private var busy=false
    private var folder:ModCollection?{store.folders.first{$0.id==folderID}}
    private var filtered:[ModCollectionEntry]{folder?.entries.filter{query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)} ?? []}
    var body:some View{VStack(spacing:18){HStack{Text("模组夹").font(.system(size:25,weight:.semibold));Spacer();Button{model.modal=nil}label:{Image(systemName:"xmark").frame(width:22,height:22)}.buttonStyle(HarborButtonStyle())};HStack{TextField("名称",text:$name).textFieldStyle(.roundedBorder);ColorPicker("颜色",selection:Binding(get:{Color(hexString:color)},set:{color=$0.hexString}),supportsOpacity:false).frame(width:95);Button("保存"){do{try store.update(folderID,name:name,color:color)}catch{model.errorMessage=error.localizedDescription}}.buttonStyle(HarborButtonStyle())};SearchBox(prompt:"搜索模组夹内的模组",query:$query)
        ScrollView{LazyVStack(spacing:9){ForEach(filtered){entry in HStack(spacing:14){Toggle("选择 "+entry.title,isOn:Binding(get:{selection.contains(entry.id)},set:{if $0{selection.insert(entry.id)}else{selection.remove(entry.id)}})).labelsHidden().toggleStyle(.checkbox);CollectionArtwork(entry:entry).frame(width:48,height:48).clipShape(RoundedRectangle(cornerRadius:10));VStack(alignment:.leading,spacing:5){Group{if let project=entry.project{ModProjectName(project:project)}else{ModProjectName(project:AddonProject(projectId:entry.id,title:entry.title,description:"",author:"",iconUrl:nil,downloads:0,pageUrl:nil))}}.font(.system(size:14,weight:.medium)).lineLimit(2);Text(entry.file == nil ? entry.source?.title ?? "在线项目":"本地收藏 · 不依赖原实例文件").font(.system(size:11)).harborSecondaryText()};Spacer()}.padding(14).frame(maxWidth:.infinity,minHeight:80,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:16)).contentShape(RoundedRectangle(cornerRadius:16)).onTapGesture{if selection.contains(entry.id){selection.remove(entry.id)}else{selection.insert(entry.id)}}}}}.frame(minHeight:200,maxHeight:.infinity)
        HStack{Button(selection.count==filtered.count ? "取消全选":"全选"){selection=selection.count==filtered.count ? []:Set(filtered.map(\.id))};Button("移出所选",role:.destructive){do{try store.remove(selection,folder:folderID);selection=[]}catch{model.errorMessage=error.localizedDescription}}.disabled(selection.isEmpty || busy);Spacer();Text(status).font(.system(size:11)).harborSecondaryText().lineLimit(2)}.buttonStyle(HarborButtonStyle())
        HStack{Picker("目标实例",selection:$target){Text("选择实例").tag("");ForEach(model.games){Text(model.displayName($0)+" · "+$0.version+" / "+$0.loader).tag($0.id)}};Button(busy ? "正在检查兼容性…":"导入所选到实例"){install()}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(busy || selection.isEmpty || target.isEmpty)}
        HStack{Button("删除模组夹",role:.destructive){let alert=NSAlert();alert.messageText="删除此模组夹？";alert.informativeText="不会删除任何实例里的模组。";alert.addButton(withTitle:"删除");alert.addButton(withTitle:"取消");if alert.runModal() == .alertFirstButtonReturn{do{try store.delete(folderID);model.modal=nil}catch{model.errorMessage=error.localizedDescription}}}.buttonStyle(HarborBareButtonStyle());Spacer();Text("在线收藏会重新匹配 Minecraft 版本、加载器及前置。本地 JAR 请自行确认兼容性。").font(.system(size:10)).harborSecondaryText()}
    }.padding(26).task{if let folder{name=folder.name;color=folder.color};target=model.selected?.id ?? ""}}
    private func install(){guard let game=model.games.first(where:{$0.id==target}),let folder else{return};guard !model.running.contains(game.id) else{model.errorMessage="请先退出目标实例，再批量导入模组。";return};let entries=folder.entries.filter{selection.contains($0.id)};busy=true
        Task{defer{busy=false};do{
            var plan:[AddonPlanItem]=[];var versions:[String:String]=[:]
            for entry in entries where entry.project != nil{try Task.checkCancellation();guard let project=entry.project,let source=entry.source else{continue};status="检查 "+entry.title
                guard let version=try await ResourceService.versions(project.id,game:game,kind:.mods,source:source).first else{throw FileTransactions.error("找不到适配 "+game.version+" / "+game.loader+" 的 "+entry.title+"，尚未导入。")}
                for item in try await ResourceService.plan(version,game:game,kind:.mods,source:source){if let old=versions[item.id],old != item.version.id{throw FileTransactions.error("模组夹中的前置版本冲突，请分别检查后安装。")};if versions[item.id]==nil{versions[item.id]=item.version.id;plan.append(item)}}
            }
            for entry in entries where entry.file != nil{guard let path=entry.file else{continue};let url=URL(fileURLWithPath:path);let bytes=try await Task.detached{try Data(contentsOf:url,options:.mappedIfSafe)}.value;let sha=SHA512.hash(data:bytes).map{String(format:"%02x",$0)}.joined();let project="local-"+entry.id
                let file=AddonFile(filename:url.lastPathComponent,url:url.absoluteString,size:Int64(bytes.count),hashes:["sha512":sha],primary:true)
                let version=AddonVersion(id:entry.id,projectId:project,name:entry.title,versionNumber:"本地收藏",gameVersions:[game.version],loaders:[AddonService.loader(game)],files:[file],dependencies:[]);plan.append(.init(version:version,file:file))
            }
            if !plan.isEmpty{model.installAddon(plan,game:game,kind:.mods,title:folder.name);status="已创建安装任务，包含 \(plan.count) 个模组与前置"}

        }catch{status="导入未完成";model.errorMessage=error.localizedDescription}}
    }
}
@MainActor extension LauncherModel {
    func collectMods(_ mods:[ModFile],folder:String){let resolved=mods.map{mod->ModFile in var item=mod;item.iconPath=resourceRecords[mod.path.path]?.iconPath ?? mod.iconPath;return item};Task{do{try await ModCollectionStore.shared.addLocal(resolved,to:folder);toast("已收藏到模组夹")}catch{errorMessage=error.localizedDescription}}}
    func importCollectionFiles(_ entries:[ModCollectionEntry],game:GameInstance)async throws{
        guard !running.contains(game.id),!editingContent else{throw FileTransactions.error("请先退出目标游戏并等待文件操作完成。")};editingContent=true;defer{editingContent=false}
        let destination=URL(fileURLWithPath:game.runDirectory).appendingPathComponent("mods")
        try await Task.detached{let sources=try entries.map{entry->URL in guard let path=entry.file else{throw FileTransactions.error("收藏文件丢失。")};return URL(fileURLWithPath:path)};try FileTransactions.importFiles(sources,to:destination,extensions:["jar"],folders:false)}.value
        contentDidChange(game)
    }
}
