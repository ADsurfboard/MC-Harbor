import SwiftUI
import HarborCore
import UniformTypeIdentifiers

private enum FolderInstanceAction: String, Identifiable { case collect, install; var id: String { rawValue } }

struct HarborFolderContents: View {
    @ObservedObject var model: HarborFolderLibrary
    let folderID: UUID
    @State private var query = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var showImporter = false
    @State private var details: FolderMod?
    @State private var instanceAction: FolderInstanceAction?
    @State private var transfer = false
    @State private var copy = false
    @Environment(\.dismiss) private var dismiss
    private var folder: ModFolder? { model.snapshot.folders.first { $0.id == folderID } }
    private var mods: [FolderMod] {
        (folder?.mods ?? []).filter { query.isEmpty || [$0.name, $0.filename, $0.summary ?? "", $0.version ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    private func payload(_ ids: Set<String>) -> FolderModDrag {
        .init(library: model.snapshot.identity, folder: folderID, mods: (folder?.mods ?? []).map(\.id).filter(ids.contains))
    }
    var body: some View {
        NavigationStack {
            List {
                if folder?.mods.isEmpty == true {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("这个模组夹还是空的").font(.headline)
                        Text("点右上角“添加”，可选择多个 JAR 文件，或一次收藏一个实例里的全部模组。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 22).listRowBackground(Color.clear)
                }
                ForEach(mods) { mod in
                    Button {
                        if selecting {
                            if selected.contains(mod.id) { selected.remove(mod.id) } else { selected.insert(mod.id) }
                        } else { details = mod }
                    } label: {
                        HStack(alignment: .center, spacing: 14) {
                            if selecting {
                                Image(systemName: selected.contains(mod.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(selected.contains(mod.id) ? Color.accentColor : .secondary)
                            }
                            HarborFolderModRow(mod: mod, model: model)
                        }.frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("folder.mod." + mod.id)
                        .draggable(HarborModDrag(value: payload(selecting && selected.contains(mod.id) ? selected : [mod.id])))
                        .contextMenu {
                            Button { details = mod } label: { Label("查看详情", systemImage: "info.circle") }
                            Button { selected = [mod.id]; instanceAction = .install } label: { Label("添加到实例", systemImage: "square.and.arrow.down") }
                            Button { selected = [mod.id]; copy = true; transfer = true } label: { Label("复制到模组夹", systemImage: "folder.badge.plus") }
                            Button(role: .destructive) { remove([mod.id]) } label: { Label("移除收藏", systemImage: "trash") }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { remove([mod.id]) } label: { Label("移除", systemImage: "trash") }
                            Button { selected = [mod.id]; instanceAction = .install } label: { Label("添加到实例", systemImage: "square.and.arrow.down") }.tint(.accentColor)
                        }
                        .listRowBackground(Color.clear).listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                }.onMove { indices, destination in
                    guard query.isEmpty, let folder else { return }
                    let ids = Set(indices.map { folder.mods[$0].id })
                    model.move(payload(ids), to: folderID, at: destination)
                }.moveDisabled(!query.isEmpty || model.busy)
            }.listStyle(.plain).harborPageBackground()
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
            .navigationTitle(folder?.name ?? "模组夹").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索名称、版本或简介")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.frame(minHeight: 44) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selecting ? "取消选择" : "选择") { selecting.toggle(); selected.removeAll() }
                        .frame(minHeight: 44).disabled(model.busy || folder?.mods.isEmpty != false)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showImporter = true } label: { Label("从文件收藏模组", systemImage: "doc.badge.plus") }
                        Button { instanceAction = .collect } label: { Label("收藏实例的全部模组", systemImage: "square.stack.3d.up") }
                        NavigationLink { HarborFolderDisplaySettings() } label: { Label("设置列表信息量", systemImage: "slider.horizontal.3") }
                    } label: { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel("添加模组").disabled(model.busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting && !selected.isEmpty {
                    VStack(spacing: 8) {
                        HStack {
                            Text("已选择 \(selected.count) 个").font(.footnote)
                            Spacer()
                            Button(selected.count == mods.count ? "取消全选" : "全选") {
                                selected = selected.count == mods.count ? [] : Set(mods.map(\.id))
                            }.frame(minHeight: 44)
                        }
                        HStack(spacing: 12) {
                            Button { instanceAction = .install } label: { Label("添加到实例", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44) }.harborGlassButton(prominent: true)
                            Menu {
                                Button("复制到模组夹") { copy = true; transfer = true }
                                Button("移动到模组夹") { copy = false; transfer = true }
                                Button("移除收藏", role: .destructive) { remove(selected) }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.harborGlassButton()
                        }.disabled(model.busy)
                    }.padding(.horizontal, 18).padding(.vertical, 8).background(.regularMaterial)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "jar") ?? .archive], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): model.importFiles(urls, into: folderID)
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .sheet(item: $details) { HarborFolderModDetail(mod: $0, model: model).harborMotionPolicy() }
            .sheet(item: $instanceAction) { action in
                HarborFolderInstancePicker(model: model, installing: action == .install) { instance in
                    if action == .collect { model.collectInstance(instance, into: folderID) }
                    else { model.install(selected, folder: folderID, into: instance) }
                    selected.removeAll(); selecting = false
                }.harborMotionPolicy()
            }
            .sheet(isPresented: $transfer) {
                NavigationStack {
                    List(model.snapshot.folders.filter { $0.id != folderID }) { target in
                        Button {
                            model.move(payload(selected), to: target.id, copy: copy)
                            selected.removeAll(); selecting = false; transfer = false
                        } label: { Label(target.name, systemImage: "folder").frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }
                    }.harborPageBackground().navigationTitle(copy ? "复制到模组夹" : "移动到模组夹")
                        .overlay { if model.snapshot.folders.count < 2 { Text("先在模组夹主页新建另一个模组夹。\n可保留多个不同用途的收藏。").multilineTextAlignment(.center).padding() } }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { transfer = false } } }
                }.presentationDetents([.medium, .large]).harborMotionPolicy()
            }
            .modifier(HarborFolderStatus(model: model))
            .onChange(of: model.snapshot.folders) { _ in selected.formIntersection(Set(folder?.mods.map(\.id) ?? [])) }
            .dropDestination(for: HarborModDrag.self) { items, _ in
                guard let value = items.first?.value, !model.busy else { return false }
                model.move(value, to: folderID); return true
            }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private func remove(_ ids: Set<String>) {
        model.run("移除收藏") { try await $0.remove(ids, from: folderID); return "已移除收藏。实例和原始文件保留。" }
        selected.subtract(ids)
    }
}

private struct HarborFolderModRow: View {
    let mod: FolderMod
    @ObservedObject var model: HarborFolderLibrary
    @AppStorage(HarborFolderOptions.icon) private var icon = true
    @AppStorage(HarborFolderOptions.loader) private var loader = true
    @AppStorage(HarborFolderOptions.version) private var version = true
    @AppStorage(HarborFolderOptions.game) private var game = false
    @AppStorage(HarborFolderOptions.summary) private var summary = true
    @AppStorage(HarborFolderOptions.author) private var author = false
    @AppStorage(HarborFolderOptions.date) private var date = false
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if icon { HarborFolderArtwork(url: model.imageURL(mod)).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 7) {
                Text(mod.name).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if loader && !mod.loaders.isEmpty { Text(mod.loaders.joined(separator: " / ")).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                if version, let value = mod.version { Text("模组版本 \(value)").font(.caption).foregroundStyle(.secondary) }
                if game && !mod.gameVersions.isEmpty { Text("Minecraft \(mod.gameVersions.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) }
                if summary, let value = mod.summary { Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                if author, let value = mod.authors { Text(value).font(.caption).foregroundStyle(.secondary) }
                if date { Text(mod.collectedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HarborFolderModDetail: View {
    let mod: FolderMod
    @ObservedObject var model: HarborFolderLibrary
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 20) {
                        HarborFolderArtwork(url: model.imageURL(mod)).frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 18))
                        Text(mod.name).font(.title2.bold()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 12)
                    LabeledContent("加载器", value: mod.loaders.isEmpty ? "文件未记录" : mod.loaders.joined(separator: " / "))
                    LabeledContent("模组版本", value: mod.version ?? "文件未记录")
                    LabeledContent("Minecraft", value: mod.gameVersions.isEmpty ? "文件未记录" : mod.gameVersions.joined(separator: "、"))
                    if let authors = mod.authors { LabeledContent("作者", value: authors) }
                    LabeledContent("收藏时间") { Text(mod.collectedAt.formatted(date: .abbreviated, time: .shortened)) }
                }
                Section("简介") { Text(mod.summary ?? "这个模组没有在资料文件中提供简介。内容未经过在线翻译。") .textSelection(.enabled) }
                Section("文件") {
                    Text(mod.filename).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("收藏的是原模组的独立副本；安装时会重新校验，并跳过完全相同的文件。版本范围按原模组声明显示。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.harborPageBackground().navigationTitle("模组详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.large])
    }
}

private struct HarborFolderInstancePicker: View {
    let model: HarborFolderLibrary
    let installing: Bool
    let action: (PhoneInstance) -> Void
    @State private var instances: [PhoneInstance] = []
    @State private var error: String?
    @State private var query = ""
    @State private var confirmation: PhoneInstance?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(installing ? "请选择 Minecraft 版本与加载器匹配的实例。只会添加缺少的文件；同名但内容不同的模组会停止导入，避免覆盖。此操作不会自动补全依赖。" : "读取所选实例 mods 文件夹中的全部 JAR 模组，复制到当前模组夹；不会移动或修改原始文件。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if instances.isEmpty && error == nil { Text("暂无可选择的实例。先在游戏库中安装或导入实例。") }
                ForEach(instances.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { instance in
                    Button {
                        if installing { confirmation = instance } else { action(instance); dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(instance.name).font(.headline).foregroundStyle(.primary)
                            Text("\(instance.version) · \(instance.loader)").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.harborPageBackground().navigationTitle(installing ? "添加到实例" : "从实例收藏")
                .searchable(text: $query, prompt: "搜索实例")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .task {
                    do { instances = try JSONDecoder().decode([PhoneInstance].self, from: model.services.instanceListJSON()) }
                    catch { self.error = error.localizedDescription }
                }
                .confirmationDialog("添加到“\(confirmation?.name ?? "")”？请确认加载器与版本匹配。", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                    if let instance = confirmation { Button("添加所选模组") { action(instance); dismiss() } }
                    Button("取消", role: .cancel) { confirmation = nil }
                }
        }.presentationDetents([.large])
    }
}
