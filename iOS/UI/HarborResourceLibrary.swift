import SwiftUI
import HarborCore
import Security

enum HarborResourcePreferences {
    static let route = "harbor.ios.resources.route"
    static let provider = "harbor.ios.translation.provider"
    static let summaries = "harbor.ios.translation.summaries"
    static var selectedRoute: ResourceRoute { ResourceRoute(rawValue: UserDefaults.standard.string(forKey: route) ?? "") ?? .domesticFirst }
    static var selectedProvider: ResourceTranslationProvider { ResourceTranslationProvider(rawValue: UserDefaults.standard.string(forKey: provider) ?? "") ?? .bilibili }
    static func aliKey() -> String? {
        var result: CFTypeRef?
        guard SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "net.morben.harbor.ios.translation", kSecAttrAccount: "aliyun", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func saveAliKey(_ value: String) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: "net.morben.harbor.ios.translation", kSecAttrAccount: "aliyun"] as CFDictionary
        if value.isEmpty {
            let result = SecItemDelete(query)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }; return
        }
        let update = SecItemUpdate(query, [kSecValueData: Data(value.utf8)] as CFDictionary)
        let result = update == errSecItemNotFound ? SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: "net.morben.harbor.ios.translation", kSecAttrAccount: "aliyun", kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil) : update
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
}

@MainActor final class HarborResourceLibrary: ObservableObject {
    @Published var source: ResourceSource = .modrinth
    @Published var kind: ResourceKind = .mod
    @Published var selectedProfile = ""
    @Published var query = ""
    @Published var page = 0
    @Published var projects: [ResourceProject] = []
    @Published var total = 0
    @Published var loading = false
    @Published var searchError: String?
    @Published var searchedQuery: String?
    @Published var installing = false
    @Published var progress = 0.0
    @Published var progressText = ""
    @Published var notice: String?
    @Published var error: String?
    let services: HarborNativeServices
    private let installer: ResourceInstaller
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    init(services: HarborNativeServices) {
        self.services = services; installer = ResourceInstaller(home: services.harborHomeURL)
    }
    func search(target: ResourceTarget?) async {
        let current = UUID(); generation = current
        loading = true; searchError = nil; projects = []; searchedQuery = nil
        defer { if current == generation { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let translated: String
            if ResourceNames.containsChinese(text) {
                if let known = ResourceNames.english(text) { translated = known }
                else { translated = try await ResourceTextService.shared.translate(text, toChinese: false, provider: HarborResourcePreferences.selectedProvider, aliKey: HarborResourcePreferences.aliKey()) }
            } else { translated = text }
            try Task.checkCancellation()
            let chosen = kind == .mod && !["fabric", "forge", "quilt", "neoforge"].contains(target?.loader ?? "") ? nil : target
            let result = try await ResourceCatalog(route: HarborResourcePreferences.selectedRoute).search(translated, source: source, kind: kind, target: chosen, page: page)
            try Task.checkCancellation(); guard current == generation else { return }
            projects = result.projects; total = result.total
            searchedQuery = translated == text ? nil : translated
        } catch is CancellationError { }
        catch { if current == generation { searchError = error.localizedDescription } }
    }
    func cancel() { operation?.cancel() }
    func install(_ version: ResourceVersion, project: ResourceProject, kind: ResourceKind, into instance: PhoneInstance) {
        guard !installing, let target = instance.resourceTarget else { return }
        installing = true; progress = 0; progressText = "检查兼容版本与必要前置"
        let route = HarborResourcePreferences.selectedRoute
        operation = Task {
            defer { installing = false; operation = nil }
            do {
                let plan = try await ResourceCatalog(route: route).plan(version, source: project.source, kind: kind, target: target)
                try Task.checkCancellation()
                struct Access: Decodable { let token: String; let directory: String }
                let access = try JSONDecoder().decode(Access.self, from: services.beginResourceAccess(profile: instance.id, kind: kind.directory))
                defer { services.endModAccess(token: access.token) }
                let count = try await installer.install(plan, kind: kind, destination: URL(fileURLWithPath: access.directory), route: route) { done, total, file in
                    await MainActor.run { self.progress = Double(done) / Double(max(1, total)); self.progressText = file }
                }
                showNotice(count == 0 ? "这些文件已经安装，已校验内容一致。" : "\(project.title) 与必要前置已安装，共 \(count) 个文件。")
            } catch is CancellationError { showNotice("下载已取消，已有资源已保留。") }
            catch { self.error = error.localizedDescription }
        }
    }
    private func showNotice(_ value: String) {
        noticeTask?.cancel(); withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { notice = value }
        noticeTask = Task {
            try? await Task.sleep(for: .milliseconds(3500)); guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { notice = nil }
        }
    }
}

struct HarborResourceSettings: View {
    @AppStorage(HarborResourcePreferences.route) private var route = ResourceRoute.domesticFirst.rawValue
    @AppStorage(HarborResourcePreferences.provider) private var provider = ResourceTranslationProvider.bilibili.rawValue
    @AppStorage(HarborResourcePreferences.summaries) private var summaries = true
    @State private var aliKey = ""
    @State private var message: String?
    var body: some View {
        Form {
            Section("下载来源") {
                Picker("来源顺序", selection: $route) {
                    Text("国内镜像优先").tag(ResourceRoute.domesticFirst.rawValue)
                    Text("官方优先，镜像备用").tag(ResourceRoute.officialFirst.rawValue)
                }.accessibilityIdentifier("resources.route")
                Text("默认优先 MCIM 国内镜像，Modrinth 和资源文件失败后尝试原站。CurseForge 的公开镜像用于读取资料；作者未开放直接下载的文件会提供原项目链接，不会猜测下载地址。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("中文搜索与简介") {
                Toggle("简介自动汉化", isOn: $summaries).accessibilityIdentifier("resources.translate")
                Picker("翻译服务", selection: $provider) {
                    ForEach(ResourceTranslationProvider.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.accessibilityIdentifier("resources.provider")
                Text("常用模组中文名可离线识别；其他中文关键词由所选服务转换后搜索。开启简介汉化时先显示加载状态，成功后显示中文；失败可重试或主动查看原文。国外服务只在你选择后使用。")
                    .font(.footnote).foregroundStyle(.secondary)
                if provider == ResourceTranslationProvider.aliyun.rawValue {
                    SecureField("阿里云 API Key", text: $aliKey).textContentType(.password)
                    Button("保存密钥") { saveKey(aliKey) }.frame(minHeight: 44).disabled(aliKey.isEmpty)
                    Button("删除已保存的密钥", role: .destructive) { saveKey("") }.frame(minHeight: 44)
                    Text("使用阿里云北京地域 Qwen-MT 接口，可能按你的套餐计费。密钥仅存本机钥匙串，不同步到项目或好友服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.footnote) }
            }
            Section("安装保护") {
                Text("资源按实例的 Minecraft 版本与加载器筛选。安装模组时同时检查必要前置；最多三路下载，逐个校验后再写入。已有同名且不同内容的文件会阻止安装并保留原件。游戏运行或其他文件操作期间禁止改写实例。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("光影文件可以管理；是否能渲染仍取决于 iOS 图形运行层及光影自身的兼容性。切到后台会取消当前下载，回到前台可重新开始。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.harborPageBackground().navigationTitle("资源与翻译").navigationBarTitleDisplayMode(.inline)
    }
    private func saveKey(_ value: String) {
        do { try HarborResourcePreferences.saveAliKey(value); aliKey = ""; message = value.isEmpty ? "密钥已删除。" : "密钥已保存在本机钥匙串。" }
        catch { message = error.localizedDescription }
    }
}
