import Foundation

public enum ResourceSource: String, Codable, CaseIterable, Sendable { case modrinth, curseforge }
public enum ResourceRoute: String, Codable, CaseIterable, Sendable { case domesticFirst, officialFirst }
public enum ResourceKind: String, Codable, CaseIterable, Sendable {
    case mod, resourcepack, shader
    public var directory: String { switch self { case .mod: "mods"; case .resourcepack: "resourcepacks"; case .shader: "shaderpacks" } }
    public var title: String { switch self { case .mod: "模组"; case .resourcepack: "资源包"; case .shader: "光影" } }
    var curseClass: String { switch self { case .mod: "6"; case .resourcepack: "12"; case .shader: "6552" } }
}
public struct ResourceTarget: Equatable, Sendable {
    public let gameVersion: String
    public let loader: String
    public init(gameVersion: String, loader: String) { self.gameVersion = gameVersion; self.loader = loader.lowercased() }
}
public struct ResourceProject: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let author: String
    public let icon: URL?
    public let page: URL?
    public let downloads: Int
    public let slug: String?
    public let source: ResourceSource
    public init(id: String, title: String, summary: String, author: String, icon: URL?, page: URL?, downloads: Int, slug: String?, source: ResourceSource) {
        self.id = id; self.title = title; self.summary = summary; self.author = author; self.icon = icon
        self.page = page; self.downloads = downloads; self.slug = slug; self.source = source
    }
}
public struct ResourceDependency: Codable, Sendable {
    public let project: String?
    public let version: String?
    public let required: Bool
    public init(project: String?, version: String?, required: Bool) { self.project = project; self.version = version; self.required = required }
}
public struct ResourceFile: Codable, Sendable, Hashable {
    public let name: String
    public let url: URL
    public let size: Int64
    public let hashes: [String: String]
    public init(name: String, url: URL, size: Int64, hashes: [String: String]) { self.name = name; self.url = url; self.size = size; self.hashes = hashes }
}
public struct ResourceVersion: Codable, Identifiable, Sendable {
    public let id: String
    public let project: String
    public let title: String
    public let number: String
    public let games: [String]
    public let loaders: [String]
    public let files: [ResourceFile]
    public let dependencies: [ResourceDependency]
    public init(id: String, project: String, title: String, number: String, games: [String], loaders: [String], files: [ResourceFile], dependencies: [ResourceDependency]) {
        self.id = id; self.project = project; self.title = title; self.number = number; self.games = games
        self.loaders = loaders; self.files = files; self.dependencies = dependencies
    }
}
public struct ResourceSearchPage: Sendable { public let projects: [ResourceProject]; public let total: Int }
public enum ResourceError: LocalizedError, Sendable {
    case invalid(String), http(Int), unavailable(String)
    public var errorDescription: String? {
        switch self { case .invalid(let value), .unavailable(let value): value; case .http(let status): "资源服务返回 HTTP \(status)，请重试或切换来源。" }
    }
}
public struct ResourceHTTPResult: Sendable {
    public let data: Data
    public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status }
}
public typealias ResourceTransport = @Sendable (URLRequest, Int) async throws -> ResourceHTTPResult

public enum ResourceNetwork {
    public static let userAgent = "MC-Harbor-iOS/0.1 (+https://github.com/ADsurfboard/MC-Harbor)"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 4; config.urlCache = nil; config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
    public static func publicHTTPS(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else { return false }
        return true
    }
    public static func fileURLAllowed(_ url: URL) -> Bool {
        publicHTTPS(url) && ["cdn.modrinth.com", "edge.forgecdn.net", "mediafilez.forgecdn.net", "media.forgecdn.net", "mod.mcimirror.top"].contains(url.host?.lowercased() ?? "")
    }
    public static func candidates(_ original: URL, route: ResourceRoute) -> [URL] {
        guard fileURLAllowed(original), var mirror = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return [] }
        guard original.host != "mod.mcimirror.top" else { return [original] }
        mirror.host = "mod.mcimirror.top"
        guard let url = mirror.url else { return [original] }
        return route == .domesticFirst ? [url, original] : [original, url]
    }
    public static func fetch(_ request: URLRequest, limit: Int) async throws -> ResourceHTTPResult {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ResourceError.http(status) }
        guard response.expectedContentLength <= Int64(limit) else { throw ResourceError.invalid("资源服务返回的数据过大。") }
        var data = Data(); data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            guard data.count < limit else { throw ResourceError.invalid("资源服务返回的数据过大。") }
            data.append(byte)
            if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
        }
        return ResourceHTTPResult(data: data, status: status)
    }
}

/// Stateless requests allow a cancelled/obsolete search to end without changing
/// another page. A source failure falls back only to its equivalent endpoint.
public struct ResourceCatalog: Sendable {
    public let route: ResourceRoute
    private let transport: ResourceTransport
    public init(route: ResourceRoute = .domesticFirst, transport: @escaping ResourceTransport = ResourceNetwork.fetch) { self.route = route; self.transport = transport }
    public func request(source: ResourceSource, path: String, query: [URLQueryItem] = []) async throws -> Data {
        let official = source == .modrinth ? "https://api.modrinth.com/v2" : "https://api.curseforge.com/v1"
        let mirror = source == .modrinth ? "https://mod.mcimirror.top/modrinth/v2" : "https://mod.mcimirror.top/curseforge/v1"
        // CurseForge's official API needs an application key. Never ship a key
        // copied from another launcher or turn an author opt-out into a URL.
        let bases = source == .curseforge ? [mirror] : route == .domesticFirst ? [mirror, official] : [official, mirror]
        var last: Error = ResourceError.unavailable("资源来源暂不可用。")
        for base in bases {
            try Task.checkCancellation()
            var url = URLComponents(string: base + path)!
            url.queryItems = query.isEmpty ? nil : query
            var request = URLRequest(url: url.url!, timeoutInterval: 12)
            request.setValue(ResourceNetwork.userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let result = try await transport(request, 8 * 1024 * 1024)
                try Task.checkCancellation()
                guard result.status == 200 else { throw ResourceError.http(result.status) }
                guard result.data.count <= 8 * 1024 * 1024 else { throw ResourceError.invalid("资源列表过大。") }
                guard (try? JSONSerialization.jsonObject(with: result.data)) != nil else { throw ResourceError.invalid("资源来源没有返回 JSON，正在尝试备用来源。") }
                return result.data
            } catch { last = error; try Task.checkCancellation() }
        }
        throw last
    }
    private func identifier(_ id: String, source: ResourceSource) throws -> String {
        let pattern = source == .curseforge ? "^[0-9]{1,15}$" : "^[A-Za-z0-9_-]{1,100}$"
        guard id.range(of: pattern, options: .regularExpression) != nil else { throw ResourceError.invalid("资源编号无效。") }; return id
    }
    public func search(_ text: String, source: ResourceSource, kind: ResourceKind, target: ResourceTarget?, page: Int = 0) async throws -> ResourceSearchPage {
        guard (0...1000).contains(page), text.utf8.count <= 1024 else { throw ResourceError.invalid("搜索词或页码超出范围。") }
        var query: [URLQueryItem]
        if source == .modrinth {
            var facets = [["project_type:" + kind.rawValue]]
            if let target { facets.append(["versions:" + target.gameVersion]); if kind == .mod { facets.append(["categories:" + target.loader]) } }
            query = [.init(name: "query", value: text), .init(name: "facets", value: String(decoding: try JSONEncoder().encode(facets), as: UTF8.self)), .init(name: "limit", value: "30"), .init(name: "offset", value: String(page * 30)), .init(name: "index", value: text.isEmpty ? "downloads" : "relevance")]
            return try ResourceDecoding.modrinthSearch(await request(source: source, path: "/search", query: query), kind: kind)
        }
        query = [.init(name: "gameId", value: "432"), .init(name: "classId", value: kind.curseClass), .init(name: "searchFilter", value: text), .init(name: "pageSize", value: "30"), .init(name: "index", value: String(page * 30)), .init(name: "sortField", value: text.isEmpty ? "6" : "8"), .init(name: "sortOrder", value: "desc")]
        query += curseFilters(target, kind: kind)
        return try ResourceDecoding.curseSearch(await request(source: source, path: "/mods/search", query: query))
    }
    private func curseFilters(_ target: ResourceTarget?, kind: ResourceKind) -> [URLQueryItem] {
        guard let target else { return [] }
        var values = [URLQueryItem(name: "gameVersion", value: target.gameVersion)]
        if kind == .mod, let loader = ["forge": "1", "fabric": "4", "quilt": "5", "neoforge": "6"][target.loader] { values.append(.init(name: "modLoaderType", value: loader)) }
        return values
    }
    public func versions(project: String, source: ResourceSource, kind: ResourceKind, target: ResourceTarget?) async throws -> [ResourceVersion] {
        let id = try identifier(project, source: source)
        if source == .modrinth {
            var query = [URLQueryItem(name: "include_changelog", value: "false")]
            if let target {
                query.append(.init(name: "game_versions", value: String(decoding: try JSONEncoder().encode([target.gameVersion]), as: UTF8.self)))
                if kind == .mod { query.append(.init(name: "loaders", value: String(decoding: try JSONEncoder().encode([target.loader]), as: UTF8.self))) }
            }
            return try ResourceDecoding.modrinthVersions(await request(source: source, path: "/project/" + id + "/version", query: query))
        }
        return try ResourceDecoding.curseVersions(await request(source: source, path: "/mods/" + id + "/files", query: [.init(name: "pageSize", value: "50")] + curseFilters(target, kind: kind)), project: id)
    }
    public func version(_ version: String, project: String?, source: ResourceSource) async throws -> ResourceVersion {
        let id = try identifier(version, source: source)
        if source == .modrinth { return try ResourceDecoding.modrinthVersion(await request(source: source, path: "/version/" + id)) }
        let project = try identifier(project ?? "", source: source)
        return try ResourceDecoding.curseVersion(await request(source: source, path: "/mods/" + project + "/files/" + id), project: project)
    }
    public func plan(_ selected: ResourceVersion, source: ResourceSource, kind: ResourceKind, target: ResourceTarget) async throws -> [ResourceFile] {
        var visited: [String: String] = [:], active: Set<String> = [], output: [ResourceFile] = []
        func visit(_ value: ResourceVersion) async throws {
            try Task.checkCancellation()
            guard value.games.contains(target.gameVersion), kind != .mod || value.loaders.contains(target.loader) else { throw ResourceError.invalid("资源或前置与实例的 Minecraft 版本、加载器不兼容。") }
            if let previous = visited[value.project] {
                guard previous == value.id else { throw ResourceError.invalid("两个前置要求了同一模组的不同版本，请调整选择。") }; return
            }
            guard !active.contains(value.project), visited.count + active.count < 40 else { throw ResourceError.invalid("前置存在循环或超过 40 个，本次安装已停止。") }
            active.insert(value.project)
            if kind == .mod {
                for dependency in value.dependencies where dependency.required {
                    let next: ResourceVersion
                    if let id = dependency.version { next = try await version(id, project: dependency.project, source: source) }
                    else if let project = dependency.project, let first = try await versions(project: project, source: source, kind: kind, target: target).first { next = first }
                    else { throw ResourceError.unavailable("必要前置没有兼容的可下载版本。") }
                    try await visit(next)
                }
            }
            guard let file = value.files.first else { throw ResourceError.unavailable("作者未提供可直接下载的文件，请打开原项目页面。") }
            try ResourceFileValidation.validate(file, kind: kind)
            guard !output.contains(where: { $0.name.caseInsensitiveCompare(file.name) == .orderedSame }) else { throw ResourceError.invalid("下载计划存在同名文件。") }
            output.append(file); active.remove(value.project); visited[value.project] = value.id
        }
        try await visit(selected); return output
    }
}
