import CryptoKit
import AppKit
import Foundation
import SwiftUI

extension UpdateChecks {
    @MainActor static func discovery(_ config:[String:Any],root:URL)async throws {
        var failed=0
        func check(_ name:String,_ value:Bool){print((value ? "PASS ":"FAIL ")+name);if !value{failed+=1};fflush(stdout)}
        let library=root.appendingPathComponent("game");let folder=library.appendingPathComponent("versions/中文实例 🌱")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let game=GameInstance(id:"中文实例 🌱",version:"1.20.1",loader:"Fabric",directory:folder.path,runDirectory:folder.path,iconPath:nil,modified:Date())
        check("Chinese-known-name",await ModTextTranslation.searchQuery(" 钠 ")=="sodium")
        check("English-query-unchanged",await ModTextTranslation.searchQuery("Sodium")=="Sodium")
        check("Chinese-complex-name",await ModTextTranslation.searchQuery("机械动力")=="Create")
        let mod=ModFile(id:"test",name:"Sodium",path:folder.appendingPathComponent("sodium-0.5.jar"),enabled:true,size:1,modID:"sodium")
        check("installed-recommendation",ModDiscovery.installed(ModDiscovery.catalog[0],mods:[mod]))
        check("uninstalled-recommendation",!ModDiscovery.installed(ModDiscovery.catalog[1],mods:[mod]))
        let destination=root.appendingPathComponent("中文快捷方式.webloc")
        try InstanceShortcuts.create(game:game,library:library.path,destination:destination)
        let plist=try PropertyListSerialization.propertyList(from:Data(contentsOf:destination),format:nil) as! [String:String]
        let url=URL(string:plist["URL"]!)!,target=try InstanceShortcuts.target(for:url)
        check("shortcut-unicode-instance",target.instance==game.id)
        check("shortcut-correct-library",target.library==library.path)
        check("shortcut-no-private-path-in-URL",!url.absoluteString.contains(root.path))
        let attributes=try FileManager.default.attributesOfItem(atPath:InstanceShortcuts.manifest.path)
        check("shortcut-private-manifest",(attributes[.posixPermissions] as? Int)==0o600)
        for bad in ["mcharbor://launch/"+UUID().uuidString,url.absoluteString+"?id=other","https://launch/"+url.lastPathComponent]{check("reject-unregistered-or-altered-shortcut",(try? InstanceShortcuts.target(for:URL(string:bad)!))==nil)}
        do{try InstanceShortcuts.create(game:game,library:library.path,destination:root.appendingPathComponent("bad.command"));check("reject-executable-shortcut",false)}catch{check("reject-executable-shortcut",true)}
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
            var summaries=["en|zh-CN|Public mod summary":"模组公开简介"]
            for index in 0..<240{summaries["en|zh-CN|QA summary "+String(index)]="汉化简介 "+String(index)}
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
