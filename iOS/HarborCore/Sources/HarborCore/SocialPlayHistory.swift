import Foundation

/// Records only real game-surface sessions reported by the native engine.
/// Foreground elapsed time uses system uptime, not the wall clock. Recovery
/// retains the last checkpoint and never invents time after an app was killed.
public actor SocialPlayHistory {
    private struct State: Codable {
        var schema = 1
        var records: [SocialPlaySession] = []
        var activeID: String?
        var activeProfile: String?
    }
    private let root: URL
    private let index: URL
    private var state: State
    private var activeUptime: Double?
    private var baseSeconds = 0.0
    public init(home: URL) throws {
        root = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("harbor-play-history", isDirectory: true)
        index = root.appendingPathComponent("history-v1.json")
        guard root.path == root.resolvingSymlinksInPath().path else { throw ResourceError.invalid("游玩记录目录包含符号链接。") }
        if FileManager.default.fileExists(atPath: index.path) {
            let info = try index.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard info.isSymbolicLink != true, (info.fileSize ?? .max) <= 4 * 1024 * 1024 else { throw ResourceError.invalid("游玩记录文件异常，原件已保留。") }
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: index))
            guard state.schema == 1, state.records.count <= 1000 else { throw ResourceError.invalid("游玩记录版本或数量异常，原件已保留。") }
            var ids: Set<String> = []
            for record in state.records {
                try record.validate()
                guard ids.insert(record.id).inserted else { throw ResourceError.invalid("游玩记录编号重复，原件已保留。") }
            }
            // A new process cannot know how long the previous one ran after
            // its last checkpoint. Preserve the saved duration exactly.
            state.activeID = nil; state.activeProfile = nil
        } else { state = State() }
    }
    public func snapshot() -> [SocialPlaySession] { state.records.sorted { $0.started > $1.started } }
    public func hasActiveSession() -> Bool { state.activeID != nil }
    private func update(uptime: Double) {
        guard let id = state.activeID, let index = state.records.firstIndex(where: { $0.id == id }), let activeUptime else { return }
        let previous = state.records[index]
        let elapsed = uptime.isFinite ? max(0, uptime - activeUptime) : 0
        let seconds = min(31_536_000, floor(baseSeconds + elapsed))
        state.records[index] = SocialPlaySession(id: previous.id, instance: previous.instance, version: previous.version, loader: previous.loader, world: previous.world, started: previous.started, seconds: seconds, friends: previous.friends)
    }
    private func save() throws {
        guard root.path == root.resolvingSymlinksInPath().path, index.path == index.resolvingSymlinksInPath().path else { throw ResourceError.invalid("游玩记录目录发生变化，已停止写入。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 4 * 1024 * 1024 else { throw ResourceError.invalid("游玩记录文件过大。") }
        try data.write(to: index, options: .atomic)
    }
    private func transaction(_ change: () -> Void) throws -> [SocialPlaySession] {
        let previous = state, previousUptime = activeUptime, previousSeconds = baseSeconds
        change()
        do { try save(); return snapshot() }
        catch { state = previous; activeUptime = previousUptime; baseSeconds = previousSeconds; throw error }
    }
    public func start(profile: String, instance: String, version: String, loader: String, friends: [String], running: Bool = true,
                      wallTime: Double = Date().timeIntervalSince1970, uptime: Double = ProcessInfo.processInfo.systemUptime) throws -> [SocialPlaySession] {
        guard !profile.isEmpty, profile.utf8.count <= 4096, uptime.isFinite else { throw ResourceError.invalid("游戏会话资料无效。") }
        if state.activeID != nil, state.activeProfile == profile { return try checkpoint(uptime: uptime) }
        let record = SocialPlaySession(instance: instance, version: version, loader: loader, started: wallTime, seconds: 0, friends: Array(Set(friends)).sorted())
        try record.validate()
        return try transaction {
            update(uptime: uptime)
            state.records.insert(record, at: 0); state.records = Array(state.records.prefix(1000))
            state.activeID = record.id; state.activeProfile = profile
            activeUptime = running ? uptime : nil; baseSeconds = 0
        }
    }
    public func checkpoint(uptime: Double = ProcessInfo.processInfo.systemUptime) throws -> [SocialPlaySession] {
        guard state.activeID != nil else { return snapshot() }
        return try transaction { update(uptime: uptime) }
    }
    public func pause(uptime: Double = ProcessInfo.processInfo.systemUptime) throws -> [SocialPlaySession] {
        guard state.activeID != nil else { return snapshot() }
        return try transaction {
            update(uptime: uptime)
            baseSeconds = state.records.first { $0.id == state.activeID }?.seconds ?? 0
            activeUptime = nil
        }
    }
    public func resume(uptime: Double = ProcessInfo.processInfo.systemUptime) throws -> [SocialPlaySession] {
        guard state.activeID != nil, activeUptime == nil, uptime.isFinite else { return snapshot() }
        return try transaction {
            baseSeconds = state.records.first { $0.id == state.activeID }?.seconds ?? 0
            activeUptime = uptime
        }
    }
    public func finish(uptime: Double = ProcessInfo.processInfo.systemUptime) throws -> [SocialPlaySession] {
        guard state.activeID != nil else { return snapshot() }
        return try transaction {
            update(uptime: uptime); state.activeID = nil; state.activeProfile = nil; activeUptime = nil; baseSeconds = 0
        }
    }
}
