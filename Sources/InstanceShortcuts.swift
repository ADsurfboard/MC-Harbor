import AppKit
import Foundation
import Darwin

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
        guard destination.pathExtension.lowercased()=="app" else{throw FileTransactions.error("请选择 .app 快捷应用。")};guard !FileManager.default.fileExists(atPath:destination.path) else{throw FileTransactions.error("目标已存在，请更换名称。")}
        let token=UUID().uuidString
        var all=targets();all[token]=InstanceShortcutTarget(instance:game.id,library:URL(fileURLWithPath:library).standardizedFileURL.resolvingSymlinksInPath().path)
        let helper=NativePaths.resources.appendingPathComponent("InstanceShortcut")
        guard FileManager.default.isExecutableFile(atPath:helper.path) else{throw FileTransactions.error("快捷方式组件缺失，请重新安装 MC Harbor。")}
        let info:[String:Any]=["CFBundleName":game.id,"CFBundleExecutable":"InstanceShortcut","CFBundleIdentifier":"net.morben.harbor.shortcut."+token.lowercased(),"CFBundlePackageType":"APPL","LSUIElement":true,"HarborURL":url(for:token)!.absoluteString,"HarborApplication":Bundle.main.bundleURL.path,"HarborDataRoot":NativePaths.root.standardizedFileURL.resolvingSymlinksInPath().path,"HarborBundleID":"net.morben.shenggan.launcher"]
        let bytes=try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0)
        try JSONEncoder().encode(all).write(to:manifest,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
        do{let contents=destination.appendingPathComponent("Contents");let macos=contents.appendingPathComponent("MacOS");try FileManager.default.createDirectory(at:macos,withIntermediateDirectories:true);try FileManager.default.copyItem(at:helper,to:macos.appendingPathComponent("InstanceShortcut"));try bytes.write(to:contents.appendingPathComponent("Info.plist"),options:.atomic)}catch{try? FileManager.default.removeItem(at:destination);all.removeValue(forKey:token);try? JSONEncoder().encode(all).write(to:manifest,options:.atomic);throw error}
    }
}
@MainActor extension LauncherModel {
    func createInstanceShortcut(_ game:GameInstance){
        let panel=NSSavePanel();panel.title="创建实例快捷方式";panel.prompt="创建";panel.nameFieldStringValue=displayName(game)+".app";panel.directoryURL=FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask).first
        guard panel.runModal() == .OK,let destination=panel.url else{return}
        do{try InstanceShortcuts.create(game:game,library:preferences.gameRoot,destination:destination);if let image=InstanceArt.image(artworkGame(game)){NSWorkspace.shared.setIcon(image,forFile:destination.path,options:[])};toast("实例快捷方式已创建，双击即可启动")}catch{errorMessage=error.localizedDescription}
    }
    func openInstanceShortcut(_ url:URL){
        guard url.scheme?.lowercased()=="mcharbor" else{return}
        HarborWindowController.shared.showMainWindow()
        do{
            let target=try InstanceShortcuts.target(for:url)
            let root=URL(fileURLWithPath:preferences.gameRoot).standardizedFileURL.resolvingSymlinksInPath().path
            let targetRoot=URL(fileURLWithPath:target.library).standardizedFileURL.resolvingSymlinksInPath().path
            guard targetRoot==root else{throw FileTransactions.error("此快捷方式属于另一个游戏库，请先在设置中切换到对应游戏库。")}
            showIntro=false
            Task{let scanned=await Task.detached{NativeScanner.scan(root)}.value;self.games=scanned
                guard let game=scanned.first(where:{$0.id==target.instance}) else{self.errorMessage="实例已移动或删除，请重新创建快捷方式。";return}
                self.preferences.selectedGame=game.id;self.section = .library
                if !self.running.contains(game.id){self.launch(game)}
            }
        }catch{errorMessage=error.localizedDescription}
    }
}

struct InstanceShortcutRequest:Codable {let url:String;let created:TimeInterval}
enum InstanceShortcutInbox {
    static var directory:URL{NativePaths.root.appendingPathComponent("shortcut-inbox",isDirectory:true)}
    static func prepare()throws{try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);guard (try directory.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else{throw FileTransactions.error("快捷方式请求目录不能是符号链接。")}}
    static func take()throws->[URL]{
        try prepare();let fm=FileManager.default;var urls:[URL]=[]
        let files=try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey,.fileSizeKey],options:[.skipsHiddenFiles]).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        for file in files.prefix(50){defer{try? fm.removeItem(at:file)};let values=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey]);guard values.isSymbolicLink != true,(values.fileSize ?? 0)<=4096,UUID(uuidString:file.deletingPathExtension().lastPathComponent) != nil else{continue}
            guard let request=try? JSONDecoder().decode(InstanceShortcutRequest.self,from:Data(contentsOf:file)),abs(Date().timeIntervalSince1970-request.created)<300,let url=URL(string:request.url),(try? InstanceShortcuts.target(for:url)) != nil else{continue};urls.append(url)
        };return urls
    }
}
final class InstanceShortcutWatcher {
    private let source:DispatchSourceFileSystemObject
    init(changed:@escaping()->Void)throws{try InstanceShortcutInbox.prepare();let descriptor=open(InstanceShortcutInbox.directory.path,O_EVTONLY);guard descriptor>=0 else{throw FileTransactions.error("无法监听实例快捷方式请求。")};source=DispatchSource.makeFileSystemObjectSource(fileDescriptor:descriptor,eventMask:.write,queue:.main);source.setEventHandler(handler:changed);source.setCancelHandler{close(descriptor)};source.resume()}
    deinit{source.cancel()}
}
@MainActor extension LauncherModel {
    func monitorInstanceShortcuts(){guard shortcutWatcher==nil else{return};do{shortcutWatcher=try InstanceShortcutWatcher{[weak self] in Task{@MainActor in self?.consumeInstanceShortcuts()}};consumeInstanceShortcuts()}catch{errorMessage=error.localizedDescription}}
    func consumeInstanceShortcuts(){do{for url in try InstanceShortcutInbox.take(){openInstanceShortcut(url)}}catch{errorMessage=error.localizedDescription}}
}
