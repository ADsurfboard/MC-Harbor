import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor extension LauncherModel {
    func importContent(_ game:GameInstance,kind:ContentKind){
        let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.canChooseDirectories=kind != .mods
        panel.allowedContentTypes=kind == .mods ? [UTType(filenameExtension:"jar") ?? .data]:[.zip,.folder]
        panel.prompt="导入"+kind.title
        if panel.runModal() == .OK{copyContent(panel.urls,game:game,kind:kind)}
    }
    func copyContent(_ urls:[URL],game:GameInstance,kind:ContentKind){
        guard !running.contains(game.id) else{errorMessage="请退出此实例后再修改文件。";return}
        editingContent=true
        let destination=URL(fileURLWithPath:game.runDirectory).appendingPathComponent(kind.rawValue)
        Task{defer{editingContent=false};do{try await Task.detached(priority:.userInitiated){try FileTransactions.importFiles(urls,to:destination,extensions:kind == .mods ? ["jar"]:["zip"],folders:kind != .mods)}.value;contentDidChange(game);toast("已导入 \(urls.count) 个"+kind.title);HarborAudio.shared.play(.success)}catch{errorMessage=error.localizedDescription;HarborAudio.shared.play(.error)}}
    }
    func setMods(_ mods:[ModFile],enabled:Bool,game:GameInstance){
        guard !running.contains(game.id) else{errorMessage="请退出此实例后再修改模组。";return}
        guard !editingContent else{return}
        let pairs=mods.filter{$0.enabled != enabled}.map{($0.path,enabled ? URL(fileURLWithPath:String($0.path.path.dropLast(9))):URL(fileURLWithPath:$0.path.path+".disabled"))}
        guard !pairs.isEmpty else{return};editingContent=true
        Task{defer{editingContent=false};do{try await Task.detached{try FileTransactions.move(pairs)}.value
            let destinations=Dictionary(uniqueKeysWithValues:pairs.map{($0.0.path,$0.1)})
            if let cached=modMetadata[game.id]{modMetadata[game.id]=cached.map{mod in guard let path=destinations[mod.path.path] else{return mod};return ModFile(id:mod.id,name:mod.name,path:path,enabled:enabled,size:mod.size,version:mod.version,authors:mod.authors,modID:mod.modID,iconPath:mod.iconPath)}}
            contentChanged.send()}catch{errorMessage=error.localizedDescription;HarborAudio.shared.play(.error)}}
    }
    func setContentActive(_ url:URL,active:Bool,game:GameInstance){
        guard !running.contains(game.id) else{errorMessage="请退出此实例后再修改文件。";return}
        let destination=active ? URL(fileURLWithPath:String(url.path.dropLast(9))):URL(fileURLWithPath:url.path+".disabled")
        Task{do{try await Task.detached{try FileTransactions.move([(url,destination)])}.value;contentDidChange(game)}catch{errorMessage=error.localizedDescription}}
    }
    func trashContent(_ urls:[URL],game:GameInstance){
        guard !running.contains(game.id) else{errorMessage="请退出此实例后再修改文件。";return}
        Task{do{try await Task.detached{for url in urls{try FileManager.default.trashItem(at:url,resultingItemURL:nil)}}.value;contentDidChange(game);toast("已移到废纸篓")}catch{errorMessage=error.localizedDescription}}
    }
    func contentDidChange(_ game:GameInstance){modMetadata.removeValue(forKey:game.id);contentChanged.send();loadMods(game,force:true);loadResourceIndex(game,force:true)}
    func exportPack(_ game:GameInstance){
        let panel=NSSavePanel();panel.allowedContentTypes=[.zip];panel.nameFieldStringValue=displayName(game)+".zip";panel.prompt="导出整合包"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        if FileManager.default.fileExists(atPath:url.path){errorMessage="请使用新的文件名，现有归档不会被覆盖。";return}
        backend("export",title:"导出 "+displayName(game),arguments:["id":game.id,"runDirectory":game.runDirectory,"output":url.path]){result in self.toast("整合包已导出");HarborAudio.shared.play(.success);if let p=result["path"] as? String{NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:p)])}}
    }
    func backupWorld(_ world:LocalContent,game:GameInstance){backend("backup",title:"备份 "+world.name,arguments:["runDirectory":game.runDirectory,"world":world.name]){_ in self.toast("存档备份完成");HarborAudio.shared.play(.success)}}
    func importWorld(_ game:GameInstance){
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.prompt="导入存档"
        guard panel.runModal() == .OK,let source=panel.url else{return}
        guard FileManager.default.fileExists(atPath:source.appendingPathComponent("level.dat").path) else{errorMessage="所选文件夹没有 level.dat。";return}
        let destination=URL(fileURLWithPath:game.runDirectory).appendingPathComponent("saves")
        Task{do{try await Task.detached{try FileTransactions.importFiles([source],to:destination,extensions:[],folders:true)}.value;contentChanged.send();toast("存档已导入")}catch{errorMessage=error.localizedDescription}}
    }
}

enum FileTransactions {
    static func error(_ description:String)->NSError{NSError(domain:"MC Harbor",code:1,userInfo:[NSLocalizedDescriptionKey:description])}
    /// Preflight all destinations, then roll back moves if any member fails.
    static func move(_ pairs:[(URL,URL)])throws{
        let fm=FileManager.default
        guard Set(pairs.map{$0.1.standardizedFileURL.path}).count==pairs.count else{throw error("所选文件的目标名称重复。")}
        for (source,target) in pairs{guard fm.fileExists(atPath:source.path) else{throw error("文件不存在："+source.lastPathComponent)};guard !fm.fileExists(atPath:target.path) else{throw error("已存在："+target.lastPathComponent)}}
        var moved:[(URL,URL)]=[]
        do{for pair in pairs{try fm.moveItem(at:pair.0,to:pair.1);moved.append(pair)}}catch{for pair in moved.reversed(){try? fm.moveItem(at:pair.1,to:pair.0)};throw error}
    }
    /// Stage copies before making them visible. Existing files and symlinked imports are preserved.
    static func importFiles(_ sources:[URL],to directory:URL,extensions:Set<String>,folders:Bool)throws{
        guard !sources.isEmpty else{return};let fm=FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        for source in sources{
            let values=try source.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard values.isSymbolicLink != true else{throw error("不能导入符号链接。")}
            guard (values.isDirectory==true && folders) || extensions.contains(source.pathExtension.lowercased()) else{throw error("不支持的文件："+source.lastPathComponent)}
            guard !fm.fileExists(atPath:directory.appendingPathComponent(source.lastPathComponent).path) else{throw error("已存在："+source.lastPathComponent)}
        }
        let stage=directory.appendingPathComponent(".harbor-import-"+UUID().uuidString,isDirectory:true);try fm.createDirectory(at:stage,withIntermediateDirectories:false);defer{try? fm.removeItem(at:stage)}
        for source in sources{try fm.copyItem(at:source,to:stage.appendingPathComponent(source.lastPathComponent))}
        try move(sources.map{(stage.appendingPathComponent($0.lastPathComponent),directory.appendingPathComponent($0.lastPathComponent))})
    }
}
