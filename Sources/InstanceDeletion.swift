import AppKit
import Foundation

enum InstanceDeletion {
    static func validatedDirectory(_ game:GameInstance,root:String)throws->URL {
        let versions=URL(fileURLWithPath:root,isDirectory:true).appendingPathComponent("versions",isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
        let candidate=URL(fileURLWithPath:game.directory,isDirectory:true).standardizedFileURL
        guard !game.id.isEmpty,game.id != ".",game.id != "..",!game.id.contains("/"),!game.id.contains("\\"),candidate.lastPathComponent==game.id,
              candidate.deletingLastPathComponent().resolvingSymlinksInPath()==versions,
              (try candidate.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])).isDirectory==true,
              (try candidate.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true,
              candidate.resolvingSymlinksInPath().deletingLastPathComponent()==versions else{throw NSError(domain:"MC Harbor",code:1,userInfo:[NSLocalizedDescriptionKey:"实例目录不属于当前游戏库，或是符号链接；未删除。"])}
        let entries=try FileManager.default.contentsOfDirectory(at:versions,includingPropertiesForKeys:[.isSymbolicLinkKey,.isDirectoryKey])
        for entry in entries where entry.lastPathComponent != game.id {
            let values=try? entry.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]);guard values?.isDirectory==true,values?.isSymbolicLink != true else{continue}
            let file=entry.appendingPathComponent(entry.lastPathComponent+".json")
            guard let data=try? Data(contentsOf:file),let obj=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{continue}
            if obj["inheritsFrom"] as? String==game.id{throw NSError(domain:"MC Harbor",code:2,userInfo:[NSLocalizedDescriptionKey:"实例「\(entry.lastPathComponent)」依赖此版本，请先处理依赖它的实例。"])}
        }
        return candidate
    }
    static func moveToTrash(_ game:GameInstance,root:String)throws->URL? {
        let candidate=try validatedDirectory(game,root:root);var result:NSURL?
        try FileManager.default.trashItem(at:candidate,resultingItemURL:&result)
        return result as URL?
    }
}

extension LauncherModel {
    func deleteInstance(_ game:GameInstance){
        guard !running.contains(game.id) else{errorMessage="游戏正在运行，请退出后再删除。";return}
        do{_ = try InstanceDeletion.validatedDirectory(game,root:preferences.gameRoot)}catch{errorMessage=error.localizedDescription;return}
        let alert=NSAlert();alert.messageText="将实例移到废纸篓？";alert.informativeText="「\(displayName(game))」的实例目录及其中的存档、模组和设置将移到废纸篓。共享游戏目录及其他实例不会被删除。";alert.addButton(withTitle:"移到废纸篓");alert.addButton(withTitle:"取消");alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        do{_ = try InstanceDeletion.moveToTrash(game,root:preferences.gameRoot);preferences.favorites.remove(game.id);preferences.nickname.removeValue(forKey:game.id);preferences.instanceIcons.removeValue(forKey:game.id);preferences.instanceOptions.removeValue(forKey:game.id);if preferences.selectedGame==game.id{preferences.selectedGame=""};modMetadata.removeValue(forKey:game.id);resourceRecords.removeValue(forKey:game.id);resourceIndexed.remove(game.id);inspectedGame=nil;games.removeAll{$0.id==game.id};scan();toast("实例已移到废纸篓")}
        catch{errorMessage="无法删除实例："+error.localizedDescription}
    }
}
