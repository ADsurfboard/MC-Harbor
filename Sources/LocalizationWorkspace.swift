import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LanguageResource:Decodable,Identifiable,Sendable {
    let id:String;let path:String;let name:String;let kind:String;let enabled:Bool;let iconPath:String?;let languageFiles:Int;let languages:[String];let entries:Int;let translated:Int
}
struct LanguageProject:Decodable,Sendable {let project:String;let name:String;let version:String;let packFormat:Double;let sources:[LanguageResource];let warnings:[String]}
struct LanguageEntry:Decodable,Identifiable,Sendable {let id:String;let namespace:String;let key:String;let source:String;var translation:String;let origin:String;let issue:String}
private struct LanguageEntries:Decodable{let entries:[LanguageEntry]}

/// A native editor over a private workspace, with persistent drafts and read-only original assets.
struct LocalizationWorkspace:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    @State private var project:LanguageProject?
    @State private var selected:Set<String>=[]
    @State private var current=""
    @State private var rows:[LanguageEntry]=[]
    @State private var chosen:String?
    @State private var query=""
    @State private var filter="all"
    @State private var packName=""
    @State private var packFormat=""
    @State private var busy=false
    @State private var status=""
    @State private var failure=""
    @State private var edits:[String:[String:String]]=[:]
    @State private var operation:Task<Void,Never>?
    @State private var draftWrite:DispatchWorkItem?
    private var row:LanguageEntry?{rows.first{$0.id==chosen}}
    private var hasTextSelection:Bool{project?.sources.contains{selected.contains($0.id) && ["ftbquests","datapacks"].contains($0.kind)} ?? false}
    private var editCount:Int{edits.values.reduce(0){$0+$1.count}}
    private func translation(_ row:LanguageEntry)->String{edits[current]?[row.id] ?? row.translation}
    private var filtered:[LanguageEntry]{rows.filter{row in (filter=="all" || (filter=="pending" ? translation(row).isEmpty:!row.issue.isEmpty)) && (query.isEmpty || (row.key+" "+row.source+" "+translation(row)).localizedCaseInsensitiveContains(query))}}
    var body:some View {
        VStack(spacing:0) {
            toolbar
            Divider().opacity(0.25)
            HStack(spacing:0) {
                resourceList.frame(width:232)
                Divider().opacity(0.25)
                VStack(spacing:0) {
                    HStack(spacing:10){SearchBox(prompt:"搜索语言键、原文或译文",query:$query);Picker("条目",selection:$filter){Text("全部").tag("all");Text("待翻译").tag("pending");Text("格式问题").tag("issues")}.labelsHidden().frame(width:100)}.padding(16)
                    Table(filtered,selection:$chosen) {
                        TableColumn("语言键"){entry in Text(entry.key).font(.system(size:10,design:.monospaced)).lineLimit(1)}.width(min:100,ideal:160)
                        TableColumn("原文"){entry in Text(entry.source).font(.system(size:11)).lineLimit(2)}.width(min:120,ideal:240)
                        TableColumn("中文"){entry in Text(translation(entry).isEmpty ? "待翻译":translation(entry)).font(.system(size:11)).foregroundStyle(translation(entry).isEmpty ? Color.secondary:Color.primary).lineLimit(2)}.width(min:120,ideal:250)
                    }.tableStyle(.inset(alternatesRowBackgrounds:true)).scrollContentBackground(.hidden)
                    .overlay{if rows.isEmpty && !busy{ContentUnavailableView(project==nil ? "读取实例资源中的语言":"选择包含语言条目的实例资源",systemImage:"character.book.closed")}}
                    if let row{editor(row)}
                }
            }
            Divider().opacity(0.25)
            HStack(spacing:12){if busy{ProgressView().controlSize(.mini)};Text(failure.isEmpty ? status:failure).font(.system(size:11)).foregroundStyle(failure.isEmpty ? Color.secondary:Color.orange).lineLimit(2).textSelection(.enabled).help(project?.warnings.joined(separator:"\n") ?? "");Spacer();if editCount>0{Text("\(editCount) 条草稿").font(.system(size:10)).foregroundStyle(.secondary);Button("保存译文"){run{try await commitEdits()}}.buttonStyle(HarborButtonStyle(prominent:true)).keyboardShortcut(.return,modifiers:.command).disabled(busy)}}.padding(.horizontal,20).frame(height:48)
        }
        .task(id:game.id){scan()}
        .task(id:current){await readEntries()}
        .onChange(of:edits){_,_ in scheduleDraftWrite()}
        .onDisappear{operation?.cancel();draftWrite?.cancel();persistDrafts()}
    }
    private var toolbar:some View {
        VStack(spacing:14) {
            HStack(spacing:10){Text("实例资源汉化").font(.system(size:20,weight:.semibold));Spacer();Button{scan()}label:{Image(systemName:"arrow.clockwise")}.buttonStyle(HarborButtonStyle()).help("读取语言文件、FTB Quests 任务文本与存档数据包").disabled(busy);Button("导入译文…"){importTranslations()}.buttonStyle(HarborButtonStyle()).disabled(busy || project==nil);Button("一键汉化"){translate()}.buttonStyle(HarborButtonStyle(prominent:true)).disabled(busy || selected.isEmpty)}
            HStack(spacing:10){TextField("资源包名称",text:$packName).textFieldStyle(.roundedBorder).frame(maxWidth:.infinity);Text("格式").font(.system(size:11)).foregroundStyle(.secondary);TextField("格式号",text:$packFormat).textFieldStyle(.roundedBorder).frame(width:62);Button("导出汉化包…"){export(sourceOnly:false)}.buttonStyle(HarborButtonStyle()).disabled(busy || selected.isEmpty);Button("提取给 AI…"){export(sourceOnly:true)}.buttonStyle(HarborButtonStyle()).disabled(busy || selected.isEmpty)}
            HStack(spacing:10){Text("lang · KubeJS · FTB 任务 · 存档数据包").font(.system(size:11)).foregroundStyle(.secondary);Spacer();Button("应用任务 / 数据包…"){applyTextAssets()}.buttonStyle(HarborButtonStyle()).disabled(busy || !hasTextSelection).help("备份后应用所选任务和数据包的已有译文，不改变任务关系、奖励条件或其他文件")}
        }.padding(20)
    }
    private var resourceList:some View {
        VStack(spacing:0) {
            HStack{Text("实例资源").font(.system(size:12,weight:.semibold));Spacer();Button("全选"){selected=Set(project?.sources.map(\.id) ?? [])};Button("清空"){selected=[]}}.font(.system(size:10)).buttonStyle(HarborBareButtonStyle()).padding(14)
            ScrollView{LazyVStack(spacing:5){ForEach(project?.sources ?? []){source in HStack(spacing:7){Toggle("选择 "+source.name,isOn:Binding(get:{selected.contains(source.id)},set:{on in if on{selected.insert(source.id)}else{selected.remove(source.id)}})).labelsHidden().toggleStyle(.checkbox).controlSize(.small);Button{current=source.id;chosen=nil}label:{HStack(spacing:9){ResourceArtwork(iconPath:source.iconPath,fallback:source.kind=="mods" ? "puzzlepiece.extension":"character.book.closed").frame(width:25,height:25);VStack(alignment:.leading,spacing:4){Text(source.name).font(.system(size:11,weight:.medium)).lineLimit(1);Text("\(source.translated)/\(source.entries) · \(source.languageFiles) 文件").font(.system(size:9)).foregroundStyle(.secondary)};Spacer(minLength:0)}.padding(9).frame(maxWidth:.infinity,alignment:.leading).background(model.themeColor.opacity(current==source.id ? 0.12:0.025),in:RoundedRectangle(cornerRadius:12)).contentShape(RoundedRectangle(cornerRadius:12))}.buttonStyle(HarborBareButtonStyle())}.padding(.horizontal,10)}}}.scrollIndicators(.hidden)
        }
    }
    private func editor(_ entry:LanguageEntry)->some View {
        VStack(alignment:.leading,spacing:9) {
            HStack{Text(entry.namespace+" / "+entry.key).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled);Spacer();Text(entry.origin=="community" ? "社区译文":entry.origin=="embedded" ? "资源内中文":entry.origin=="manual" ? "自定义":"待翻译").font(.system(size:10)).foregroundStyle(.secondary)}
            HStack(alignment:.top,spacing:14){ScrollView{Text(entry.source).font(.system(size:12)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading).padding(9)}.frame(maxWidth:.infinity).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:10));TextEditor(text:Binding(get:{translation(entry)},set:{value in var source=edits[current] ?? [:];if value==entry.translation{source.removeValue(forKey:entry.id)}else{source[entry.id]=value};edits[current]=source.isEmpty ? nil:source})).font(.system(size:12)).scrollContentBackground(.hidden).padding(5).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10)).frame(maxWidth:.infinity)}.frame(height:110)
            if !entry.issue.isEmpty{Text(entry.issue).font(.system(size:10)).foregroundStyle(.orange)}
        }.padding(16).background(Color.primary.opacity(0.025))
    }
    private func base(_ command:String)->[String:Any]{var input:[String:Any]=["command":command,"root":model.preferences.gameRoot,"id":game.id,"runDirectory":game.runDirectory,"version":game.version,"loader":game.loader,"name":model.displayName(game)];if let project{input["project"]=project.project};return input}
    private func run(_ action:@escaping()async throws->Void){operation?.cancel();operation=Task{busy=true;failure="";defer{busy=false};do{try await action()}catch{if !(error is CancellationError){failure=error.localizedDescription}}}}
    private func scan(){run{let result=try await BackendQuery.run(base("langScan"));let loaded:LanguageProject=try ResourceService.decode(result);let previous=current;project=loaded;if packName.isEmpty{packName=model.displayName(game)+" 汉化"};packFormat=loaded.packFormat==0 ? "":String(format:"%g",loaded.packFormat);selected=Set(loaded.sources.filter(\.enabled).map(\.id));if !loaded.sources.contains(where:{$0.id==current}){current=loaded.sources.first?.id ?? ""};edits=LocalizationDrafts.read(loaded.project);status="\(loaded.sources.count) 个实例资源 · \(loaded.sources.reduce(0){$0+$1.languageFiles}) 个文本文件";if !loaded.warnings.isEmpty{status+=" · \(loaded.warnings.count) 项读取提示"};if previous==current{await readEntries()}}}
    private func readEntries()async{guard let project,!current.isEmpty else{rows=[];return};let resource=current;var input=base("langRead");input["project"]=project.project;input["resource"]=resource;do{let payload=try await BackendQuery.run(input);let result:LanguageEntries=try await Task.detached(priority:.userInitiated){try ResourceService.decode(payload)}.value;guard !Task.isCancelled,resource==current else{return};rows=result.entries;chosen=rows.first?.id}catch{if !(error is CancellationError){failure=error.localizedDescription}}}
    private func commitEdits()async throws{guard editCount>0 else{return};let snapshot=edits;var input=base("langSave");input["changes"]=snapshot.flatMap{resource,values in values.map{["resource":resource,"entry":$0.key,"translation":$0.value]}};let result=try await BackendQuery.run(input);if let updated=result["project"] as? [String:Any]{project=try ResourceService.decode(updated)};edits=[:];persistDrafts();await readEntries();status="译文已保存"}
    private func translate(){run{try await commitEdits();var input=base("langTranslate");input["selected"]=Array(selected);let result=try await BackendQuery.run(input);if let updated=result["project"] as? [String:Any]{project=try ResourceService.decode(updated)};await readEntries();status="已补入 \(result["filled"] as? Int ?? 0) 条 · \(result["pending"] as? Int ?? 0) 条待翻译";if let warnings=result["warnings"] as? [String],!warnings.isEmpty{failure=warnings.joined(separator:" · ")}}}
    private func importTranslations(){let panel=NSOpenPanel();panel.allowedContentTypes=[.zip,.json,UTType(filenameExtension:"lang") ?? .text];panel.prompt="导入译文";guard panel.runModal() == .OK,let file=panel.url else{return};run{try await commitEdits();var input=base("langImport");input["file"]=file.path;input["selected"]=Array(selected);let result=try await BackendQuery.run(input);if let updated=result["project"] as? [String:Any]{project=try ResourceService.decode(updated)};await readEntries();status="已导入 \(result["imported"] as? Int ?? 0) 条译文 · \(result["rejected"] as? Int ?? 0) 条格式不符"}}
    private func export(sourceOnly:Bool){let panel=NSSavePanel();panel.allowedContentTypes=[.zip];panel.nameFieldStringValue=packName+(sourceOnly ? "-未汉化":"")+".zip";panel.prompt=sourceOnly ? "提取语言":"导出汉化包";guard panel.runModal() == .OK,let file=panel.url else{return};run{try await commitEdits();guard let format=Double(packFormat),format>0 else{throw FileTransactions.error("请填写正确的资源包格式号。")} ;var input=base("langExport");input["selected"]=Array(selected);input["packName"]=packName;input["packFormat"]=format;input["mode"]=sourceOnly ? "source":"translated";input["output"]=file.path;let result=try await BackendQuery.run(input);status="已导出 \(result["entries"] as? Int ?? 0) 条 · \(result["sources"] as? Int ?? 0) 个实例资源";NSWorkspace.shared.activateFileViewerSelecting([file]);HarborAudio.shared.play(.success)}}
    private func applyTextAssets(){
        let alert=NSAlert();alert.messageText="应用所选任务与数据包的译文？";alert.informativeText="请先关闭游戏。将校验文件修订、备份原文件，再写入已有译文。普通 lang 仍通过汉化资源包使用；任务 ID、依赖、指令与奖励条件保持。";alert.addButton(withTitle:"备份并应用");alert.addButton(withTitle:"取消");guard alert.runModal() == .alertFirstButtonReturn else{return}
        run{try await commitEdits();var input=base("langApply");input["selected"]=Array(selected);let result=try await BackendQuery.run(input);let count=result["files"] as? Int ?? 0;status=count==0 ? "没有需要应用的任务 / 数据包译文":"已应用 \(count) 个任务 / 数据文件，原文件备份已校验";if count>0,let backup=result["backup"] as? String{NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:backup)])};HarborAudio.shared.play(.success)}
    }
    private func scheduleDraftWrite(){draftWrite?.cancel();guard let project else{return};let path=project.project,value=edits;let item=DispatchWorkItem{LocalizationDrafts.write(value,project:path)};draftWrite=item;DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+0.35,execute:item)}
    private func persistDrafts(){if let project{LocalizationDrafts.write(edits,project:project.project)}}
}
private enum LocalizationDrafts {
    static func read(_ project:String)->[String:[String:String]]{(try? JSONDecoder().decode([String:[String:String]].self,from:Data(contentsOf:URL(fileURLWithPath:project).appendingPathComponent("drafts.json")))) ?? [:]}
    static func write(_ values:[String:[String:String]],project:String){guard let data=try? JSONEncoder().encode(values) else{return};try? data.write(to:URL(fileURLWithPath:project).appendingPathComponent("drafts.json"),options:.atomic)}
}
