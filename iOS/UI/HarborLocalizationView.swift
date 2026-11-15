import SwiftUI
import HarborCore
import UniformTypeIdentifiers

struct HarborLocalizationHome: View {
    let services: HarborNativeServices
    let instances: [PhoneInstance]
    var body: some View {
        List {
            Section {
                Text("读取模组和资源包的语言文件、KubeJS 的 assets/lang、FTB 任务与存档数据包文本。可以选资源、逐条编辑、补全译文，再导出汉化包或未汉化原文交给 AI。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("选择实例") {
                ForEach(instances) { instance in
                    NavigationLink { HarborLocalizationView(services: services, instance: instance) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(instance.name).font(.headline)
                            Text(instance.version + " · " + instance.loader).font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 52)
                    }.accessibilityIdentifier("localization.instance." + instance.id)
                }
                if instances.isEmpty { Text("请先安装或导入一个实例。").foregroundStyle(.secondary) }
            }
        }.harborPageBackground().navigationTitle("实例资源汉化")
    }
}

struct HarborLocalizationView: View {
    @StateObject private var model: HarborLocalizationLibrary
    @State private var query = ""
    @State private var resources = false
    @State private var configure = false
    @State private var importing = false
    @State private var confirmApply = false
    @State private var pendingOnly = false
    @Environment(\.scenePhase) private var phase
    init(services: HarborNativeServices, instance: PhoneInstance) {
        _model = StateObject(wrappedValue: HarborLocalizationLibrary(services: services, instance: instance))
    }
    private struct Row: Identifiable {
        let value: LocalizationRow
        let resource: String
        let path: String
        var id: String { value.id }
    }
    private var rows: [Row] {
        guard let project = model.project else { return [] }
        return project.sources.filter(\.selected).flatMap { source in source.documents.flatMap { doc in doc.rows.compactMap { row -> Row? in
            guard !pendingOnly || row.translation.isEmpty,
                  query.isEmpty || [row.key, row.source, row.translation, source.name].contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { return nil }
            return Row(value: row, resource: source.name, path: doc.path)
        } } }
    }
    var body: some View {
        List {
            Section {
                if let project = model.project {
                    let counts = project.counts
                    Text("\(counts.translated) / \(counts.total) 条已有译文").font(.headline)
                    Text("未译和格式不符的条目会保留原文。任务 / 数据包需要单独应用，资源包不会自动改写任务配置。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button { resources = true } label: { Label("选择资源", systemImage: "checklist").frame(minHeight: 44).contentShape(Rectangle()) }
                            .harborGlassButton().disabled(model.busy)
                        Spacer(minLength: 0)
                        Button { model.translate() } label: { Text("一键汉化").frame(minHeight: 44).contentShape(Rectangle()) }
                            .harborGlassButton(prominent: true).disabled(model.busy || counts.total == 0)
                    }
                    HarborSettingsToggle("只看待翻译", isOn: $pendingOnly)
                } else {
                    Text("原始模组保持不变，译文保存在本机独立工作区。请先读取实例。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if model.busy { HStack(spacing: 12) { ProgressView(); Text(model.status.isEmpty ? "正在处理" : model.status).font(.footnote); Spacer(); Button("停止") { model.cancel() }.frame(minHeight: 44) } }
                else if !model.status.isEmpty { Text(model.status).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                if let file = model.exported { ShareLink(item: file) { Label("分享刚导出的文件", systemImage: "square.and.arrow.up").frame(minHeight: 44) } }
            }
            if model.project != nil {
                Section("对照编辑 · \(rows.count) 条") {
                    ForEach(rows) { row in
                        NavigationLink { LocalizationRowEditor(row: row.value, resource: row.resource, path: row.path, model: model) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(row.value.key).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                Text(row.value.source).font(.subheadline).lineLimit(3)
                                Text(row.value.translation.isEmpty ? "待翻译" : row.value.translation)
                                    .font(.subheadline).foregroundStyle(row.value.translation.isEmpty ? Color.secondary : .primary).lineLimit(3)
                            }.padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
                        }.disabled(model.busy)
                    }
                }
                if let warnings = model.project?.warnings, !warnings.isEmpty {
                    Section {
                        NavigationLink {
                            List(Array(warnings.enumerated()), id: \.offset) { item in Text(item.element).font(.footnote).textSelection(.enabled).padding(.vertical, 7) }
                                .harborPageBackground().navigationTitle("处理记录")
                        } label: { Label("处理记录（\(warnings.count)）", systemImage: "exclamationmark.bubble").frame(minHeight: 44) }
                    }
                }
            }
        }.harborPageBackground().navigationTitle("实例资源汉化").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索语言键、原文、译文或资源")
            .safeAreaInset(edge: .top) {
                HStack(spacing: 14) {
                    Button { model.scan() } label: { Label("读取实例", systemImage: "arrow.clockwise").frame(minHeight: 44).contentShape(Rectangle()) }
                        .harborGlassButton().accessibilityLabel("读取实例语言").accessibilityIdentifier("localization.scan").disabled(model.busy)
                    Spacer(minLength: 8)
                    Menu {
                        Button("名称与资源包格式") { configure = true }
                        Button("导入译文 JSON 或资源包 ZIP") { importing = true }
                        Button("导出汉化包") { model.export(sourceOnly: false) }
                        Button("提取未汉化原文给 AI") { model.export(sourceOnly: true) }
                        Button("备份并应用任务 / 数据包译文") { confirmApply = true }
                        NavigationLink { HarborResourceSettings() } label: { Text("翻译来源设置") }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .harborGlassButton().accessibilityLabel("汉化操作").disabled(model.busy || model.project == nil)
                }.padding(.horizontal, 18).padding(.vertical, 8)
            }
            .task { await model.load() }
            .onChange(of: phase) { if $0 == .background { model.cancel() } }
            .onDisappear { model.cancel() }
            .sheet(isPresented: $resources) { resourceSelection }
            .sheet(isPresented: $configure) { if let project = model.project { LocalizationPackSettings(name: project.name, format: project.packFormat) { model.rename($0, format: $1); configure = false } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .zip]) { result in
                switch result { case .success(let file): model.importTranslations(file); case .failure(let error): model.error = error.localizedDescription }
            }
            .confirmationDialog("备份并应用所选任务 / 数据包译文？", isPresented: $confirmApply, titleVisibility: .visible) {
                Button("备份并应用") { model.apply() }
                Button("取消", role: .cancel) {}
            } message: { Text("先核对原文版本并保存 ZIP 备份，再写入已有译文。游戏运行时禁止应用；已有自定义中文任务语言文件会保留并提示手动合并。") }
    }
    private var resourceSelection: some View {
        NavigationStack {
            List {
                if let project = model.project {
                    ForEach(project.sources) { source in
                        Button { model.select(source.id, enabled: !source.selected) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: source.selected ? "checkmark.circle.fill" : "circle").font(.title3)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(source.name).font(.headline).foregroundStyle(.primary)
                                    Text("\(source.documents.count) 文件 · \(source.documents.reduce(0) { $0 + $1.rows.count }) 条").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxWidth: .infinity, minHeight: 52).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                }
            }.harborPageBackground().navigationTitle("选择实例资源").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { resources = false }.frame(minHeight: 44) } }
        }.harborMotionPolicy()
    }
}

private struct LocalizationRowEditor: View {
    let row: LocalizationRow
    let resource: String
    let path: String
    @ObservedObject var model: HarborLocalizationLibrary
    @State private var translation: String
    init(row: LocalizationRow, resource: String, path: String, model: HarborLocalizationLibrary) {
        self.row = row; self.resource = resource; self.path = path; self.model = model; _translation = State(initialValue: row.translation)
    }
    var body: some View {
        Form {
            Section { Text(resource); Text(path).font(.caption).foregroundStyle(.secondary); Text(row.key).font(.caption.monospaced()).textSelection(.enabled) }
            Section("原文") { Text(row.source).textSelection(.enabled) }
            Section("中文") { TextEditor(text: $translation).textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 180).accessibilityLabel("中文译文") }
            Section {
                Button("保存译文") { model.edit(row: row.id, value: translation) }.frame(minHeight: 44).disabled(model.busy)
                if !translation.isEmpty && !LocalizationPlaceholders.compatible(row.source, translation) { Text("请保留原文的占位符、格式代码与标签。").foregroundStyle(.red).font(.footnote) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if !model.status.isEmpty { Text(model.status).font(.footnote).foregroundStyle(.secondary) }
            }
        }.harborPageBackground().navigationTitle("对照编辑").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalizationPackSettings: View {
    @State var name: String
    @State private var format: String
    let save: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    init(name: String, format: Int, save: @escaping (String, Int) -> Void) { _name = State(initialValue: name); _format = State(initialValue: String(format)); self.save = save }
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("资源包名称", text: $name); TextField("资源包格式号", text: $format).keyboardType(.numberPad) }
                Section { Text("默认格式号 15 适用于 Minecraft 1.20–1.20.1。其他游戏版本请按该版本资源包格式填写，启动器不会把未知版本伪装成已兼容。").font(.footnote).foregroundStyle(.secondary) }
            }.harborPageBackground().navigationTitle("汉化包设置").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.frame(minHeight: 44) }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { if let value = Int(format) { save(name, value) } }.frame(minHeight: 44).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (Int(format) ?? 0) <= 0 || (Int(format) ?? 10001) > 10000) }
                }
        }.harborMotionPolicy()
    }
}
