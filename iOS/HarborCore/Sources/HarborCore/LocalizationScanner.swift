import Foundation

public struct LocalizationScanResult: Sendable {
    public var sources: [LocalizationSource] = []
    public var warnings: [String] = []
    public var datapackArchives: [String] = []
    public init() {}
}

public enum LocalizationScanner {
    public static func language(_ path: String) -> Bool {
        path.range(of: #"^assets/[a-z0-9_.-]+/lang/en_(?:us|gb)\.(?:json|lang)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Archive bytes are read by the existing coordinated native ZIP reader;
    /// this layer parses the same documents as loose KubeJS/resource assets.
    public static func archive(entries: [String: Data], name: String, installPath: String, kind: String) throws -> LocalizationSource {
        var documents: [LocalizationDocument] = []
        var seen: Set<String> = [], total = 0
        for (path, bytes) in entries.sorted(by: { $0.key < $1.key }) {
            try LocalizationDocument.validatePath(path)
            guard seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ResourceError.invalid("语言包包含重复路径。") }
            total += bytes.count
            guard total <= 24 * 1024 * 1024, entries.count <= 2048 else { throw ResourceError.invalid("语言文本超过安全上限，请分批处理。") }
            guard language(path) else { continue }
            var doc = try LocalizationDocument.read(bytes, path: path, kind: path.lowercased().hasSuffix(".lang") ? .languageLegacy : .languageJSON)
            let chinesePath = path.replacingOccurrences(of: #"(?i)/en_(?:us|gb)\."#, with: "/zh_cn.", options: .regularExpression)
            if let embedded = entries.first(where: { $0.key.caseInsensitiveCompare(chinesePath) == .orderedSame }),
               let chinese = try? LocalizationDocument.read(embedded.value, path: embedded.key, kind: doc.kind) {
                let values = Dictionary(chinese.rows.map { ($0.key, $0.source) }, uniquingKeysWith: { first, _ in first })
                for r in doc.rows.indices {
                    if let value = values[doc.rows[r].key], LocalizationPlaceholders.compatible(doc.rows[r].source, value) { doc.rows[r].translation = value }
                }
            }
            // en_us takes precedence; otherwise en_gb is the fallback. They do
            // not silently collide into one zh_cn output.
            if path.lowercased().contains("/en_gb."), entries.keys.contains(where: { $0.caseInsensitiveCompare(path.replacingOccurrences(of: "en_gb.", with: "en_us.", options: .caseInsensitive)) == .orderedSame }) { continue }
            documents.append(doc)
        }
        var source = LocalizationSource(name: name, installPath: installPath, kind: kind, documents: documents)
        source.originalFiles = entries
        return source
    }
    public static func loose(instance: URL) throws -> LocalizationScanResult {
        let root = instance.standardizedFileURL.resolvingSymlinksInPath(), fm = FileManager.default
        var result = LocalizationScanResult(), bytes = 0, count = 0
        func safe(_ url: URL) throws {
            guard url.path.hasPrefix(root.path + "/"), url.path == url.resolvingSymlinksInPath().path else { throw ResourceError.invalid("语言目录包含符号链接或越界路径：" + url.lastPathComponent) }
        }
        func collect(_ relative: String, kind: String) throws {
            try LocalizationDocument.validatePath(relative)
            let base = root.appendingPathComponent(relative)
            guard fm.fileExists(atPath: base.path) else { return }
            try safe(base)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            var walkError: Error?
            guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in walkError = error; return false }) else { throw ResourceError.invalid("无法读取语言目录：" + relative) }
            var docs: [LocalizationDocument] = [], languages: [String: Data] = [:], existingLocales: [String: Data] = [:]
            while let enumerated = enumerator.nextObject() as? URL {
                // Foundation enumerators can report /private/var while their
                // input URL is standardized as /var on current Apple OSes.
                // Normalize that system alias before relative-path arithmetic;
                // real per-entry symlinks are still explicitly rejected.
                let url = enumerated.standardizedFileURL
                try Task.checkCancellation(); count += 1
                guard count <= 30_000 else { throw ResourceError.invalid("语言扫描超过 30000 个文件，请分批处理。") }
                let properties = try url.resourceValues(forKeys: Set(keys))
                let path = String(url.path.dropFirst(base.path.count + 1))
                if properties.isSymbolicLink == true { enumerator.skipDescendants(); result.warnings.append(relative + "/" + path + "：符号链接已跳过"); continue }
                if path.split(separator: "/").count > 16 { enumerator.skipDescendants(); result.warnings.append(relative + "：超过 16 层的目录已跳过"); continue }
                guard properties.isRegularFile == true else { continue }
                try safe(url)
                let lower = path.lowercased(), fileKind: LocalizationDocumentKind?
                if kind == "languages" { fileKind = lower.range(of: #"^assets/[a-z0-9_.-]+/lang/[a-z]{2,3}_[a-z0-9]{2,6}\.(json|lang)$"#, options: .regularExpression) != nil ? (lower.hasSuffix(".lang") ? .languageLegacy : .languageJSON) : nil }
                else if kind == "ftbquests" {
                    if lower.hasPrefix("lang/") && !lower.hasPrefix("lang/en_us.") && !lower.hasPrefix("lang/en_us/") && !lower.hasPrefix("lang/en_gb.") && !lower.hasPrefix("lang/en_gb/") { continue }
                    fileKind = ["snbt", "json5", "json"].contains(url.pathExtension.lowercased()) ? (lower.hasPrefix("lang/") ? .ftbLocale : .ftbQuest) : nil
                } else {
                    let textJSON = lower == "pack.mcmeta" || lower.hasPrefix("data/") && ["/advancement/", "/advancements/", "/patchouli_books/", "/quests/"].contains(where: { lower.contains($0) }) && (lower.hasSuffix(".json") || lower.hasSuffix(".json5"))
                    fileKind = textJSON ? .datapack : lower.hasPrefix("data/") && lower.hasSuffix(".mcfunction") ? .function : nil
                }
                guard let fileKind else { continue }
                guard (properties.fileSize ?? Int.max) <= 4 * 1024 * 1024 else { result.warnings.append(relative + "/" + path + "：超过 4 MB，已跳过"); continue }
                let data = try Data(contentsOf: url); bytes += data.count
                guard bytes <= 24 * 1024 * 1024 else { throw ResourceError.invalid("实例文本超过 24 MB，请分批处理。") }
                if kind == "languages" { languages[path] = data }
                else {
                    do {
                        var doc = try LocalizationDocument.read(data, path: path, kind: fileKind)
                        if fileKind == .ftbLocale {
                            let chinese = path.replacingOccurrences(of: #"(?i)(^|/)en_(?:us|gb)(?=/|\.)"#, with: "$1zh_cn", options: .regularExpression)
                            let file = base.appendingPathComponent(chinese)
                            if fm.fileExists(atPath: file.path) {
                                try safe(file)
                                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                                guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw ResourceError.invalid("已有中文任务语言文件不是普通文件或超过 4 MB。") }
                                let original = try Data(contentsOf: file); bytes += original.count
                                guard bytes <= 24 * 1024 * 1024 else { throw ResourceError.invalid("实例文本超过 24 MB，请分批处理。") }
                                let locale = try LocalizationDocument.read(original, path: chinese, kind: .ftbLocale)
                                existingLocales[chinese] = original
                                let values = Dictionary(locale.rows.map { ($0.key, $0.source) }, uniquingKeysWith: { first, _ in first })
                                for index in doc.rows.indices {
                                    if let value = values[doc.rows[index].key], LocalizationPlaceholders.compatible(doc.rows[index].source, value) { doc.rows[index].translation = value }
                                }
                            }
                        }
                        if !doc.rows.isEmpty { docs.append(doc) }
                    }
                    catch { result.warnings.append(relative + "/" + path + "：" + error.localizedDescription) }
                }
            }
            if let walkError { throw walkError }
            let paths = Set(docs.map { $0.path.lowercased() })
            docs.removeAll { $0.kind == .ftbLocale && $0.path.lowercased().contains("en_gb") && paths.contains($0.path.lowercased().replacingOccurrences(of: "en_gb", with: "en_us")) }
            var source = kind == "languages" ? try archive(entries: languages, name: relative, installPath: relative, kind: kind) : .init(name: relative, installPath: relative, kind: kind, documents: docs)
            if kind == "ftbquests" { source.originalFiles = existingLocales }
            if !source.documents.isEmpty || !source.originalFiles.isEmpty { result.sources.append(source) }
        }
        // KubeJS language assets are real resource-pack assets; arbitrary JS
        // source strings are deliberately not guessed or rewritten.
        for relative in ["kubejs", "resources"] { try collect(relative, kind: "languages") }
        let resourcepacks = root.appendingPathComponent("resourcepacks")
        if fm.fileExists(atPath: resourcepacks.path) {
            try safe(resourcepacks)
            let packs = try fm.contentsOfDirectory(at: resourcepacks, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard packs.count <= 2048 else { throw ResourceError.invalid("资源包数量过多，请分批处理。") }
            for pack in packs {
                let properties = try pack.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if properties.isDirectory == true && properties.isSymbolicLink != true { try collect("resourcepacks/" + pack.lastPathComponent, kind: "languages") }
            }
        }
        for relative in ["config/ftbquests/quests", "config/ftbquests/normal", "defaultconfigs/ftbquests/quests"] { try collect(relative, kind: "ftbquests") }
        func packs(_ relative: String) throws {
            let base = root.appendingPathComponent(relative)
            guard fm.fileExists(atPath: base.path) else { return }; try safe(base)
            let values = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.count <= 512 else { throw ResourceError.invalid("数据包数量过多，请先整理。") }
            for url in values.sorted(by: { $0.path < $1.path }) {
                let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if properties.isSymbolicLink == true { result.warnings.append(url.lastPathComponent + "：符号链接已跳过"); continue }
                if properties.isDirectory == true { try collect(relative + "/" + url.lastPathComponent, kind: "datapacks") }
                else if url.pathExtension.lowercased() == "zip" { result.datapackArchives.append(relative + "/" + url.lastPathComponent) }
            }
        }
        try packs("datapacks")
        let saves = root.appendingPathComponent("saves")
        if fm.fileExists(atPath: saves.path) {
            try safe(saves)
            let worlds = try fm.contentsOfDirectory(at: saves, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard worlds.count <= 256 else { throw ResourceError.invalid("存档数量超过 256，请分批处理。") }
            for world in worlds {
                let properties = try world.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard properties.isDirectory == true, properties.isSymbolicLink != true else { continue }
                let relative = "saves/" + world.lastPathComponent
                try collect(relative + "/serverconfig/ftbquests/quests", kind: "ftbquests"); try packs(relative + "/datapacks")
            }
        }
        return result
    }
}
