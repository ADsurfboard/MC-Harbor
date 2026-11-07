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
        }else{
            let cache=root.appendingPathComponent("cache/mod-text-translations.json");try FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(["en|zh-CN|Public mod summary":"模组公开简介"]).write(to:cache)
            check("cached-description-without-network",try await ModTextTranslation.shared.translate("Public mod summary")=="模组公开简介")
        }

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
        check("theme-settings-persist",try JSONDecoder().decode(HarborThemeSettings.self,from:JSONEncoder().encode(settings))==settings)
        guard failed==0 else{exit(1)}
    }
}
