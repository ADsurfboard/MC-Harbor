import SwiftUI
import HarborCore
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    static let harborFolderMods = UTType(exportedAs: "net.morben.harbor.folder-mods", conformingTo: .data)
}
struct HarborModDrag: Transferable, Codable {
    let value: FolderModDrag
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .harborFolderMods)
    }
}
private struct InstanceModAccess: Decodable { let token: String; let directory: String; let files: [String] }

@MainActor final class HarborFolderLibrary: ObservableObject {
    @Published var snapshot = ModFolderSnapshot()
    @Published var busy = false
    @Published var progress = ""
    @Published var error: String?
    @Published var notice: String?
    let root: URL
    let services: HarborNativeServices
    private var storage: ModFolderLibrary?
    private var operation: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    init(services: HarborNativeServices) {
        self.services = services
        root = services.harborHomeURL.appendingPathComponent("harbor-mod-folders", isDirectory: true)
    }
    func load() async {
        guard storage == nil, !busy else { return }
        busy = true; progress = "读取模组夹"
        do {
            let url = root
            let actor = try await Task.detached(priority: .utility) { try ModFolderLibrary(root: url) }.value
            storage = actor; snapshot = await actor.snapshot()
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    func run(_ label: String, operation: @escaping @MainActor (ModFolderLibrary) async throws -> String) {
        guard !busy, let storage else { return }
        busy = true; progress = label
        self.operation = Task {
            defer { busy = false; self.operation = nil }
            do {
                let message = try await operation(storage)
                snapshot = await storage.snapshot(); showNotice(message)
            } catch is CancellationError { showNotice("已取消，原文件已保留。") }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel() }
    func showNotice(_ text: String) {
        noticeTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { notice = text }
        noticeTask = Task {
            try? await Task.sleep(for: .milliseconds(3500))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { notice = nil }
        }
    }
    func imageURL(_ mod: FolderMod) -> URL? {
        mod.hasIcon ? root.appendingPathComponent("icons/" + mod.id + ".png") : nil
    }
    private func archive(_ url: URL, entry: String?) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            services.readModArchive(at: url, entry: entry) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ModFolderError.invalid(error ?? "无法读取模组归档。")) }
            }
        }
    }
    private func read(_ files: [URL], staging: URL) async throws -> [FolderModImport] {
        guard files.count <= 4000 else { throw ModFolderError.invalid("一次最多收藏 4000 个模组。") }
        var imports: [FolderModImport] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation(); progress = "读取 \(index + 1) / \(files.count) · \(file.lastPathComponent)"
            let data = try await archive(file, entry: nil)
            let encoded = try JSONDecoder().decode([String: String].self, from: data)
            let entries = encoded.compactMapValues { Data(base64Encoded: $0) }
            let metadata = try ModArchiveMetadata.read(entries: entries, filename: file.lastPathComponent)
            var iconFile: URL?
            // A missing/oversized icon never prevents keeping an otherwise valid
            // mod. The real mod metadata remains visible in its details page.
            if let path = metadata.iconPath, let bytes = try? await archive(file, entry: path) {
                let target = staging.appendingPathComponent(UUID().uuidString + ".png")
                try await Task.detached(priority: .utility) { try bytes.write(to: target, options: .atomic) }.value
                iconFile = target
            }
            let mod = FolderMod(id: "", name: metadata.name, filename: file.lastPathComponent,
                version: metadata.version, loaders: metadata.loaders, gameVersions: metadata.gameVersions,
                summary: metadata.summary, authors: metadata.authors)
            imports.append(.init(file: file, metadata: mod, iconFile: iconFile))
        }
        return imports
    }
    func importFiles(_ files: [URL], into folder: UUID) {
        run("读取模组") { storage in
            let staging = try await self.makeStaging()
            defer { self.removeStaging(staging) }
            let imports = try await self.read(files, staging: staging)
            self.progress = "复制并校验收藏副本"
            let added = try await storage.importFiles(imports, to: folder)
            return "已收藏 \(added) 个模组，重复文件已跳过。原文件保留。"
        }
    }
    func collectInstance(_ instance: PhoneInstance, into folder: UUID) {
        run("读取实例模组") { storage in
            let access = try JSONDecoder().decode(InstanceModAccess.self, from: self.services.beginModAccess(profile: instance.id))
            defer { self.services.endModAccess(token: access.token) }
            if access.files.isEmpty { return "这个实例的 mods 文件夹中没有 JAR 模组。" }
            let staging = try await self.makeStaging()
            defer { self.removeStaging(staging) }
            let imports = try await self.read(access.files.map { URL(fileURLWithPath: $0) }, staging: staging)
            self.progress = "复制并校验收藏副本"
            let added = try await storage.importFiles(imports, to: folder)
            return "已从“\(instance.name)”收藏 \(added) 个模组。原实例未修改。"
        }
    }
    func install(_ ids: Set<String>, folder: UUID, into instance: PhoneInstance) {
        run("向实例复制所选模组") { storage in
            let access = try JSONDecoder().decode(InstanceModAccess.self, from: self.services.beginModAccess(profile: instance.id))
            defer { self.services.endModAccess(token: access.token) }
            let number = try await storage.install(ids, from: folder, to: URL(fileURLWithPath: access.directory, isDirectory: true))
            return "已向“\(instance.name)”添加 \(number) 个模组，已有相同文件已跳过。"
        }
    }
    func move(_ payload: FolderModDrag, to folder: UUID, at offset: Int? = nil, copy: Bool = false) {
        run(copy ? "复制收藏" : "移动收藏") { storage in
            try await storage.transfer(payload, to: folder, at: offset, copy: copy)
            return copy ? "已复制到模组夹。" : "已移动收藏。"
        }
    }
    private func makeStaging() async throws -> URL {
        try await Task.detached(priority: .utility) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("HarborFolderIcons-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }.value
    }
    private func removeStaging(_ url: URL) {
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }
}

enum HarborFolderOptions {
    static let icon = "harbor.folders.showIcon", loader = "harbor.folders.showLoader"
    static let version = "harbor.folders.showVersion", game = "harbor.folders.showGame"
    static let summary = "harbor.folders.showSummary", author = "harbor.folders.showAuthor"
    static let date = "harbor.folders.showDate"
}
struct HarborFolderDisplaySettings: View {
    @AppStorage(HarborFolderOptions.icon) private var icon = true
    @AppStorage(HarborFolderOptions.loader) private var loader = true
    @AppStorage(HarborFolderOptions.version) private var version = true
    @AppStorage(HarborFolderOptions.game) private var game = false
    @AppStorage(HarborFolderOptions.summary) private var summary = true
    @AppStorage(HarborFolderOptions.author) private var author = false
    @AppStorage(HarborFolderOptions.date) private var date = false
    var body: some View {
        Form {
            Section("列表显示的信息") {
                Label("模组名称始终显示", systemImage: "textformat")
                HarborSettingsToggle("模组图标", isOn: $icon); HarborSettingsToggle("Forge、Fabric 等加载器", isOn: $loader)
                HarborSettingsToggle("模组版本", isOn: $version); HarborSettingsToggle("Minecraft 版本或范围", isOn: $game)
                HarborSettingsToggle("模组简介", isOn: $summary); HarborSettingsToggle("作者", isOn: $author); HarborSettingsToggle("收藏时间", isOn: $date)
            }
            Section {
                Button("仅显示名称") { icon = false; loader = false; version = false; game = false; summary = false; author = false; date = false }
                    .frame(minHeight: 44)
                Button("恢复推荐显示") { icon = true; loader = true; version = true; game = false; summary = true; author = false; date = false }
                    .frame(minHeight: 44)
            } footer: { Text("这些选项只影响列表；点击模组仍能查看完整资料。未记录的版本不会被猜测或补造。") }
        }.harborPageBackground().navigationTitle("模组夹显示")
    }
}

struct HarborFoldersView: View {
    @ObservedObject var model: HarborFolderLibrary
    @State private var active: ModFolder?
    @State private var editing: ModFolder?
    @State private var pendingDeletion: ModFolder?
    @State private var newFolder = false
    @State private var query = ""
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 162, maximum: 260), spacing: 18)], spacing: 24) {
                ForEach(model.snapshot.folders.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { folder in
                    HarborFolderCard(folder: folder, model: model) { active = folder }
                        .accessibilityIdentifier("folder.open." + folder.name)
                        .contextMenu {
                            Button { active = folder } label: { Label("打开模组夹", systemImage: "folder") }
                            Button { editing = folder } label: { Label("名称与颜色", systemImage: "paintpalette") }
                            Button(role: .destructive) {
                                pendingDeletion = folder
                            } label: { Label("删除模组夹", systemImage: "trash") }
                        }
                        .dropDestination(for: HarborModDrag.self) { items, _ in
                            guard let payload = items.first?.value, !model.busy else { return false }
                            model.move(payload, to: folder.id); return true
                        }
                }
            }.padding(20)
            if model.snapshot.folders.isEmpty && !model.busy {
                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("把常用模组整理在一起").font(.title3.bold())
                    Text("新建模组夹后，可从文件或整个实例收藏模组，再批量添加到另一个实例。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("新建模组夹") { newFolder = true }.frame(minHeight: 44).harborGlassButton(prominent: true)
                }.padding(28)
            }
        }.background { HarborPageBackdrop() }.navigationTitle("模组夹")
        .searchable(text: $query, prompt: "搜索模组夹")
        .safeAreaInset(edge: .top) {
            // Navigation-bar items are visually capped at 36pt on iOS 26.
            // Keep collection actions in the content safe area with real 44pt targets.
            HStack(spacing: 14) {
                Button { newFolder = true } label: {
                    Label("新建模组夹", systemImage: "folder.badge.plus")
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.harborGlassButton(prominent: true)
                    .accessibilityIdentifier("folder.new")
                Spacer(minLength: 8)
                NavigationLink { HarborFolderDisplaySettings() } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).contentShape(Rectangle())
                }.harborGlassButton().accessibilityLabel("模组夹显示设置")
            }.padding(.horizontal, 20).padding(.vertical, 8)
        }.task { await model.load() }
        .sheet(isPresented: $newFolder) { HarborFolderEditor(model: model, folder: nil).harborMotionPolicy() }
        .sheet(item: $editing) { HarborFolderEditor(model: model, folder: $0).harborMotionPolicy() }
        .sheet(item: $active) { folder in
            HarborFolderContents(model: model, folderID: folder.id).harborMotionPolicy()
        }
        .confirmationDialog("删除“\(pendingDeletion?.name ?? "")”？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            if let folder = pendingDeletion {
                Button("删除模组夹", role: .destructive) {
                    model.run("删除模组夹") { try await $0.delete(folder.id); return "已移除模组夹。实例和原始模组未修改。" }
                    pendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { Text("只删除这个模组夹的名称与收藏列表，不删除实例里的模组，也不影响其他模组夹。") }
        .modifier(HarborFolderStatus(model: model))
    }
}

private struct HarborFolderEditor: View {
    @ObservedObject var model: HarborFolderLibrary
    let folder: ModFolder?
    @State private var name: String
    @State private var color: String
    @Environment(\.dismiss) private var dismiss
    private let colors = ["none", "#a8c9e8", "#a8d7be", "#dfb4c6", "#ccbae3", "#e0c79a", "#b4c3c5"]
    init(model: HarborFolderLibrary, folder: ModFolder?) {
        self.model = model; self.folder = folder
        _name = State(initialValue: folder?.name ?? ""); _color = State(initialValue: folder?.color ?? "none")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("例如：常用优化", text: $name).accessibilityIdentifier("folder.editor.name") }
                Section("轻染色 · 保留半透明材质") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))]) {
                        ForEach(colors, id: \.self) { value in
                            Button { color = value } label: {
                                ZStack {
                                    Circle().fill(value == "none" ? Color(uiColor: .tertiarySystemFill) : Color.folderHex(value))
                                    if value == "none" { Image(systemName: "drop.halffull").foregroundStyle(.primary) }
                                    if color == value { Image(systemName: "checkmark").font(.headline).foregroundStyle(.primary) }
                                }.frame(width: 38, height: 38).frame(minWidth: 52, minHeight: 52).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(value == "none" ? "无颜色" : value)
                                .accessibilityAddTraits(color == value ? .isSelected : [])
                        }
                    }
                }
            }.harborPageBackground().navigationTitle(folder == nil ? "新建模组夹" : "名称与颜色")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let title = name, tint = color
                        model.run("保存模组夹") { storage in
                            if let folder { try await storage.update(folder.id, name: title, color: tint) }
                            else { _ = try await storage.create(name: title, color: tint) }
                            return "模组夹已保存。"
                        }
                        dismiss()
                    }.disabled(model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 60)
                        .accessibilityIdentifier("folder.editor.save")
                }
            }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct HarborFolderStatus: ViewModifier {
    @ObservedObject var model: HarborFolderLibrary
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if model.busy || model.notice != nil {
                HStack(spacing: 12) {
                    if model.busy { ProgressView() } else { Image(systemName: "checkmark.circle") }
                    Text(model.busy ? model.progress : model.notice ?? "").font(.footnote).fixedSize(horizontal: false, vertical: true)
                    if model.busy {
                        Button("取消") { model.cancel() }.frame(minWidth: 44, minHeight: 44)
                    }
                }.padding(16).frame(maxWidth: 560).harborGlass(radius: 24)
                    .padding(16).transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("folder.status")
            }
        }.alert("无法完成操作", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
