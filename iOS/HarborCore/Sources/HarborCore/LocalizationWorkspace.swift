import Foundation
import CryptoKit

public struct LocalizationSource: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let installPath: String
    public let kind: String
    public var documents: [LocalizationDocument]
    public var originalFiles: [String: Data] = [:]
    public var selected: Bool = true
    public init(name: String, installPath: String, kind: String, documents: [LocalizationDocument]) {
        let sourceID = LocalizationDocument.digest(Data((kind + "/" + installPath).utf8))
        self.id = sourceID
        self.name = name; self.installPath = installPath; self.kind = kind
        self.documents = documents.map { value in
            var doc = value
            doc.rows = value.rows.map { row in
                .init(id: LocalizationDocument.digest(Data((sourceID + "/" + row.id).utf8)), key: row.key, source: row.source,
                      translation: row.translation, start: row.start, end: row.end)
            }
            return doc
        }
    }
}

public struct LocalizationProject: Codable, Sendable {
    public var name: String
    public var packFormat: Int
    public var sources: [LocalizationSource]
    public var warnings: [String]
    public init(name: String, packFormat: Int = 15, sources: [LocalizationSource] = [], warnings: [String] = []) {
        self.name = name; self.packFormat = packFormat; self.sources = sources; self.warnings = warnings
    }
    public var counts: (total: Int, translated: Int) {
        var total = 0, translated = 0
        for source in sources where source.selected { for doc in source.documents { for row in doc.rows {
            total += 1
            if !row.translation.isEmpty && LocalizationPlaceholders.compatible(row.source, row.translation) { translated += 1 }
        } } }
        return (total, translated)
    }
    public mutating func inheritDrafts(from previous: Self) {
        let drafts = Dictionary(previous.sources.flatMap(\.documents).flatMap(\.rows).filter { !$0.translation.isEmpty }.map { ($0.id, $0.translation) }, uniquingKeysWith: { first, _ in first })
        for s in sources.indices { for d in sources[s].documents.indices { for r in sources[s].documents[d].rows.indices {
            let row = sources[s].documents[d].rows[r]
            if let value = drafts[row.id], LocalizationPlaceholders.compatible(row.source, value) { sources[s].documents[d].rows[r].translation = value }
        } } }
    }
    public mutating func setTranslation(row id: String, value: String) throws {
        for s in sources.indices { for d in sources[s].documents.indices {
            if let r = sources[s].documents[d].rows.firstIndex(where: { $0.id == id }) {
                let row = sources[s].documents[d].rows[r]
                guard value.isEmpty || LocalizationPlaceholders.compatible(row.source, value) else { throw ResourceError.invalid("占位符 / 格式不符：" + row.key) }
                sources[s].documents[d].rows[r].translation = value; return
            }
        } }
        throw ResourceError.invalid("语言条目已变化，请重新读取。")
    }
}

public actor LocalizationWorkspaceStore {
    private let file: URL
    public init(home: URL, instance: String) {
        file = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("harbor-localization", isDirectory: true).appendingPathComponent(LocalizationDocument.digest(Data(instance.utf8)) + ".json")
    }
    public func load() throws -> LocalizationProject? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try safe()
        let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 96 * 1024 * 1024 else { throw ResourceError.invalid("汉化工作区过大或不是普通文件。") }
        return try JSONDecoder().decode(LocalizationProject.self, from: Data(contentsOf: file))
    }
    public func save(_ project: LocalizationProject) throws {
        try safe(); let data = try JSONEncoder().encode(project)
        guard data.count <= 96 * 1024 * 1024 else { throw ResourceError.invalid("汉化工作区超过 96 MB，请分批选择实例资源。") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    private func safe() throws {
        guard file.standardizedFileURL.path == file.resolvingSymlinksInPath().path else { throw ResourceError.invalid("汉化工作区包含符号链接，已停止。") }
    }
}

public struct LocalizationExportEntry: Sendable {
    public let path: String
    public let data: Data
    public init(path: String, data: Data) { self.path = path; self.data = data }
}

public enum LocalizationPack {
    public static func entries(_ project: LocalizationProject, sourceOnly: Bool) throws -> [LocalizationExportEntry] {
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, project.name.utf8.count <= 256,
              project.packFormat > 0, project.packFormat <= 10_000 else { throw ResourceError.invalid("请填写资源包名称和有效格式号。") }
        var entries: [LocalizationExportEntry] = []
        var language: [String: [String: String]] = [:]
        var textIndex: [[String: String]] = []
        for source in project.sources where source.selected {
            for doc in source.documents {
                let parts = doc.path.split(separator: "/").map(String.init)
                if (doc.kind == .languageJSON || doc.kind == .languageLegacy), parts.count == 4, parts[0] == "assets", parts[2] == "lang" {
                    let name = parts[3].lowercased()
                    guard name == "en_us.json" || name == "en_us.lang" || name == "en_gb.json" || name == "en_gb.lang" else { continue }
                    let target = "assets/" + parts[1] + "/lang/zh_cn." + (doc.kind == .languageLegacy ? "lang" : "json")
                    var values = language[target] ?? [:]
                    for row in doc.rows {
                        let value = sourceOnly || row.translation.isEmpty ? row.source : row.translation
                        guard sourceOnly || row.translation.isEmpty || LocalizationPlaceholders.compatible(row.source, value) else { throw ResourceError.invalid("译文格式不符：" + row.key) }
                        if let old = values[row.key], old != value { throw ResourceError.invalid("所选资源存在同名语言键冲突，请分开导出：" + parts[1] + "/" + row.key) }
                        values[row.key] = value
                    }
                    language[target] = values
                } else if !sourceOnly {
                    let rendered = try doc.rendered()
                    if rendered != doc.original {
                        let path = doc.kind == .ftbLocale ? Self.chinesePath(doc.path) : doc.path
                        let prefix = source.installPath.isEmpty ? "" : source.installPath + "/"
                        entries.append(.init(path: "overrides/" + prefix + path, data: rendered))
                    }
                }
                if sourceOnly {
                    if source.originalFiles[doc.path] == nil { entries.append(.init(path: "original/" + source.id + "/" + doc.path, data: doc.original)) }
                    for row in doc.rows { textIndex.append(["resource": source.name, "path": doc.path, "key": row.key, "source": row.source, "id": row.id, "translation": ""]) }
                }
            }
            if sourceOnly { for (path, data) in source.originalFiles { entries.append(.init(path: "original/" + source.id + "/" + path, data: data)) } }
        }
        for (path, values) in language {
            let data: Data
            if path.hasSuffix(".lang") {
                guard !values.values.contains(where: { $0.contains("\n") || $0.contains("\r") }) else { throw ResourceError.invalid("旧版 LANG 条目包含换行。") }
                data = Data(values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "\n").utf8)
            } else { data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
            entries.append(.init(path: path, data: data))
        }
        guard !entries.isEmpty else { throw ResourceError.invalid("没有可导出的语言或任务译文，请先读取并选择实例资源。") }
        let meta: [String: Any] = ["pack": ["pack_format": project.packFormat, "description": project.name + (sourceOnly ? " · 未汉化原文" : " · MC Harbor 汉化")]]
        entries.append(.init(path: "pack.mcmeta", data: try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])))
        if sourceOnly { entries.append(.init(path: "AI-translation.json", data: try JSONSerialization.data(withJSONObject: textIndex, options: [.prettyPrinted, .sortedKeys]))) }
        let instructions = sourceOnly ? "未汉化提取包。assets 中 zh_cn 的值仍为原文；original 保留所有选中文件；AI-translation.json 是条目索引。只翻译值，保留键和占位符。FTB / 数据包不能只靠资源包生效，译文须作为 overrides 合并到实例。" : "汉化包：游戏中启用此资源包。未完成的条目保留原文，不表示已完成。overrides 中是任务 / 数据包文本，需退出游戏并备份后按实例目录合并；资源包本身不会自动改写任务配置。原始模组未修改。"
        entries.append(.init(path: "MC-Harbor-README.txt", data: Data(instructions.utf8)))
        return entries
    }
    private static func chinesePath(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)(^|/)en_(?:us|gb)(?=/|\.)"#, with: "$1zh_cn", options: .regularExpression)
    }
}

/// Stored ZIP avoids shipping a second compression dependency. Bounded chunks
/// are streamed to a newly-created file; failed output is removed, not reused.
public enum LocalizationZIP {
    public static func write(_ entries: [LocalizationExportEntry], to output: URL) throws {
        guard entries.count <= 20_000, output.isFileURL else { throw ResourceError.invalid("导出条目过多或目标无效。") }
        var names: Set<String> = [], total = 0
        for entry in entries {
            try LocalizationDocument.validatePath(entry.path)
            guard entry.path.utf8.count <= 65_535, names.insert(entry.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  entry.data.count <= 24 * 1024 * 1024, total <= 96 * 1024 * 1024 - entry.data.count else { throw ResourceError.invalid("导出路径重复或文本超过安全上限。") }
            total += entry.data.count
        }
        guard output.path == output.resolvingSymlinksInPath().path else { throw ResourceError.invalid("导出目标不能包含符号链接。") }
        try Data().write(to: output, options: .withoutOverwriting)
        let file: FileHandle
        do { file = try FileHandle(forWritingTo: output) }
        catch { try? FileManager.default.removeItem(at: output); throw error }
        var completed = false
        defer { try? file.close(); if !completed { try? FileManager.default.removeItem(at: output) } }
        var expectedHash = SHA256()
        func write(_ data: Data) throws { try file.write(contentsOf: data); expectedHash.update(data: data) }
        var directory = Data(), offset: UInt32 = 0
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let name = Data(entry.path.utf8), size = UInt32(entry.data.count), crc = crc32(entry.data)
            var header = Data(); header.u32(0x04034b50); header.u16(20); header.u16(0x800); header.u16(0)
            header.u16(0); header.u16(0x21); header.u32(crc); header.u32(size); header.u32(size); header.u16(UInt16(name.count)); header.u16(0); header.append(name)
            try write(header); try write(entry.data)
            directory.u32(0x02014b50); directory.u16(20); directory.u16(20); directory.u16(0x800); directory.u16(0)
            directory.u16(0); directory.u16(0x21); directory.u32(crc); directory.u32(size); directory.u32(size); directory.u16(UInt16(name.count)); directory.u16(0)
            directory.u16(0); directory.u16(0); directory.u16(0); directory.u32(0); directory.u32(offset); directory.append(name)
            offset += UInt32(header.count) + size
        }
        try write(directory)
        var end = Data(); end.u32(0x06054b50); end.u16(0); end.u16(0); end.u16(UInt16(entries.count)); end.u16(UInt16(entries.count))
        end.u32(UInt32(directory.count)); end.u32(offset); end.u16(0)
        try write(end); try file.synchronize()
        let readback = try FileHandle(forReadingFrom: output); defer { try? readback.close() }
        var actualHash = SHA256()
        while let chunk = try readback.read(upToCount: 65536), !chunk.isEmpty {
            try Task.checkCancellation(); actualHash.update(data: chunk)
        }
        guard actualHash.finalize() == expectedHash.finalize() else { throw ResourceError.invalid("ZIP 写入后校验失败，已移除本次无效输出。") }
        completed = true
    }
    private static let table: [UInt32] = (0..<256).map { value in
        var x = UInt32(value)
        for _ in 0..<8 { x = x & 1 == 1 ? 0xedb88320 ^ (x >> 1) : x >> 1 }
        return x
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}
private extension Data {
    mutating func u16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func u32(_ value: UInt32) { u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(truncatingIfNeeded: value >> 16)) }
}
