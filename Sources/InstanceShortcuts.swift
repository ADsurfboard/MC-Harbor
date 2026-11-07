import AppKit
import Foundation

struct InstanceShortcutTarget:Codable {let instance:String;let library:String}
enum InstanceShortcuts {
    static var manifest:URL{NativePaths.root.appendingPathComponent("instance-shortcuts.json")}
    static func targets()->[String:InstanceShortcutTarget]{(try? JSONDecoder().decode([String:InstanceShortcutTarget].self,from:Data(contentsOf:manifest))) ?? [:]}
    static func url(for token:String)->URL?{URL(string:"mcharbor://launch/"+token)}
    static func target(for url:URL)throws->InstanceShortcutTarget {
        let token=url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        guard url.scheme?.lowercased()=="mcharbor",url.host=="launch",url.query==nil,url.fragment==nil,UUID(uuidString:token) != nil,let target=targets()[token] else{throw FileTransactions.error("快捷方式无效或不属于此 Mac。请在实例菜单中重新创建。")}
        return target
    }
    static func create(game:GameInstance,library:String,destination:URL)throws {
        guard destination.pathExtension.lowercased()=="webloc" else{throw FileTransactions.error("请选择 .webloc 快捷方式文件。")}
        let token=UUID().uuidString
        var all=targets();all[token]=InstanceShortcutTarget(instance:game.id,library:URL(fileURLWithPath:library).standardizedFileURL.resolvingSymlinksInPath().path)
        let bytes=try PropertyListSerialization.data(fromPropertyList:["URL":url(for:token)!.absoluteString],format:.xml,options:0)
        try JSONEncoder().encode(all).write(to:manifest,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
        do{try bytes.write(to:destination,options:.atomic)}catch{all.removeValue(forKey:token);try? JSONEncoder().encode(all).write(to:manifest,options:.atomic);throw error}
    }
}
@MainActor extension LauncherModel {
    func createInstanceShortcut(_ game:GameInstance){
        let panel=NSSavePanel();panel.title="创建实例快捷方式";panel.prompt="创建";panel.nameFieldStringValue=displayName(game)+".webloc";panel.directoryURL=FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask).first
        guard panel.runModal() == .OK,let destination=panel.url else{return}
        do{try InstanceShortcuts.create(game:game,library:preferences.gameRoot,destination:destination);if let image=InstanceArt.image(artworkGame(game)){NSWorkspace.shared.setIcon(image,forFile:destination.path,options:[])};toast("实例快捷方式已创建，双击即可启动")}catch{errorMessage=error.localizedDescription}
    }
    func openInstanceShortcut(_ url:URL){
        guard url.scheme?.lowercased()=="mcharbor" else{return}
        HarborWindowController.shared.showMainWindow()
        do{
            let target=try InstanceShortcuts.target(for:url)
            let root=URL(fileURLWithPath:preferences.gameRoot).standardizedFileURL.resolvingSymlinksInPath().path
            guard target.library==root else{throw FileTransactions.error("此快捷方式属于另一个游戏库，请先在设置中切换到对应游戏库。")}
            scan()
            guard let game=games.first(where:{$0.id==target.instance}) else{throw FileTransactions.error("实例已移动或删除，请重新创建快捷方式。")}
            preferences.selectedGame=game.id;section = .library
            if !running.contains(game.id){launch(game)}
        }catch{errorMessage=error.localizedDescription}
    }
}
