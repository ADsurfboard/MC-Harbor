import Foundation

public struct ModArchiveMetadata: Sendable {
    public var name: String
    public var version: String?
    public var loaders: [String]
    public var gameVersions: [String]
    public var summary: String?
    public var authors: String?
    public var iconPath: String?

    public static let entries = ["fabric.mod.json", "quilt.mod.json", "META-INF/neoforge.mods.toml",
                                 "META-INF/mods.toml", "mcmod.info", "META-INF/MANIFEST.MF"]
    /// Parse metadata only. No scripts, expressions, URLs or mod classes execute.
    /// Version constraints are retained as declared, never converted into a claim
    /// that an arbitrary Minecraft version is compatible.
    public static func read(entries: [String: Data], filename: String) throws -> Self {
        guard entries.count <= 8, entries.values.allSatisfy({ $0.count <= 1024 * 1024 }) else {
            throw ModFolderError.invalid("模组资料过大，无法安全读取。")
        }
        var result = Self(name: String((filename as NSString).deletingPathExtension.prefix(120)),
                          loaders: [], gameVersions: [])
        func text(_ value: Any?, limit: Int = 16_384) -> String? {
            guard let value = value as? String else { return nil }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
        }
        func strings(_ value: Any?) -> [String] {
            if let one = text(value, limit: 120) { return [one] }
            return (value as? [String] ?? []).prefix(256).compactMap { text($0, limit: 120) }
        }
        func people(_ value: Any?) -> String? {
            guard let list = value as? [Any] else { return text(value, limit: 2048) }
            let names = list.prefix(64).compactMap { item -> String? in
                if let person = item as? [String: Any] { return text(person["name"], limit: 120) }
                return text(item, limit: 120)
            }
            return text(names.joined(separator: "、"), limit: 2048)
        }
        func json(_ path: String) throws -> Any? {
            guard let data = entries[path] else { return nil }
            do {
                let value = try JSONSerialization.jsonObject(with: data)
                guard path == "mcmod.info" || value is [String: Any] else { throw ModFolderError.invalid("资料根节点不是对象。") }
                return value
            }
            catch { throw ModFolderError.invalid("\(path) 无法解析，原模组文件未改动。") }
        }
        if let object = try json("fabric.mod.json") as? [String: Any] {
            result.loaders = ["Fabric"]
            result.name = text(object["name"], limit: 120) ?? text(object["id"], limit: 120) ?? result.name
            result.version = text(object["version"], limit: 256)
            result.summary = text(object["description"]); result.authors = people(object["authors"])
            result.gameVersions = strings((object["depends"] as? [String: Any])?["minecraft"])
            if let icon = object["icon"] as? String { result.iconPath = icon }
            else if let sizes = object["icon"] as? [String: String] {
                result.iconPath = sizes.sorted { (Int($0.key) ?? 0) > (Int($1.key) ?? 0) }.first?.value
            }
        } else if let root = try json("quilt.mod.json") as? [String: Any],
                  let loader = root["quilt_loader"] as? [String: Any] {
            let metadata = loader["metadata"] as? [String: Any] ?? [:]
            result.loaders = ["Quilt"]
            result.name = text(metadata["name"], limit: 120) ?? text(loader["id"], limit: 120) ?? result.name
            result.version = text(loader["version"], limit: 256); result.summary = text(metadata["description"])
            result.authors = text((metadata["contributors"] as? [String: Any] ?? [:]).keys.sorted().joined(separator: "、"), limit: 2048)
            result.iconPath = metadata["icon"] as? String
            for dependency in loader["depends"] as? [[String: Any]] ?? [] where dependency["id"] as? String == "minecraft" {
                result.gameVersions = strings(dependency["versions"])
            }
        } else if let data = entries["META-INF/neoforge.mods.toml"] ?? entries["META-INF/mods.toml"] {
            guard let source = String(data: data, encoding: .utf8) else { throw ModFolderError.invalid("模组 TOML 不是有效 UTF-8。") }
            let fields = tomlMod(source)
            guard !fields.isEmpty else { throw ModFolderError.invalid("模组 TOML 未包含可读取的 mods 资料。") }
            result.loaders = [entries["META-INF/neoforge.mods.toml"] != nil ? "NeoForge" : "Forge"]
            result.name = text(fields["displayName"], limit: 120) ?? text(fields["modId"], limit: 120) ?? result.name
            result.version = text(fields["version"], limit: 256); result.summary = text(fields["description"])
            result.authors = text(fields["authors"], limit: 2048); result.iconPath = fields["logoFile"]
        } else if let value = try json("mcmod.info") {
            let array = value as? [[String: Any]] ?? (value as? [String: Any])?["modList"] as? [[String: Any]] ?? []
            if let object = array.first {
                result.loaders = ["Forge"]
                result.name = text(object["name"], limit: 120) ?? text(object["modid"], limit: 120) ?? result.name
                result.version = text(object["version"], limit: 256); result.summary = text(object["description"])
                result.authors = people(object["authorList"]); result.iconPath = object["logoFile"] as? String
                result.gameVersions = strings(object["mcversion"])
            }
        }
        if let version = result.version, version.contains("$") {
            result.version = nil
            if let manifest = entries["META-INF/MANIFEST.MF"], let source = String(data: manifest, encoding: .utf8) {
                let unfolded = source.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "")
                for line in unfolded.components(separatedBy: .newlines) where line.hasPrefix("Implementation-Version:") {
                    result.version = text(String(line.dropFirst("Implementation-Version:".count)), limit: 256); break
                }
            }
        }
        if let path = result.iconPath {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if path.count > 512 || path.hasPrefix("/") || path.contains("\\") || path.contains(":") ||
                components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) ||
                !["png", "jpg", "jpeg", "webp"].contains((path as NSString).pathExtension.lowercased()) {
                result.iconPath = nil
            }
        }
        guard !result.name.isEmpty else { throw ModFolderError.invalid("无法读取模组名称。") }
        return result
    }

    /// The first [[mods]] record is the primary mod. Support basic/literal and
    /// multiline strings without executing TOML substitutions or Java code.
    private static func tomlMod(_ source: String) -> [String: String] {
        let lines = source.components(separatedBy: .newlines)
        var result: [String: String] = [:], inMod = false, index = 0
        let keys: Set<String> = ["modId", "displayName", "version", "description", "authors", "logoFile"]
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines); index += 1
            if line.hasPrefix("[") {
                let header = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
                if header == "[[mods]]" { if inMod { break }; inMod = true }
                else if inMod { break }
                continue
            }
            guard inMod, let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            guard keys.contains(key) else { continue }
            var value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'" else { continue }
            let delimiter = String(repeating: String(quote), count: value.hasPrefix(String(repeating: String(quote), count: 3)) ? 3 : 1)
            value.removeFirst(delimiter.count)
            while delimiter.count == 3 && !value.contains(delimiter) && index < lines.count {
                value += "\n" + lines[index]; index += 1
            }
            var cursor = value.startIndex, end: String.Index?
            while cursor < value.endIndex {
                if quote == "\"", value[cursor] == "\\" {
                    cursor = value.index(after: cursor)
                    if cursor < value.endIndex { cursor = value.index(after: cursor) }
                    continue
                }
                if value[cursor...].hasPrefix(delimiter) { end = cursor; break }
                cursor = value.index(after: cursor)
            }
            guard let end else { continue }
            var content = String(value[..<end])
            if quote == "\"" {
                content = content.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            result[key] = content
        }
        return result
    }
}
