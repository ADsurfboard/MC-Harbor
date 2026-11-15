import Foundation

public struct HarborWallpaper: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public let filename: String
    public let video: Bool
    public let added: Date
}
public struct HarborWallpaperSnapshot: Codable, Sendable {
    public var items: [HarborWallpaper] = []
    public var selected: UUID?
    public init() {}
}
public struct WallpaperPreparedMedia: Sendable {
    public let original: URL
    public let thumbnail: Data
    public let fileExtension: String
    public let video: Bool
    init(original: URL, thumbnail: Data, fileExtension: String, video: Bool) {
        self.original = original; self.thumbnail = thumbnail; self.fileExtension = fileExtension; self.video = video
    }
}

/// Only a validated, copied file can become a wallpaper. Loading a missing or
/// corrupt item cannot force-unwrap a URL/image or change the current choice.
public actor WallpaperLibrary {
    private let root: URL
    private let index: URL
    private var snapshot: HarborWallpaperSnapshot?
    public init(home: URL) {
        root = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("harbor-wallpapers")
        index = root.appendingPathComponent("library.json")
    }
    private func safe(_ file: URL) throws {
        guard file.path == file.resolvingSymlinksInPath().path, file == root || file.path.hasPrefix(root.path + "/") else { throw ResourceError.invalid("壁纸库包含符号链接或越界路径。") }
    }
    public func load() throws -> HarborWallpaperSnapshot {
        if let snapshot { return snapshot }
        try safe(root); try safe(index)
        let loaded: HarborWallpaperSnapshot
        if FileManager.default.fileExists(atPath: index.path) {
            let properties = try index.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard properties.isRegularFile == true, (properties.fileSize ?? Int.max) <= 1024 * 1024 else { throw ResourceError.invalid("壁纸库索引无效，原文件已保留。") }
            loaded = try JSONDecoder().decode(HarborWallpaperSnapshot.self, from: Data(contentsOf: index))
        } else { loaded = .init() }
        var ids: Set<UUID> = [], names: Set<String> = []
        guard loaded.items.count <= 500 else { throw ResourceError.invalid("壁纸库条目超过 500。") }
        for item in loaded.items {
            guard validName(item.name), item.filename == item.id.uuidString + "." + URL(fileURLWithPath: item.filename).pathExtension,
                  Self.extensions.contains(URL(fileURLWithPath: item.filename).pathExtension), ids.insert(item.id).inserted,
                  item.video == ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: item.filename).pathExtension),
                  names.insert(item.filename.lowercased()).inserted else { throw ResourceError.invalid("壁纸库索引包含无效条目。") }
        }
        if let selected = loaded.selected, !ids.contains(selected) { throw ResourceError.invalid("当前壁纸索引已失效，原文件已保留。") }
        snapshot = loaded; return loaded
    }
    public func media(_ item: HarborWallpaper) throws -> URL {
        let current = try load()
        guard current.items.contains(where: { $0.id == item.id && $0.filename == item.filename }) else { throw ResourceError.invalid("壁纸已不存在，请刷新壁纸库。") }
        let path = root.appendingPathComponent(item.filename); try safe(path)
        let properties = try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, let size = properties.fileSize, size > 0, size <= (item.video ? 512 : 50) * 1024 * 1024 else { throw ResourceError.invalid("壁纸文件缺失、损坏或过大。") }
        return path
    }
    public func preview(_ id: UUID) throws -> Data {
        guard try load().items.contains(where: { $0.id == id }) else { throw ResourceError.invalid("壁纸已不存在。") }
        let path = root.appendingPathComponent(id.uuidString + ".preview.png"); try safe(path)
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw ResourceError.invalid("壁纸预览文件损坏。") }
        return try Data(contentsOf: path)
    }
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "mp4", "mov", "m4v"]
    private func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 80 && !value.unicodeScalars.contains { $0.value < 32 }
    }
    private func commit(_ value: HarborWallpaperSnapshot) throws {
        try safe(index); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: index, options: .atomic); snapshot = value
    }
    public func add(_ media: WallpaperPreparedMedia, name: String) throws -> HarborWallpaper {
        var current = try load()
        let ext = media.fileExtension.lowercased()
        guard current.items.count < 500, validName(name), Self.extensions.contains(ext), media.thumbnail.count <= 4 * 1024 * 1024,
              !media.thumbnail.isEmpty, media.video == ["mp4", "mov", "m4v"].contains(ext) else { throw ResourceError.invalid("壁纸名称、格式或预览无效。") }
        let values = try media.original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard media.original.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= (media.video ? 512 : 50) * 1024 * 1024 else { throw ResourceError.invalid("请选择有效的本地图片或视频。图片上限 50 MB，视频上限 512 MB。") }
        try safe(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID(), filename = id.uuidString + "." + ext
        let file = root.appendingPathComponent(filename), preview = root.appendingPathComponent(id.uuidString + ".preview.png")
        try safe(file); try safe(preview)
        do {
            try Task.checkCancellation(); try FileManager.default.copyItem(at: media.original, to: file)
            try safe(file)
            let copied = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard copied.isRegularFile == true, copied.fileSize == size else { throw ResourceError.invalid("壁纸复制未完整完成，原件已保留。") }
            try media.thumbnail.write(to: preview, options: .withoutOverwriting)
            try Task.checkCancellation()
            let item = HarborWallpaper(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), filename: filename, video: media.video, added: Date())
            current.items.append(item); try commit(current); return item
        } catch {
            try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: preview); throw error
        }
    }
    public func rename(_ id: UUID, name: String) throws {
        var current = try load()
        guard validName(name), let index = current.items.firstIndex(where: { $0.id == id }) else { throw ResourceError.invalid("壁纸名称无效或条目已删除。") }
        current.items[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); try commit(current)
    }
    public func select(_ id: UUID?) throws {
        var current = try load()
        if let id {
            guard let item = current.items.first(where: { $0.id == id }) else { throw ResourceError.invalid("壁纸已不存在。") }
            _ = try media(item)
        }
        current.selected = id; try commit(current)
    }
    public func remove(_ id: UUID) throws {
        var current = try load()
        guard let item = current.items.first(where: { $0.id == id }) else { return }
        let file = root.appendingPathComponent(item.filename), preview = root.appendingPathComponent(id.uuidString + ".preview.png")
        try safe(file); try safe(preview)
        current.items.removeAll { $0.id == id }; if current.selected == id { current.selected = nil }
        // Persist the valid index first. A failed deletion may leave only owned
        // orphaned bytes, never an index referring to a partially removed item.
        try commit(current)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        if FileManager.default.fileExists(atPath: preview.path) { try FileManager.default.removeItem(at: preview) }
    }
}
