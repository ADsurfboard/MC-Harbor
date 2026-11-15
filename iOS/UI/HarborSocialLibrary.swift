import SwiftUI
import UIKit
import HarborCore
import CryptoKit
import Security

enum HarborGameEvents {
    static let started = Notification.Name("net.morben.harbor.game.started")
    static let stopped = Notification.Name("net.morben.harbor.game.stopped")
}
private final class HarborSocialObservation: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

private enum SocialCredential {
    static func query(_ endpoint: URL) -> [CFString: Any] {
        let account = SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: "net.morben.harbor.ios.friends", kSecAttrAccount: account]
    }
    static func read(_ endpoint: URL) -> String? {
        var query = query(endpoint); query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ token: String, endpoint: URL) throws {
        let query = query(endpoint), value = Data(token.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: value] as CFDictionary)
        var addition = query; addition[kSecValueData] = value; addition[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = update == errSecItemNotFound ? SecItemAdd(addition as CFDictionary, nil) : update
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

@MainActor final class HarborSocialLibrary: ObservableObject {
    static let defaultAvatar: UIImage? = {
        let bundle = Bundle(for: HarborRootFactory.self)
        guard let url = bundle.url(forResource: "steve", withExtension: "png"), let data = try? Data(contentsOf: url) else { return nil }
        return HarborSocialLibrary.face(data)
    }()
    @Published var snapshot: SocialSnapshot?
    @Published var busy = false
    @Published var error: String?
    @Published var status = "创建好友身份后即可使用内置服务，无需配置服务器。"
    @Published var live = false
    @Published var notes: [String: String] = [:]
    @Published var histories: [String: [SocialPlaySession]] = [:]
    @Published var messages: [String: [SocialMessage]] = [:]
    @Published var avatars: [String: UIImage] = [:]
    @Published var unread: Set<String> = []
    @Published var drafts: [String: String] = [:]
    @Published var selectedCompanions: Set<String> = []
    @Published var localHistory: [SocialPlaySession] = []
    let endpoint: URL
    private let settingsDirectory: URL
    private var localIdentity: String?
    private var settingsURL: URL? { localIdentity.map { settingsDirectory.appendingPathComponent($0 + ".json") } }
    private var secret: String?
    private let transport: ResourceTransport?
    private let home: URL
    private var historyStore: SocialPlayHistory?
    private var historyLoading: Task<SocialPlayHistory, Error>?
    private var historyLifecycle: Task<Void, Never>?
    private var historyTick: Task<Void, Never>?
    private var observations: [HarborSocialObservation] = []
    private var uploaded: [String: String] = [:]
    private var uploading = false
    private var operation: Task<Void, Never>?
    private var connection: Task<Void, Never>?
    private var ping: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var generation = UUID()
    private var reads: [String: Double] = [:]
    private var loadingAvatars: Set<String> = []
    private var avatarHashes: [String: String] = [:]
    private var pending: [String: (String, UUID)] = [:]
    private var sending: Set<String> = []
    private var refreshing = false
    private var active = false
    init(home: URL, transport: ResourceTransport? = nil, credential: String? = nil) {
        self.home = home
        self.transport = transport
        settingsDirectory = home.appendingPathComponent("harbor-social", isDirectory: true)
        let bundle = Bundle(for: HarborRootFactory.self)
        let services = bundle.url(forResource: "Services", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        let object = services.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        endpoint = URL(string: object?["friends"] ?? "https://mc-harbor-friends.dinakesidkeiwkkeksos.workers.dev")!
        secret = credential ?? SocialCredential.read(endpoint)
        let started = NotificationCenter.default.addObserver(forName: HarborGameEvents.started, object: nil, queue: .main) { [weak self] notification in
            guard let profile = notification.userInfo?["profile"] as? String, let instances = notification.userInfo?["instances"] as? Data else { return }
            Task { @MainActor [weak self] in self?.gameStarted(profile: profile, instances: instances) }
        }
        let stopped = NotificationCenter.default.addObserver(forName: HarborGameEvents.stopped, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.gameStopped() }
        }
        let foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.activate() }
        }
        let background = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.suspend() }
        }
        observations = [started, stopped, foreground, background].map(HarborSocialObservation.init)
    }
    private func loadLocal(for identity: String) {
        guard identity != localIdentity else { return }
        localIdentity = identity; notes = [:]; reads = [:]; uploaded = [:]
        guard let settingsURL else { return }
        if let size = try? settingsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
           let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(LocalSettings.self, from: data) {
            notes = saved.notes; reads = saved.reads; uploaded = saved.uploaded ?? [:]
        }
    }
    private struct LocalSettings: Codable { var notes: [String: String]; var reads: [String: Double]; var uploaded: [String: String]? }
    private func save() {
        guard let settingsURL else { return }
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(LocalSettings(notes: notes, reads: reads, uploaded: uploaded)).write(to: settingsURL, options: .atomic)
        } catch { self.error = "本机备注保存失败：" + error.localizedDescription }
    }
    private func client(token: String? = nil) throws -> SocialClient { try SocialClient(endpoint: endpoint, token: token ?? secret, transport: transport) }
    var recoverySecret: String? { secret }
    func setNote(_ value: String, for person: SocialPerson) {
        guard snapshot?.friends.contains(where: { $0.id == person.id }) == true else { return }
        notes[person.id] = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)); save()
    }
    func name(_ person: SocialPerson) -> String { notes[person.id].flatMap { $0.isEmpty ? nil : $0 } ?? person.name }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    func register(_ name: String) {
        perform {
            let token = try await self.client().register(name: name)
            // Keep a newly issued key in memory if Keychain saving fails, so
            // the user can still explicitly copy it instead of losing access.
            self.secret = token
            try SocialCredential.write(token, endpoint: self.endpoint)
            try await self.reload(); self.startLive()
        }
    }
    func restore(_ token: String) {
        perform {
            let candidate = try self.client(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            let value = try await candidate.snapshot()
            let valid = token.trimmingCharacters(in: .whitespacesAndNewlines)
            try SocialCredential.write(valid, endpoint: self.endpoint)
            self.suspend(); self.secret = valid; self.snapshot = value; self.histories = [:]; self.messages = [:]; self.avatars = [:]; self.avatarHashes = [:]; self.unread = []
            self.loadLocal(for: value.me.id); self.pending = [:]; self.sending = []; self.drafts = [:]; self.selectedCompanions = []
            self.active = true; self.generation = UUID(); self.startLive()
        }
    }
    func activate() {
        active = true
        let previous = historyLifecycle
        historyLifecycle = Task {
            await previous?.value
            guard active else { return }
            do {
                let store = try await prepareHistory(); localHistory = try await store.resume()
                if await store.hasActiveSession() { startHistoryTick() }
                try await syncHistory()
            } catch { self.error = error.localizedDescription }
        }
        guard secret != nil else { return }
        if connection == nil { perform { try await self.reload(); self.startLive() } }
    }
    func suspend() {
        active = false; generation = UUID(); live = false
        operation?.cancel(); connection?.cancel(); ping?.cancel(); fallback?.cancel()
        socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel()
        connection = nil; ping = nil; fallback = nil; socket = nil; session = nil
        historyTick?.cancel(); historyTick = nil
        let previous = historyLifecycle
        historyLifecycle = Task {
            await previous?.value
            do { if let historyStore { localHistory = try await historyStore.pause() } }
            catch { self.error = error.localizedDescription }
        }
    }
    func reload() async throws {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        let id = generation, value = try await client().snapshot()
        try Task.checkCancellation(); guard id == generation else { return }
        snapshot = value
        loadLocal(for: value.me.id)
        let allowed = Set(value.friends.map(\.id))
        histories = histories.filter { entry in allowed.contains(entry.key) && value.friends.contains(where: { $0.id == entry.key && $0.sharing }) }
        messages = messages.filter { allowed.contains($0.key) }
        avatars = avatars.filter { entry in
            let person = value.friends.first { $0.id == entry.key } ?? (entry.key == value.me.id ? value.me : nil)
            return person?.skinHash.isEmpty == false && person?.skinHash == avatarHashes[entry.key]
        }
        avatarHashes = avatarHashes.filter { avatars[$0.key] != nil }
        selectedCompanions.formIntersection(allowed); unread.formIntersection(allowed)
        status = "好友资料已同步"
        do { try await syncHistory() } catch { status = "好友可用；游戏动态同步暂不可用，可稍后刷新。" }
    }
    func request(_ code: String) { perform { try await self.client().request(code: code); try await self.reload() } }
    func respond(_ person: SocialPerson, accept: Bool) { perform { try await self.client().respond(id: person.id, accept: accept); try await self.reload() } }
    func remove(_ person: SocialPerson) { perform { try await self.client().remove(id: person.id); try await self.reload() } }
    func share(_ value: Bool) { perform { try await self.client().setSharing(value); if !value { self.uploaded = [:]; self.save() }; try await self.reload() } }
    func clearSkin() { perform { try await self.client().clearSkin(); try await self.reload() } }
    func shareSkin(_ data: Data, slim: Bool) {
        perform {
            guard SocialSkin.hasSafeDimensions(data), let image = UIImage(data: data), image.size.width == 64, [CGFloat(32), 64].contains(image.size.height) else { throw ResourceError.invalid("皮肤尺寸必须为64×64或64×32。") }
            try await self.client().shareSkin(data, slim: slim); try await self.reload()
        }
    }
    func loadHistory(_ person: SocialPerson) async {
        guard person.sharing, snapshot?.friends.contains(where: { $0.id == person.id }) == true else { histories[person.id] = nil; return }
        do {
            let id = generation, values = try await client().history(id: person.id)
            try Task.checkCancellation(); guard id == generation, snapshot?.friends.contains(where: { $0.id == person.id && $0.sharing }) == true else { return }
            histories[person.id] = values
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func loadAvatar(_ person: SocialPerson) async {
        guard !person.skinHash.isEmpty else { avatars[person.id] = nil; return }
        guard avatarHashes[person.id] != person.skinHash, loadingAvatars.insert(person.id).inserted else { return }
        defer { loadingAvatars.remove(person.id) }
        do {
            let id = generation, data = try await client().skin(id: person.id)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let current = snapshot?.friends.first { $0.id == person.id } ?? (snapshot?.me.id == person.id ? snapshot?.me : nil)
            guard !Task.isCancelled, id == generation, current?.skinHash == person.skinHash, hash == person.skinHash, let image = Self.face(data) else { return }
            if avatars.count >= 64, let first = avatars.keys.first { avatars.removeValue(forKey: first); avatarHashes.removeValue(forKey: first) }
            avatars[person.id] = image; avatarHashes[person.id] = hash
        } catch { /* The list remains usable when a friend revokes skin access. */ }
    }
    static func face(_ data: Data) -> UIImage? {
        guard SocialSkin.hasSafeDimensions(data), let source = UIImage(data: data)?.cgImage, source.width == 64, [32, 64].contains(source.height),
              let base = source.cropping(to: CGRect(x: 8, y: 8, width: 8, height: 8)) else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: base).draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
            if let overlay = source.cropping(to: CGRect(x: 40, y: 8, width: 8, height: 8)) {
                UIImage(cgImage: overlay).draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
        }
    }
    func refreshMessages(_ person: SocialPerson, markRead: Bool = true) async throws {
        guard snapshot?.friends.contains(where: { $0.id == person.id }) == true else { return }
        let id = generation, values = try await client().messages(id: person.id)
        try Task.checkCancellation(); guard id == generation, snapshot?.friends.contains(where: { $0.id == person.id }) == true else { return }
        messages[person.id] = values
        if markRead, let latest = values.last { reads[person.id] = latest.created; unread.remove(person.id); save() }
    }
    func markRead(_ person: SocialPerson) {
        if let latest = messages[person.id]?.last { reads[person.id] = latest.created; unread.remove(person.id); save() }
    }
    private func prepareHistory() async throws -> SocialPlayHistory {
        if let historyStore { return historyStore }
        if let historyLoading { return try await historyLoading.value }
        let home = home
        let loading = Task.detached(priority: .utility) { try SocialPlayHistory(home: home) }
        historyLoading = loading; defer { historyLoading = nil }
        let store = try await loading.value
        historyStore = store; localHistory = await store.snapshot(); return store
    }
    private func gameStarted(profile: String, instances: Data) {
        guard instances.count <= 4 * 1024 * 1024, let values = try? JSONDecoder().decode([PhoneInstance].self, from: instances), let instance = values.first(where: { $0.id == profile }) else { return }
        let allowed = Set(snapshot?.friends.map(\.id) ?? [])
        let previous = historyLifecycle, companions = Array(selectedCompanions.intersection(allowed).prefix(100))
        historyLifecycle = Task {
            await previous?.value
            do {
                let store = try await prepareHistory()
                localHistory = try await store.start(profile: profile, instance: instance.name, version: instance.gameVersion ?? instance.version, loader: instance.loader, friends: companions, running: UIApplication.shared.applicationState == .active)
                if UIApplication.shared.applicationState == .active { active = true; startHistoryTick() }
                try await syncHistory()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func gameStopped() {
        historyTick?.cancel(); historyTick = nil
        let previous = historyLifecycle
        historyLifecycle = Task {
            await previous?.value
            do { let store = try await prepareHistory(); localHistory = try await store.finish(); try await syncHistory() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func startHistoryTick() {
        guard historyTick == nil else { return }
        historyTick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled else { return }
                guard let self, self.active else { return }
                do { let store = try await self.prepareHistory(); self.localHistory = try await store.checkpoint(); try await self.syncHistory() }
                catch { self.status = "本机游戏记录或动态同步暂不可用，请返回好友页检查。" }
            }
        }
    }
    private func syncHistory() async throws {
        guard active, !uploading, let me = snapshot?.me, me.sharing else { return }
        uploading = true; defer { uploading = false }
        let id = generation, client = try client()
        var pending: [(SocialPlaySession, String)] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for value in localHistory.prefix(100) {
            let hash = SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
            if uploaded[value.id] != hash { pending.append((value, hash)) }
        }
        for start in stride(from: 0, to: pending.count, by: 25) {
            try Task.checkCancellation()
            guard id == generation, snapshot?.me.id == me.id, snapshot?.me.sharing == true else { return }
            let batch = Array(pending[start..<min(start + 25, pending.count)])
            try await client.uploadHistory(batch.map(\.0))
            guard id == generation, snapshot?.me.id == me.id else { return }
            for (record, hash) in batch { uploaded[record.id] = hash }
            let keep = Set(localHistory.map(\.id)); uploaded = uploaded.filter { keep.contains($0.key) }; save()
        }
    }
    func send(_ text: String, to person: SocialPerson, invite: SocialInvitation? = nil) async throws {
        guard snapshot?.friends.contains(where: { $0.id == person.id }) == true else { throw ResourceError.invalid("请先确认双方好友关系。") }
        guard sending.insert(person.id).inserted else { throw ResourceError.invalid("请等待上一条消息发送结束。") }
        defer { sending.remove(person.id) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let signatureData = Data(text.utf8) + (try invite.map { try encoder.encode($0) } ?? Data())
        let signature = SHA256.hash(data: signatureData).map { String(format: "%02x", $0) }.joined()
        let identifier = pending[person.id].flatMap { $0.0 == signature ? $0.1 : nil } ?? UUID()
        pending[person.id] = (signature, identifier)
        let id = generation, value = try await client().send(id: identifier, to: person.id, text: text, invite: invite)
        try Task.checkCancellation(); guard id == generation, snapshot?.friends.contains(where: { $0.id == person.id }) == true else { return }
        var rows = messages[person.id] ?? []; rows.removeAll { $0.id == value.id }; rows.append(value)
        messages[person.id] = Array(rows.sorted { $0.created < $1.created }.suffix(100)); pending[person.id] = nil
    }
    private func refreshInbox() async throws {
        let id = generation, inbox = try await client().inbox()
        guard id == generation else { return }
        let allowed = Set(snapshot?.friends.map(\.id) ?? [])
        unread = Set(inbox.filter { allowed.contains($0.peer) && $0.sender != snapshot?.me.id && $0.created > (reads[$0.peer] ?? 0) }.map(\.peer))
    }
    private func startLive() {
        guard active, connection == nil, secret != nil else { return }
        let id = generation
        connection = Task {
            var delay = 3.0
            while !Task.isCancelled, active, generation == id {
                do {
                    let client = try client(), health = try await client.health()
                    try Task.checkCancellation(); guard generation == id else { return }
                    try await refreshInbox()
                    guard health.realtime == true else { startFallback(id); return }
                    let (session, socket) = try client.liveSession(); self.session = session; self.socket = socket; socket.resume()
                    ping = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(25)); guard !Task.isCancelled else { return }
                            do {
                                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                    socket.sendPing { error in
                                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                                    }
                                }
                            } catch { return }
                        }
                    }
                    while !Task.isCancelled, generation == id {
                        let message = try await socket.receive()
                        let data: Data
                        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        guard data.count <= 4096, let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        live = true; delay = 3
                        if event["type"] as? String == "ready" { status = "实时聊天已连接" }
                        if event["type"] as? String == "friends" { try await reload() }
                        if event["type"] as? String == "chat", let peer = event["peer"] as? String, let person = snapshot?.friends.first(where: { $0.id == peer }) {
                            try await refreshMessages(person, markRead: false); try await refreshInbox()
                        }
                    }
                } catch {
                    if !Task.isCancelled, generation == id { live = false; status = "实时连接暂不可用，正在自动重连。"; startFallback(id) }
                }
                ping?.cancel(); socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel()
                guard !Task.isCancelled, generation == id else { return }
                try? await Task.sleep(for: .seconds(delay)); delay = min(60, delay * 2)
            }
        }
    }
    private func startFallback(_ id: UUID) {
        guard fallback == nil else { return }
        fallback = Task {
            while !Task.isCancelled, generation == id, active {
                try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled, generation == id else { return }
                if !live { try? await reload(); try? await refreshInbox() }
            }
        }
    }
}
