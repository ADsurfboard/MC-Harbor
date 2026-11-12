import CryptoKit
import AppKit
import Foundation
import SwiftUI

private actor TranslationProbe {
    var calls=0,active=0,peak=0;var inputs:[String]=[]
    func query(_ text:String,_ toChinese:Bool,_ provider:String)async throws->String{
        calls+=1;active+=1;peak=max(peak,active);inputs.append(text);defer{active-=1}
        try await Task.sleep(nanoseconds:40_000_000)
        if text=="Failure row"{throw FileTransactions.error("Fixture service refused this row")}
        return toChinese ? "译文 "+provider+" "+text:"Organize inventory"
    }
    func snapshot()->(Int,Int,[String]){(calls,peak,inputs)}
}

extension UpdateChecks {
    @MainActor static func discovery(_ config:[String:Any],root:URL)async throws {
        var failed=0
        func check(_ name:String,_ value:Bool){print((value ? "PASS ":"FAIL ")+name);if !value{failed+=1};fflush(stdout)}
        let library=root.appendingPathComponent("game");let folder=library.appendingPathComponent("versions/中文实例 🌱")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let game=GameInstance(id:"中文实例 🌱",version:"1.20.1",loader:"Fabric",directory:folder.path,runDirectory:folder.path,iconPath:nil,modified:Date())
        check("Chinese-known-name",await ModTextTranslation.searchQuery(" 钠 ")=="sodium")
        check("offline-Chinese-index-proper-mod-name",await ModTextTranslation.searchQuery("连锁采集")=="Vein Mining")
        check("offline-Chinese-index-not-literal",await ModTextTranslation.searchQuery("雕凿工艺")=="Chisels & Bits")
        check("English-query-unchanged",await ModTextTranslation.searchQuery("Sodium")=="Sodium")
        check("Chinese-complex-name",await ModTextTranslation.searchQuery("机械动力")=="Create")
        check("all-search-title-Sodium-Chinese",await ModNameIndex.shared.chinese(title:"Sodium")=="钠")
        check("all-search-title-slug-exact",await ModNameIndex.shared.chinese(title:"Just Enough Items (JEI)",slug:"jei")=="JEI物品管理器")
        check("all-search-title-index-beyond-recommendations",await ModNameIndex.shared.chinese(title:"Chisels & Bits")=="雕凿工艺")
        check("different-project-never-matched-by-prefix",await ModNameIndex.shared.chinese(title:"Create: Unrelated QA Addon")==nil)
        let fixtureIndexFile=root.appendingPathComponent("name-index.txt")
        try "sodium;;sodium;钠;Sodium\n".write(to:fixtureIndexFile,atomically:true,encoding:.utf8)
        let fixtureIndex=ModNameIndex(file:fixtureIndexFile)
        check("index-first-read",await fixtureIndex.chinese(title:"Sodium")=="钠")
        try FileManager.default.removeItem(at:fixtureIndexFile)
        var indexed=true
        for _ in 0..<100{if await fixtureIndex.chinese(title:"Sodium") != "钠"{indexed=false}}
        check("indexed-name-lookup-not-rescanned-after-source-removed",indexed)
        let probe=TranslationProbe(),cache=ModTextTranslation(file:root.appendingPathComponent("cache/probe.json")){try await probe.query($0,$1,$2)}
        let duplicateValues=try await withThrowingTaskGroup(of:String.self,returning:[String].self){group in
            for _ in 0..<30{group.addTask{try await cache.translate("Same summary",provider:"bilibili")}}
            var values:[String]=[];for try await value in group{values.append(value)};return values
        }
        check("thirty-identical-requests-coalesced",await probe.snapshot().0==1 && Set(duplicateValues).count==1)
        try await withThrowingTaskGroup(of:Void.self){group in for n in 0..<12{group.addTask{_ = try await cache.translate("Unique summary "+String(n),provider:"bilibili")}};try await group.waitForAll()}
        check("translation-global-concurrency-bounded",await probe.snapshot().1<=3)
        _ = try await cache.translate("Same summary",provider:"mymemory")
        check("provider-cache-separated",await probe.snapshot().0==14)
        check("Chinese-only-query-segments-are-translated",try await cache.translate("整理背包",toChinese:false,provider:"bilibili")=="Organize inventory")
        check("reverse-translation-protects-identifiers",TranslationText.parts("收集 %s",toChinese:false).contains{!$0.translate && $0.text=="%s"})
        let protected=try await cache.translate("Collect %1$s at {0} with §a color",provider:"bilibili")
        check("cached-translation-preserves-tokens",protected.contains("%1$s") && protected.contains("{0}") && protected.contains("§a"))
        check("placeholders-not-sent-to-provider",await probe.snapshot().2.allSatisfy{!$0.contains("%1$s") && !$0.contains("{0}") && !$0.contains("§a")})
        let cancelOwner=Task{try await cache.translate("Cancelled shared summary",provider:"bilibili")}
        try await Task.sleep(nanoseconds:5_000_000);cancelOwner.cancel()
        let survivor=try await cache.translate("Cancelled shared summary",provider:"bilibili")
        do{_ = try await cancelOwner.value;check("cancelled-consumer-stays-cancelled",false)}catch is CancellationError{check("cancelled-consumer-stays-cancelled",true)}
        check("shared-request-survives-other-consumer-cancellation",survivor.contains("译文"))
        let metadataCache=ResourceMetadataCache(),metadataProbe=TranslationProbe()
        let metadata=try await withThrowingTaskGroup(of:Data.self,returning:[Data].self){group in
            for _ in 0..<20{group.addTask{try await metadataCache.data("public-get"){Data(try await metadataProbe.query("metadata",true,"bilibili").utf8)}}}
            var results:[Data]=[];for try await value in group{results.append(value)};return results
        }
        check("public-metadata-request-coalescing",await metadataProbe.snapshot().0==1 && Set(metadata).count==1)
        _ = try await metadataCache.data("public-get",ttl:0){Data(try await metadataProbe.query("metadata",true,"bilibili").utf8)}
        check("metadata-TTL-refreshes",await metadataProbe.snapshot().0==2)
        let beforeStop=await probe.snapshot().0
        let stopped=Task{try await cache.translate("Stop this sole consumer",provider:"bilibili")}
        for _ in 0..<50{if await probe.snapshot().0>beforeStop{break};try await Task.sleep(nanoseconds:1_000_000)}
        stopped.cancel()
        do{_ = try await stopped.value;check("last-consumer-can-cancel-work",false)}catch is CancellationError{check("last-consumer-can-cancel-work",true)}
        let samples=(0..<200).map{FolderFlowField.sample(x:Double($0%20)/20,y:Double($0/20)/10,time:123.4)}
        check("flow-field-bounded",samples.allSatisfy{(0...1).contains($0)})
        check("flow-field-actually-moves",FolderFlowField.sample(x:0.3,y:0.7,time:0) != FolderFlowField.sample(x:0.3,y:0.7,time:7))
        func paletteImage(_ rgba:[UInt8],width:Int,height:Int)throws->CGImage{
            guard let space=CGColorSpace(name:CGColorSpace.sRGB),let provider=CGDataProvider(data:Data(rgba) as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else{throw FileTransactions.error("Palette fixture failed")};return image
        }
        let red=FolderColorPair.RGB(r:1,g:0,b:0),blue=FolderColorPair.RGB(r:0,g:0,b:1)
        let split=try paletteImage(Array(repeating:[UInt8(255),0,0,255],count:20).flatMap{$0}+Array(repeating:[UInt8(0),0,255,255],count:20).flatMap{$0},width:40,height:1)
        let pair=FolderColorPair.analyze(split)
        check("palette-extracts-two-original-core-colours",pair.map{($0.first.distance(red)<0.01 && $0.second.distance(blue)<0.01)||($0.first.distance(blue)<0.01 && $0.second.distance(red)<0.01)}==true)
        let alphaImage=try paletteImage(Array(repeating:[UInt8(128),0,0,128],count:20).flatMap{$0}+Array(repeating:[UInt8(0),255,0,0],count:20).flatMap{$0},width:40,height:1)
        let alpha=FolderColorPair.analyze(alphaImage)
        check("palette-ignores-transparent-RGB-and-unpremultiplies",alpha.map{$0.first.distance(red)<0.001 && $0.second.distance(red)<0.001}==true)
        check("palette-empty-alpha-has-no-invented-colours",FolderColorPair.analyze(try paletteImage([0,0,0,0],width:1,height:1))==nil)
        check("palette-deterministic",pair==FolderColorPair.analyze(split))
        check("fluid-colours-stay-on-source-two-tone-line",samples.allSatisfy{let rgb=red.mixed(with:blue,amount:$0);return rgb.g==0 && abs(rgb.r+rgb.b-1)<0.00001})
        let iconFile=root.appendingPathComponent("palette-local.png")
        try NSBitmapImageRep(cgImage:split).representation(using:.png,properties:[:])!.write(to:iconFile)
        let visuals=await withTaskGroup(of:CollectionVisual?.self,returning:[CollectionVisual].self){group in for _ in 0..<16{group.addTask{await CollectionArtworkLoader.shared.visual(iconFile.path)}};var values:[CollectionVisual]=[];for await value in group{if let value{values.append(value)}};return values}
        check("artwork-single-decode-shared-across-sixteen-consumers",visuals.count==16 && visuals.allSatisfy{$0.bitmap.image === visuals[0].bitmap.image})
        check("artwork-loader-delivers-source-palette",visuals.first?.colors==pair)
        let batchEntries=[PendingLanguageEntry(resource:"qa",id:"ok",source:"Success row"),PendingLanguageEntry(resource:"qa",id:"bad",source:"Failure row")]
        let batch=try await OnlineLanguageTranslation.translate(batchEntries,provider:"bilibili"){try await probe.query($0,true,$1)}
        check("one-refused-row-keeps-other-success",batch.changes.count==1 && batch.failures["qa/bad"] != nil)
        try await Task.sleep(nanoseconds:650_000_000)
        let restoredTranslationCache=ModTextTranslation(file:root.appendingPathComponent("cache/probe.json")){_,_,_ in throw FileTransactions.error("No network allowed")}
        check("debounced-cache-restores-without-network",try await restoredTranslationCache.translate("Same summary",provider:"bilibili")==duplicateValues.first)
        check("summary-loading-never-displays-English",ModSummaryPresentation.state(text:"English summary",enabled:true,original:false,value:nil,failed:false) == .loading)
        check("summary-failure-never-displays-English",ModSummaryPresentation.state(text:"English summary",enabled:true,original:false,value:nil,failed:true) == .failed)
        check("summary-translated-only-when-ready",ModSummaryPresentation.state(text:"English summary",enabled:true,original:false,value:"中文简介",failed:false) == .translated("中文简介"))
        check("summary-toggle-off-keeps-original",ModSummaryPresentation.state(text:"English summary",enabled:false,original:false,value:nil,failed:false) == .original("English summary"))
        check("summary-mixed-English-Chinese-is-processed",ModSummaryPresentation.needsTranslation("优化 and reduce memory"))
        check("foreign-providers-are-manually-selectable",Set(OnlineTranslationProvider.allCases.map(\.rawValue))==Set(["bilibili","aliyun","mymemory","google"]))
        let mod=ModFile(id:"test",name:"Sodium",path:folder.appendingPathComponent("sodium-0.5.jar"),enabled:true,size:1,modID:"sodium")
        check("installed-recommendation",ModDiscovery.installed(ModDiscovery.catalog[0],mods:[mod]))
        check("uninstalled-recommendation",!ModDiscovery.installed(ModDiscovery.catalog[1],mods:[mod]))
        let destination=root.appendingPathComponent("中文快捷方式.app")
        try InstanceShortcuts.create(game:game,library:library.path,destination:destination)
        let plist=try PropertyListSerialization.propertyList(from:Data(contentsOf:destination.appendingPathComponent("Contents/Info.plist")),format:nil) as! [String:Any]
        let url=URL(string:plist["HarborURL"] as! String)!,target=try InstanceShortcuts.target(for:url)
        check("shortcut-unicode-instance",target.instance==game.id)
        check("shortcut-correct-library",target.library==library.path)
        check("shortcut-no-private-path-in-URL",!url.absoluteString.contains(root.path))
        let attributes=try FileManager.default.attributesOfItem(atPath:InstanceShortcuts.manifest.path)
        check("shortcut-private-manifest",(attributes[.posixPermissions] as? Int)==0o600)
        for bad in ["mcharbor://launch/"+UUID().uuidString,url.absoluteString+"?id=other","https://launch/"+url.lastPathComponent]{check("reject-unregistered-or-altered-shortcut",(try? InstanceShortcuts.target(for:URL(string:bad)!))==nil)}
        do{try InstanceShortcuts.create(game:game,library:library.path,destination:root.appendingPathComponent("bad.command"));check("reject-executable-shortcut",false)}catch{check("reject-executable-shortcut",true)}
        check("shortcut-explicit-app-target",plist["HarborApplication"] as? String == Bundle.main.bundleURL.path)
        check("shortcut-bundled-executable",FileManager.default.isExecutableFile(atPath:destination.appendingPathComponent("Contents/MacOS/InstanceShortcut").path))
        check("shortcut-explicit-private-data-root",plist["HarborDataRoot"] as? String == NativePaths.root.standardizedFileURL.resolvingSymlinksInPath().path)
        try InstanceShortcutInbox.prepare()
        check("shortcut-inbox-private",(try FileManager.default.attributesOfItem(atPath:InstanceShortcutInbox.directory.path)[.posixPermissions] as? Int)==0o700)
        func enqueue(_ request:InstanceShortcutRequest)throws{try JSONEncoder().encode(request).write(to:InstanceShortcutInbox.directory.appendingPathComponent(UUID().uuidString+".json"),options:.atomic)}
        try enqueue(InstanceShortcutRequest(url:url.absoluteString,created:Date().timeIntervalSince1970))
        try enqueue(InstanceShortcutRequest(url:url.absoluteString,created:Date().timeIntervalSince1970-600))
        try enqueue(InstanceShortcutRequest(url:"mcharbor://launch/"+UUID().uuidString,created:Date().timeIntervalSince1970))
        try Data("invalid".utf8).write(to:InstanceShortcutInbox.directory.appendingPathComponent(UUID().uuidString+".json"))
        let inbox=try InstanceShortcutInbox.take()
        check("shortcut-inbox-only-valid-requests",inbox==[url])
        check("shortcut-inbox-consumed-once",try InstanceShortcutInbox.take().isEmpty)
        var notified=false
        let watcher=try InstanceShortcutWatcher{notified=true}
        try enqueue(InstanceShortcutRequest(url:url.absoluteString,created:Date().timeIntervalSince1970))
        for _ in 0..<40{if notified{break};try await Task.sleep(nanoseconds:50_000_000)}
        check("shortcut-inbox-filesystem-notifies",notified)
        check("shortcut-inbox-warm-request",try InstanceShortcutInbox.take()==[url])
        withExtendedLifetime(watcher){}
        let collections=ModCollectionStore(root:root.appendingPathComponent("collections"))
        let collectionID=try collections.create("优化 模组夹",color:"#ABCDEF")
        check("collection-create",collections.folders.count==1)
        try collections.update(collectionID,name:"PVP 配置",color:"#BDCDEF")
        check("collection-rename-recolor",collections.folders[0].name=="PVP 配置" && collections.folders[0].color=="#BDCDEF")
        let collectionProject=AddonProject(projectId:"AANobbMI",title:"Sodium",description:"Renderer",author:"QA",iconUrl:nil,downloads:1,pageUrl:nil)
        try collections.add(collectionProject,source:.modrinth,to:collectionID);try collections.add(collectionProject,source:.modrinth,to:collectionID)
        check("collection-duplicate-idempotent",collections.folders[0].entries.count==1)
        let recorded=collections.folders[0].entries[0]
        check("collection-records-time-summary-author",recorded.collectedAt != nil && recorded.summary=="Renderer" && recorded.authors=="QA")
        let legacyData=Data("{\"id\":\"legacy\",\"title\":\"Original name\"}".utf8)
        let legacyEntry=try JSONDecoder().decode(ModCollectionEntry.self,from:legacyData)
        check("collection-old-record-survives-new-optional-metadata",legacyEntry.title=="Original name" && legacyEntry.collectedAt==nil && legacyEntry.modVersion==nil)
        let batchID=try collections.create("全实例收藏")
        let files=(0..<3).map{n in folder.appendingPathComponent("mod-\(n).jar")}
        for (n,file) in files.enumerated(){try Data("unchanged-mod-\(n)".utf8).write(to:file)}
        let batchMods=files.enumerated().map{n,file in ModFile(id:file.path,name:"模组 \(n)",path:file,enabled:true,size:15,version:"1.2.\(n)",authors:"QA",summary:"Description")}
        check("collection-batch-all-mods-added",try await collections.addLocal(batchMods,to:batchID,game:game)==3)
        check("collection-batch-repeated-skips-duplicates",try await collections.addLocal(batchMods,to:batchID,game:game)==0)
        let batchFolder=collections.folders.first{$0.id==batchID}!
        check("collection-batch-keeps-versions-loader-time",batchFolder.entries.count==3 && batchFolder.entries.allSatisfy{$0.loaders==["Fabric"] && $0.gameVersions==["1.20.1"] && $0.modVersion?.hasPrefix("1.2.")==true && $0.collectedAt != nil})
        check("collection-batch-original-files-unchanged",try files.enumerated().allSatisfy{n,file in try Data(contentsOf:file)==Data("unchanged-mod-\(n)".utf8)})
        let minimal=CollectionDisplaySettings(icon:false,loader:false,modVersion:false,gameVersion:false,collectedAt:false,summary:false,authors:false)
        check("collection-name-only-settings-persist",try JSONDecoder().decode(CollectionDisplaySettings.self,from:JSONEncoder().encode(minimal)).isNameOnly)
        check("settings-search-finds-multi-keyword-mod-folder",HarborSettingsIndex.search("模组夹 图标").map(\.anchor)==["模组夹信息显示"])
        check("settings-search-finds-domestic-download-setting",HarborSettingsIndex.search("国内 下载").contains{$0.anchor=="下载"})
        check("settings-search-no-unrelated-placeholder",HarborSettingsIndex.search("不存在的QA设置").isEmpty)
        try collections.delete(batchID)
        let collectionRestored=ModCollectionStore(root:collections.root)
        check("collection-persists",collectionRestored.folders==collections.folders)
        try collections.remove(Set(["modrinth:AANobbMI"]),folder:collectionID)
        check("collection-remove",collections.folders[0].entries.isEmpty)
        do{try collections.update(collectionID,name:"",color:"#000000");check("collection-reject-empty-name",false)}catch{check("collection-reject-empty-name",true)}
        do{try collections.update(collectionID,name:"name",color:"invalid");check("collection-reject-invalid-color",false)}catch{check("collection-reject-invalid-color",true)}
        try collections.delete(collectionID);check("collection-delete",collections.folders.isEmpty)
        let complete=try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"stop","message":["content":"优化性能"]]]])
        check("domestic-translation-parse",try DomesticTranslation.parse(complete,source:"Improve performance",toChinese:true)=="优化性能")
        let partial=try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"length","message":["content":"部分译文"]]]])
        do{_ = try DomesticTranslation.parse(partial,source:"Improve performance",toChinese:true);check("reject-truncated-translation",false)}catch{check("reject-truncated-translation",true)}
        if config["live"] as? Bool==true {
            let hit=try await ResourceService.search(await ModTextTranslation.searchQuery("钠"),game:game,kind:.mods,source:.modrinth)
            check("live-Chinese-search-finds-Sodium",hit.hits.contains{$0.projectId=="AANobbMI"})
            let english=try await ResourceService.search("Sodium",game:game,kind:.mods,source:.modrinth)
            check("live-English-search-finds-Sodium",english.hits.contains{$0.projectId=="AANobbMI"})
            let recommendations=try await ModDiscovery.recommendations(game:game)
            check("live-recommendations-nonempty",recommendations.count>=3)
            for item in recommendations{
                let versions=try await ResourceService.versions(item.project.id,game:game,kind:.mods,source:.modrinth)
                check("live-compatible-"+item.suggestion.slug,versions.contains{$0.gameVersions.contains(game.version) && $0.loaders.contains("fabric")})
            }
            let translated=try await ModTextTranslation.shared.translate("View the recipes for every item.")
            check("live-description-Chinese",translated.range(of:"[\\p{Han}]",options:.regularExpression) != nil)
            check("live-description-cache",try await ModTextTranslation.shared.translate("View the recipes for every item.")==translated)
            let translatedQuery=await ModTextTranslation.searchQuery("整理背包")
            check("live-general-Chinese-query",translatedQuery.range(of:"[A-Za-z]",options:.regularExpression) != nil)
            for page in 0..<8 {
                let response=try await ResourceService.search("",game:game,kind:.mods,source:.modrinth,page:page)
                guard let project=response.hits.first(where:{$0.description.contains(" ") && !ModDiscovery.identifierOnly($0.description)}) else{check("live-page-"+String(page+1),false);continue}
                let chinese=try await ModTextTranslation.shared.translate(project.description)
                check("live-page-"+String(page+1),chinese.range(of:"[\\p{Han}]",options:.regularExpression) != nil)
            }
        }else{
            let cache=root.appendingPathComponent("cache/mod-text-translations.json");try FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
            var summaries=[DomesticTranslation.provider+"|en|zh-CN|Public mod summary":"模组公开简介"]
            for index in 0..<240{summaries[DomesticTranslation.provider+"|en|zh-CN|QA summary "+String(index)]="汉化简介 "+String(index)}
            try JSONEncoder().encode(summaries).write(to:cache)
            check("cached-description-without-network",try await ModTextTranslation.shared.translate("Public mod summary")=="模组公开简介")
        }

        if config["live"] as? Bool != true{
            for page in 0..<8{var complete=true;for row in 0..<30{let index=page*30+row;let value=try await ModTextTranslation.shared.translate("QA summary "+String(index));complete=complete && value=="汉化简介 "+String(index)};check("translation-page-"+String(page+1),complete)}
        }
        check("hashtag-kept-without-translation",try await ModTextTranslation.shared.translate("#listentonature")=="#listentonature")
        check("installed-mod-Chinese-name",ModDiscovery.chineseName(mod)=="钠")
        check("optimization-category",ModSection.optimization.facet=="optimization")
        check("pvp-search-section",ModSection.pvp.query("",source:.modrinth)=="pvp")
        check("CF-section-keyword",ModSection.optimization.query("fps",source:.curseforge)=="fps performance")
        let backup=Data(#"[[["优化游戏性能","Optimize game performance",null,null]],null,"en"]"#.utf8)
        check("backup-translation-parser",try PublicModTranslation.parseBackup(backup,source:"Optimize game performance")=="优化游戏性能")
        do{_ = try PublicModTranslation.parseBackup(Data(#"{"error":"quota"}"#.utf8),source:"Hello");check("backup-error-not-translation",false)}catch{check("backup-error-not-translation",true)}
        let bytes=Data("Harbor download test".utf8),hash=SHA512.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        let file=AddonFile(filename:"test.jar",url:"https://example.org/test.jar",size:Int64(bytes.count),hashes:["sha512":hash],primary:true)
        let transferTarget=root.appendingPathComponent("test.jar")
        var attempts=0
        _ = try await ResourceDownloadPolicy.perform(file,to:transferTarget,candidates:[file.url],progress:{_,_ in}){_,url in attempts+=1;if attempts==1{throw URLError(.timedOut)};try bytes.write(to:url);return url}
        let recoveredBytes=try Data(contentsOf:transferTarget)
        check("timeout-retried-and-verified",attempts==2 && recoveredBytes==bytes)
        try FileManager.default.removeItem(at:transferTarget);attempts=0
        _ = try await ResourceDownloadPolicy.perform(file,to:transferTarget,candidates:["https://mirror.example.org/test.jar"],progress:{_,_ in}){_,url in attempts+=1;try (attempts==1 ? Data("bad".utf8):bytes).write(to:url);return url}
        let fallbackBytes=try Data(contentsOf:transferTarget)
        check("corrupt-download-falls-back",attempts==2 && fallbackBytes==bytes)
        try FileManager.default.removeItem(at:transferTarget)
        let unsafe=AddonFile(filename:"test.jar",url:"http://example.org/test.jar",size:file.size,hashes:file.hashes,primary:true)
        do{_ = try await ResourceDownloadPolicy.perform(unsafe,to:transferTarget,candidates:[unsafe.url],progress:{_,_ in}){_,url in check("unsafe-fetch-not-called",false);return url};check("insecure-download-rejected",false)}catch{check("insecure-download-rejected",true)}
        let model=LauncherModel();model.running.insert(game.id);let waiting=WorkItem(title:"QA staged download");model.works.append(waiting)
        let waitTask=Task{try await model.waitForResourceInstall(game,jobID:waiting.id)}
        try await HarborDelay.sleep(seconds:0.08)
        check("running-game-defers-install",model.works.first{$0.id==waiting.id}?.detail.contains("等待")==true)
        model.resourceDownloadNotice(title:"Test mod",game:game)
        check("running-download-notice",model.downloadNotice?.contains("已开始下载")==true && model.downloadNotice?.contains("等待")==true)
        model.running.remove(game.id);try await waitTask.value
        check("game-exit-resumes-install",!model.running.contains(game.id))
        model.running.insert(game.id);let cancelWait=Task{try await model.waitForResourceInstall(game,jobID:waiting.id)};cancelWait.cancel()
        do{try await cancelWait.value;check("queued-install-cancellable",false)}catch is CancellationError{check("queued-install-cancellable",true)};model.running.remove(game.id)
        let owner=UUID(),other=UUID()
        try await model.beginResourceCommit(game,jobID:owner);model.finishResourceCommit(game,jobID:other)
        check("cancel-other-job-preserves-install-lock",model.resourceInstalling[model.resourceDirectoryKey(game)]?.contains(owner)==true)
        model.finishResourceCommit(game,jobID:owner)
        check("completed-job-releases-own-install-lock",model.resourceInstalling[model.resourceDirectoryKey(game)]==nil)
        let host=NSView(frame:NSRect(x:0,y:0,width:700,height:240)),table=NSTableView(frame:NSRect(x:0,y:0,width:700,height:240)),anchor=TableChromeView(minimumRowHeight:56)
        host.addSubview(table);host.addSubview(anchor);anchor.schedule();try await HarborDelay.sleep(seconds:0.08)
        check("Intel-mod-table-minimum-row-height",table.rowHeight>=56 && !table.usesAutomaticRowHeights)
        let store=ModRemarkStore(file:root.appendingPathComponent("remarks.json"))
        let optimization=try store.createList(" 常用优化 "),pvp=try store.createList("PVP")
        check("remark-list-name-trimmed",store.listName(optimization)=="常用优化")
        check("remark-list-deduplicated",try store.createList("常用优化")==optimization)
        let project=AddonProject(projectId:"AANobbMI",title:"Sodium",description:"Renderer",author:"Modrinth",iconUrl:nil,downloads:1,pageUrl:nil)
        try store.save(project:project,source:.modrinth,name:"流畅帧率",listID:optimization)
        try store.save(project:project,source:.modrinth,name:"竞技优化",listID:pvp)
        try store.save(project:project,source:.curseforge,name:"另一个来源",listID:pvp)
        check("remark-Chinese-search",store.matches("流畅").first?.project.id==project.id)
        check("remark-English-search",store.matches("sodium").count==3)
        check("remark-list-filter",store.matches("",listID:optimization).count==1)
        check("remark-sources-isolated",store.entry(project.id,source:.curseforge,listID:pvp)?.name=="另一个来源")
        let restored=ModRemarkStore(file:root.appendingPathComponent("remarks.json"))
        check("remarks-persist-restart",restored.matches("竞技").count==1 && restored.lists.count==3)
        try restored.remove(project.id,source:.modrinth,listID:pvp)
        check("remove-one-remark-preserves-others",restored.matches("Sodium").count==2)
        do{try store.save(project:project,source:.modrinth,name:"",listID:pvp);check("empty-remark-rejected",false)}catch{check("empty-remark-rejected",true)}
        var settings=HarborThemeSettings()
        settings.roles[HarborThemeArea.primaryText.rawValue] = .theme
        settings.roles[HarborThemeArea.accentText.rawValue] = .theme
        settings.roles[HarborThemeArea.icons.rawValue] = .inverse
        settings.roles[HarborThemeArea.buttonText.rawValue] = .inverse
        for light in [true,false]{
            let appearance:HarborAppearance=light ? .theme:.dark
            for hex in ["#C3E3D4","#C4DDD9","#D8E2BE","#D4D9D1","#E8D9BD","#E3D1DE"]{
                let runtime=HarborThemeRuntime(settings:settings,appearance:appearance,theme:Color(hexString:hex))
                check("theme-readable-"+hex+"-"+String(light),HarborColorContrast.ratio(NSColor(runtime.accentText),HarborColorContrast.reference(light:light))>=4.5)
                check("button-readable-"+hex+"-"+String(light),HarborColorContrast.ratio(NSColor(runtime.buttonInk),NSColor(runtime.buttonFill))>=4.5)
            }
        }
        settings.protectContrast=false;settings.roles["accentText"] = .custom;settings.custom["accentText"]="#123456"
        check("custom-role-applied",HarborThemeRuntime(settings:settings,appearance:.light,theme:.green).accentText.hexString=="#123456")
        settings.inverseMode = .rgb
        let inverse=NSColor(HarborThemeRuntime(settings:settings,appearance:.light,theme:Color(hex:0x336699)).inverse).usingColorSpace(.sRGB)!
        check("rgb-inverse",abs(inverse.redComponent-0.8)<0.015 && abs(inverse.greenComponent-0.6)<0.015 && abs(inverse.blueComponent-0.4)<0.015)
        settings.inverseMode = .custom;settings.inverseHex="#557799"
        check("custom-inverse",HarborThemeRuntime(settings:settings,appearance:.light,theme:.green).inverse.hexString=="#557799")
        check("native-control-readable",HarborColorContrast.ratio(NSColor(HarborThemeRuntime(settings:HarborThemeSettings(),appearance:.light,theme:Color(hex:0xC3E3D4)).controlTint),HarborColorContrast.reference(light:true))>=4.5)
        check("theme-settings-persist",try JSONDecoder().decode(HarborThemeSettings.self,from:JSONEncoder().encode(settings))==settings)
        guard failed==0 else{exit(1)}
    }
}
