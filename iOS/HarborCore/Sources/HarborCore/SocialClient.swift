import Foundation

public struct SocialPerson: Codable, Identifiable, Hashable, Sendable {
    public let id: String, code: String, name: String, skinHash: String, skinModel: String
    public let sharing: Bool
    public func validate() throws {
        guard UUID(uuidString: id) != nil, code.range(of: "^[A-Z0-9]{6,32}$", options: .regularExpression) != nil,
              !name.isEmpty, name.utf16.count <= 64, ["default", "slim"].contains(skinModel),
              skinHash.isEmpty || skinHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ResourceError.invalid("好友资料格式无效。") }
    }
}
public struct SocialSnapshot: Codable, Sendable {
    public let me: SocialPerson
    public let friends: [SocialPerson], requests: [SocialPerson], sent: [SocialPerson]
    public func validate() throws {
        guard friends.count + requests.count + sent.count <= 300 else { throw ResourceError.invalid("好友列表超出限制。") }
        try me.validate()
        var ids: Set<String> = []
        for person in friends + requests + sent {
            try person.validate()
            guard person.id != me.id, ids.insert(person.id).inserted else { throw ResourceError.invalid("好友列表包含重复身份。") }
        }
    }
}
public struct SocialPlaySession: Codable, Identifiable, Equatable, Sendable {
    public let id: String, instance: String, version: String, loader: String, world: String
    public let started: Double, seconds: Double
    public let friends: [String]
    public init(id: String = UUID().uuidString, instance: String, version: String, loader: String, world: String = "", started: Double, seconds: Double, friends: [String] = []) {
        self.id = id; self.instance = instance; self.version = version; self.loader = loader; self.world = world
        self.started = started; self.seconds = seconds; self.friends = friends
    }
    public func validate() throws {
        guard UUID(uuidString: id) != nil, !instance.isEmpty, instance.utf16.count <= 200, version.utf16.count <= 80,
              loader.utf16.count <= 80, world.utf16.count <= 200, started.isFinite, started > 0,
              seconds.isFinite, seconds >= 0, seconds <= 31_536_000, seconds.rounded(.down) == seconds, friends.count <= 100,
              friends.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw ResourceError.invalid("游戏动态数据无效。") }
    }
}
public struct SocialInvitation: Codable, Equatable, Sendable {
    public let transport: String, target: String, instance: String, version: String, loader: String
    public init(transport: String, target: String, instance: String = "", version: String = "", loader: String = "") {
        self.transport = transport; self.target = target; self.instance = instance; self.version = version; self.loader = loader
    }
    public func validate() throws {
        guard ["terracotta", "address"].contains(transport), !target.isEmpty, target.utf16.count <= 260,
              !target.contains(where: { $0.isWhitespace || $0.isNewline }),
              !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              instance.utf16.count <= 200, version.utf16.count <= 80, loader.utf16.count <= 80 else { throw ResourceError.invalid("联机邀请格式无效。") }
        if transport == "address" {
            guard !target.contains("/"), !target.contains("@"), !target.contains("?"), !target.contains("#"),
                  let value = URLComponents(string: "minecraft://" + target), let host = value.host, !host.isEmpty,
                  value.port == nil || (1...65535).contains(value.port ?? 0), value.user == nil else { throw ResourceError.invalid("请填写服务器域名或 IP，可附加端口。") }
        }
    }
}
public struct SocialMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String, sender: String, kind: String, text: String
    public let invite: SocialInvitation?
    public let created: Double, expires: Double
    public func validate() throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: sender) != nil, ["text", "invite"].contains(kind),
              text.utf16.count <= 2000, created.isFinite, expires.isFinite, expires > created,
              (kind == "invite") == (invite != nil) else { throw ResourceError.invalid("聊天消息格式无效。") }
        try invite?.validate()
    }
}
public struct SocialInboxEntry: Codable, Sendable { public let peer: String, sender: String; public let created: Double }
public struct SocialHealth: Codable, Sendable { public let ok: Bool; public let chat: Bool?; public let realtime: Bool? }

public enum SocialSkin {
    /// Check IHDR dimensions before any image decompression on the UI thread.
    public static func hasSafeDimensions(_ data: Data) -> Bool {
        let header = Array(data.prefix(33))
        guard (33...131_072).contains(data.count), data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              Array(header[12..<16]) == Array("IHDR".utf8) else { return false }
        func number(_ start: Int) -> UInt32 { header[start..<(start + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        return number(16) == 64 && [UInt32(32), 64].contains(number(20))
    }
    public static func readCoordinated(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let result = CoordinatedSkinResult()
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            do {
                let file = try FileHandle(forReadingFrom: coordinated); defer { try? file.close() }
                let data = try file.read(upToCount: 131_073) ?? Data()
                guard hasSafeDimensions(data) else { throw ResourceError.invalid("请选择64×64或64×32的 PNG 皮肤，且文件不超过128 KB。") }
                result.set(.success(data))
            } catch { result.set(.failure(error)) }
        }
        if let error { throw error }
        return try result.get()
    }
}

private final class CoordinatedSkinResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data, Error>?
    func set(_ result: Result<Data, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() throws -> Data {
        lock.lock(); let result = value; lock.unlock()
        guard let result else { throw ResourceError.invalid("文件提供方未返回皮肤数据。") }; return try result.get()
    }
}

private final class SocialOriginGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(_ origin: URL) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.host == origin.host, url.port == origin.port, url.scheme == origin.scheme else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum SocialHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()
    static func fetch(_ request: URLRequest, limit: Int) async throws -> ResourceHTTPResult {
        guard let origin = request.url else { throw ResourceError.invalid("好友服务地址无效。") }
        let (bytes, response) = try await session.bytes(for: request, delegate: SocialOriginGuard(origin))
        guard response.expectedContentLength <= Int64(limit) else { throw ResourceError.invalid("好友服务响应过大。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ResourceError.invalid("好友服务响应过大。") }
            data.append(byte); if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return ResourceHTTPResult(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Protocol-compatible with the existing Mac service. The application ships a
/// public service URL only; recovery secrets belong exclusively to the device.
public struct SocialClient: Sendable {
    public let endpoint: URL
    private let token: String?
    private let transport: ResourceTransport
    public init(endpoint: URL, token: String? = nil, allowLoopbackForTests: Bool = false, transport: ResourceTransport? = nil) throws {
        let local = allowLoopbackForTests && endpoint.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(endpoint.host ?? "")
        guard (ResourceNetwork.publicHTTPS(endpoint) || local), endpoint.path.isEmpty || endpoint.path == "/", endpoint.query == nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil else { throw ResourceError.invalid("好友服务必须是 HTTPS 根地址。") }
        if let token { guard token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil else { throw ResourceError.invalid("好友身份恢复密钥格式无效。") } }
        self.endpoint = endpoint; self.token = token; self.transport = transport ?? SocialHTTP.fetch
    }
    private func peer(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw ResourceError.invalid("好友身份编号无效。") }; return value
    }
    private func raw(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true, limit: Int = 2 * 1024 * 1024) async throws -> Data {
        guard !authenticated || token != nil else { throw ResourceError.unavailable("请先创建好友身份或导入恢复密钥。") }
        var request = URLRequest(url: endpoint.appendingPathComponent(path), timeoutInterval: 15)
        request.httpMethod = method; request.httpBody = body
        request.setValue(ResourceNetwork.userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated, let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let response = try await transport(request, limit); try Task.checkCancellation()
        guard response.data.count <= limit else { throw ResourceError.invalid("好友服务响应过大。") }
        guard (200..<300).contains(response.status) else {
            let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let message = (object?["error"] as? String).map { String($0.prefix(300)) }
            throw ResourceError.unavailable(message ?? "好友服务返回 HTTP \(response.status)，请稍后重试。")
        }
        return response.data
    }
    private func json<T: Decodable & Sendable>(_ path: String, as: T.Type = T.self, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> T {
        try JSONDecoder().decode(T.self, from: await raw(path, method: method, body: body, authenticated: authenticated))
    }
    private func body(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) }
    public func health() async throws -> SocialHealth { try await json("health", authenticated: false) }
    public func register(name: String) async throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 40, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ResourceError.invalid("昵称需为 1—40 个字符。") }
        struct Registration: Decodable, Sendable { let token: String }
        let result: Registration = try await json("v1/register", method: "POST", body: body(["name": name]), authenticated: false)
        guard result.token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil else { throw ResourceError.invalid("好友服务返回的身份密钥格式无效。") }
        return result.token
    }
    public func snapshot() async throws -> SocialSnapshot {
        let result: SocialSnapshot = try await json("v1/friends"); try result.validate(); return result
    }
    public func request(code: String) async throws {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.range(of: "^[A-Z0-9]{6,12}$", options: .regularExpression) != nil else { throw ResourceError.invalid("请输入对方完整的好友码。") }
        _ = try await raw("v1/friends/request", method: "POST", body: body(["code": code]))
    }
    public func respond(id: String, accept: Bool) async throws { _ = try await raw("v1/friends/respond", method: "POST", body: body(["id": try peer(id), "accept": accept])) }
    public func remove(id: String) async throws { _ = try await raw("v1/friends/" + peer(id), method: "DELETE") }
    public func setSharing(_ enabled: Bool) async throws { _ = try await raw("v1/me", method: "PUT", body: body(["sharing": enabled])) }
    public func deleteIdentity() async throws { _ = try await raw("v1/me", method: "DELETE") }
    public func skin(id: String) async throws -> Data { try await raw("v1/skin/" + peer(id), limit: 128 * 1024) }
    public func shareSkin(_ png: Data, slim: Bool) async throws {
        guard SocialSkin.hasSafeDimensions(png) else { throw ResourceError.invalid("请选择64×64或64×32的 Minecraft PNG 皮肤。") }
        _ = try await raw("v1/me", method: "PUT", body: body(["skin": png.base64EncodedString(), "skinModel": slim ? "slim" : "default"]))
    }
    public func clearSkin() async throws { _ = try await raw("v1/me", method: "PUT", body: body(["clearSkin": true])) }
    public func history(id: String) async throws -> [SocialPlaySession] {
        let result: [SocialPlaySession] = try await json("v1/history/" + peer(id))
        guard result.count <= 1000 else { throw ResourceError.invalid("游戏动态数量超出限制。") }
        for item in result { try item.validate() }; return result
    }
    public func uploadHistory(_ values: [SocialPlaySession]) async throws {
        guard values.count <= 25 else { throw ResourceError.invalid("动态每批最多25条。") }
        for value in values { try value.validate() }
        struct Payload: Encodable { let entries: [SocialPlaySession] }
        _ = try await raw("v1/history", method: "PUT", body: JSONEncoder().encode(Payload(entries: values)))
    }
    public func inbox() async throws -> [SocialInboxEntry] {
        let result: [SocialInboxEntry] = try await json("v1/inbox")
        guard result.count <= 300, result.allSatisfy({ UUID(uuidString: $0.peer) != nil && UUID(uuidString: $0.sender) != nil && $0.created.isFinite }) else { throw ResourceError.invalid("未读消息列表无效。") }; return result
    }
    public func messages(id: String) async throws -> [SocialMessage] {
        let values: [SocialMessage] = try await json("v1/messages/" + peer(id))
        guard values.count <= 100 else { throw ResourceError.invalid("聊天消息数量超出限制。") }
        for value in values { try value.validate() }; return values.filter { $0.expires > Date().timeIntervalSince1970 }
    }
    public func send(id: UUID, to: String, text: String, invite: SocialInvitation? = nil) async throws -> SocialMessage {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf16.count <= 2000, invite != nil || !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value < 9 || (11...31).contains($0.value) }) else { throw ResourceError.invalid("消息需为 1—2000 个字符。") }
        try invite?.validate()
        struct Payload: Encodable { let id: String, kind: String, text: String; let invite: SocialInvitation? }
        let body = try JSONEncoder().encode(Payload(id: id.uuidString, kind: invite == nil ? "text" : "invite", text: text, invite: invite))
        let message: SocialMessage = try await json("v1/messages/" + peer(to), method: "POST", body: body)
        try message.validate(); guard message.id.caseInsensitiveCompare(id.uuidString) == .orderedSame else { throw ResourceError.invalid("消息回执编号不匹配。") }; return message
    }
    public func liveRequest() throws -> URLRequest {
        guard let token else { throw ResourceError.unavailable("请先创建好友身份。") }
        var url = URLComponents(url: endpoint.appendingPathComponent("v1/live"), resolvingAgainstBaseURL: false)!
        url.scheme = endpoint.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: url.url!, timeoutInterval: 20)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue(ResourceNetwork.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
    public func liveSession() throws -> (URLSession, URLSessionWebSocketTask) {
        let request = try liveRequest()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: SocialOriginGuard(request.url!), delegateQueue: nil)
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 4096
        return (session, socket)
    }
}
