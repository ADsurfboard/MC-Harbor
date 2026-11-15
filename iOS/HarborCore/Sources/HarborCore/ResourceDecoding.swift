import Foundation

enum ResourceDecoding {
    private static func root(_ data: Data) throws -> Any {
        guard data.count <= 8 * 1024 * 1024 else { throw ResourceError.invalid("资源列表过大。") }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw ResourceError.invalid("资源服务没有返回有效的 JSON。") }
    }
    private static func string(_ object: [String: Any], _ key: String) -> String { String((object[key] as? String ?? "").prefix(16_384)) }
    private static func array(_ object: [String: Any], _ key: String) -> [String] { (object[key] as? [String] ?? []).prefix(500).map { String($0.prefix(200)) } }
    private static func url(_ text: String) -> URL? { guard let url = URL(string: text), ResourceNetwork.publicHTTPS(url) else { return nil }; return url }
    static func modrinthSearch(_ data: Data, kind: ResourceKind) throws -> ResourceSearchPage {
        guard let object = try root(data) as? [String: Any], let hits = object["hits"] as? [[String: Any]], hits.count <= 100,
              let total = object["total_hits"] as? Int, total >= 0 else { throw ResourceError.invalid("Modrinth 搜索数据格式无效。") }
        let projects = hits.compactMap { hit -> ResourceProject? in
            let id = string(hit, "project_id"), title = string(hit, "title"), slug = string(hit, "slug")
            guard !id.isEmpty, !title.isEmpty else { return nil }
            return ResourceProject(id: id, title: title, summary: string(hit, "description"), author: string(hit, "author"), icon: url(string(hit, "icon_url")), page: url("https://modrinth.com/" + kind.rawValue + "/" + id), downloads: max(0, hit["downloads"] as? Int ?? 0), slug: slug.isEmpty ? nil : slug, source: .modrinth)
        }
        return ResourceSearchPage(projects: projects, total: total)
    }
    static func curseSearch(_ data: Data) throws -> ResourceSearchPage {
        guard let object = try root(data) as? [String: Any], let hits = object["data"] as? [[String: Any]], hits.count <= 100 else { throw ResourceError.invalid("CurseForge 搜索数据格式无效。") }
        let projects = hits.compactMap { hit -> ResourceProject? in
            guard let id = hit["id"] as? Int, id > 0 else { return nil }
            let title = string(hit, "name"); guard !title.isEmpty else { return nil }
            let authors = (hit["authors"] as? [[String: Any]] ?? []).prefix(50).map { string($0, "name") }.joined(separator: "、")
            return ResourceProject(id: String(id), title: title, summary: string(hit, "summary"), author: authors,
                icon: url(string(hit["logo"] as? [String: Any] ?? [:], "thumbnailUrl")), page: url(string(hit["links"] as? [String: Any] ?? [:], "websiteUrl")), downloads: max(0, (hit["downloadCount"] as? NSNumber)?.intValue ?? 0), slug: string(hit, "slug"), source: .curseforge)
        }
        return ResourceSearchPage(projects: projects, total: max(projects.count, (object["pagination"] as? [String: Any])?["totalCount"] as? Int ?? projects.count))
    }
    static func modrinthVersions(_ data: Data) throws -> [ResourceVersion] {
        guard let values = try root(data) as? [[String: Any]], values.count <= 5000 else { throw ResourceError.invalid("Modrinth 版本数据无效。") }
        return try values.map(modrinth)
    }
    static func modrinthVersion(_ data: Data) throws -> ResourceVersion {
        guard let value = try root(data) as? [String: Any] else { throw ResourceError.invalid("模组版本数据无效。") }; return try modrinth(value)
    }
    private static func modrinth(_ value: [String: Any]) throws -> ResourceVersion {
        let id = string(value, "id"), project = string(value, "project_id")
        guard !id.isEmpty, !project.isEmpty, let rawFiles = value["files"] as? [[String: Any]], rawFiles.count <= 100 else { throw ResourceError.invalid("模组版本缺少编号或文件列表。") }
        // Preserve the API primary flag; do not accidentally install a sources JAR.
        let sorted = rawFiles.enumerated().sorted { left, right in
            let a = left.element["primary"] as? Bool ?? false, b = right.element["primary"] as? Bool ?? false
            return a == b ? left.offset < right.offset : a
        }.map(\.element)
        let files = sorted.compactMap { file -> ResourceFile? in
            guard let address = url(string(file, "url")), let size = file["size"] as? Int64 else { return nil }
            return ResourceFile(name: string(file, "filename"), url: address, size: size, hashes: file["hashes"] as? [String: String] ?? [:])
        }
        let dependencies = (value["dependencies"] as? [[String: Any]] ?? []).prefix(100).map {
            ResourceDependency(project: $0["project_id"] as? String, version: $0["version_id"] as? String, required: string($0, "dependency_type") == "required")
        }
        return ResourceVersion(id: id, project: project, title: string(value, "name"), number: string(value, "version_number"), games: array(value, "game_versions"), loaders: array(value, "loaders").map { $0.lowercased() }, files: files, dependencies: dependencies)
    }
    static func curseVersions(_ data: Data, project: String) throws -> [ResourceVersion] {
        guard let root = try root(data) as? [String: Any], let values = root["data"] as? [[String: Any]], values.count <= 100 else { throw ResourceError.invalid("CurseForge 文件列表无效。") }
        return try values.filter { $0["isAvailable"] as? Bool != false }.map { try curse($0, project: project) }
    }
    static func curseVersion(_ data: Data, project: String) throws -> ResourceVersion {
        guard let root = try root(data) as? [String: Any], let value = root["data"] as? [String: Any], value["isAvailable"] as? Bool != false else { throw ResourceError.invalid("CurseForge 文件已不可用。") }
        return try curse(value, project: project)
    }
    private static func curse(_ value: [String: Any], project: String) throws -> ResourceVersion {
        guard let id = value["id"] as? Int, id > 0 else { throw ResourceError.invalid("CurseForge 文件缺少编号。") }
        var hashes: [String: String] = [:]
        for hash in value["hashes"] as? [[String: Any]] ?? [] {
            if let algorithm = hash["algo"] as? Int, let name = [1: "sha1", 2: "md5"][algorithm] { hashes[name] = string(hash, "value") }
        }
        var files: [ResourceFile] = []
        if let address = url(string(value, "downloadUrl")), let size = value["fileLength"] as? Int64 {
            files = [ResourceFile(name: string(value, "fileName"), url: address, size: size, hashes: hashes)]
        }
        let dependencies = (value["dependencies"] as? [[String: Any]] ?? []).prefix(100).compactMap { entry -> ResourceDependency? in
            guard let project = entry["modId"] as? Int else { return nil }
            return ResourceDependency(project: String(project), version: nil, required: entry["relationType"] as? Int == 3)
        }
        let games = array(value, "gameVersions")
        return ResourceVersion(id: String(id), project: project, title: string(value, "displayName"), number: string(value, "displayName"), games: games, loaders: games.map { $0.lowercased() }.filter { ["forge", "fabric", "quilt", "neoforge"].contains($0) }, files: files, dependencies: dependencies)
    }
}

public enum ResourceFileValidation {
    public static func validate(_ file: ResourceFile, kind: ResourceKind) throws {
        let name = file.name
        guard !name.isEmpty, name.utf8.count <= 240, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              URL(fileURLWithPath: name).pathExtension.lowercased() == (kind == .mod ? "jar" : "zip"),
              file.size > 0, file.size <= 2_000_000_000, ResourceNetwork.fileURLAllowed(file.url) else { throw ResourceError.invalid("资源的文件名、大小或下载地址无效。") }
        guard let hash = digest(file), hash.value.range(of: "^[0-9a-fA-F]{\(hash.length)}$", options: .regularExpression) != nil else { throw ResourceError.invalid("资源缺少完整的校验值，无法安全安装。") }
    }
    public static func digest(_ file: ResourceFile) -> (name: String, value: String, length: Int)? {
        for (name, length) in [("sha512", 128), ("sha1", 40), ("md5", 32)] { if let value = file.hashes[name] { return (name, value, length) } }
        return nil
    }
}
