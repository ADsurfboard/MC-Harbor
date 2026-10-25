import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private enum InstanceTab:String,CaseIterable,Identifiable {
    case mods="模组",resources="资源包",shaders="光影",worlds="存档",localization="汉化",screenshots="截图",logs="日志",settings="设置"
    var id:String{rawValue}
}

struct InstanceWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var tab:InstanceTab = .mods
    var body:some View {
        VStack(spacing:0){
            HStack(spacing:16){
                WorldIcon(game:model.artworkGame(game)).frame(width:48,height:48)
                VStack(alignment:.leading,spacing:5){Text(model.displayName(game)).font(.system(size:27,weight:.semibold)).lineLimit(1);Text(game.version+" · "+game.loader).font(.system(size:11)).foregroundStyle(.secondary)}
                Spacer()
                Button{model.launch(game)}label:{Label(model.running.contains(game.id) ? "运行中":"启动",systemImage:"play.fill")}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(model.running.contains(game.id))
                Menu{Button("打开实例目录"){model.open(game.runDirectory)};Button("校验与修复"){model.repair(game)};Button("备份存档"){model.backup(game)};Button("导出整合包…"){model.exportPack(game)};Divider();Button(model.preferences.favorites.contains(game.id) ? "取消收藏":"收藏"){model.favorite(game)}}label:{Image(systemName:"ellipsis").frame(width:34,height:34).contentShape(Circle())}.menuStyle(.borderlessButton).frame(width:34).harborPrism(radius:9)
                Button{model.inspectedGame=nil}label:{Image(systemName:"xmark").frame(width:16,height:18)}.buttonStyle(HarborButtonStyle()).help("关闭实例管理")
            }.padding(.horizontal,28).padding(.top,26).padding(.bottom,22)
            HStack(spacing:5){ForEach(InstanceTab.allCases){item in Button{tab=item;HarborAudio.shared.play(.navigate)}label:{Text(item.rawValue).font(.system(size:13,weight:tab==item ? .semibold:.regular)).padding(.horizontal,15).frame(height:34).foregroundStyle(tab==item ? model.controlTint:Color.secondary).background{if tab==item{HarborMaterial(shape:Capsule(),appearance:model.appearance,interactive:true)}}}.buttonStyle(HarborBareButtonStyle())};Spacer()}.padding(.horizontal,24).padding(.bottom,16)
            Divider().opacity(0.35)
            Group{switch tab{
            case .mods:ModWorkspace(model:model,game:game)
            case .resources:ContentWorkspace(model:model,game:game,kind:.resourcepacks)
            case .shaders:ContentWorkspace(model:model,game:game,kind:.shaderpacks)
            case .worlds:WorldWorkspace(model:model,game:game)
            case .localization:LocalizationWorkspace(model:model,game:game)
            case .screenshots:ScreenshotWorkspace(model:model,game:game)
            case .logs:LogWorkspace(model:model,game:game)
            case .settings:InstanceSettingsWorkspace(model:model,game:game)
            }}.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .harborGlass(appearance:model.appearance,radius:28)
        .overlay(OpticalRim(radius:28,strength:0.35,color:model.themeColor,clarity:model.surfaceClarity).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius:28))
        .onExitCommand{model.inspectedGame=nil}
        .task(id:game.id){tab = game.loader == "Minecraft" ? .worlds:.mods;model.loadMods(game);model.loadResourceIndex(game)}
    }
}

private struct ModWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var query=""
    @State private var filter="all"
    @State private var selection:Set<String>=[]
    @State private var sortOrder=[KeyPathComparator(\ModFile.name,order:.forward)]
    private var mods:[ModFile]{model.modMetadata[game.id] ?? NativeScanner.mods(game)}
    private var filtered:[ModFile]{mods.filter{(filter=="all" || $0.enabled == (filter=="enabled")) && (query.isEmpty || ($0.name+" "+$0.version+" "+$0.authors+" "+$0.modID+" "+$0.path.lastPathComponent).localizedCaseInsensitiveContains(query))}.sorted(using:sortOrder)}
    private var selected:[ModFile]{mods.filter{selection.contains($0.id)}}
    var body:some View {
        VStack(spacing:0){
            HStack(spacing:12){SearchBox(prompt:"搜索名称、作者或模组 ID",query:$query);Picker("状态",selection:$filter){Text("全部").tag("all");Text("已启用").tag("enabled");Text("已停用").tag("disabled")}.labelsHidden().frame(width:100);Button{model.modal = .addons(game,.mods)}label:{Label("下载模组",systemImage:"arrow.down.circle")}.buttonStyle(HarborButtonStyle(prominent:true));Button{model.importContent(game,kind:.mods)}label:{Image(systemName:"plus")}.buttonStyle(HarborButtonStyle()).help("导入本地模组")}.padding(20)
            Table(filtered,selection:$selection,sortOrder:$sortOrder){
                TableColumn("模组",value:\.name){mod in HStack(spacing:11){ResourceArtwork(iconPath:model.resourceRecords[mod.path.path]?.iconPath ?? mod.iconPath,fallback:"puzzlepiece.extension.fill").frame(width:28,height:28).opacity(mod.enabled ? 1:0.45);VStack(alignment:.leading,spacing:3){Text(mod.name).font(.system(size:12,weight:.medium)).lineLimit(1);Text(mod.modID.isEmpty ? mod.path.lastPathComponent:mod.modID).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)}}.padding(.vertical,5)}.width(min:200,ideal:300)
                TableColumn("版本",value:\.version){mod in Text(mod.version).font(.system(size:11,design:.monospaced)).lineLimit(1)}.width(min:80,ideal:125,max:190)
                TableColumn("作者",value:\.authors){mod in Text(mod.authors).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)}.width(min:80,ideal:145,max:200)
                TableColumn("大小",value:\.size){mod in Text(ByteCountFormatter.string(fromByteCount:mod.size,countStyle:.file)).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)}.width(75)
                TableColumn("来源"){mod in ResourceSourceButton(model:model,path:mod.path.path)}.width(42)
                TableColumn("启用"){mod in Toggle("启用 "+mod.name,isOn:Binding(get:{mod.enabled},set:{enabled in model.setMods([mod],enabled:enabled,game:game)})).labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.running.contains(game.id))}.width(52)
            }
            .tableStyle(.inset(alternatesRowBackgrounds:true)).scrollContentBackground(.hidden)
            .contextMenu(forSelectionType:String.self){ids in let files=mods.filter{ids.contains($0.id)};if !files.isEmpty{Button("启用"){model.setMods(files,enabled:true,game:game)};Button("停用"){model.setMods(files,enabled:false,game:game)};Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting(files.map(\.path))};Divider();Button("移到废纸篓",role:.destructive){model.trashContent(files.map(\.path),game:game)}}}
            .overlay{if filtered.isEmpty{ContentUnavailableView(query.isEmpty ? "暂无模组":"没有匹配的模组",systemImage:"puzzlepiece.extension")}}
            .dropDestination(for:URL.self){urls,_ in model.copyContent(urls,game:game,kind:.mods);return true}
            Divider().opacity(0.35)
            HStack(spacing:13){Text(selection.isEmpty ? "\(mods.count) 个模组 · \(mods.filter(\.enabled).count) 个启用":"已选择 \(selection.count) 个").font(.system(size:11)).foregroundStyle(.secondary);Spacer();if !selection.isEmpty{Button("启用"){model.setMods(selected,enabled:true,game:game)};Button("停用"){model.setMods(selected,enabled:false,game:game)};Button{model.trashContent(selected.map(\.path),game:game);selection=[]}label:{Image(systemName:"trash")}.help("移到废纸篓")};Button{model.loadMods(game,force:true)}label:{Image(systemName:"arrow.clockwise")}.help("重新读取")}.buttonStyle(HarborBareButtonStyle()).padding(.horizontal,22).frame(height:43)
        }
    }
}

struct SearchBox:View {
    let prompt:String
    @Binding var query:String
    var body:some View{HStack(spacing:9){Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField(prompt,text:$query).textFieldStyle(.plain);if !query.isEmpty{Button{query=""}label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}.buttonStyle(HarborBareButtonStyle())}}.font(.system(size:12)).padding(.horizontal,12).frame(height:34).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:11))}
}

struct LocalContent:Identifiable,Sendable {
    let url:URL
    let name:String
    let modified:Date
    let bytes:Int64
    let isDirectory:Bool
    var id:String{url.path}
    var active:Bool{url.pathExtension != "disabled"}
    static func read(_ directory:URL)->[LocalContent]{
        let urls=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.contentModificationDateKey,.fileSizeKey],options:[.skipsHiddenFiles])) ?? []
        return urls.compactMap{url in guard let v=try? url.resourceValues(forKeys:[.isDirectoryKey,.contentModificationDateKey,.fileSizeKey]) else{return nil};return LocalContent(url:url,name:url.lastPathComponent,modified:v.contentModificationDate ?? .distantPast,bytes:Int64(v.fileSize ?? 0),isDirectory:v.isDirectory ?? false)}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
}

private struct ContentWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    let kind:ContentKind
    @State private var query=""
    @State private var files:[LocalContent]=[]
    @State private var selection:Set<String>=[]
    private var directory:URL{URL(fileURLWithPath:game.runDirectory).appendingPathComponent(kind.rawValue)}
    private var filtered:[LocalContent]{files.filter{query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)}}
    var body:some View{VStack(spacing:0){
        HStack(spacing:12){SearchBox(prompt:"搜索"+kind.title,query:$query);Button{model.modal = .addons(game,kind)}label:{Label("下载"+kind.title,systemImage:"arrow.down.circle")}.buttonStyle(HarborButtonStyle(prominent:true));Button{model.importContent(game,kind:kind)}label:{Image(systemName:"plus")}.buttonStyle(HarborButtonStyle()).help("导入本地"+kind.title)}.padding(20)
        Table(filtered,selection:$selection){TableColumn(kind.title){file in HStack(spacing:12){ResourceArtwork(iconPath:model.resourceRecords[file.url.path]?.iconPath,fallback:kind.symbol).frame(width:32,height:32);VStack(alignment:.leading,spacing:4){Text(file.name.replacingOccurrences(of:".disabled",with:"")).font(.system(size:13,weight:.medium));Text(file.isDirectory ? "文件夹":file.url.pathExtension.uppercased()).font(.system(size:10)).foregroundStyle(.secondary)}}.padding(.vertical,8)}.width(min:250,ideal:500);TableColumn("大小"){file in Text(file.isDirectory ? "—":ByteCountFormatter.string(fromByteCount:file.bytes,countStyle:.file)).font(.system(size:11)).foregroundStyle(.secondary)}.width(95);TableColumn("来源"){file in ResourceSourceButton(model:model,path:file.url.path)}.width(42);TableColumn("可用"){file in Toggle(file.name,isOn:Binding(get:{file.active},set:{on in model.setContentActive(file.url,active:on,game:game)})).labelsHidden().toggleStyle(.switch).controlSize(.mini)}.width(55)}.tableStyle(.inset(alternatesRowBackgrounds:true)).scrollContentBackground(.hidden)
            .contextMenu(forSelectionType:String.self){ids in let urls=files.filter{ids.contains($0.id)}.map(\.url);if !urls.isEmpty{Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting(urls)};Button("移到废纸篓",role:.destructive){model.trashContent(urls,game:game)}}}
            .overlay{if filtered.isEmpty{ContentUnavailableView("暂无"+kind.title,systemImage:kind.symbol)}}
            .dropDestination(for:URL.self){urls,_ in model.copyContent(urls,game:game,kind:kind);return true}
        Divider().opacity(0.35);HStack{Text("\(files.count) 个"+kind.title).foregroundStyle(.secondary);Spacer();if !selection.isEmpty{Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting(files.filter{selection.contains($0.id)}.map(\.url))};Button("移到废纸篓",role:.destructive){model.trashContent(files.filter{selection.contains($0.id)}.map(\.url),game:game);selection=[]}};Button{refresh()}label:{Image(systemName:"arrow.clockwise")}}.font(.system(size:11)).buttonStyle(HarborBareButtonStyle()).padding(.horizontal,22).frame(height:43)
    }.task(id:kind){refresh()}.onReceive(model.contentChanged){_ in refresh()}}
    private func refresh(){let dir=directory;Task{files=await Task.detached{LocalContent.read(dir)}.value}}
}

private struct WorldWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var query=""
    @State private var worlds:[LocalContent]=[]
    private var filtered:[LocalContent]{worlds.filter{query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)}}
    var body:some View{VStack(spacing:0){HStack(spacing:12){SearchBox(prompt:"搜索存档",query:$query);Button{model.backup(game)}label:{Label("备份存档",systemImage:"externaldrive.badge.timemachine")}.buttonStyle(HarborButtonStyle(prominent:true));Button{model.importWorld(game)}label:{Image(systemName:"plus")}.buttonStyle(HarborButtonStyle()).help("导入存档文件夹");Button{model.open(NativePaths.root.appendingPathComponent("backups").path)}label:{Image(systemName:"clock.arrow.circlepath")}.buttonStyle(HarborButtonStyle()).help("查看备份")}.padding(20)
        ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:270),spacing:14)],spacing:14){ForEach(filtered){world in HStack(spacing:14){WorldThumbnail(url:world.url.appendingPathComponent("icon.png"));VStack(alignment:.leading,spacing:6){Text(world.name).font(.system(size:15,weight:.medium)).lineLimit(1);Text(world.modified,format:.dateTime.year().month().day().hour().minute()).font(.system(size:10)).foregroundStyle(.secondary)};Spacer();ResourceSourceButton(model:model,path:world.url.path);Button{model.modal = .worldEditor(game,world)}label:{Image(systemName:"square.and.pencil").frame(width:20,height:20)}.buttonStyle(HarborButtonStyle()).disabled(model.running.contains(game.id)).help("编辑存档");Menu{Button("编辑存档…"){model.modal = .worldEditor(game,world)}.disabled(model.running.contains(game.id));Button("打开存档目录"){model.open(world.url.path)};Button("备份此存档"){model.backupWorld(world,game:game)};Button("移到废纸篓",role:.destructive){model.trashContent([world.url],game:game)}}label:{Image(systemName:"ellipsis").frame(width:32,height:32).contentShape(Circle())}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:32).harborPrism(radius:9)}.padding(16).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:19))}}.padding(.horizontal,20).padding(.bottom,20)}.overlay{if worlds.isEmpty{ContentUnavailableView("暂无存档",systemImage:"globe.europe.africa")}}
    }.task{refresh()}.onReceive(model.contentChanged){_ in refresh()}}
    private func refresh(){let dir=URL(fileURLWithPath:game.runDirectory).appendingPathComponent("saves");Task{worlds=await Task.detached{LocalContent.read(dir).filter{$0.isDirectory && FileManager.default.fileExists(atPath:$0.url.appendingPathComponent("level.dat").path)}}.value}}
}
private struct WorldThumbnail:View {
    let url:URL
    var body:some View{Group{if let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFill()}else{Image(systemName:"globe.europe.africa").font(.system(size:30,weight:.ultraLight)).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.primary.opacity(0.04))}}.frame(width:60,height:60).clipShape(RoundedRectangle(cornerRadius:13))}
}

private struct ScreenshotWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var files:[LocalContent]=[]
    var body:some View{ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:210),spacing:15)],spacing:18){ForEach(files){file in Button{NSWorkspace.shared.open(file.url)}label:{VStack(alignment:.leading,spacing:8){AsyncThumbnail(url:file.url).frame(height:150).clipShape(RoundedRectangle(cornerRadius:15));Text(file.name).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)}}.buttonStyle(HarborBareButtonStyle()).contextMenu{Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting([file.url])};Button("移到废纸篓",role:.destructive){model.trashContent([file.url],game:game)}}}}.padding(22)}.overlay{if files.isEmpty{ContentUnavailableView("暂无截图",systemImage:"photo.on.rectangle")}}.task{refresh()}.onReceive(model.contentChanged){_ in refresh()}}
    private func refresh(){let dir=URL(fileURLWithPath:game.runDirectory).appendingPathComponent("screenshots");Task{files=await Task.detached{LocalContent.read(dir).filter{["png","jpg","jpeg"].contains($0.url.pathExtension.lowercased())}.sorted{$0.modified>$1.modified}}.value}}
}
struct AsyncThumbnail:View {
    let url:URL
    @State private var image:NSImage?
    var body:some View{Group{if let image{Image(nsImage:image).resizable().scaledToFill()}else{Color.primary.opacity(0.035)}}.clipped().task(id:url){image=await Task.detached{guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:640,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{return nil as NSImage?};return NSImage(cgImage:cg,size:.zero)}.value}}
}

private struct LogWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var files:[LocalContent]=[]
    @State private var chosen=""
    @State private var text=""
    var body:some View{VStack(spacing:0){HStack{Picker("日志",selection:$chosen){ForEach(files){file in Text(file.name).tag(file.url.path)}}.labelsHidden();Spacer();Button("复制"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}.buttonStyle(HarborButtonStyle());Button{load()}label:{Image(systemName:"arrow.clockwise")}.buttonStyle(HarborButtonStyle())}.padding(20);ScrollView{Text(text.isEmpty ? "暂无日志":text).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(22)}.background(Color.primary.opacity(0.025))}.task{let dir=URL(fileURLWithPath:game.runDirectory).appendingPathComponent("logs");files=await Task.detached{LocalContent.read(dir).filter{$0.url.pathExtension=="log" || $0.url.pathExtension=="txt"}.sorted{$0.modified>$1.modified}}.value;chosen=files.first?.url.path ?? "";load()}.onChange(of:chosen){_,_ in load()}}
    private func load(){let path=chosen;Task{text=await Task.detached{guard !path.isEmpty,let h=try? FileHandle(forReadingFrom:URL(fileURLWithPath:path)) else{return ""};defer{try? h.close()};let length=(try? h.seekToEnd()) ?? 0;if length>500_000{try? h.seek(toOffset:length-500_000)}else{try? h.seek(toOffset:0)};return String(decoding:(try? h.readToEnd()) ?? Data(),as:UTF8.self)}.value}}
}

private struct InstanceSettingsWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    private var options:Binding<InstanceOptions>{Binding(get:{model.preferences.instanceOptions[game.id] ?? InstanceOptions()},set:{model.preferences.instanceOptions[game.id]=$0})}
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:24){
        section("实例"){HStack(spacing:16){WorldIcon(game:model.artworkGame(game)).frame(width:48,height:48);Button("更换图标…"){model.chooseInstanceIcon(game)};Button("恢复原图标"){model.resetInstanceIcon(game)}.disabled(model.preferences.instanceIcons[game.id]==nil);Spacer()};HStack{Text("显示名称");Spacer();TextField(game.id,text:Binding(get:{model.preferences.nickname[game.id] ?? ""},set:{model.preferences.nickname[game.id]=$0})).textFieldStyle(.roundedBorder).frame(width:300)};HStack{Text("目录");Spacer();Text(game.runDirectory).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)};HStack{Button("校验与修复"){model.repair(game)};Button("导出整合包…"){model.exportPack(game)};Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:game.directory)])}}} 
        section("空间"){InstanceSpaceView(game:game)}
        section("运行"){Picker("最大内存",selection:options.memory){Text("继承原实例 / 全局设置").tag(0);ForEach([2048,3072,4096,5120,6144],id:\.self){Text("\($0/1024) GB").tag($0)}};HStack{Text("Java");Spacer();TextField("自动选择兼容版本",text:options.javaPath).textFieldStyle(.roundedBorder).font(.system(size:11,design:.monospaced)).frame(width:370);Button("选择…"){let p=NSOpenPanel();p.prompt="选择 Java";if p.runModal() == .OK,let url=p.url{var value=options.wrappedValue;value.javaPath=url.path;options.wrappedValue=value}}};Toggle("全屏",isOn:options.fullscreen);HStack{Text("窗口大小");Spacer();TextField("宽",value:options.width,format:.number.grouping(.never)).frame(width:78);Text("×").foregroundStyle(.secondary);TextField("高",value:options.height,format:.number.grouping(.never)).frame(width:78)}.textFieldStyle(.roundedBorder);DisclosureGroup("高级"){TextField("附加 JVM 参数",text:options.jvmArguments).textFieldStyle(.roundedBorder).font(.system(size:11,design:.monospaced)).padding(.top,10)}}
    }.padding(24)}.buttonStyle(HarborButtonStyle())}
    private func section<C:View>(_ title:String,@ViewBuilder content:()->C)->some View{VStack(alignment:.leading,spacing:17){Text(title).font(.system(size:17,weight:.semibold));content().font(.system(size:12))}.padding(23).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:21))}
}
