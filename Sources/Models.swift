import AppKit
import SwiftUI
import UniformTypeIdentifiers

public enum HarborAppearance: String, Codable, CaseIterable, Identifiable {
    case dark, light, ultraClear
    public var id: String { rawValue }
    var title: String { switch self { case .dark: return "深色"; case .light: return "浅色"; case .ultraClear: return "通透" } }
}
public enum WallpaperKind: String, Codable, CaseIterable, Identifiable {
    case harbor, image, video
    public var id: String { rawValue }
}
public struct WallpaperSettings: Codable, Equatable {
    public var kind: WallpaperKind = .harbor
    public var filePath: String? = nil
    public var transparency: Double = 0.86
    public var dimming: Double = 0.04
    public var blur: Double = 0
    public var backdropBlur: Double = 28
}
struct NativePreferences: Codable {
    var themeHex = "#29825B"
    var glassClarity: Double = 0.82
    var rainbowCorners = true
    var knownLibraries:[String] = []
    var appearance: HarborAppearance = .ultraClear
    var wallpaper = WallpaperSettings()
    var fluidBackground = false
    var reduceMotion = false
    var gameRoot = "/Applications/.minecraft"
    var selectedGame = "冻土"
    var favorites: Set<String> = []
    var memory = 3072
    var javaPath = "/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home/bin/java"
    var downloadSource = "auto"
    var downloadThreads = 8
    var completeDependencies = false
    var introEnabled = true
    var voiceEnabled = true
    var introVolume: Double = 0.65
    var username = "张少"
    var introDuration: Double = 4.8
    var soundsEnabled = true
    var soundVolume: Double = 0.48
    var instanceOptions: [String:InstanceOptions] = [:]
    var nickname: [String:String] = [:]
    var instanceIcons:[String:String] = [:]
    var selectedAccount: String? = nil
    var microsoftClientID = ""
}
struct InstanceOptions: Codable {
    var memory = 0
    var javaPath = ""
    var jvmArguments = ""
    var fullscreen = false
    var width = 1280
    var height = 800
}
enum ContentKind: String, CaseIterable, Identifiable {
    case mods, resourcepacks, shaderpacks
    case worlds="saves",modpacks
    var id:String { rawValue }
    var title:String { switch self {case .mods:return "模组";case .resourcepacks:return "资源包";case .shaderpacks:return "光影";case .worlds:return "地图";case .modpacks:return "整合包"} }
    var projectType:String { switch self {case .mods:return "mod";case .resourcepacks:return "resourcepack";case .shaderpacks:return "shader";case .worlds:return "world";case .modpacks:return "modpack"} }
    var symbol:String { switch self {case .mods:return "puzzlepiece.extension";case .resourcepacks:return "square.stack.3d.up";case .shaderpacks:return "sun.max";case .worlds:return "globe.europe.africa";case .modpacks:return "shippingbox"} }
}
enum HarborModal: Identifiable {
    case install(RemoteGame), offline, addons(GameInstance,ContentKind),worldEditor(GameInstance,LocalContent)
    var id:String {switch self {case .install(let v):return "install-"+v.id;case .offline:return "offline";case .addons(let g,let k):return "addons-"+g.id+k.rawValue;case .worldEditor(let g,let w):return "world-"+g.id+w.id}}
}
struct GameInstance: Identifiable, Hashable, Sendable {
    let id: String
    let version: String
    let loader: String
    let directory: String
    let runDirectory: String
    let iconPath: String?
    let modified: Date
}
struct RemoteGame: Codable, Identifiable, Sendable {
    let id: String
    let type: String
    let url: String
    let sha1: String?
    let releaseTime: String?
}
struct VersionManifest: Codable { let versions: [RemoteGame] }
struct LauncherAccount: Codable, Identifiable {
    var id: String
    var name: String
    var kind: String
    var uuid: String
}
struct ModFile: Identifiable { let id: String; let name: String; let path: URL; let enabled: Bool; let size: Int64; var version = ""; var authors = ""; var modID = "";var iconPath:String? = nil }
struct WorkItem: Identifiable { let id=UUID(); var title: String; var detail=""; var progress: Double? = nil; var active=true; var error=false }
enum NativeSection: String, CaseIterable, Identifiable {
    case library, downloads, accounts, settings
    var id: String { rawValue }
    var title: String { switch self { case .library:return "游戏";case .downloads:return "下载";case .accounts:return "账号";case .settings:return "设置" } }
    var icon: String { switch self { case .library:return "square.stack.3d.up";case .downloads:return "arrow.down.circle";case .accounts:return "person.crop.circle";case .settings:return "slider.horizontal.3" } }
}
enum NativePaths {
    static var root: URL {
        if let value=ProcessInfo.processInfo.environment["SHENGGAN_DATA_DIR"] { return URL(fileURLWithPath:value,isDirectory:true) }
        let parent=Bundle.main.bundleURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath:parent.appendingPathComponent("MCHarbor.portable").path) { return parent.appendingPathComponent("MCHarborData",isDirectory:true) }
        if FileManager.default.fileExists(atPath:parent.appendingPathComponent("Shenggan.portable").path) { return parent.appendingPathComponent("ShengganData",isDirectory:true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ShengganLauncher",isDirectory:true)
    }
    static var resources: URL {if let path=ProcessInfo.processInfo.environment["SHENGGAN_BACKEND_RESOURCES"]{return URL(fileURLWithPath:path)};return Bundle.main.resourceURL! }
    static func prepare() { try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
}
enum NativeScanner {
    static func scan(_ root: String) -> [GameInstance] {
        let base=URL(fileURLWithPath:root,isDirectory:true)
        let dirs=(try? FileManager.default.contentsOfDirectory(at:base.appendingPathComponent("versions"),includingPropertiesForKeys:[.contentModificationDateKey],options:[.skipsHiddenFiles])) ?? []
        return dirs.compactMap { dir -> GameInstance? in
            let id=dir.lastPathComponent
            guard let data=try? Data(contentsOf:dir.appendingPathComponent(id+".json")),let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return nil}
            let libs=(json["libraries"] as? [[String:Any]] ?? []).compactMap{$0["name"] as? String}.joined(separator:" ").lowercased()
            let patches=(json["patches"] as? [[String:Any]] ?? [])
            let patchNames=patches.compactMap{$0["id"] as? String}.joined(separator:" ").lowercased()
            let all=libs+" "+patchNames
            let loader=all.contains("cleanroom") ? "Cleanroom" : all.contains("neoforge") ? "NeoForge" : all.contains("quilt") ? "Quilt" : all.contains("legacyfabric") ? "Legacy Fabric" : all.contains("forge") ? "Forge" : all.contains("fabric") ? "Fabric" : "Minecraft"
            let v=(json["gameVersion"] as? String) ?? patches.first(where:{$0["id"] as? String == "game"})?["version"] as? String ?? (json["inheritsFrom"] as? String) ?? id
            let originalConfig=readJSON(dir.appendingPathComponent(".hmcl/config/instance-game-settings.json"))
            let overrides=originalConfig["overrideProperties"] as? [String] ?? []
            let global=readJSON(base.deletingLastPathComponent().appendingPathComponent(".hmcl/config/game-settings.json"))
            let presets=global["presets"] as? [[String:Any]] ?? []
            let parent=(presets.first { ($0["id"] as? String) == (originalConfig["parent"] as? String) }) ?? presets.first ?? [:]
            let defaultIsolation=parent["defaultIsolationType"] as? String ?? "MODDED"
            var isolated=defaultIsolation == "ALWAYS" || (defaultIsolation == "MODDED" && loader != "Minecraft")
            var customRun=parent["runningDirectory"] as? String ?? ""
            if overrides.contains("runningDirectory") || !(originalConfig["runningDirectory"] as? String ?? "").isEmpty { isolated=true;customRun=originalConfig["runningDirectory"] as? String ?? "" }
            if FileManager.default.fileExists(atPath:dir.appendingPathComponent("modpack.json").path) {isolated=true;customRun=""}
            let legacy=readJSON(dir.appendingPathComponent("hmclversion.cfg"))
            if originalConfig.isEmpty,let type=legacy["gameDirType"] as? Int { isolated=type != 0;if type==2 {customRun=legacy["gameDir"] as? String ?? ""} }
            let run=customRun.isEmpty ? (isolated ? dir.path:root):customRun
            let icon=["icon.png","icon.jpg",".hmcl/icon.png"].map{dir.appendingPathComponent($0).path}.first{FileManager.default.fileExists(atPath:$0)}
            return GameInstance(id:id,version:v,loader:loader,directory:dir.path,runDirectory:run,iconPath:icon,modified:(try? dir.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted{$0.modified > $1.modified}
    }
    static func readJSON(_ url:URL)->[String:Any] {guard let bytes=try? Data(contentsOf:url) else{return [:]};return (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]}
    static func mods(_ game: GameInstance) -> [ModFile] {
        let paths=(try? FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:game.runDirectory).appendingPathComponent("mods"),includingPropertiesForKeys:[.fileSizeKey],options:[.skipsHiddenFiles])) ?? []
        return paths.filter{$0.lastPathComponent.hasSuffix(".jar") || $0.lastPathComponent.hasSuffix(".jar.disabled")}.map{p in ModFile(id:p.path,name:p.lastPathComponent.replacingOccurrences(of:".disabled",with:""),path:p,enabled:p.pathExtension != "disabled",size:Int64((try? p.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0))}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
}
