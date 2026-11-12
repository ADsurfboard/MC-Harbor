import Foundation

extension UpdateChecks {
    @MainActor static func localizationPipeline(_ config:[String:Any],root:URL)async throws {
        var checks:[String:Bool]=[:]
        func check(_ name:String,_ result:Bool){checks[name]=result;print((result ? "PASS ":"FAIL ")+name);fflush(stdout)}
        let run=root.appendingPathComponent("game/versions/LanguageQA"),stage=root.appendingPathComponent("jar-source")
        func write(_ relative:String,_ text:String,base:URL?=nil)throws{let file=(base ?? run).appendingPathComponent(relative);try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:file)}
        try write("LanguageQA.json",#"{"id":"LanguageQA","gameVersion":"1.20.1","mainClass":"net.minecraft.client.main.Main","type":"release","libraries":[],"arguments":{"game":[],"jvm":[]}}"#)
        try write("fabric.mod.json",#"{"schemaVersion":1,"id":"languageqa","version":"1","name":"Language QA"}"#,base:stage)
        try write("assets/languageqa/lang/en_us.json",#"{"ready":"Ready","welcome":"Welcome","embedded":"Existing"}"#,base:stage)
        try write("assets/languageqa/lang/zh_cn.json",#"{"ready":"Ready","embedded":"已有中文"}"#,base:stage)
        let mods=run.appendingPathComponent("mods");try FileManager.default.createDirectory(at:mods,withIntermediateDirectories:true)
        let jar=mods.appendingPathComponent("languageqa.jar"),zip=Process();zip.executableURL=URL(fileURLWithPath:"/usr/bin/zip");zip.currentDirectoryURL=stage;zip.arguments=["-qr",jar.path,"."];try zip.run();zip.waitUntilExit();guard zip.terminationStatus==0 else{throw FileTransactions.error("Fixture JAR creation failed")}
        let original=try Data(contentsOf:jar)
        try write("kubejs/assets/kubeqa/lang/en_us.json",#"{"collect":"Collect %s items."}"#)
        try write("config/ftbquests/quests/chapters/qa.snbt",#"{id:"CHAPTER_QA",title:"A new beginning",quests:[{id:"QUEST_QA",title:"Collect logs"}]}"#)
        try write("saves/World/datapacks/story/data/story/advancements/start.json",#"{"display":{"title":{"text":"A new beginning"},"description":{"text":"Collect logs"}},"criteria":{"unchanged":{"trigger":"minecraft:tick"}}}"#)
        var input:[String:Any]=["root":root.appendingPathComponent("game").path,"runDirectory":run.path,"id":"LanguageQA","version":"1.20.1","loader":"Fabric"]
        func call(_ command:String,_ fields:[String:Any]=[:])async throws->[String:Any]{var value=input;value["command"]=command;value.merge(fields,uniquingKeysWith:{$1});return try await BackendQuery.run(value)}
        let scan=try await call("langScan"),project:LanguageProject=try ResourceService.decode(scan);input["project"]=project.project;input["selected"]=project.sources.map(\.id)
        check("pipeline-scans-real-mod-KubeJS-FTB-world",Set(project.sources.map(\.kind)).isSuperset(of:["mods","loose","ftbquests","datapacks"]))
        check("pipeline-has-no-read-warnings",project.warnings.isEmpty)
        let live=config["live"] as? Bool==true
        let cache=ModTextTranslation(file:root.appendingPathComponent("cache/pipeline.json")){text,toChinese,provider in
            if live{return try await DomesticTranslation.query(text,toChinese:toChinese,provider:provider)}
            let fixture=["Ready":"就绪","Welcome":"欢迎","Collect":"收集","items.":"件物品。","A new beginning":"新的开始","Collect logs":"收集原木"]
            guard let value=fixture[text] else{throw FileTransactions.error("Unknown fixture source: "+text)};return value
        }
        var translated=0
        for _ in 0..<8 {
            let batch:PendingLanguageBatch=try ResourceService.decode(try await call("langPending",["limit":32]))
            if batch.entries.isEmpty{break}
            let result=try await OnlineLanguageTranslation.translate(batch.entries,provider:"bilibili"){try await cache.translate($0,provider:$1)}
            check("pipeline-each-row-translated",result.failures.isEmpty && result.changes.count==batch.entries.count)
            guard result.failures.isEmpty else{throw FileTransactions.error(result.failures.description)}
            let saved=try await call("langSave",["changes":result.changes,"onlyMissing":true,"origin":"machine"]);translated += saved["saved"] as? Int ?? 0
        }
        let remaining:PendingLanguageBatch=try ResourceService.decode(try await call("langPending",["limit":1]))
        check("pipeline-all-resource-kinds-complete",translated>=7 && remaining.pending==0)
        let export=root.appendingPathComponent("translated.zip"),pack=try await call("langExport",["packName":"Language QA","packFormat":15,"output":export.path])
        check("pipeline-export-zero-pending",pack["pending"] as? Int==0)
        let unzip=Process(),outputPipe=Pipe();unzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");unzip.arguments=["-p",export.path,"assets/kubeqa/lang/zh_cn.json"];unzip.standardOutput=outputPipe;try unzip.run();let data=outputPipe.fileHandleForReading.readDataToEndOfFile();unzip.waitUntilExit();let values=try JSONDecoder().decode([String:String].self,from:data)
        check("pipeline-export-keeps-placeholders",values["collect"]?.contains("%s")==true && values["collect"]?.range(of:"[\\p{Han}]",options:.regularExpression) != nil)
        let applied=try await call("langApply")
        check("pipeline-text-assets-applied-with-backup",(applied["files"] as? Int ?? 0)>=2 && (applied["backup"] as? String).map{FileManager.default.fileExists(atPath:$0)}==true)
        let quest=try String(contentsOf:run.appendingPathComponent("config/ftbquests/quests/chapters/qa.snbt"),encoding:.utf8)
        check("pipeline-FTB-visible-text-Chinese-IDs-unchanged",quest.contains("CHAPTER_QA") && quest.contains("QUEST_QA") && quest.range(of:"[\\p{Han}]",options:.regularExpression) != nil)
        let advancement=try JSONSerialization.jsonObject(with:Data(contentsOf:run.appendingPathComponent("saves/World/datapacks/story/data/story/advancements/start.json"))) as! [String:Any]
        check("pipeline-world-criteria-unchanged",(advancement["criteria"] as? [String:Any])?["unchanged"] != nil)
        check("pipeline-original-mod-unchanged",try Data(contentsOf:jar)==original)
        let report:[String:Any]=["liveDomesticTranslation":live,"passed":checks.values.filter{$0}.count,"failed":checks.values.filter{!$0}.count,"checks":checks]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.deletingLastPathComponent().appendingPathComponent("language-pipeline-report.json"))
        guard !checks.values.contains(false) else{throw FileTransactions.error("Localization pipeline failed")}
    }
}

// Geometry / optical composition preview, not a substitute for physical pointer or OS-version QA.
import AppKit
import SwiftUI
extension UpdateChecks {
    @MainActor static func folderPreview(root:URL)async throws {
        let resources=NativePaths.resources
        let entries=["grass","forge","fabric"].enumerated().map{n,name in ModCollectionEntry(id:"fixture-\(n)",title:name,icon:resources.appendingPathComponent("Loaders/"+name+".png").path,file:nil,project:nil,source:nil)}
        let folders=[ModCollection(id:"green",name:"优化模组",color:"#A7CDBB",entries:entries),ModCollection(id:"pink",name:"冒险与建造",color:"#D4BAC9",entries:entries.reversed()),ModCollection(id:"empty",name:"空模组夹",color:"#D7D7CE",entries:[])]
        for dark in [false,true] {
            let suite="net.morben.harbor.render-qa."+UUID().uuidString
            let store=UserDefaults(suiteName:suite)!
            let content=HStack(spacing:26){ForEach(folders){folder in ModFolderCard(folder:folder){}}}.padding(44).frame(width:950,height:340).background(dark ? Color(white:0.12):Color(white:0.94)).defaultAppStorage(store).environment(\.colorScheme,dark ? .dark:.light)
            let host=NSHostingView(rootView:content.environment(\.harborThemeRuntime,HarborThemeRuntime(settings:HarborThemeSettings(),appearance:dark ? .dark:.light,theme:Color(hex:0xA7CDBB))));if #available(macOS 13.0, *){host.sizingOptions=[]};host.frame=NSRect(x:0,y:0,width:950,height:340)
            let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.contentView=host;window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
            window.orderBack(nil);host.layoutSubtreeIfNeeded();window.displayIfNeeded();try await Task.sleep(nanoseconds:700_000_000);host.layoutSubtreeIfNeeded();host.displayIfNeeded()
            guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{throw FileTransactions.error("Folder preview failed")};host.cacheDisplay(in:host.bounds,to:bitmap)
            guard let data=bitmap.representation(using:.png,properties:[:]) else{throw FileTransactions.error("Folder preview encoding failed")}
            try data.write(to:root.appendingPathComponent("folders-"+(dark ? "dark":"light")+".png"));window.orderOut(nil);store.removePersistentDomain(forName:suite)
        }
        print("PASS folder-preview-two-schemes-three-tints-and-empty")
    }
}
