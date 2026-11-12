import SwiftUI
import AppKit

struct CollectionDisplaySettings:Codable,Equatable {
    var icon=true,loader=true,modVersion=true,gameVersion=false,collectedAt=false,summary=false,authors=false
    var isNameOnly:Bool{!icon && !loader && !modVersion && !gameVersion && !collectedAt && !summary && !authors}
}
struct CollectionDisplayOptions:View {
    @Binding var settings:CollectionDisplaySettings
    var body:some View{Group{
        Toggle("模组图标",isOn:$settings.icon);Toggle("加载器",isOn:$settings.loader);Toggle("模组版本",isOn:$settings.modVersion);Toggle("Minecraft 版本",isOn:$settings.gameVersion);Toggle("收藏时间",isOn:$settings.collectedAt);Toggle("模组简介",isOn:$settings.summary);Toggle("作者",isOn:$settings.authors)
        Divider();Button("仅显示模组名称"){settings=CollectionDisplaySettings(icon:false,loader:false,modVersion:false,gameVersion:false,collectedAt:false,summary:false,authors:false)};Button("恢复默认信息量"){settings=CollectionDisplaySettings()}
    }}
}
struct CollectionDisplayPanel:View {
    @Binding var settings:CollectionDisplaySettings
    var body:some View{VStack(alignment:.leading,spacing:14){Text("模组夹信息显示").font(.system(size:17,weight:.semibold));Text("模组名称始终显示。其他信息可逐项关闭；完整资料仍可从详情查看。旧收藏未记录的资料不会凭空补造。").font(.system(size:11)).harborSecondaryText();CollectionDisplayOptions(settings:$settings)}.padding(24).frame(maxWidth:.infinity,alignment:.leading)}
}
struct CollectionEntryRow:View {
    let entry:ModCollectionEntry;let settings:CollectionDisplaySettings;let selected:Bool;let toggle:()->Void;let details:()->Void
    private var metadata:String{var values:[String]=[];if settings.loader{values.append((entry.loaders?.isEmpty==false ? entry.loaders!.map{$0.capitalized}.joined(separator:" / "):"未记录加载器"))};if settings.modVersion{values.append(entry.modVersion.flatMap{$0.isEmpty ? nil:$0} ?? "未记录模组版本")};if settings.gameVersion{values.append("MC "+(entry.gameVersions?.joined(separator:" / ") ?? "未记录版本"))};return values.joined(separator:" · ")}
    var body:some View{HStack(spacing:0){Button(action:toggle){HStack(spacing:14){Image(systemName:selected ? "checkmark.circle.fill":"circle").font(.system(size:17));if settings.icon{CollectionArtwork(entry:entry).frame(width:48,height:48).clipShape(RoundedRectangle(cornerRadius:10))};VStack(alignment:.leading,spacing:5){ModProjectName(project:entry.project ?? AddonProject(projectId:entry.id,title:entry.title,description:"",author:"",iconUrl:nil,downloads:0,pageUrl:nil)).font(.system(size:14,weight:.medium)).lineLimit(2);if !metadata.isEmpty{Text(metadata).font(.system(size:11)).harborSecondaryText().lineLimit(2)};if settings.authors,let author=entry.authors ?? entry.project?.author,!author.isEmpty{Text(author).font(.system(size:11)).harborSecondaryText()};if settings.collectedAt{Text(entry.collectedAt.map{"收藏于 "+$0.formatted(date:.abbreviated,time:.shortened)} ?? "旧收藏未记录时间").font(.system(size:10)).harborSecondaryText()};if settings.summary,let text=entry.summary ?? entry.project?.description,!text.isEmpty{ModSummaryText(text:text,enabled:true,compact:true)}};Spacer(minLength:0)}.padding(14).frame(maxWidth:.infinity,minHeight:settings.isNameOnly ? 48:78,alignment:.leading).contentShape(Rectangle())}.buttonStyle(HarborBareButtonStyle());Button(action:details){Image(systemName:"info.circle").frame(width:38,height:38).contentShape(Circle())}.buttonStyle(HarborBareButtonStyle()).help("查看模组详情").padding(.trailing,12)}.background(Color.primary.opacity(selected ? 0.09:0.035),in:RoundedRectangle(cornerRadius:16))}
}
struct CollectionEntryDetails:View {
    let entry:ModCollectionEntry;let translate:Bool
    @Environment(\.dismiss) private var dismiss
    var body:some View{VStack(spacing:18){HStack(spacing:14){CollectionArtwork(entry:entry).frame(width:58,height:58);Text(entry.title).font(.system(size:23,weight:.semibold)).lineLimit(2);Spacer();Button("完成"){dismiss()}.buttonStyle(HarborButtonStyle())};ScrollView{VStack(alignment:.leading,spacing:16){
        info("模组名称",entry.title);info("加载器",entry.loaders?.map{$0.capitalized}.joined(separator:" / ") ?? "旧收藏未记录 / 未指定版本")
        info("模组版本",entry.modVersion.flatMap{$0.isEmpty ? nil:$0} ?? "未记录 / 未固定版本")
        info(entry.file==nil ? "Minecraft 版本":"来源实例 Minecraft 版本",entry.gameVersions?.joined(separator:" / ") ?? "未记录 / 未指定版本")
        info("收藏时间",entry.collectedAt.map{$0.formatted(date:.long,time:.shortened)} ?? "旧收藏未记录时间")
        info("作者",entry.authors ?? entry.project?.author ?? "未记录")
        if let summary=entry.summary ?? entry.project?.description,!summary.isEmpty{Text("模组简介").font(.system(size:12,weight:.semibold));ModSummaryText(text:summary,enabled:translate,compact:false)}else{info("模组简介","本地文件或旧收藏未提供简介")}
        if let project=entry.project{Button("查看原项目"){if let address=project.pageUrl,let url=URL(string:address),url.scheme=="https"{NSWorkspace.shared.open(url)}}.buttonStyle(HarborButtonStyle()).disabled(project.pageUrl==nil)}
        if let file=entry.file{Button("查看收藏文件"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:file)])}.buttonStyle(HarborButtonStyle())}
    }.frame(maxWidth:.infinity,alignment:.leading)}}.padding(26).frame(width:580,height:540)}
    private func info(_ title:String,_ value:String)->some View{VStack(alignment:.leading,spacing:5){Text(title).font(.system(size:11,weight:.semibold)).harborSecondaryText();Text(value).font(.system(size:13)).textSelection(.enabled)}}
}
struct CollectInstanceModsMenu:View {
    @ObservedObject var model:LauncherModel;let game:GameInstance
    var body:some View{Menu("收藏全部"){ForEach(ModCollectionStore.shared.folders){folder in Button(folder.name){model.collectInstanceMods(game,folder:folder.id)}};Button("新建模组夹…"){do{if let id=try ModCollectionStore.shared.promptCreate(){model.collectInstanceMods(game,folder:id)}}catch{model.errorMessage=error.localizedDescription}}}.buttonStyle(HarborButtonStyle()).help("复制此实例的全部模组到模组夹，重复项自动跳过；不改动原实例")}
}

/// The circular trigger and every popover action use the whole visible surface as their hit region.
struct InstanceActionsButton:View {
    @ObservedObject var model:LauncherModel;let game:GameInstance
    @State private var presented=false
    var body:some View{Button{presented.toggle()}label:{Image(systemName:"ellipsis").font(.system(size:17,weight:.semibold)).frame(width:42,height:42).background(Color.primary.opacity(0.07),in:Circle()).contentShape(Circle())}.buttonStyle(HarborBareButtonStyle()).help("更多实例操作").popover(isPresented:$presented,arrowEdge:.bottom){VStack(alignment:.leading,spacing:4){
        action("打开实例目录"){model.open(game.runDirectory)}
        action("校验与修复"){model.repair(game)}
        action("备份存档"){model.backup(game)}
        action("导出整合包…"){model.exportPack(game)}
        CollectInstanceModsMenu(model:model,game:game).frame(maxWidth:.infinity,minHeight:34)
        action("创建实例快捷方式…"){model.createInstanceShortcut(game)}
        Divider();action(model.preferences.favorites.contains(game.id) ? "取消收藏":"收藏"){model.favorite(game)}
        Divider();Button(role:.destructive){presented=false;model.deleteInstance(game)}label:{Text("删除实例…").frame(maxWidth:.infinity,minHeight:34,alignment:.leading).padding(.horizontal,10).contentShape(Rectangle())}.buttonStyle(HarborBareButtonStyle()).disabled(model.running.contains(game.id))
    }.padding(10).frame(width:240)}}
    private func action(_ name:String,_ operation:@escaping()->Void)->some View{Button{presented=false;operation()}label:{Text(name).font(.system(size:12)).frame(maxWidth:.infinity,minHeight:34,alignment:.leading).padding(.horizontal,10).contentShape(Rectangle())}.buttonStyle(HarborBareButtonStyle())}
}
