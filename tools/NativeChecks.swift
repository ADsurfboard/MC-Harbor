import AppKit
import Foundation
import SwiftUI

// Only UI artwork is stubbed in this headless harness. All scanners, transactions and network code are production code.
struct WorldIcon:View{let game:GameInstance;var body:some View{EmptyView()}}
struct ShengganMark:View{var body:some View{EmptyView()}}
struct FluidField:View{let dark:Bool;let color:Color;let active:Bool;var body:some View{EmptyView()}}

@main struct NativeChecks {
    static func main()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        setenv("SHENGGAN_DATA_DIR",root.path,1)
        let saved:[String:Any]=["username":"Preserve_Me","memory":5120,"appearance":"dark","nickname":["fixture":"  "],"gameRoot":root.appendingPathComponent("game").path]
        try JSONSerialization.data(withJSONObject:saved).write(to:root.appendingPathComponent("preferences.json"))
        var checks:[String:Bool]=[:]
        let gameRoot=root.appendingPathComponent("game");let instance=gameRoot.appendingPathComponent("versions/fixture");try FileManager.default.createDirectory(at:instance,withIntermediateDirectories:true)
        var version=NativeScanner.readJSON(URL(fileURLWithPath:"/Applications/.minecraft/versions/1.20.1/1.20.1.json"));version["id"]="fixture";try JSONSerialization.data(withJSONObject:version).write(to:instance.appendingPathComponent("fixture.json"))
        for (name,libraries,expected) in [("quilt-fixture",["net.fabricmc:intermediary:1.20.1","org.quiltmc:quilt-loader:0.27.1"],"Quilt"),("legacy-fixture",["net.fabricmc:fabric-loader:0.16.0","net.legacyfabric:intermediary:1.7.10"],"Legacy Fabric"),("cleanroom-fixture",["net.minecraftforge:forge:1.12.2","com.cleanroommc:cleanroom:0.3.0"],"Cleanroom")]{
            let directory=gameRoot.appendingPathComponent("versions/"+name);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:["id":name,"gameVersion":"1.20.1","libraries":libraries.map{["name":$0]}]).write(to:directory.appendingPathComponent(name+".json"))
            checks["loader-"+expected]=NativeScanner.scan(gameRoot.path).first{$0.id==name}?.loader==expected
        }
        let model=await MainActor.run{LauncherModel()}
        await MainActor.run{
            checks["preferencesRetainUsername"]=model.preferences.username=="Preserve_Me"
            checks["preferencesRetainMemory"]=model.preferences.memory==5120
            checks["newThemeDefaults"]=model.preferences.themeHex=="#29825B"
            model.preferences.glassClarity = -1;checks["negativeClarityFrost"]=model.surfaceClarity==0
            model.preferences.glassClarity = 0;checks["zeroClarityStandard"]=model.surfaceClarity==0.5
            model.preferences.glassClarity = 1;checks["positiveClarityClear"]=model.surfaceClarity==1
        }
        let fixture=GameInstance(id:"fixture",version:"1.20.1",loader:"Forge",directory:instance.path,runDirectory:root.appendingPathComponent("addon-target").path,iconPath:nil,modified:Date())
        checks["blankAliasFallsBack"]=await MainActor.run{model.displayName(fixture)=="fixture"}
        let source=root.appendingPathComponent("source");let target=root.appendingPathComponent("target");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let file=source.appendingPathComponent("sample.jar");let bytes=Data([0x50,0x4b,3,4,0x41,0x42]);try bytes.write(to:file)
        try FileTransactions.importFiles([file],to:target,extensions:["jar"],folders:false)
        checks["importPreservesBytes"]=try Data(contentsOf:target.appendingPathComponent("sample.jar"))==bytes
        do{try FileTransactions.importFiles([file],to:target,extensions:["jar"],folders:false);checks["collisionRejected"]=false}catch{checks["collisionRejected"]=true}
        let active=target.appendingPathComponent("sample.jar");let disabled=target.appendingPathComponent("sample.jar.disabled");try FileTransactions.move([(active,disabled)])
        checks["modDisablePreservesBytes"]=try Data(contentsOf:disabled)==bytes
        try FileTransactions.move([(disabled,active)])
        checks["modEnableRestoresPath"]=FileManager.default.fileExists(atPath:active.path)
        let search=try await AddonService.search("Jade",game:fixture,kind:.mods)
        checks["liveModSearch"] = !search.hits.isEmpty
        guard let project=search.hits.first else{throw FileTransactions.error("Modrinth returned no compatible project")}
        let versions=try await AddonService.versions(project.id,game:fixture,kind:.mods)
        guard let selected=versions.first else{throw FileTransactions.error("No compatible addon version")}
        let plan=try await AddonService.plan(selected,game:fixture,kind:.mods)
        checks["loaderAndGameMatch"]=plan.allSatisfy{$0.version.gameVersions.contains("1.20.1") && $0.version.loaders.contains("forge")}
        try await AddonService.install(plan,game:fixture,kind:.mods){_,_ in}
        for item in plan{checks["sha512-"+item.id]=try AddonService.verify(URL(fileURLWithPath:fixture.runDirectory).appendingPathComponent("mods/"+item.file.filename),file:item.file)}
        try await AddonService.install(plan,game:fixture,kind:.mods){_,_ in}
        checks["repeatInstallIdempotent"]=true
        if let first=plan.first{
            let run=URL(fileURLWithPath:fixture.runDirectory);let live=run.appendingPathComponent("mods/"+first.file.filename);let renamed=run.appendingPathComponent("mods/manually-renamed.jar")
            try FileManager.default.moveItem(at:live,to:renamed);try FileManager.default.removeItem(at:run.appendingPathComponent(".harbor/modrinth-installed.json"))
            try await AddonService.install(plan,game:fixture,kind:.mods){_,_ in}
            checks["manualModIDReplaced"] = !FileManager.default.fileExists(atPath:renamed.path)
            checks["replacementBackupRetained"]=(FileManager.default.enumerator(at:run.appendingPathComponent(".harbor/previous"),includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []).contains{$0.lastPathComponent=="manually-renamed.jar"}
        }
        let report:[String:Any]=["checks":checks,"passed":checks.values.filter{$0}.count,"failed":checks.values.filter{!$0}.count,"downloadedProject":project.title,"files":plan.map{$0.file.filename}]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.deletingLastPathComponent().appendingPathComponent("native-check-report.json"))
        print("Native checks:",checks.values.filter{$0}.count,"passed,",checks.values.filter{!$0}.count,"failed")
        if checks.values.contains(false){exit(1)}
    }
}
