import SwiftUI
import HarborCore

@MainActor final class HarborWorldLibrary: ObservableObject {
    @Published var worlds: [WorldEditFolder] = []
    @Published var snapshot: WorldEditSnapshot?
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    let services: HarborNativeServices
    let instance: PhoneInstance
    private var operation: Task<Void, Never>?
    private struct Access: Decodable { let token: String; let directory: String }
    init(services: HarborNativeServices, instance: PhoneInstance) { self.services = services; self.instance = instance }
    private func withStore<T: Sendable>(_ work: @Sendable (WorldEditorStore) async throws -> T) async throws -> T {
        let access = try JSONDecoder().decode(Access.self, from: services.beginResourceAccess(profile: instance.id, kind: "saves"))
        defer { services.endModAccess(token: access.token) }
        return try await work(WorldEditorStore(instance: URL(fileURLWithPath: access.directory).deletingLastPathComponent(), home: services.harborHomeURL))
    }
    private func run(_ title: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil; status = title
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() }
            catch is CancellationError { status = "已停止，原有存档保留。" }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel() }
    func clear() { if !busy { snapshot = nil } }
    func refresh() {
        run("读取存档列表") { self.worlds = try await self.withStore { try await $0.worlds() }; self.status = "" }
    }
    func load(_ folder: String, player: String? = nil) {
        run("读取存档元数据") { self.snapshot = try await self.withStore { try await $0.read(folder: folder, player: player) }; self.status = "未保存前不会写入世界或玩家元数据。" }
    }
    func save(_ draft: [String: String]) {
        guard let snapshot else { return }
        var changes: [String: WorldEditValue] = [:]
        for (key, value) in draft where snapshot.values[key]?.text != value {
            if key == "name" { changes[key] = .text(value) }
            else {
                guard let number = Double(value), number.isFinite else { error = "请填写有效数字：" + key; return }; changes[key] = .number(number)
            }
        }
        guard !changes.isEmpty else { return }
        let edits = changes
        run("核对原文、备份与保存") {
            self.snapshot = try await self.withStore { try await $0.save(folder: snapshot.folder, player: snapshot.player, revision: snapshot.revision, changes: edits) }
            self.status = "修改已保存，原始元数据 ZIP 备份已保留。"
        }
    }
}

struct HarborWorldsHome: View {
    let services: HarborNativeServices
    let instances: [PhoneInstance]
    var body: some View {
        List {
            Section { Text("编辑 Java 版存档的游戏模式、时间与玩家状态。保存前取得存档锁并备份；游戏运行中无法编辑。不会改写区块、背包或模组自定义数据。").font(.subheadline).foregroundStyle(.secondary) }
            Section("选择实例") {
                ForEach(instances) { instance in
                    NavigationLink { HarborWorldsView(services: services, instance: instance) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(instance.name).font(.headline)
                            Text(instance.version + " · " + instance.loader).font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 52)
                    }.accessibilityIdentifier("worlds.instance." + instance.id)
                }
                if instances.isEmpty { Text("请先安装或导入一个实例。").foregroundStyle(.secondary) }
            }
        }.harborPageBackground().navigationTitle("存档编辑")
    }
}

private struct HarborWorldsView: View {
    @StateObject private var model: HarborWorldLibrary
    init(services: HarborNativeServices, instance: PhoneInstance) { _model = StateObject(wrappedValue: HarborWorldLibrary(services: services, instance: instance)) }
    var body: some View {
        List {
            if model.busy { HStack(spacing: 12) { ProgressView(); Text(model.status) }.frame(minHeight: 52) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(model.worlds) { world in
                NavigationLink { HarborWorldEditorView(model: model, folder: world.id) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(world.id).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if let date = world.modified { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }.frame(minHeight: 56).padding(.vertical, 8)
                }.disabled(model.busy).accessibilityIdentifier("worlds.folder." + world.id)
            }
            if model.worlds.isEmpty && !model.busy && model.error == nil { Text("此实例还没有 Java 版存档。进入游戏创建并保存世界后即可编辑。").foregroundStyle(.secondary).padding(.vertical, 20) }
        }.harborPageBackground().navigationTitle("存档").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                HStack { Text(model.instance.name).font(.subheadline).lineLimit(2); Spacer(); Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise").frame(minHeight: 44).contentShape(Rectangle()) }.harborGlassButton().disabled(model.busy) }
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }.onAppear { model.clear(); model.refresh() }
    }
}

private struct HarborWorldEditorView: View {
    @ObservedObject var model: HarborWorldLibrary
    let folder: String
    @State private var draft: [String: String] = [:]
    @State private var pendingPlayer: String?
    @State private var discard = false
    @Environment(\.scenePhase) private var phase
    private var snapshot: WorldEditSnapshot? { model.snapshot?.folder == folder ? model.snapshot : nil }
    private var key: String { (snapshot?.revision ?? "") + "|" + (snapshot?.player ?? "") }
    private var dirty: Bool { snapshot.map { value in draft.contains { value.values[$0.key]?.text != $0.value } } ?? false }
    var body: some View {
        Form {
            if let snapshot {
                Section("世界 · \(snapshot.version)") {
                    field("存档名称", key: "name", numeric: false)
                    choice("游戏模式", key: "gameMode", options: ["生存", "创造", "冒险", "旁观"])
                    choice("难度", key: "difficulty", options: ["和平", "简单", "普通", "困难"])
                    flag("极限模式", key: "hardcore"); flag("允许作弊", key: "cheats")
                    field("游戏天数", key: "day", note: "从第 0 天开始")
                    field("当日时间", key: "dayTick", note: "0–23999 tick")
                    field("世界累计时间", key: "ageTicks", note: "tick，独立于昼夜时间")
                }
                Section("玩家") {
                    if snapshot.players.isEmpty { Text("尚无玩家数据。进入此世界保存一次后即可编辑玩家状态。").font(.footnote).foregroundStyle(.secondary) }
                    else {
                        Picker("所选玩家", selection: Binding(get: { snapshot.player }, set: { id in
                            if dirty { pendingPlayer = id; discard = true } else { model.load(folder, player: id) }
                        })) { ForEach(snapshot.players) { Text($0.name).tag($0.id) } }
                        field("生命值", key: "health", note: "通常 20 为 10 颗心")
                        field("饱食度", key: "hunger", note: "0–20")
                        field("饱和度", key: "saturation", note: "0–20")
                        field("经验等级", key: "xpLevel", note: "保存时同步总经验")
                        field("经验进度", key: "xpProgress", note: "0–0.999999")
                        if let total = snapshot.values["xpTotal"] { LabeledContent("当前总经验", value: total.text) }
                    }
                }
                if !snapshot.warnings.isEmpty { Section("读取记录") { ForEach(snapshot.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) } } }
                if let backup = snapshot.backup { Section("备份") { ShareLink(item: backup) { Label("分享本次原始元数据备份", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) } } }
            }
            Section {
                if model.busy { HStack(spacing: 12) { ProgressView(); Text(model.status).font(.footnote) }.frame(minHeight: 44) }
                else if !model.status.isEmpty { Text(model.status).font(.footnote).foregroundStyle(.secondary) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
            }
        }.harborPageBackground().navigationTitle(folder).navigationBarTitleDisplayMode(.inline).scrollDismissesKeyboard(.interactively)
            .disabled(model.busy)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 14) {
                    Button { if dirty { pendingPlayer = snapshot?.player; discard = true } else { model.load(folder, player: snapshot?.player) } } label: { Text("重新读取").frame(minHeight: 44).contentShape(Rectangle()) }.harborGlassButton().disabled(model.busy)
                    Button { model.save(draft) } label: { Text("备份并保存修改").frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle()) }
                        .harborGlassButton(prominent: true).disabled(model.busy || !dirty).accessibilityIdentifier("worlds.save")
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
            .onAppear { model.load(folder) }
            .onChange(of: key) { _ in draft = snapshot?.values.mapValues(\.text) ?? [:] }
            .onChange(of: phase) { if $0 == .background { model.cancel() } }
            .onDisappear { model.cancel(); model.clear() }
            .confirmationDialog("放弃尚未保存的修改？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃修改并读取") { model.load(folder, player: pendingPlayer); pendingPlayer = nil }
                Button("继续编辑", role: .cancel) { pendingPlayer = nil }
            }
    }
    private func binding(_ key: String) -> Binding<String> { Binding(get: { draft[key] ?? "" }, set: { draft[key] = $0 }) }
    @ViewBuilder private func field(_ title: String, key: String, numeric: Bool = true, note: String = "") -> some View {
        if snapshot?.values[key] != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(title); if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) } }
                TextField(title, text: binding(key)).font(.system(.body, design: numeric ? .monospaced : .default))
                    .keyboardType(numeric ? .decimalPad : .default).textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 44).accessibilityIdentifier("worlds.field." + key)
            }.padding(.vertical, 5)
        }
    }
    @ViewBuilder private func choice(_ title: String, key: String, options: [String]) -> some View {
        if snapshot?.values[key] != nil { Picker(title, selection: binding(key)) { ForEach(Array(options.enumerated()), id: \.offset) { Text($0.element).tag(String($0.offset)) } }.frame(minHeight: 44) }
    }
    @ViewBuilder private func flag(_ title: String, key: String) -> some View {
        if snapshot?.values[key] != nil { HarborSettingsToggle(title, isOn: Binding(get: { draft[key] != nil && draft[key] != "0" }, set: { draft[key] = $0 ? "1" : "0" })) }
    }
}
