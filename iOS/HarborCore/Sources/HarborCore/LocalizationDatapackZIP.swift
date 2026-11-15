import Foundation
import CryptoKit

public enum LocalizationDatapackZIP {
    public static let expandedLimit = 24 * 1024 * 1024
    public static let archiveLimit = 32 * 1024 * 1024
    /// Read every entry through the existing native bounded ZIP reader. Binary
    /// entries are retained byte-for-byte and never interpreted as language.
    public static func scan(entries: [String: Data], name: String, installPath: String, revision: String) throws -> LocalizationSource {
        guard !entries.isEmpty, entries.count <= 2048, revision.count == 64 else { throw ResourceError.invalid("数据包为空、条目过多或归档修订号无效。") }
        var total = 0, names: Set<String> = [], documents: [LocalizationDocument] = []
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation(); try LocalizationDocument.validatePath(path)
            guard names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  total <= expandedLimit - data.count else { throw ResourceError.invalid("数据包路径重复或展开内容超过 24 MB。") }
            total += data.count
            if let kind = documentKind(path) { documents.append(try LocalizationDocument.read(data, path: path, kind: kind)) }
        }
        guard entries["pack.mcmeta"] != nil else { throw ResourceError.invalid("ZIP 根目录缺少 pack.mcmeta，请选择实际数据包。") }
        var source = LocalizationSource(name: name, installPath: installPath, kind: "datapack-zip", documents: documents.filter { !$0.rows.isEmpty })
        source.originalFiles = entries; source.archiveRevision = revision; return source
    }
    static func documentKind(_ path: String) -> LocalizationDocumentKind? {
        let path = path.lowercased()
        if path == "pack.mcmeta" { return .datapack }
        guard path.hasPrefix("data/") else { return nil }
        if path.hasSuffix(".mcfunction") { return .function }
        if ["/advancement/", "/advancements/", "/patchouli_books/", "/quests/"].contains(where: path.contains), path.hasSuffix(".json") || path.hasSuffix(".json5") { return .datapack }
        return nil
    }
    public static func revision(_ file: URL) throws -> String {
        let file = file.standardizedFileURL
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard file.path == file.resolvingSymlinksInPath().path, info.isRegularFile == true, info.isSymbolicLink != true,
              (info.fileSize ?? Int.max) <= archiveLimit else { throw ResourceError.invalid("ZIP 数据包不是普通文件、包含链接或超过 32 MB。") }
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var hash = SHA256(), total = 0
        while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty {
            try Task.checkCancellation(); total += bytes.count
            guard total <= archiveLimit else { throw ResourceError.invalid("读取时 ZIP 数据包超过 32 MB。") }; hash.update(data: bytes)
        }
        guard total == info.fileSize else { throw ResourceError.invalid("读取时 ZIP 数据包发生变化。") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func rendered(_ source: LocalizationSource) throws -> Data {
        guard source.kind == "datapack-zip", !source.originalFiles.isEmpty else { throw ResourceError.invalid("数据包归档缺少原件，无法安全重建。") }
        var files = source.originalFiles
        for document in source.documents {
            guard files[document.path] == document.original else { throw ResourceError.invalid("数据包文本与原始条目不一致。") }
            files[document.path] = try document.rendered()
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= expandedLimit else { throw ResourceError.invalid("译文使数据包展开内容超过 24 MB，请分批编辑。") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-datapack-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("translated.zip")
        try LocalizationZIP.write(files.map { .init(path: $0.key, data: $0.value) }, to: output)
        guard (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= archiveLimit else { throw ResourceError.invalid("重建后 ZIP 数据包超过 32 MB。") }
        return try Data(contentsOf: output)
    }
}
