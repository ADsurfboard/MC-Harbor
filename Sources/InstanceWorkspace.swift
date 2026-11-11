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
                VStack(alignment:.leading,spacing:5){Text(model.displayName(game)).font(.system(size:27,weight:.semibold)).lineLimit(1);Text(game.version+" · "+game.loader).font(.system(size:11)).harborSecondaryText()}
                Spacer()
                Button{model.launch(game)}label:{Label(model.running.contains(game.id) ? "运行中":"启动",systemImage:"play.fill")}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(model.running.contains(game.id))
                if model.running.contains(game.id){Button{model.stopGame(game)}label:{Label("关闭游戏",systemImage:"stop.fill")}.buttonStyle(HarborButtonStyle())}
                Menu{Button("打开实例目录"){model.open(game.runDirectory)};Button("校验与修复"){model.repair(game)};Button("备份存档"){model.backup(game)};Button("导出整合包…"){model.exportPack(game)};Button("创建实例快捷方式…"){model.createInstanceShortcut(game)};Divider();Button(model.preferences.favorites.contains(game.id) ? "取消收藏":"收藏"){model.favorite(game)};Divider();Button("删除实例…",role:.destructive){model.deleteInstance(game)}.disabled(model.running.contains(game.id))}label:{HarborSymbol(systemName:"ellipsis").frame(width:34,height:34).contentShape(Circle())}.menuStyle(.borderlessButton).frame(width:34)
                Button{model.inspectedGame=nil}label:{HarborSymbol(systemName:"xmark").frame(width:16,height:18)}.buttonStyle(HarborButtonStyle()).help("关闭实例管理")
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

        .clipShape(RoundedRectangle(cornerRadius:28))
        .onExitCommand{model.inspectedGame=nil}
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("HarborOpenLocalization"))){_ in tab = .localization}
        .task(id:game.id){tab = game.loader == "Minecraft" ? .worlds:.mods;model.loadMods(game);model.loadResourceIndex(game)}
    }
}

private struct ModWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var query=""
    @State private var filter="all"
    @State private var selection:Set<String>=[]
    @State private var translate=true
    private var mods:[ModFile]{model.modMetadata[game.id] ?? NativeScanner.mods(game)}
    private var filtered:[ModFile]{mods.filter{(filter=="all" || $0.enabled == (filter=="enabled")) && (query.isEmpty || ($0.name+" "+$0.version+" "+$0.authors+" "+$0.modID+" "+ModDiscovery.chineseName($0)+" "+$0.path.lastPathComponent).localizedCaseInsensitiveContains(query))}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}}
    private var selected:[ModFile]{mods.filter{selection.contains($0.id)}}
    var body:some View{VStack(spacing:0){
        HStack(spacing:12){SearchBox(prompt:"搜索中英文名称、作者或 ID",query:$query);Toggle("简介汉化",isOn:$translate).toggleStyle(.switch).controlSize(.mini);Picker("状态",selection:$filter){Text("全部").tag("all");Text("已启用").tag("enabled");Text("已停用").tag("disabled")}.labelsHidden().frame(width:100);Button{model.modal = .addons(game,.mods)}label:{Label("下载",systemImage:"arrow.down.circle")}.buttonStyle(HarborButtonStyle(prominent:true));Button{model.importContent(game,kind:.mods)}label:{Image(systemName:"plus").frame(width:22,height:22)}.buttonStyle(HarborButtonStyle())}.padding(20)
        ScrollView{LazyVStack(spacing:10){ForEach(filtered){mod in row(mod)}}.padding(.horizontal,20).padding(.bottom,16)}.frame(maxHeight:.infinity).overlay{if filtered.isEmpty{HarborEmptyView("没有匹配的模组",systemImage:"puzzlepiece.extension")}}.harborDropFiles{model.copyContent($0,game:game,kind:.mods)}
        if translate,let mod=selected.first{ScrollView{InstalledModTranslation(model:model,mod:mod).frame(maxWidth:.infinity,alignment:.leading).padding(16)}.frame(maxHeight:92)}
        Divider().opacity(0.3)
        HStack(spacing:12){Button(selection.count==filtered.count && !filtered.isEmpty ? "取消全选":"全选"){selection=selection.count==filtered.count ? []:Set(filtered.map(\.id))};Text("已选 \(selection.count) / \(mods.count)").font(.system(size:11)).harborSecondaryText();Spacer();if !selection.isEmpty{Button("语言汉化"){model.localizationPaths=Set(selected.map{$0.path.path});NotificationCenter.default.post(name:Notification.Name("HarborOpenLocalization"),object:nil)};Menu("收藏到模组夹"){ForEach(ModCollectionStore.shared.folders){folder in Button(folder.name){model.collectMods(selected,folder:folder.id)}};Button("新建模组夹…"){do{if let id=try ModCollectionStore.shared.promptCreate(){model.collectMods(selected,folder:id)}}catch{model.errorMessage=error.localizedDescription}}};Button("启用"){model.setMods(selected,enabled:true,game:game)};Button("停用"){model.setMods(selected,enabled:false,game:game)};Button("移到废纸篓",role:.destructive){model.trashContent(selected.map(\.path),game:game);selection=[]}};Button{model.loadMods(game,force:true)}label:{Image(systemName:"arrow.clockwise").frame(width:22,height:22)}}.buttonStyle(HarborButtonStyle()).padding(.horizontal,20).frame(height:56)
    }}
    private func row(_ mod:ModFile)->some View{HStack(spacing:14){
        Toggle("选择 "+mod.name,isOn:Binding(get:{selection.contains(mod.id)},set:{if $0{selection.insert(mod.id)}else{selection.remove(mod.id)}})).labelsHidden().toggleStyle(.checkbox)
        ResourceArtwork(iconPath:model.resourceRecords[mod.path.path]?.iconPath ?? mod.iconPath,fallback:"puzzlepiece.extension.fill").frame(width:42,height:42).clipped().opacity(mod.enabled ? 1:0.45)
        VStack(alignment:.leading,spacing:6){Text(translate && !ModDiscovery.chineseName(mod).isEmpty ? ModDiscovery.chineseName(mod)+" · "+mod.name:mod.name).font(.system(size:13,weight:.semibold)).lineLimit(1);Text([mod.modID,mod.version,mod.authors].filter{!$0.isEmpty}.joined(separator:" · ")).font(.system(size:11)).harborSecondaryText().lineLimit(1);Text(mod.path.lastPathComponent).font(.system(size:10,design:.monospaced)).harborSecondaryText().lineLimit(1)}.frame(maxWidth:.infinity,alignment:.leading).clipped()
        Text(ByteCountFormatter.string(fromByteCount:mod.size,countStyle:.file)).font(.system(size:10)).harborSecondaryText().frame(width:66,alignment:.trailing)
        ResourceSourceButton(model:model,path:mod.path.path)
        Toggle("启用 "+mod.name,isOn:Binding(get:{mod.enabled},set:{model.setMods([mod],enabled:$0,game:game)})).labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.running.contains(game.id)).frame(width:38)
    }.padding(.horizontal,16).frame(height:92).background(selection.contains(mod.id) ? model.controlTint.opacity(0.1):Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(selection.contains(mod.id) ? model.controlTint.opacity(0.5):Color.clear,lineWidth:0.7)).contentShape(RoundedRectangle(cornerRadius:16)).onTapGesture{if selection.contains(mod.id){selection.remove(mod.id)}else{selection.insert(mod.id)}}.contextMenu{Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting([mod.path])};Button("移到废纸篓",role:.destructive){model.trashContent([mod.path],game:game)}}}
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
    let game:GameInstance;let kind:ContentKind
    @State private var query=""
    @State private var files:[LocalContent]=[]
    @State private var selection:Set<String>=[]
    private var directory:URL{URL(fileURLWithPath:game.runDirectory).appendingPathComponent(kind.rawValue)}
    private var filtered:[LocalContent]{files.filter{query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)}}
    private var selected:[LocalContent]{files.filter{selection.contains($0.id)}}
    var body:some View{VStack(spacing:0){
        HStack{SearchBox(prompt:"搜索"+kind.title,query:$query);Button{model.modal = .addons(game,kind)}label:{Label("下载"+kind.title,systemImage:"arrow.down.circle")}.buttonStyle(HarborButtonStyle(prominent:true));Button{model.importContent(game,kind:kind)}label:{Image(systemName:"plus").frame(width:22,height:22)}.buttonStyle(HarborButtonStyle())}.padding(20)
        ScrollView{LazyVStack(spacing:10){ForEach(filtered){file in HStack(spacing:14){Toggle("选择 "+file.name,isOn:Binding(get:{selection.contains(file.id)},set:{if $0{selection.insert(file.id)}else{selection.remove(file.id)}})).labelsHidden().toggleStyle(.checkbox);ResourceArtwork(iconPath:model.resourceRecords[file.url.path]?.iconPath,fallback:kind.symbol).frame(width:44,height:44).clipped();VStack(alignment:.leading,spacing:7){Text(file.name.replacingOccurrences(of:".disabled",with:"")).font(.system(size:13,weight:.medium)).lineLimit(2);Text(file.isDirectory ? "文件夹":ByteCountFormatter.string(fromByteCount:file.bytes,countStyle:.file)).font(.system(size:11)).harborSecondaryText()}.frame(maxWidth:.infinity,alignment:.leading).clipped();ResourceSourceButton(model:model,path:file.url.path);Toggle("启用 "+file.name,isOn:Binding(get:{file.active},set:{model.setContentActive(file.url,active:$0,game:game)})).labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.running.contains(game.id))}.padding(.horizontal,16).frame(height:88).background(selection.contains(file.id) ? model.controlTint.opacity(0.1):Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:16)).contentShape(RoundedRectangle(cornerRadius:16)).onTapGesture{if selection.contains(file.id){selection.remove(file.id)}else{selection.insert(file.id)}}}}.padding(.horizontal,20).padding(.bottom,16)}.frame(maxHeight:.infinity).overlay{if filtered.isEmpty{HarborEmptyView("暂无"+kind.title,systemImage:kind.symbol)}}.harborDropFiles{model.copyContent($0,game:game,kind:kind)}
        Divider().opacity(0.3);HStack(spacing:12){Button(selection.count==filtered.count && !filtered.isEmpty ? "取消全选":"全选"){selection=selection.count==filtered.count ? []:Set(filtered.map(\.id))};Text("已选 \(selection.count) / \(files.count)").font(.system(size:11)).harborSecondaryText();Spacer();if !selection.isEmpty{Button("启用"){model.setContentsActive(selected,active:true,game:game)};Button("停用"){model.setContentsActive(selected,active:false,game:game)};Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.url))};Button("移到废纸篓",role:.destructive){model.trashContent(selected.map(\.url),game:game);selection=[]}};Button{refresh()}label:{Image(systemName:"arrow.clockwise").frame(width:22,height:22)}}.buttonStyle(HarborButtonStyle()).padding(.horizontal,20).frame(height:56)
    }.task(id:kind){refresh()}.onReceive(model.contentChanged){_ in refresh()}}
    private func refresh(){let dir=directory;Task{files=await Task.detached{LocalContent.read(dir)}.value;selection.formIntersection(Set(files.map(\.id)))}}
}

private struct WorldWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var query=""
    @State private var worlds:[LocalContent]=[]
    private var filtered:[LocalContent]{worlds.filter{query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)}}
    var body:some View{VStack(spacing:0){HStack(spacing:12){SearchBox(prompt:"搜索存档",query:$query);Button{model.backup(game)}label:{Label("备份存档",systemImage:"externaldrive.badge.timemachine")}.buttonStyle(HarborButtonStyle(prominent:true));Button{model.importWorld(game)}label:{HarborSymbol(systemName:"plus")}.buttonStyle(HarborButtonStyle()).help("导入存档文件夹");Button{model.open(NativePaths.root.appendingPathComponent("backups").path)}label:{HarborSymbol(systemName:"clock.arrow.circlepath")}.buttonStyle(HarborButtonStyle()).help("查看备份")}.padding(20)
        ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:270),spacing:14)],spacing:14){ForEach(filtered){world in HStack(spacing:14){WorldThumbnail(url:world.url.appendingPathComponent("icon.png"));VStack(alignment:.leading,spacing:6){Text(world.name).font(.system(size:15,weight:.medium)).lineLimit(1);Text(world.modified,format:.dateTime.year().month().day().hour().minute()).font(.system(size:10)).harborSecondaryText()};Spacer();ResourceSourceButton(model:model,path:world.url.path);Button{model.modal = .worldEditor(game,world)}label:{HarborSymbol(systemName:"square.and.pencil").frame(width:20,height:20)}.buttonStyle(HarborButtonStyle()).disabled(model.running.contains(game.id)).help("编辑存档");Menu{Button("编辑存档…"){model.modal = .worldEditor(game,world)}.disabled(model.running.contains(game.id));Button("打开存档目录"){model.open(world.url.path)};Button("备份此存档"){model.backupWorld(world,game:game)};Button("移到废纸篓",role:.destructive){model.trashContent([world.url],game:game)}}label:{HarborSymbol(systemName:"ellipsis").frame(width:32,height:32).contentShape(Circle())}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:32)}.padding(16).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:19))}}.padding(.horizontal,20).padding(.bottom,20)}.overlay{if worlds.isEmpty{HarborEmptyView("暂无存档",systemImage:"globe.europe.africa")}}
    }.task{refresh()}.onReceive(model.contentChanged){_ in refresh()}}
    private func refresh(){let dir=URL(fileURLWithPath:game.runDirectory).appendingPathComponent("saves");Task{worlds=await Task.detached{LocalContent.read(dir).filter{$0.isDirectory && FileManager.default.fileExists(atPath:$0.url.appendingPathComponent("level.dat").path)}}.value}}
}
private struct WorldThumbnail:View {
    let url:URL
    var body:some View{Group{if let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFill()}else{HarborSymbol(systemName:"globe.europe.africa").font(.system(size:30,weight:.ultraLight)).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.primary.opacity(0.04))}}.frame(width:60,height:60).clipShape(RoundedRectangle(cornerRadius:13))}
}

private struct ScreenshotWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var files:[LocalContent]=[]
    var body:some View{ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:210),spacing:15)],spacing:18){ForEach(files){file in Button{NSWorkspace.shared.open(file.url)}label:{VStack(alignment:.leading,spacing:8){AsyncThumbnail(url:file.url).frame(height:150).clipShape(RoundedRectangle(cornerRadius:15));Text(file.name).font(.system(size:10)).harborSecondaryText().lineLimit(1)}}.buttonStyle(HarborBareButtonStyle()).contextMenu{Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting([file.url])};Button("移到废纸篓",role:.destructive){model.trashContent([file.url],game:game)}}}}.padding(22)}.overlay{if files.isEmpty{HarborEmptyView("暂无截图",systemImage:"photo.on.rectangle")}}.task{refresh()}.onReceive(model.contentChanged){_ in refresh()}}
    private func refresh(){let dir=URL(fileURLWithPath:game.runDirectory).appendingPathComponent("screenshots");Task{files=await Task.detached{LocalContent.read(dir).filter{["png","jpg","jpeg"].contains($0.url.pathExtension.lowercased())}.sorted{$0.modified>$1.modified}}.value}}
}
struct AsyncThumbnail:View {
    let url:URL
    @State private var image:NSImage?
    var body:some View{Group{if let image{Image(nsImage:image).resizable().scaledToFill()}else{Color.primary.opacity(0.035)}}.clipped().task(id:url){let bitmap=await Task.detached{HarborImageCache.decodeThumbnail(url.path,pixels:640)}.value;if !Task.isCancelled{image=bitmap.map{NSImage(cgImage:$0.image,size:.zero)}}}}
}

private struct LogWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var files:[LocalContent]=[]
    @State private var chosen=""
    @State private var text=""
    var body:some View{VStack(spacing:0){HStack{Picker("日志",selection:$chosen){ForEach(files){file in Text(file.name).tag(file.url.path)}}.labelsHidden();Spacer();Button("复制"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}.buttonStyle(HarborButtonStyle());Button{load()}label:{HarborSymbol(systemName:"arrow.clockwise")}.buttonStyle(HarborButtonStyle())}.padding(20);ScrollView{Text(text.isEmpty ? "暂无日志":text).font(.system(size:11,design:.monospaced)).harborSecondaryText().textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(22)}.background(Color.primary.opacity(0.025))}.task{let dir=URL(fileURLWithPath:game.runDirectory).appendingPathComponent("logs");files=await Task.detached{LocalContent.read(dir).filter{$0.url.pathExtension=="log" || $0.url.pathExtension=="txt"}.sorted{$0.modified>$1.modified}}.value;chosen=files.first?.url.path ?? "";load()}.harborOnChange(of:chosen){_,_ in load()}}
    private func load(){let path=chosen;Task{text=await Task.detached{guard !path.isEmpty,let h=try? FileHandle(forReadingFrom:URL(fileURLWithPath:path)) else{return ""};defer{try? h.close()};let length=(try? h.seekToEnd()) ?? 0;if length>500_000{try? h.seek(toOffset:length-500_000)}else{try? h.seek(toOffset:0)};return String(decoding:(try? h.readToEnd()) ?? Data(),as:UTF8.self)}.value}}
}

private struct InstanceSettingsWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    private var options:Binding<InstanceOptions>{Binding(get:{model.preferences.instanceOptions[game.id] ?? InstanceOptions()},set:{model.preferences.instanceOptions[game.id]=$0})}
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:24){
        section("实例"){HStack(spacing:16){WorldIcon(game:model.artworkGame(game)).frame(width:48,height:48);Button("更换图标…"){model.chooseInstanceIcon(game)};Button("恢复原图标"){model.resetInstanceIcon(game)}.disabled(model.preferences.instanceIcons[game.id]==nil);Spacer()};HStack{Text("显示名称");Spacer();TextField(game.id,text:Binding(get:{model.preferences.nickname[game.id] ?? ""},set:{model.preferences.nickname[game.id]=$0})).textFieldStyle(.roundedBorder).frame(width:300)};HStack{Text("目录");Spacer();Text(game.runDirectory).font(.system(size:10,design:.monospaced)).harborSecondaryText().textSelection(.enabled).lineLimit(2)};HStack{Button("校验与修复"){model.repair(game)};Button("导出整合包…"){model.exportPack(game)};Button("创建实例快捷方式…"){model.createInstanceShortcut(game)};Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:game.directory)])}}}
        section("空间"){InstanceSpaceView(game:game)}
        section("运行"){Picker("最大内存",selection:options.memory){Text("继承原实例 / 全局设置").tag(0);ForEach([2048,3072,4096,5120,6144],id:\.self){Text("\($0/1024) GB").tag($0)}};HStack{Text("Java");Spacer();TextField("自动选择兼容版本",text:options.javaPath).textFieldStyle(.roundedBorder).font(.system(size:11,design:.monospaced)).frame(width:370);Button("选择…"){let p=NSOpenPanel();p.prompt="选择 Java";if p.runModal() == .OK,let url=p.url{var value=options.wrappedValue;value.javaPath=url.path;options.wrappedValue=value}}};Toggle("全屏",isOn:options.fullscreen);HStack{Text("窗口大小");Spacer();TextField("宽",value:options.width,format:.number.grouping(.never)).frame(width:78);Text("×").harborSecondaryText();TextField("高",value:options.height,format:.number.grouping(.never)).frame(width:78)}.textFieldStyle(.roundedBorder);DisclosureGroup("高级"){TextField("附加 JVM 参数",text:options.jvmArguments).textFieldStyle(.roundedBorder).font(.system(size:11,design:.monospaced)).padding(.top,10)}}
    }.padding(24)}.buttonStyle(HarborButtonStyle())}
    private func section<C:View>(_ title:String,@ViewBuilder content:()->C)->some View{VStack(alignment:.leading,spacing:17){Text(title).font(.system(size:17,weight:.semibold));content().font(.system(size:12))}.padding(23).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:21))}
}
