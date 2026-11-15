import SwiftUI
import HarborCore

private func localizationBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .utility, operation: work)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

@MainActor final class HarborLocalizationLibrary: ObservableObject {
    @Published var project: LocalizationProject?
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var exported: URL?
    private let services: HarborNativeServices
    let instance: PhoneInstance
    private let store: LocalizationWorkspaceStore
    private var operation: Task<Void, Never>?
    private var loaded = false
    init(services: HarborNativeServices, instance: PhoneInstance) {
        self.services = services; self.instance = instance
        store = LocalizationWorkspaceStore(home: services.harborHomeURL, instance: instance.id)
    }
    func load() async {
        guard !loaded else { return }; loaded = true
        do { project = try await store.load() } catch { self.error = "读取已保存的汉化草稿失败，原件已保留：" + error.localizedDescription }
    }
    func cancel() { operation?.cancel() }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() }
            catch is CancellationError { status = "已停止，已经保存的译文保留。" }
            catch { self.error = error.localizedDescription }
        }
    }
    private func archive(_ file: URL) async throws -> [String: Data] {
        try Task.checkCancellation()
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            services.readModArchive(at: file, entry: "@harbor-language-files") { data, message in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ResourceError.invalid(message ?? "语言归档读取失败。")) }
            }
        }
        try Task.checkCancellation()
        guard bytes.count <= 36 * 1024 * 1024 else { throw ResourceError.invalid("语言归档响应过大。") }
        let encoded = try JSONDecoder().decode([String: String].self, from: bytes)
        var result: [String: Data] = [:]
        for (path, base64) in encoded {
            guard let data = Data(base64Encoded: base64) else { throw ResourceError.invalid("语言归档未完整读取。") }
            result[path] = data
        }
        return result
    }
    func scan() {
        run {
            struct Access: Decodable { let token: String; let directory: String; let files: [String] }
            let access = try JSONDecoder().decode(Access.self, from: self.services.beginModAccess(profile: self.instance.id))
            defer { self.services.endModAccess(token: access.token) }
            let root = URL(fileURLWithPath: access.directory).deletingLastPathComponent()
            var result = try await localizationBackground { try LocalizationScanner.loose(instance: root) }
            var archives: [(URL, String, String)] = access.files.map { (URL(fileURLWithPath: $0), "mods/" + URL(fileURLWithPath: $0).lastPathComponent, "mods") }
            let packs = root.appendingPathComponent("resourcepacks")
            if FileManager.default.fileExists(atPath: packs.path) {
                guard packs.path == packs.resolvingSymlinksInPath().path else { throw ResourceError.invalid("资源包目录包含符号链接。") }
                let files = try FileManager.default.contentsOfDirectory(at: packs, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard files.count <= 2048 else { throw ResourceError.invalid("资源包数量过多，请分批处理。") }
                for file in files where file.pathExtension.lowercased() == "zip" { archives.append((file, "resourcepacks/" + file.lastPathComponent, "resourcepacks")) }
            }
            var total = result.sources.reduce(0) { $0 + max($1.originalFiles.values.reduce(0) { $0 + $1.count }, $1.documents.reduce(0) { $0 + $1.original.count }) }
            for (index, item) in archives.enumerated() {
                try Task.checkCancellation(); self.status = "读取语言 \(index + 1)/\(archives.count) · " + item.0.lastPathComponent
                do {
                    let entries = try await self.archive(item.0)
                    let source = try await localizationBackground { try LocalizationScanner.archive(entries: entries, name: item.0.lastPathComponent, installPath: item.1, kind: item.2) }
                    total += source.originalFiles.values.reduce(0) { $0 + $1.count }
                    guard total <= 24 * 1024 * 1024 else { throw ResourceError.invalid("实例语言超过 24 MB，请拆分资源后扫描。") }
                    if !source.documents.isEmpty || !source.originalFiles.isEmpty { result.sources.append(source) }
                } catch is CancellationError { throw CancellationError() }
                catch { result.warnings.append(item.0.lastPathComponent + "：" + error.localizedDescription) }
            }
            try Task.checkCancellation()
            var fresh = LocalizationProject(name: self.project?.name ?? self.instance.name + " 汉化", packFormat: self.project?.packFormat ?? 15, sources: result.sources, warnings: result.warnings)
            if let previous = self.project { fresh.inheritDrafts(from: previous) }
            try await self.store.save(fresh); self.project = fresh
            self.status = "读取 \(fresh.sources.count) 个实例资源，\(fresh.counts.total) 条；\(fresh.warnings.count) 项处理记录。"
        }
    }
    func save(_ value: LocalizationProject) async throws { try await store.save(value); project = value }
    func select(_ id: String, enabled: Bool) {
        guard !busy, var value = project, let index = value.sources.firstIndex(where: { $0.id == id }) else { return }
        value.sources[index].selected = enabled
        run { try await self.save(value) }
    }
    func edit(row: String, value: String) {
        guard var project else { return }
        run { try project.setTranslation(row: row, value: value); try await self.save(project); self.status = "译文已保存。" }
    }
    func rename(_ name: String, format: Int) {
        guard var project else { return }
        run { project.name = name; project.packFormat = format; try await self.save(project) }
    }
    func translate() {
        guard let current = project else { return }
        let provider = HarborResourcePreferences.selectedProvider, key = HarborResourcePreferences.aliKey()
        run {
            var value = current
            var pending: [(Int, Int, Int, LocalizationRow)] = []
            for s in value.sources.indices where value.sources[s].selected { for d in value.sources[s].documents.indices { for r in value.sources[s].documents[d].rows.indices {
                let row = value.sources[s].documents[d].rows[r]
                if row.translation.isEmpty { pending.append((s, d, r, row)) }
            } } }
            guard pending.count <= 30_000 else { throw ResourceError.invalid("待译条目超过 30000，请只选择部分资源后翻译。") }
            var translated = 0, failed = 0, batch = 0
            for index in stride(from: 0, to: pending.count, by: 3) {
                try Task.checkCancellation()
                let chunk = Array(pending[index..<min(index + 3, pending.count)])
                let results = await withTaskGroup(of: (Int, String?, String?).self) { group in
                    for (offset, item) in chunk.enumerated() {
                        group.addTask {
                            do {
                                let text = try await ResourceTextService.shared.translate(item.3.source, provider: provider, aliKey: key, forceTranslation: true)
                                guard LocalizationPlaceholders.compatible(item.3.source, text) else { throw ResourceError.invalid("译文占位符 / 格式不符") }
                                return (offset, text, nil)
                            } catch { return (offset, nil, error.localizedDescription) }
                        }
                    }
                    var results: [(Int, String?, String?)] = []
                    for await result in group { results.append(result) }; return results
                }
                for result in results {
                    let item = chunk[result.0]
                    if let text = result.1 { value.sources[item.0].documents[item.1].rows[item.2].translation = text; translated += 1 }
                    else {
                        failed += 1
                        if value.warnings.count < 200 { value.warnings.append(item.3.key + "：" + (result.2 ?? "未完成")) }
                    }
                }
                batch += 1
                if batch % 4 == 0 || index + 3 >= pending.count || Task.isCancelled {
                    try await self.store.save(value); self.project = value
                }
                self.status = "已翻译 \(translated) 条，未完成 \(failed) 条；处理 \(min(index + 3, pending.count))/\(pending.count)。"
                try Task.checkCancellation()
                if translated == 0 && failed >= 12 { throw ResourceError.unavailable("连续翻译失败，已停止避免无效重试。请检查所选翻译服务，已保存部分可继续补全。") }
            }
            try await self.save(value)
            self.status = "新增 \(translated) 条译文；仍待翻译 \(value.counts.total - value.counts.translated) 条。未完成条目可重试或手动编辑。"
        }
    }
    func export(sourceOnly: Bool) {
        guard let project else { return }
        run {
            self.status = "打包与校验"
            let home = self.services.harborHomeURL.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("harbor-localization-exports")
            guard home.path == home.resolvingSymlinksInPath().path else { throw ResourceError.invalid("导出目录包含符号链接。") }
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let file = home.appendingPathComponent(UUID().uuidString + (sourceOnly ? "-未汉化.zip" : "-汉化.zip"))
            try await localizationBackground { try LocalizationZIP.write(LocalizationPack.entries(project, sourceOnly: sourceOnly), to: file) }
            self.exported = file; self.status = sourceOnly ? "已提取未汉化原文，可分享给 AI。" : "汉化包已导出。任务和数据包译文位于 overrides，请备份后应用。"
        }
    }
    func apply() {
        guard let project else { return }
        run {
            struct Access: Decodable { let token: String; let directory: String }
            let access = try JSONDecoder().decode(Access.self, from: self.services.beginModAccess(profile: self.instance.id))
            defer { self.services.endModAccess(token: access.token) }
            let root = URL(fileURLWithPath: access.directory).deletingLastPathComponent(), home = self.services.harborHomeURL
            let result = try await localizationBackground { try LocalizationApply.apply(project, instance: root, backupHome: home) }
            self.status = "已应用 \(result.files) 个任务 / 数据包文本；原文件备份已保留。"
            if let backup = result.backup { self.exported = backup }
        }
    }
    func importTranslations(_ file: URL) {
        guard let current = project else { return }
        run {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            var value = current, changes: [String: String] = [:]
            if file.pathExtension.lowercased() == "zip" {
                let entries = try await self.archive(file)
                for source in value.sources where source.selected { for doc in source.documents where doc.kind == .languageJSON || doc.kind == .languageLegacy {
                    let target = doc.path.replacingOccurrences(of: #"(?i)/en_(?:us|gb)\."#, with: "/zh_cn.", options: .regularExpression)
                    if let translated = entries.first(where: { $0.key.caseInsensitiveCompare(target) == .orderedSame }) {
                        let chinese = try LocalizationDocument.read(translated.value, path: translated.key, kind: doc.kind)
                        let terms = Dictionary(chinese.rows.map { ($0.key, $0.source) }, uniquingKeysWith: { first, _ in first })
                        for row in doc.rows { if let text = terms[row.key] { changes[row.id] = text } }
                    }
                } }
            } else {
                let data = try await localizationBackground {
                    var result: Data?, failure: NSError?, inner: Error?
                    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: .withoutChanges, error: &failure) { url in
                        do {
                            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw ResourceError.invalid("译文 JSON 超过 8 MB。") }
                            result = try Data(contentsOf: url)
                        } catch { inner = error }
                    }
                    if let failure { throw failure }
                    if let inner { throw inner }
                    guard let result else { throw ResourceError.invalid("未完整读取译文 JSON。") }; return result
                }
                let json = try JSONSerialization.jsonObject(with: data)
                if let map = json as? [String: String] { changes = map }
                else if let rows = json as? [[String: Any]] {
                    for row in rows { if let id = row["id"] as? String, let translation = row["translation"] as? String { changes[id] = translation } }
                } else { throw ResourceError.invalid("请选择导出的 AI 条目 JSON，并在每条中填写 translation；或导入同结构中文资源包 ZIP。") }
            }
            var accepted = 0, rejected = 0
            for s in value.sources.indices where value.sources[s].selected { for d in value.sources[s].documents.indices { for r in value.sources[s].documents[d].rows.indices {
                let row = value.sources[s].documents[d].rows[r]
                guard let text = changes[row.id], !text.isEmpty else { continue }
                if LocalizationPlaceholders.compatible(row.source, text) { value.sources[s].documents[d].rows[r].translation = text; accepted += 1 }
                else { rejected += 1 }
            } } }
            guard accepted > 0 else { throw ResourceError.invalid("没有可匹配的有效译文。请保留原导出包中的 id、键和占位符，不能用其他实例的条目替代。") }
            try await self.save(value); self.status = "已导入 \(accepted) 条；\(rejected) 条格式不符，保留原有译文。"
        }
    }
}
