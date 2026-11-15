import Foundation
import CryptoKit
import Darwin

public enum WorldEditValue: Sendable, Equatable {
    case text(String), number(Double)
    public var text: String {
        switch self {
        case .text(let value): value
        case .number(let value): value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.9g", value)
        }
    }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
}
public struct WorldEditPlayer: Sendable, Identifiable {
    public let id: String
    public let name: String
}
public struct WorldEditFolder: Sendable, Identifiable {
    public let id: String
    public let modified: Date?
}
public struct WorldEditSnapshot: Sendable {
    public let folder: String
    public let revision: String
    public let version: String
    public let player: String
    public let players: [WorldEditPlayer]
    public let values: [String: WorldEditValue]
    public let warnings: [String]
    public let backup: URL?
    fileprivate var documents: [WorldEditDocument]
    fileprivate var playerCopies: [WorldEditPlayerCopy]
}
private struct WorldEditDocument: Sendable { let relative: String; let file: URL; let document: WorldNBTDocument }
private struct WorldEditPlayerCopy: Sendable { let file: String; let path: [String] }

public actor WorldEditorStore {
    private let instance: URL
    private let home: URL
    private let beforeReplace: (@Sendable (Int) throws -> Void)?
    public init(instance: URL, home: URL, beforeReplace: (@Sendable (Int) throws -> Void)? = nil) {
        self.instance = instance.standardizedFileURL.resolvingSymlinksInPath()
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.beforeReplace = beforeReplace
    }
    private func safe(_ url: URL, beneath root: URL) throws {
        guard url.path.hasPrefix(root.path + "/"), url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw ResourceError.invalid("存档路径包含符号链接或超出实例。") }
    }
    private func world(_ name: String) throws -> URL {
        try safe(instance, beneath: home)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { throw ResourceError.invalid("存档目录无效。") }
        let root = instance.appendingPathComponent("saves", isDirectory: true), folder = root.appendingPathComponent(name, isDirectory: true)
        try safe(root, beneath: instance); try safe(folder, beneath: root)
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ResourceError.invalid("存档目录已不存在。") }
        return folder
    }
    public func worlds() throws -> [WorldEditFolder] {
        try safe(instance, beneath: home)
        let root = instance.appendingPathComponent("saves", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }; try safe(root, beneath: instance)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard files.count <= 2048 else { throw ResourceError.invalid("存档目录超过 2048 个，请分批整理。") }
        var result: [WorldEditFolder] = []
        for entry in files {
            let file = entry.standardizedFileURL, values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }; try safe(file, beneath: root)
            let level = file.appendingPathComponent("level.dat")
            if FileManager.default.fileExists(atPath: level.path) {
                try safe(level, beneath: file)
                let values = try level.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                if values.isRegularFile == true { result.append(.init(id: file.lastPathComponent, modified: values.contentModificationDate)) }
            }
        }
        return result.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }
    private func locked<T>(_ folder: URL, _ action: () throws -> T) throws -> T {
        let path = folder.appendingPathComponent("session.lock"); try safe(path, beneath: folder)
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ResourceError.invalid("无法取得存档锁，请退出游戏后重试。") }; defer { close(descriptor) }
        var lock = flock(); lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET); lock.l_start = 0; lock.l_len = 0
        guard fcntl(descriptor, F_SETLK, &lock) == 0 else { throw ResourceError.invalid("存档正在被其他游戏进程使用，请退出该世界后再编辑。") }
        return try action()
    }
    private func readFile(_ file: URL, folder: URL, checkCancellation: Bool = true) throws -> Data {
        try safe(file, beneath: folder)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ResourceError.invalid("无法读取存档元数据：" + file.lastPathComponent) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 16 * 1024 * 1024 else { throw ResourceError.invalid("存档元数据不是普通文件或超过 16 MB。") }
        var data = Data()
        while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
            if checkCancellation { try Task.checkCancellation() }
            guard data.count <= 16 * 1024 * 1024 - bytes.count else { throw ResourceError.invalid("读取时存档元数据超过 16 MB。") }; data.append(bytes)
        }
        guard data.count == Int(info.st_size) else { throw ResourceError.invalid("读取过程中存档元数据发生变化，请重新读取。") }; return data
    }
    public func read(folder: String, player: String? = nil) throws -> WorldEditSnapshot {
        let location = try world(folder)
        return try locked(location) { publicSummary(try snapshot(folder: location, selected: player)) }
    }
    private func publicSummary(_ value: WorldEditSnapshot) -> WorldEditSnapshot {
        var value = value
        // UI/drafts retain only editable values and revision, not megabytes of
        // player/mod metadata. A save always re-reads under the session lock.
        value.documents = []; value.playerCopies = []; return value
    }
    private func snapshot(folder: URL, selected: String?, backup: URL? = nil) throws -> WorldEditSnapshot {
        let levelURL = folder.appendingPathComponent("level.dat"), level = try WorldNBTDocument(readFile(levelURL, folder: folder))
        guard let data = try level.root.child("Data"), data.type == 10 else { throw ResourceError.invalid("无法找到 Java 版存档的 Data 复合节点，原件未修改。") }
        let embedded = try data.child("Player")
        var files: [String: URL] = [:], choices: [WorldEditPlayer] = []
        if embedded?.type == 10 { choices.append(.init(id: "level", name: "本地玩家 · level.dat")) }
        let players = folder.appendingPathComponent("playerdata", isDirectory: true)
        if FileManager.default.fileExists(atPath: players.path) {
            try safe(players, beneath: folder)
            let values = try FileManager.default.contentsOfDirectory(at: players, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.count <= 4096 else { throw ResourceError.invalid("玩家数据超过 4096 个，请先整理后编辑。") }
            for entry in values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where entry.pathExtension.lowercased() == "dat" {
                guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent)?.uuidString.lowercased() else { continue }
                let file = entry.standardizedFileURL; try safe(file, beneath: folder)
                let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true, files[id] == nil else { throw ResourceError.invalid("玩家数据不是普通文件或 UUID 路径重复。") }
                files[id] = file; choices.append(.init(id: id, name: id))
            }
        }
        let chosen = selected.flatMap { $0.isEmpty ? nil : $0 } ?? choices.first?.id ?? ""
        guard chosen.isEmpty || choices.contains(where: { $0.id == chosen }) else { throw ResourceError.invalid("所选玩家已不存在，请重新选择。") }
        var documents = [WorldEditDocument(relative: "level.dat", file: levelURL, document: level)], copies: [WorldEditPlayerCopy] = []
        var playerDocument: WorldNBTDocument?, playerNode: WorldNBTNode?
        var embeddedUUID: String?
        if let embedded, embedded.type == 10 {
            if let uuid = try embedded.child("UUID") { embeddedUUID = try level.uuid(uuid)?.uuidString.lowercased() }
            if embeddedUUID == nil, let most = try embedded.child("UUIDMost"), let least = try embedded.child("UUIDLeast") {
                let a = UInt64(bitPattern: try level.integer(most)), b = UInt64(bitPattern: try level.integer(least))
                let hex = String(format: "%016llx%016llx", a, b)
                let parts = [8, 4, 4, 4, 12]; var at = hex.startIndex, joined: [String] = []
                for count in parts { let end = hex.index(at, offsetBy: count); joined.append(String(hex[at..<end])); at = end }; embeddedUUID = joined.joined(separator: "-")
            }
        }
        let externalID = chosen == "level" ? embeddedUUID : chosen
        if let id = externalID, let file = files[id] {
            let external = try WorldNBTDocument(readFile(file, folder: folder)), relative = "playerdata/" + file.lastPathComponent
            if let uuid = try external.root.child("UUID"), try external.uuid(uuid)?.uuidString.lowercased() != id {
                throw ResourceError.invalid("玩家 UUID 与文件名不一致，已停止编辑并保留原件。")
            }
            documents.append(.init(relative: relative, file: file, document: external)); copies.append(.init(file: relative, path: []))
            if chosen != "level" { playerDocument = external; playerNode = external.root }
        }
        if chosen == "level" || !chosen.isEmpty && chosen == embeddedUUID {
            copies.append(.init(file: "level.dat", path: ["Data", "Player"]))
            if chosen == "level" { playerDocument = level; playerNode = embedded }
        }
        var hash = SHA256()
        hash.update(data: Data(folder.path.utf8)); hash.update(data: Data([0]))
        for document in documents { hash.update(data: Data(document.relative.utf8)); hash.update(data: Data([0])); hash.update(data: document.document.original) }
        var values: [String: WorldEditValue] = [:], warnings: [String] = []
        if let name = try data.child("LevelName") { do { values["name"] = .text(try level.string(name)) } catch { warnings.append("存档名称无法安全解码，已保留原值。") } }
        func expose(_ document: WorldNBTDocument, _ node: WorldNBTNode, _ key: String, _ field: String) throws {
            guard let value = try node.child(field) else { return }
            if let number = try? document.number(value), number.isFinite, abs(number) <= 9_007_199_254_740_991 { values[key] = .number(number) }
            else { warnings.append(field + " 使用不受支持的数值类型，已保留原值。") }
        }
        for (key, field) in [("gameMode", "GameType"), ("difficulty", "Difficulty"), ("hardcore", "hardcore"), ("cheats", "allowCommands"), ("ageTicks", "Time")] { try expose(level, data, key, field) }
        if let time = try data.child("DayTime"), let ticks = try? level.integer(time), ticks >= 0, ticks <= 9_007_199_254_740_991 { values["day"] = .number(Double(ticks / 24000)); values["dayTick"] = .number(Double(ticks % 24000)) }
        if let playerDocument, let playerNode {
            for (key, field) in [("health", "Health"), ("hunger", "foodLevel"), ("saturation", "foodSaturationLevel"), ("xpLevel", "XpLevel"), ("xpProgress", "XpP"), ("xpTotal", "XpTotal")] { try expose(playerDocument, playerNode, key, field) }
        }
        let version: String
        if let node = try data.at(["Version", "Name"]), let name = try? level.string(node) { version = name } else { version = "未知版本" }
        return .init(folder: folder.lastPathComponent, revision: hash.finalize().map { String(format: "%02x", $0) }.joined(), version: version, player: chosen,
                     players: choices, values: values, warnings: warnings, backup: backup, documents: documents, playerCopies: copies)
    }
    public func save(folder: String, player: String?, revision: String, changes: [String: WorldEditValue]) throws -> WorldEditSnapshot {
        let location = try world(folder)
        return try locked(location) {
            let before = try snapshot(folder: location, selected: player)
            guard before.revision == revision else { throw ResourceError.invalid("存档已被其他程序更新，请重新读取后再编辑。") }
            let allowed: Set<String> = ["name", "gameMode", "difficulty", "hardcore", "cheats", "day", "dayTick", "ageTicks", "health", "hunger", "saturation", "xpLevel", "xpProgress"]
            guard !changes.isEmpty, changes.keys.allSatisfy(allowed.contains) else { throw ResourceError.invalid("没有有效修改，或包含不支持的编辑项。") }
            var replacements: [String: [WorldNBTReplacement]] = [:]
            func number(_ key: String, min: Double, max: Double, integer: Bool) throws -> Double? {
                guard let input = changes[key] else { return nil }
                guard let value = input.number, value.isFinite, value >= min, value <= max, !integer || value.rounded(.towardZero) == value else { throw ResourceError.invalid("数值超出范围：" + key) }; return value
            }
            func set(_ file: String, _ path: [String], _ value: Double, optional: Bool = false) throws {
                guard let document = before.documents.first(where: { $0.relative == file }) else { throw ResourceError.invalid("玩家元数据已失效。") }
                guard let node = try document.document.root.at(path) else { if optional { return }; throw ResourceError.invalid("此存档缺少可编辑字段：" + path.joined(separator: "/")) }
                replacements[file, default: []].append(try .number(node, value))
            }
            if let input = changes["name"] {
                guard case .text(let raw) = input else { throw ResourceError.invalid("存档名称必须是文字。") }
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.utf16.count <= 256, let node = try before.documents[0].document.root.at(["Data", "LevelName"]) else { throw ResourceError.invalid("存档名称须为 1–256 个字符，且此存档必须支持名称字段。") }
                replacements["level.dat", default: []].append(try .string(node, name))
            }
            for (key, field, maximum) in [("gameMode", "GameType", 3.0), ("difficulty", "Difficulty", 3), ("hardcore", "hardcore", 1), ("cheats", "allowCommands", 1), ("ageTicks", "Time", 9_007_199_254_740_991)] {
                if let value = try number(key, min: 0, max: maximum, integer: true) { try set("level.dat", ["Data", field], value) }
            }
            if changes["day"] != nil || changes["dayTick"] != nil {
                guard let time = try before.documents[0].document.root.at(["Data", "DayTime"]) else { throw ResourceError.invalid("此存档缺少昼夜时间字段。") }
                let old = try before.documents[0].document.integer(time)
                guard old >= 0 else { throw ResourceError.invalid("原有昼夜时间为负数，请在游戏中恢复后再编辑。") }
                let day = try number("day", min: 0, max: 375_299_968_945, integer: true) ?? Double(old / 24000)
                let tick = try number("dayTick", min: 0, max: 23999, integer: true) ?? Double(old % 24000)
                let combined = day * 24000 + tick
                guard combined <= 9_007_199_254_740_991 else { throw ResourceError.invalid("游戏天数超出安全范围。") }; try set("level.dat", ["Data", "DayTime"], combined)
            }
            let playerFields: Set<String> = ["health", "hunger", "saturation", "xpLevel", "xpProgress"]
            guard changes.keys.allSatisfy({ !playerFields.contains($0) }) || !before.playerCopies.isEmpty else { throw ResourceError.invalid("此存档没有所选玩家数据，请进入游戏保存一次后再编辑。") }
            for copy in before.playerCopies {
                guard let document = before.documents.first(where: { $0.relative == copy.file }), let node = try document.document.root.at(copy.path) else { throw ResourceError.invalid("所选玩家结构不受支持。") }
                for (key, field, maximum, integral) in [("health", "Health", 1_000_000.0, false), ("hunger", "foodLevel", 20, true), ("saturation", "foodSaturationLevel", 20, false)] {
                    if let value = try number(key, min: 0, max: maximum, integer: integral) { try set(copy.file, copy.path + [field], value) }
                }
                if changes["xpLevel"] != nil || changes["xpProgress"] != nil {
                    guard let levelTag = try node.child("XpLevel"), let progressTag = try node.child("XpP") else { throw ResourceError.invalid("所选玩家缺少经验字段。") }
                    let level = try number("xpLevel", min: 0, max: 21863, integer: true) ?? document.document.number(levelTag)
                    let progress = try number("xpProgress", min: 0, max: Double(Float(1).nextDown), integer: false) ?? document.document.number(progressTag)
                    guard level.isFinite, progress.isFinite, level >= 0, level <= 21863, level.rounded() == level, progress >= 0, progress < 1 else { throw ResourceError.invalid("原有经验值不受支持。") }
                    let base = level <= 16 ? level * level + 6 * level : level <= 31 ? 2.5 * level * level - 40.5 * level + 360 : 4.5 * level * level - 162.5 * level + 2220
                    let next = level >= 30 ? 112 + (level - 30) * 9 : level >= 15 ? 37 + (level - 15) * 5 : 7 + 2 * level
                    let total = base + floor(next * progress)
                    guard total <= Double(Int32.max) else { throw ResourceError.invalid("经验总量超出 Minecraft 整数范围。") }
                    try set(copy.file, copy.path + ["XpLevel"], level); try set(copy.file, copy.path + ["XpP"], progress); try set(copy.file, copy.path + ["XpTotal"], total, optional: true)
                }
                if let mode = try number("gameMode", min: 0, max: 3, integer: true) {
                    try set(copy.file, copy.path + ["playerGameType"], mode, optional: true)
                    if let abilities = try node.child("abilities"), abilities.type == 10 {
                        for (key, flag) in [("mayfly", mode == 1 || mode == 3), ("invulnerable", mode == 1 || mode == 3), ("instabuild", mode == 1), ("mayBuild", mode == 0 || mode == 1)] {
                            try set(copy.file, copy.path + ["abilities", key], flag ? 1 : 0, optional: true)
                        }
                        if mode != 1 { try set(copy.file, copy.path + ["abilities", "flying"], mode == 3 ? 1 : 0, optional: true) }
                    }
                }
            }
            return publicSummary(try commit(before, replacements: replacements, folder: location))
        }
    }
    private func commit(_ before: WorldEditSnapshot, replacements: [String: [WorldNBTReplacement]], folder: URL) throws -> WorldEditSnapshot {
        let fm = FileManager.default
        var updates: [(WorldEditDocument, Data)] = []
        for document in before.documents {
            if let edits = replacements[document.relative], !edits.isEmpty { updates.append((document, try document.document.encoded(replacements: edits))) }
        }
        guard !updates.isEmpty else { throw ResourceError.invalid("没有可保存的修改。") }
        let backupHome = home.appendingPathComponent("harbor-world-backups", isDirectory: true); try safe(backupHome, beneath: home)
        try fm.createDirectory(at: backupHome, withIntermediateDirectories: true)
        let backup = backupHome.appendingPathComponent(UUID().uuidString + ".zip")
        var entries = updates.map { LocalizationExportEntry(path: $0.0.relative, data: $0.0.document.original) }
        let manifest: [String: Any] = ["world": before.folder, "sourceRevision": before.revision, "player": before.player, "restore": "Close Minecraft and restore these original files into this world's directory."]
        entries.append(.init(path: "MC-Harbor-world-backup.json", data: try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])))
        try LocalizationZIP.write(entries, to: backup)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        var stages: [String: URL] = [:], committed: [(WorldEditDocument, Data)] = []
        defer { for file in stages.values { try? fm.removeItem(at: file) } }
        do {
            for (document, bytes) in updates {
                try Task.checkCancellation()
                guard try readFile(document.file, folder: folder) == document.document.original else { throw ResourceError.invalid("保存前存档已变化，请重新读取。") }
                let stage = document.file.deletingLastPathComponent().appendingPathComponent(".harbor-world-" + UUID().uuidString + ".tmp")
                try safe(stage, beneath: folder); try bytes.write(to: stage, options: .withoutOverwriting); stages[document.relative] = stage
                let attributes = try fm.attributesOfItem(atPath: document.file.path)
                var preserved: [FileAttributeKey: Any] = [:]
                if let mode = attributes[.posixPermissions] { preserved[.posixPermissions] = mode }
                #if os(iOS)
                if let protection = attributes[.protectionKey] { preserved[.protectionKey] = protection }
                #endif
                try fm.setAttributes(preserved, ofItemAtPath: stage.path)
                let handle = try FileHandle(forWritingTo: stage); defer { try? handle.close() }; try handle.synchronize()
                guard try readFile(stage, folder: folder) == bytes else { throw ResourceError.invalid("存档暂存写入后校验失败。") }
            }
            for (index, update) in updates.enumerated() {
                let (document, bytes) = update
                try Task.checkCancellation(); try safe(document.file, beneath: folder)
                guard try readFile(document.file, folder: folder) == document.document.original, let stage = stages[document.relative] else { throw ResourceError.invalid("应用时存档发生变化，已停止。") }
                try beforeReplace?(index)
                guard rename(stage.path, document.file.path) == 0 else { throw ResourceError.invalid("无法原子替换存档元数据。") }; committed.append((document, bytes))
            }
            for (document, bytes) in updates {
                guard try readFile(document.file, folder: folder) == bytes else { throw ResourceError.invalid("存档替换后校验失败，已停止并恢复本次改动。") }
            }
            return try snapshot(folder: folder, selected: before.player, backup: backup)
        } catch {
            var failed: [String] = []
            for (document, bytes) in committed.reversed() {
                do {
                    // Recovery must remain possible after the user cancels;
                    // the read guard still checks path/type/size/content.
                    guard try readFile(document.file, folder: folder, checkCancellation: false) == bytes else { failed.append(document.relative); continue }
                    let attributes = try fm.attributesOfItem(atPath: document.file.path)
                    try document.document.original.write(to: document.file, options: .atomic)
                    var preserved: [FileAttributeKey: Any] = [:]
                    if let mode = attributes[.posixPermissions] { preserved[.posixPermissions] = mode }
                    #if os(iOS)
                    if let protection = attributes[.protectionKey] { preserved[.protectionKey] = protection }
                    #endif
                    try fm.setAttributes(preserved, ofItemAtPath: document.file.path)
                } catch { failed.append(document.relative) }
            }
            if !failed.isEmpty { throw ResourceError.invalid("部分文件需要手动从备份恢复：" + failed.joined(separator: "、") + "；备份：" + backup.lastPathComponent) }
            throw error
        }
    }
}
