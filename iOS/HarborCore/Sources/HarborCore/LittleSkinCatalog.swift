import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

public struct LittleSkinEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let author: String
    public let model: String
    public let highResolution: Bool
    public var projectURL: URL { URL(string: "https://littleskin.cn/skinlib/show/\(id)")! }
}

public struct LittleSkinCatalog: Sendable {
    private static let origin = URL(string: "https://littleskin.cn")!
    private let transport: ResourceTransport

    public init(transport: @escaping ResourceTransport = ResourceNetwork.fetch) {
        self.transport = transport
    }

    public func search(_ query: String, page: Int) async throws -> (items: [LittleSkinEntry], hasNextPage: Bool) {
        guard (1...100_000).contains(page), query.utf8.count <= 512 else {
            throw ResourceError.invalid("搜索内容过长，或页码无效。")
        }
        var url = URLComponents(url: Self.origin.appendingPathComponent("skinlib/list"), resolvingAgainstBaseURL: false)!
        url.queryItems = ["filter": "skin", "keyword": query, "page": String(page), "sort": "likes"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let data = try await fetch(url.url!, limit: 512 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]], rows.count <= 100 else {
            throw ResourceError.invalid("LittleSkin 返回了无法识别的列表。")
        }
        var ids = Set<Int>()
        let items: [LittleSkinEntry] = rows.compactMap { row in
            guard let id = row["tid"] as? Int, id > 0, ids.insert(id).inserted,
                  let name = row["name"] as? String, !name.isEmpty,
                  let type = row["type"] as? String, ["steve", "alex"].contains(type) else { return nil }
            return LittleSkinEntry(id: id, name: String(name.prefix(160)),
                author: String((row["nickname"] as? String ?? "LittleSkin").prefix(120)),
                model: type == "alex" ? "slim" : "default", highResolution: row["hd"] as? Bool ?? false)
        }
        let hasNextPage = (object["last_page"] as? Int).map { $0 > page } ??
            (object["next_page_url"] as? String).map { !$0.isEmpty } ?? false
        return (items, page < 100_000 && hasNextPage)
    }

    public func texture(_ entry: LittleSkinEntry) async throws -> Data {
        let metadata = try await fetch(Self.origin.appendingPathComponent("texture/\(entry.id)"), limit: 16 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let hash = object["hash"] as? String, hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (object["type"] as? String) == (entry.model == "slim" ? "alex" : "steve") else {
            throw ResourceError.invalid("LittleSkin 的模型或文件指纹已变化，请刷新列表。")
        }
        let data = try await fetch(Self.origin.appendingPathComponent("textures/\(hash)"), limit: 1024 * 1024)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == hash else { throw ResourceError.invalid("皮肤文件校验失败。") }
        try Self.validate(data)
        return data
    }

    public static func validate(_ data: Data) throws {
        guard data.count <= 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (64...1024).contains(width), width.isMultiple(of: 64),
              height == width || height == width / 2,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ResourceError.invalid("请选择有效的 Minecraft PNG 皮肤，最大支持 1024 像素。")
        }
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(ResourceNetwork.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json, image/png;q=0.9", forHTTPHeaderField: "Accept")
        let response = try await transport(request, limit)
        guard response.status == 200 else { throw ResourceError.http(response.status) }
        guard response.data.count <= limit else { throw ResourceError.invalid("LittleSkin 返回的内容超过大小上限。") }
        return response.data
    }
}
