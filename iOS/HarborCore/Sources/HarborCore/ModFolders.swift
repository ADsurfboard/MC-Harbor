import Foundation
import CryptoKit
import Darwin

public struct FolderMod: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var filename: String
    public var version: String?
    public var loaders: [String]
    public var gameVersions: [String]
    public var summary: String?
    public var authors: String?
    public var collectedAt: Date
    public var hasIcon: Bool
    public init(id: String, name: String, filename: String, version: String? = nil,
                loaders: [String] = [], gameVersions: [String] = [], summary: String? = nil,
                authors: String? = nil, collectedAt: Date = Date(), hasIcon: Bool = false) {
        self.id = id; self.name = name; self.filename = filename; self.version = version
        self.loaders = loaders; self.gameVersions = gameVersions; self.summary = summary
        self.authors = authors; self.collectedAt = collectedAt; self.hasIcon = hasIcon
    }
}

public struct ModFolder: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var color: String
    public var mods: [FolderMod]
    public init(id: UUID = UUID(), name: String, color: String = "none", mods: [FolderMod] = []) {
        self.id = id; self.name = name; self.color = color; self.mods = mods
    }
}

public struct ModFolderSnapshot: Codable, Sendable {
    public var schema = 1
    public let identity: UUID
    public var folders: [ModFolder]
    public init(identity: UUID = UUID(), folders: [ModFolder] = []) {
        self.identity = identity; self.folders = folders
    }
}

/// Drag messages carry identities, never a path supplied by another app.
public struct FolderModDrag: Codable, Hashable, Sendable {
    public let library: UUID
    public let folder: UUID
    public let mods: [String]
    public init(library: UUID, folder: UUID, mods: [String]) {
        self.library = library; self.folder = folder; self.mods = mods
    }
}

public struct FolderModImport: Sendable {
    public let file: URL
    public let metadata: FolderMod?
    public let icon: Data?
    public let iconFile: URL?
    public init(file: URL, metadata: FolderMod? = nil, icon: Data? = nil, iconFile: URL? = nil) {
        self.file = file; self.metadata = metadata; self.icon = icon; self.iconFile = iconFile
    }
}

public enum ModFolderError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

/// All file copies and mutations run on this actor, away from the main actor.
/// Metadata is committed atomically after every file has been safely copied.
public actor ModFolderLibrary {
    public let root: URL
    private var state: ModFolderSnapshot
    private let fm = FileManager.default
    private var index: URL { root.appendingPathComponent("folders-v1.json") }
    private var files: URL { root.appendingPathComponent("files", isDirectory: true) }
    private var icons: URL { root.appendingPathComponent("icons", isDirectory: true) }

    public init(root: URL) throws {
        let fm = FileManager.default
        self.root = root.standardizedFileURL
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
        guard try self.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ModFolderError.invalid("模组夹目录不能是符号链接。")
        }
        let index = self.root.appendingPathComponent("folders-v1.json")
        if fm.fileExists(atPath: index.path) {
            let attributes = try index.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isSymbolicLink != true, (attributes.fileSize ?? .max) <= 8 * 1024 * 1024 else {
                throw ModFolderError.invalid("模组夹索引异常，原文件已保留。")
            }
            state = try JSONDecoder().decode(ModFolderSnapshot.self, from: Data(contentsOf: index))
        } else { state = ModFolderSnapshot() }
        try Self.validate(state)
    }
    public func snapshot() -> ModFolderSnapshot { state }
    private static func fail(_ message: String) -> ModFolderError { .invalid(message) }
    private static func validID(_ id: String) -> Bool {
        id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        value.count <= 120 && !value.unicodeScalars.contains { $0.value < 32 }
    }
    private static func validate(_ state: ModFolderSnapshot) throws {
        guard state.schema == 1, state.folders.count <= 200,
              Set(state.folders.map(\.id)).count == state.folders.count else {
            throw fail("不支持或损坏的模组夹索引，原文件已保留。")
        }
        for folder in state.folders {
            guard validName(folder.name), folder.name.count <= 60,
                  folder.color == "none" || folder.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
                  folder.mods.count <= 4000, Set(folder.mods.map(\.id)).count == folder.mods.count else {
                throw fail("模组夹名称、颜色或数量无效。")
            }
            for mod in folder.mods {
                guard validID(mod.id), validName(mod.name), mod.filename.count <= 240,
                      !mod.filename.contains("/"), !mod.filename.contains("\\"),
                      !mod.filename.contains(":"), (mod.filename as NSString).pathExtension.lowercased() == "jar",
                      !mod.filename.unicodeScalars.contains(where: { $0.value < 32 }),
                      (mod.version?.count ?? 0) <= 256, (mod.summary?.count ?? 0) <= 16_384,
                      (mod.authors?.count ?? 0) <= 2048, mod.loaders.count <= 16, mod.gameVersions.count <= 256,
                      mod.loaders.allSatisfy({ $0.count <= 120 }),
                      mod.gameVersions.allSatisfy({ $0.count <= 120 }) else {
                    throw fail("模组资料或收藏文件名无效。")
                }
            }
        }
    }
    private func commit(_ value: ModFolderSnapshot) throws {
        try Self.validate(value)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8 * 1024 * 1024 else { throw Self.fail("模组夹索引超过大小上限。") }
        try data.write(to: index, options: .atomic)
        state = value
    }
    @discardableResult public func create(name: String, color: String = "none") throws -> UUID {
        let folder = ModFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color)
        var value = state; value.folders.append(folder); try commit(value); return folder.id
    }
    public func update(_ id: UUID, name: String, color: String) throws {
        var value = state
        guard let i = value.folders.firstIndex(where: { $0.id == id }) else { throw Self.fail("模组夹已不存在。") }
        value.folders[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.folders[i].color = color
        try commit(value)
    }
    public func delete(_ id: UUID) throws {
        var value = state; value.folders.removeAll { $0.id == id }; try commit(value)
        // Retain content-addressed files: other folders may reference them.
    }
    public func remove(_ ids: Set<String>, from folder: UUID) throws {
        var value = state
        guard let i = value.folders.firstIndex(where: { $0.id == folder }) else { throw Self.fail("模组夹已不存在。") }
        value.folders[i].mods.removeAll { ids.contains($0.id) }
        try commit(value)
    }
    public func transfer(_ payload: FolderModDrag, to folder: UUID, at offset: Int? = nil, copy: Bool = false) throws {
        guard payload.library == state.identity, !payload.mods.isEmpty, payload.mods.count <= 4000,
              Set(payload.mods).count == payload.mods.count,
              let source = state.folders.firstIndex(where: { $0.id == payload.folder }),
              let target = state.folders.firstIndex(where: { $0.id == folder }) else {
            throw Self.fail("拖入内容不属于当前模组库，或模组夹已不存在。")
        }
        let ids = Set(payload.mods)
        let selected = state.folders[source].mods.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { throw Self.fail("拖动的模组已移动或移除，请重新选择。") }
        var value = state
        let oldCount = value.folders[target].mods.count
        let insertion = offset ?? oldCount
        guard insertion >= 0, insertion <= oldCount else { throw Self.fail("无效的模组排序位置。") }
        if source == target {
            let preceding = value.folders[target].mods.prefix(insertion).filter { ids.contains($0.id) }.count
            value.folders[target].mods.removeAll { ids.contains($0.id) }
            value.folders[target].mods.insert(contentsOf: selected, at: insertion - preceding)
        } else {
            let existing = Set(value.folders[target].mods.map(\.id))
            value.folders[target].mods.insert(contentsOf: selected.filter { !existing.contains($0.id) }, at: insertion)
            if !copy { value.folders[source].mods.removeAll { ids.contains($0.id) } }
        }
        try commit(value)
    }
    private func ensureDirectory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw Self.fail("收藏目录包含符号链接，已停止操作。")
        }
    }
    private func streamCopy(_ source: URL, to target: URL?) throws -> String {
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.fail("无法读取模组文件，符号链接不能导入。") }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 4, attributes.st_size <= 1_000_000_000 else {
            throw Self.fail("模组必须是小于 1 GB 的普通 JAR 文件。")
        }
        var output: FileHandle?
        if let target {
            let space = try fm.attributesOfFileSystem(forPath: target.deletingLastPathComponent().path)
            guard let free = space[.systemFreeSize] as? NSNumber,
                  free.uint64Value > UInt64(attributes.st_size) + 512 * 1024 * 1024 else {
                throw Self.fail("空间不足，已停止复制并保留原文件。")
            }
            guard fm.createFile(atPath: target.path, contents: nil) else { throw Self.fail("无法创建收藏副本。") }
            output = try FileHandle(forWritingTo: target)
        }
        defer { try? output?.close() }
        var hasher = SHA256(); var total = 0
        while let chunk = try autoreleasepool(invoking: { try input.read(upToCount: 64 * 1024) }), !chunk.isEmpty {
            try Task.checkCancellation()
            if total == 0 {
                guard chunk.count >= 4, Array(chunk.prefix(4)) == [0x50, 0x4b, 0x03, 0x04] else {
                    throw Self.fail("文件不是可读取的 JAR / ZIP 模组。")
                }
            }
            total += chunk.count
            guard total <= attributes.st_size else { throw Self.fail("读取过程中模组大小发生变化。") }
            hasher.update(data: chunk); try output?.write(contentsOf: chunk)
        }
        guard total == attributes.st_size else { throw Self.fail("模组读取不完整，请重新选择。") }
        try output?.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    @discardableResult public func importFiles(_ imports: [FolderModImport], to folder: UUID) throws -> Int {
        guard imports.count <= 4000, let i = state.folders.firstIndex(where: { $0.id == folder }) else {
            throw Self.fail("目标模组夹已不存在或一次导入的文件过多。")
        }
        try ensureDirectory(files); try ensureDirectory(icons)
        var value = state; var newFiles: [URL] = []; var staged: [URL] = []; var added = 0
        do {
            for item in imports {
                try Task.checkCancellation()
                guard item.file.isFileURL, item.file.pathExtension.lowercased() == "jar" else { throw Self.fail("请选择 .jar 模组文件。") }
                guard try item.file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw Self.fail("不能收藏符号链接，原文件未改动。")
                }
                let temporary = files.appendingPathComponent(".import-" + UUID().uuidString)
                staged.append(temporary)
                let scoped = item.file.startAccessingSecurityScopedResource()
                defer { if scoped { item.file.stopAccessingSecurityScopedResource() } }
                var hash: String?
                var readFailure: Error?
                var coordinationFailure: NSError?
                NSFileCoordinator().coordinate(readingItemAt: item.file, options: .withoutChanges,
                                               error: &coordinationFailure) { coordinated in
                    do { hash = try streamCopy(coordinated, to: temporary) }
                    catch { readFailure = error }
                }
                if let error = coordinationFailure ?? (readFailure as NSError?) { throw error }
                guard let hash else { throw Self.fail("文件提供程序没有返回可读取的模组。") }
                let destination = files.appendingPathComponent(hash + ".jar")
                if !fm.fileExists(atPath: destination.path) {
                    try fm.moveItem(at: temporary, to: destination); newFiles.append(destination)
                } else if try streamCopy(destination, to: nil) != hash {
                    throw Self.fail("已有收藏副本损坏，已保留原件并停止导入。")
                }
                guard !value.folders[i].mods.contains(where: { $0.id == hash }) else { continue }
                var mod = item.metadata ?? FolderMod(id: hash, name: item.file.deletingPathExtension().lastPathComponent,
                                                     filename: item.file.lastPathComponent)
                mod.id = hash; mod.filename = item.file.lastPathComponent; mod.collectedAt = Date(); mod.hasIcon = false
                var iconData = item.icon
                if let url = item.iconFile {
                    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                    guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? .max) <= 512 * 1024 else {
                        throw Self.fail("临时图标文件异常，已停止导入。")
                    }
                    iconData = try Data(contentsOf: url)
                }
                if let data = iconData, !data.isEmpty, data.count <= 512 * 1024 {
                    let icon = icons.appendingPathComponent(hash + ".png")
                    if !fm.fileExists(atPath: icon.path) { try data.write(to: icon, options: .atomic); newFiles.append(icon) }
                    mod.hasIcon = true
                }
                value.folders[i].mods.append(mod); added += 1
            }
            try commit(value)
            for file in staged { try? fm.removeItem(at: file) }
            return added
        } catch {
            for file in staged + newFiles { try? fm.removeItem(at: file) }
            throw error
        }
    }
    public func fileURL(for id: String) throws -> URL {
        guard Self.validID(id), state.folders.contains(where: { $0.mods.contains(where: { $0.id == id }) }) else {
            throw Self.fail("收藏模组已不存在。")
        }
        return files.appendingPathComponent(id + ".jar")
    }
    /// Stage the entire selection and roll back only our newly installed files.
    /// Existing instance mods are never overwritten, even on case-sensitive CI.
    @discardableResult public func install(_ ids: Set<String>, from folder: UUID, to directory: URL) throws -> Int {
        guard let source = state.folders.first(where: { $0.id == folder }), !ids.isEmpty else {
            throw Self.fail("请选择需要导入的模组。")
        }
        let mods = source.mods.filter { ids.contains($0.id) }
        guard mods.count == ids.count, directory.isFileURL else { throw Self.fail("选择已变化，请重新打开模组夹。") }
        try ensureDirectory(directory)
        let staging = directory.appendingPathComponent(".harbor-add-" + UUID().uuidString, isDirectory: true)
        try ensureDirectory(staging)
        defer { try? fm.removeItem(at: staging) }
        let canonical: (String) -> String = { $0.precomposedStringWithCanonicalMapping.lowercased() }
        var names = Set<String>()
        let existing = try fm.contentsOfDirectory(atPath: directory.path)
        var planned: [(URL, URL)] = []
        for mod in mods {
            try Task.checkCancellation()
            guard names.insert(canonical(mod.filename)).inserted else {
                throw Self.fail("所选模组有同名文件，请分别导入或调整选择。")
            }
            if let name = existing.first(where: { canonical($0) == canonical(mod.filename) }) {
                guard try streamCopy(directory.appendingPathComponent(name), to: nil) == mod.id else {
                    throw Self.fail("实例已有不同内容的 \(mod.filename)，不会覆盖。")
                }
                continue
            }
            let temporary = staging.appendingPathComponent(mod.filename)
            guard try streamCopy(files.appendingPathComponent(mod.id + ".jar"), to: temporary) == mod.id else {
                throw Self.fail("收藏副本校验失败，请重新收藏此模组。")
            }
            planned.append((temporary, directory.appendingPathComponent(mod.filename)))
        }
        var created: [URL] = []
        do {
            for (temporary, target) in planned {
                try Task.checkCancellation()
                // moveItem refuses an intervening file instead of replacing it.
                try fm.moveItem(at: temporary, to: target); created.append(target)
            }
            return created.count
        } catch {
            for target in created { try? fm.removeItem(at: target) }
            throw error
        }
    }
}
