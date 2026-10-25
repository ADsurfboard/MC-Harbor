import AppKit
import Foundation

struct MigrationReceipt:Codable {
    var date:Date
    var importedAccounts:Int
    var existingAccounts:Int
    var libraries:[String]
    var instances:Int
    var failures:[String]
    var backup:String
}

enum HMCLDataMigration {
    static var shared:URL{FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HMCL")}
    static func libraries(root:String)->[String]{
        let local=URL(fileURLWithPath:root).deletingLastPathComponent()
        let sources=[(shared.appendingPathComponent("config/user-game-directories.json"),shared),(local.appendingPathComponent(".hmcl/config/game-directories.json"),local)]
        var paths=[root]
        for (file,base) in sources{let object=NativeScanner.readJSON(file);for record in object["directories"] as? [[String:Any]] ?? []{guard let path=record["path"] as? String else{continue};let url=path.hasPrefix("/") ? URL(fileURLWithPath:path):base.appendingPathComponent(path);if FileManager.default.fileExists(atPath:url.appendingPathComponent("versions").path),!paths.contains(url.standardized.path){paths.append(url.standardized.path)}}}
        return paths
    }
    /// Only configuration is copied. All original games, saves and shared libraries stay in place.
    static func snapshot(root:String)throws->URL{
        let fm=FileManager.default;let destination=NativePaths.root.appendingPathComponent("migration-backups/"+String(Int(Date().timeIntervalSince1970)))
        try fm.createDirectory(at:destination,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let local=URL(fileURLWithPath:root).deletingLastPathComponent().appendingPathComponent(".hmcl")
        for (label,base) in [("shared",shared),("local",local)]{
            for folder in ["config","private","state"]{
                let source=base.appendingPathComponent(folder)
                for file in (try? fm.contentsOfDirectory(at:source,includingPropertiesForKeys:[.isRegularFileKey])) ?? [] where file.pathExtension=="json"{
                    let target=destination.appendingPathComponent(label+"/"+folder+"/"+file.lastPathComponent);try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try fm.copyItem(at:file,to:target);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
                }
            }
        }
        for library in libraries(root:root){for instance in NativeScanner.scan(library){let source=URL(fileURLWithPath:instance.directory).appendingPathComponent(".hmcl/config/instance-game-settings.json");if fm.fileExists(atPath:source.path){let target=destination.appendingPathComponent("instances/"+URL(fileURLWithPath:library).deletingLastPathComponent().lastPathComponent+"/"+instance.id+".json");try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);if !fm.fileExists(atPath:target.path){try fm.copyItem(at:source,to:target);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)}}}}
        return destination
    }
}

@MainActor extension LauncherModel {
    func migrateHMCL(){
        guard !migrating else{return};migrating=true
        let root=preferences.gameRoot
        Task{
            do{
                let backup=try await Task.detached{try HMCLDataMigration.snapshot(root:root)}.value
                backend("migrate",title:"导入 HMCL",arguments:[:],silent:true){result in
                    var imported=0;var failures=result["failures"] as? [String] ?? []
                    let prior=self.accounts.count
                    for raw in result["accounts"] as? [[String:Any]] ?? []{
                        guard let meta=raw["metadata"] as? [String:Any],let id=meta["id"] as? String,let kind=meta["kind"] as? String,let name=meta["name"] as? String,let uuid=meta["uuid"] as? String else{failures.append("账号元数据不完整");continue}
                        if self.accounts.contains(where:{$0.id==id || ($0.kind==kind && $0.uuid==uuid)}){continue}
                        do{try KeychainStore.write(try JSONSerialization.data(withJSONObject:raw),id:id);self.accounts.append(LauncherAccount(id:id,name:name,kind:kind,uuid:uuid));imported+=1}catch{failures.append("账号未导入："+name)}
                    }
                    self.saveAccounts();if self.preferences.selectedAccount==nil{let settings=NativeScanner.readJSON(URL(fileURLWithPath:root).deletingLastPathComponent().appendingPathComponent(".hmcl/config/launcher-settings.json"));let original=settings["selectedAccount"] as? String;self.preferences.selectedAccount=self.accounts.first(where:{$0.id==original})?.id ?? self.accounts.first?.id}
                    self.preferences.knownLibraries=HMCLDataMigration.libraries(root:root)
                    let receipt=MigrationReceipt(date:Date(),importedAccounts:imported,existingAccounts:prior,libraries:self.preferences.knownLibraries,instances:self.preferences.knownLibraries.reduce(0){$0+NativeScanner.scan($1).count},failures:failures,backup:backup.path)
                    if let data=try? JSONEncoder().encode(receipt){try? data.write(to:NativePaths.root.appendingPathComponent("migration.json"),options:.atomic)}
                    self.migrationStatus="已接入 \(receipt.instances) 个游戏 · \(self.accounts.count) 个账号"
                    self.migrating=false;self.scan()
                    if !failures.isEmpty{self.errorMessage="部分账号未导入，原数据已保留。\n"+failures.joined(separator:"\n")}
                    else{self.toast(self.migrationStatus)}
                }
            }catch{migrating=false;errorMessage="迁移前备份未完成："+error.localizedDescription}
        }
    }
}
