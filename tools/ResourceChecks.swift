import AppKit
import Foundation
import SwiftUI

// Artwork only is stubbed. These checks use production download, dependency and transaction code.
struct WorldIcon:View{let game:GameInstance;var body:some View{EmptyView()}}
struct ShengganMark:View{var body:some View{EmptyView()}}
struct FluidField:View{let dark:Bool;let color:Color;let active:Bool;var body:some View{EmptyView()}}

@main struct ResourceChecks {
    static func main()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        setenv("SHENGGAN_DATA_DIR",root.path,1)
        let directory=root.appendingPathComponent("game/versions/fixture");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var json=NativeScanner.readJSON(URL(fileURLWithPath:"/Applications/.minecraft/versions/1.20.1/1.20.1.json"));json["id"]="fixture";try JSONSerialization.data(withJSONObject:json).write(to:directory.appendingPathComponent("fixture.json"))
        let game=GameInstance(id:"fixture",version:"1.20.1",loader:"Forge",directory:directory.path,runDirectory:directory.path,iconPath:nil,modified:Date())
        var checks:[String:Bool]=[:];var notes:[String:Any]=[:]
        let search=try await ResourceService.search("Controlling",game:game,kind:.mods,source:.curseforge)
        guard let project=search.hits.first(where:{$0.title=="Controlling"}) ?? search.hits.first else{throw FileTransactions.error("No CurseForge fixture")}
        let versions=try await ResourceService.versions(project.id,game:game,kind:.mods,source:.curseforge)
        guard let selected=versions.first else{throw FileTransactions.error("No compatible CurseForge file")}
        let plan=try await ResourceService.plan(selected,game:game,kind:.mods,source:.curseforge)
        checks["curseforgeCompatibleVersions"]=plan.allSatisfy{$0.version.gameVersions.contains("1.20.1") && $0.version.loaders.contains("forge")}
        checks["curseforgeRequiredDependencies"]=plan.count>1
        try await AddonService.install(plan,game:game,kind:.mods){_,_ in}
        checks["curseforgeDownloadAndHash"]=try plan.allSatisfy{try AddonService.verify(directory.appendingPathComponent("mods/"+$0.file.filename),file:$0.file)}
        notes["curseforgeFiles"]=plan.map{$0.file.filename}
        let catalog=GameInstance(id:"catalog",version:"",loader:"Minecraft",directory:directory.path,runDirectory:root.path,iconPath:nil,modified:Date())
        let packs=try await ResourceService.search("Simply Optimized",game:catalog,kind:.modpacks,source:.modrinth)
        guard let pack=packs.hits.first(where:{$0.title=="Simply Optimized"}) ?? packs.hits.first,
              let packVersion=try await ResourceService.versions(pack.id,game:catalog,kind:.modpacks,source:.modrinth).first,
              let item=try await ResourceService.plan(packVersion,game:catalog,kind:.modpacks,source:.modrinth).last else{throw FileTransactions.error("No Modrinth modpack fixture")}
        let archive=try await ResourceInstall.archive(item){_,_ in}
        checks["modrinthModpackDownloadAndHash"]=try AddonService.verify(archive,file:item.file)
        let unzip=Process();unzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");unzip.arguments=["-p",archive.path,"modrinth.index.json"];let output=Pipe();unzip.standardOutput=output;try unzip.run();let manifest=output.fileHandleForReading.readDataToEndOfFile();unzip.waitUntilExit();let value=(try JSONSerialization.jsonObject(with:manifest)) as? [String:Any]
        checks["modrinthModpackRealManifest"]=unzip.terminationStatus==0 && value?["game"] as? String=="minecraft" && value?["files"] is [[String:Any]]
        notes["modpackFile"]=item.file.filename;notes["modpackBytes"]=item.file.size
        notes["worldImport"]=NSString(string:"Covered by isolated backend ZIP import and traversal tests")
        let report:[String:Any]=["checks":checks,"passed":checks.values.filter{$0}.count,"failed":checks.values.filter{!$0}.count,"notes":notes]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.deletingLastPathComponent().appendingPathComponent("resource-check-report.json"))
        print("Resources:",checks.values.filter{$0}.count,"passed,",checks.values.filter{!$0}.count,"failed")
        if checks.values.contains(false){exit(1)}
    }
}
