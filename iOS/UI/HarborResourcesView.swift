import SwiftUI
import HarborCore

struct HarborResourcesView: View {
    @ObservedObject var model: HarborResourceLibrary
    let instances: [PhoneInstance]
    let native: (String) -> Void
    @State private var initialized = false
    @State private var retry = 0
    @AppStorage(HarborResourcePreferences.route) private var route = ResourceRoute.domesticFirst.rawValue
    @AppStorage(HarborResourcePreferences.provider) private var provider = ResourceTranslationProvider.bilibili.rawValue
    private var instance: PhoneInstance? { instances.first { $0.id == model.selectedProfile } }
    private var searchID: String { [model.query, model.kind.rawValue, model.source.rawValue, model.selectedProfile, String(model.page), route, provider, String(retry)].joined(separator: "|") }
    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Picker("实例资源", selection: $model.kind) {
                        ForEach(ResourceKind.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("resources.kind")
                    installMenu
                    NavigationLink { HarborResourceSettings() } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("资源与翻译设置").accessibilityIdentifier("resources.settings")
                }
                HStack(spacing: 12) {
                    Picker("平台", selection: $model.source) {
                        Text("Modrinth").tag(ResourceSource.modrinth)
                        Text("CurseForge").tag(ResourceSource.curseforge)
                    }.labelsHidden().accessibilityIdentifier("resources.source")
                    Spacer(minLength: 4)
                    Picker("安装到", selection: $model.selectedProfile) {
                        Text("浏览全部版本").tag("")
                        ForEach(instances) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("resources.target")
                }.frame(minHeight: 44)
                if let instance {
                    Text("\(instance.name) · \(instance.gameVersion ?? instance.version) · \(instance.loader)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    NavigationLink { HarborLocalizationView(services: model.services, instance: instance) } label: {
                        Label("实例资源汉化", systemImage: "character.book.closed").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("resources.localization")
                }
                if model.kind == .mod, let instance, !["fabric", "forge", "quilt", "neoforge"].contains(instance.loader.lowercased()) {
                    Text("此实例为原版。可以浏览模组；安装前请先为实例安装对应的模组加载器。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                if model.loading {
                    HStack(spacing: 12) { ProgressView(); Text("正在搜索实例资源…") }.frame(minHeight: 56)
                        .accessibilityIdentifier("resources.loading")
                } else if let error = model.searchError {
                    Text(error).foregroundStyle(.secondary)
                    Button("重新搜索") { retry += 1 }.frame(minHeight: 44)
                } else if model.projects.isEmpty {
                    Text("没有找到匹配的资源。可更换平台、实例或搜索词。中文搜索与翻译来源可以在右上角设置。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 16)
                } else {
                    if let text = model.searchedQuery { Text("使用关键词：\(text)").font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.projects) { project in
                        NavigationLink {
                            HarborResourceDetail(model: model, project: project, kind: model.kind, instance: instance)
                        } label: { HarborResourceRow(project: project, route: HarborResourcePreferences.selectedRoute) }
                            .accessibilityIdentifier("resources.project." + project.id)
                    }
                    HStack {
                        Button { model.page -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .disabled(model.page == 0).accessibilityLabel("上一页")
                        Spacer()
                        Text("第 \(model.page + 1) 页 · \(model.total.formatted()) 个结果").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.page += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .disabled((model.page + 1) * 30 >= model.total || model.page >= 1000).accessibilityLabel("下一页")
                    }
                }
            }
            Section("游戏与整合包") {
                Button { native("resources") } label: { Label("在线整合包", systemImage: "shippingbox").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
                Button { native("importPack") } label: { Label("从文件导入整合包", systemImage: "doc.zipper").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
                Menu {
                    Button("Fabric 与 Quilt") { native("fabric") }
                    Button("Forge 与 NeoForge") { native("forge") }
                    Button("打开 JAR 安装器") { native("import") }
                } label: { Label("安装模组加载器", systemImage: "square.stack.3d.down.right").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
            }
        }
        .harborPageBackground().navigationTitle("实例资源").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: "中英文名称或关键词")
        .task(id: searchID) { await model.search(target: instance?.resourceTarget) }
        .onAppear { if !initialized { initialized = true; model.selectedProfile = instances.first?.id ?? "" } }
        .onChange(of: model.query) { _ in model.page = 0 }
        .onChange(of: model.source) { _ in model.page = 0 }
        .onChange(of: model.kind) { _ in model.page = 0 }
        .onChange(of: model.selectedProfile) { _ in model.page = 0 }
        .safeAreaInset(edge: .bottom) { HarborResourceStatus(model: model) }
    }
    private var installMenu: some View {
        Menu {
            Button("安装 Minecraft") { native("install") }
            Button("从文件导入整合包") { native("importPack") }.accessibilityIdentifier("native.page.importPack")
            Button("打开 JAR 安装器") { native("import") }.accessibilityIdentifier("native.page.import")
            Button("浏览在线整合包") { native("resources") }
            Button("Fabric 与 Quilt") { native("fabric") }
            Button("Forge 与 NeoForge") { native("forge") }
        } label: { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel("安装或导入资源").accessibilityIdentifier("resources.install.menu")
    }
}

struct HarborResourceStatus: View {
    @ObservedObject var model: HarborResourceLibrary
    var body: some View {
        Group {
            if model.installing {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.progressText).font(.caption).lineLimit(2)
                        ProgressView(value: model.progress)
                    }
                    Button("取消") { model.cancel() }.frame(minWidth: 44, minHeight: 44).harborGlassButton()
                }.padding(16).background(.regularMaterial)
            } else if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.subheadline)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("资源安装", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct HarborResourceIcon: View {
    let project: ResourceProject
    let route: ResourceRoute
    var body: some View {
        AsyncImage(url: project.icon.map { ResourceNetwork.candidates($0, route: route).first ?? $0 }) { phase in
            if let image = phase.image { image.resizable().scaledToFit().padding(3) }
            else { Image("FolderLandscape", bundle: Bundle(for: HarborRootFactory.self)).resizable().scaledToFill() }
        }.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }
}

private struct HarborResourceRow: View {
    let project: ResourceProject
    let route: ResourceRoute
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            HarborResourceIcon(project: project, route: route)
            VStack(alignment: .leading, spacing: 7) {
                HarborResourceCopy(project: project)
                Text(project.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 12).frame(minHeight: 108, alignment: .top).contentShape(Rectangle())
    }
}

private struct HarborResourceCopy: View {
    let project: ResourceProject
    var detail = false
    @AppStorage(HarborResourcePreferences.provider) private var provider = ResourceTranslationProvider.bilibili.rawValue
    @AppStorage(HarborResourcePreferences.summaries) private var translateSummary = true
    @State private var chineseName: String?
    @State private var summary: String?
    @State private var loading = true
    @State private var failed = false
    @State private var original = false
    @State private var retry = 0
    var body: some View {
        VStack(alignment: .leading, spacing: detail ? 12 : 6) {
            Text(chineseName ?? ResourceNames.chinese(project.title) ?? project.title)
                .font(detail ? .title2.bold() : .headline).foregroundStyle(.primary).lineLimit(detail ? nil : 2)
            if chineseName != nil || ResourceNames.chinese(project.title) != nil {
                Text(project.title).font(.caption).foregroundStyle(.secondary).lineLimit(detail ? nil : 1)
            }
            if project.summary.isEmpty { Text("暂无简介").font(.subheadline).foregroundStyle(.secondary) }
            else if !translateSummary || original { Text(project.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(detail ? nil : 3) }
            else if let summary { Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(detail ? nil : 3) }
            else if loading {
                HStack(spacing: 7) { ProgressView().controlSize(.small); Text("简介汉化加载中…").font(.caption).foregroundStyle(.secondary) }
            } else if failed {
                if detail { Button("简介汉化失败，点此重试") { retry += 1 }.font(.subheadline).frame(minHeight: 44) }
                else { Text("简介汉化暂不可用，进入详情可重试。").font(.caption).foregroundStyle(.secondary) }
            }
            if detail && translateSummary && !project.summary.isEmpty {
                Button(original ? "显示中文简介" : "查看原文") { original.toggle() }.font(.subheadline).frame(minHeight: 44)
            }
        }.task(id: project.source.rawValue + project.id + provider + String(translateSummary) + String(retry)) {
            loading = true; failed = false; summary = nil; chineseName = ResourceNames.chinese(project.title)
            let selected = ResourceTranslationProvider(rawValue: provider) ?? .bilibili
            let key = HarborResourcePreferences.aliKey()
            async let name = translatedName(provider: selected, key: key)
            async let description = translatedSummary(provider: selected, key: key)
            let (title, text) = await (name, description)
            guard !Task.isCancelled else { return }
            chineseName = title; summary = text; failed = translateSummary && !project.summary.isEmpty && text == nil; loading = false
        }
    }
    private func translatedName(provider: ResourceTranslationProvider, key: String?) async -> String? {
        if ResourceNames.containsChinese(project.title) { return nil }
        if let name = ResourceNames.chinese(project.title) { return name }
        return try? await ResourceTextService.shared.translate(project.title, provider: provider, aliKey: key)
    }
    private func translatedSummary(provider: ResourceTranslationProvider, key: String?) async -> String? {
        guard translateSummary, !project.summary.isEmpty else { return nil }
        return try? await ResourceTextService.shared.translate(project.summary, provider: provider, aliKey: key)
    }
}

struct HarborResourceDetail: View {
    @ObservedObject var model: HarborResourceLibrary
    let project: ResourceProject
    let kind: ResourceKind
    let instance: PhoneInstance?
    @State private var versions: [ResourceVersion] = []
    @State private var selected = ""
    @State private var loading = true
    @State private var error: String?
    @State private var retry = 0
    private var version: ResourceVersion? { versions.first { $0.id == selected } }
    private var canInstall: Bool {
        version != nil && instance?.resourceTarget != nil && !model.installing && (kind != .mod || ["fabric", "forge", "quilt", "neoforge"].contains(instance?.loader.lowercased() ?? ""))
    }
    var body: some View {
        List {
            Section {
                HarborResourceIcon(project: project, route: HarborResourcePreferences.selectedRoute)
                HarborResourceCopy(project: project, detail: true)
                LabeledContent("作者", value: project.author)
                LabeledContent("下载次数", value: project.downloads.formatted())
                if let page = project.page { Link("打开原项目页面", destination: page).frame(minHeight: 44) }
            }
            Section("兼容版本") {
                if let instance { Text("安装到 \(instance.name) · \(instance.gameVersion ?? instance.version) · \(instance.loader)").font(.subheadline).foregroundStyle(.secondary) }
                else { Text("当前为浏览模式。返回列表选择一个实例后可安装兼容资源。").font(.subheadline).foregroundStyle(.secondary) }
                if loading { ProgressView("读取版本…").frame(minHeight: 44) }
                else if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { retry += 1 }.frame(minHeight: 44)
                } else if versions.isEmpty { Text("没有此 Minecraft 版本与加载器对应的文件。").foregroundStyle(.secondary) }
                else {
                    Picker("文件版本", selection: $selected) { ForEach(versions) { Text($0.title.isEmpty ? $0.number : $0.title).tag($0.id) } }
                    if let version {
                        Text(version.games.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        if !version.loaders.isEmpty { Text(version.loaders.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary) }
                        ForEach(version.files.prefix(1), id: \.name) { file in
                            Text(file.name).font(.caption.monospaced()).textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        if version.files.isEmpty { Text("作者未提供可直接下载的文件，请使用原项目链接。").font(.footnote).foregroundStyle(.secondary) }
                    }
                    Button {
                        if let version, let instance { model.install(version, project: project, kind: kind, into: instance) }
                    } label: {
                        Label(model.installing ? "正在下载与校验" : "下载并安装", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }.harborGlassButton(prominent: true).disabled(!canInstall || version?.files.isEmpty == true)
                    Text("必要前置会一起检查与安装。已有不同内容的同名文件不会被覆盖；冲突会明确提示。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.harborPageBackground().navigationTitle("资源详情").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { HarborResourceStatus(model: model) }
        .task(id: retry) {
            loading = true; error = nil
            do {
                let values = try await ResourceCatalog(route: HarborResourcePreferences.selectedRoute).versions(project: project.id, source: project.source, kind: kind, target: instance?.resourceTarget)
                try Task.checkCancellation(); versions = values; selected = values.first?.id ?? ""
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
