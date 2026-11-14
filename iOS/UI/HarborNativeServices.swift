import Foundation
import UIKit
import SwiftUI
import HarborCore
import CryptoKit

@MainActor @objc public protocol HarborNativeServices: AnyObject {
    var harborHomeURL: URL { get }
    var runtimeDescription: String { get }
    func instanceListJSON() -> Data
    func controller(forPage page: String, profile: String?) -> UIViewController
    func sendKey(_ key: Int32, pressed: Bool)
    func sendMouseButton(_ button: Int32, pressed: Bool)
    func showGameKeyboard()
    func isPointerGrabbed() -> Bool
    @objc(readModArchiveAtURL:entry:completion:)
    func readModArchive(at url: URL, entry: String?, completion: @escaping (Data?, String?) -> Void)
    @objc(beginModAccessForProfile:error:)
    func beginModAccess(profile: String) throws -> Data
    @objc(endModAccessWithToken:)
    func endModAccess(token: String)
}

@MainActor @objc(HarborRootFactory) public final class HarborRootFactory: NSObject {
    @objc(makeControllerWithServices:) public static func makeController(services: HarborNativeServices) -> UIViewController {
        UIHostingController(rootView: HarborPhoneRoot(services: services))
    }
    @objc public static func controlConfigurationURL(home: URL, profile: String?) -> URL {
        // A file name never contains a profile name supplied by a modpack.
        let component = SHA256.hash(data: Data((profile ?? "global").utf8)).map { String(format: "%02x", $0) }.joined()
        return home.appendingPathComponent("harbor-touch", isDirectory: true)
            .appendingPathComponent(component + ".json")
    }
    @objc(controlConfigurationDataWithHome:profile:) public static func controlConfigurationData(home: URL, profile: String?) -> Data {
        for candidate in [controlConfigurationURL(home: home, profile: profile), controlConfigurationURL(home: home, profile: nil)] {
            if let size = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128 * 1024,
               let data = try? Data(contentsOf: candidate), let layout = try? TouchLayout.decode(data),
               let valid = try? JSONEncoder().encode(layout) { return valid }
        }
        return (try? JSONEncoder().encode(TouchLayout.standard())) ?? Data()
    }
    @objc(installGameControlsOn:services:profile:) public static func installGameControls(on view: UIView, services: HarborNativeServices, profile: String?) -> HarborGameTouchOverlay {
        let configuration = (try? TouchLayout.decode(controlConfigurationData(home: services.harborHomeURL, profile: profile))) ?? .standard()
        let overlay = HarborGameTouchOverlay(frame: view.bounds, configuration: configuration, services: services)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay); overlay.updateGrabState(services.isPointerGrabbed())
        return overlay
    }
}

struct PhoneInstance: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let loader: String
}

@MainActor final class PhoneLibrary: ObservableObject {
    @Published var instances: [PhoneInstance] = []
    @Published var error: String?
    let services: HarborNativeServices
    init(_ services: HarborNativeServices) { self.services = services; refresh() }
    func refresh() {
        do { instances = try JSONDecoder().decode([PhoneInstance].self, from: services.instanceListJSON()); error = nil }
        catch { self.error = "无法读取实例：" + error.localizedDescription }
    }
}

struct NativePage: Identifiable { let id = UUID(); let name: String; var profile: String? }
struct NativePageHost: UIViewControllerRepresentable {
    let services: HarborNativeServices
    let page: NativePage
    func makeUIViewController(context: Context) -> UIViewController { services.controller(forPage: page.name, profile: page.profile) }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

struct NativePresentationContent: View {
    let services: HarborNativeServices
    let page: NativePage
    var body: some View {
        Group {
            if page.name == "touch" {
                TouchLayoutEditor(home: services.harborHomeURL, profile: page.profile)
            } else {
                NativePageHost(services: services, page: page).ignoresSafeArea()
            }
        }.harborMotionPolicy()
    }
}

struct HarborPhoneRoot: View {
    let services: HarborNativeServices
    @StateObject private var library: PhoneLibrary
    @StateObject private var folders: HarborFolderLibrary
    @State private var settingsQuery = ""
    @State private var page: NativePage?
    @AppStorage(HarborLibraryOptions.coverFlow) private var coverFlow = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    init(services: HarborNativeServices) {
        self.services = services
        _library = StateObject(wrappedValue: PhoneLibrary(services))
        _folders = StateObject(wrappedValue: HarborFolderLibrary(services: services))
    }
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    if !coverFlow || verticalSizeClass != .compact {
                        Section {
                            HStack(alignment: .center, spacing: coverFlow ? 12 : 16) {
                                HarborBrandArtwork().frame(width: coverFlow ? 32 : 46, height: coverFlow ? 32 : 46)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("MC Harbor").font(coverFlow || verticalSizeClass == .compact ? .title2.bold() : .largeTitle.bold())
                                    if !coverFlow && verticalSizeClass != .compact { Text("Minecraft，随身出发。").font(.subheadline).foregroundStyle(.secondary) }
                                }
                            }.padding(.vertical, coverFlow || verticalSizeClass == .compact ? 2 : 18).listRowBackground(Color.clear)
                        }
                    }
                    Section("游戏库") {
                        if let error = library.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        if library.instances.isEmpty && library.error == nil {
                            Menu {
                                Button("安装 Minecraft") { page = .init(name: "install") }
                                Button("从文件导入 Modrinth 整合包") { page = .init(name: "importPack") }
                            } label: {
                                Label("安装 Minecraft 或导入整合包", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
                            }.accessibilityIdentifier("library.install.empty")
                        }
                        if coverFlow && !library.instances.isEmpty {
                            HarborCoverFlowLibrary(instances: library.instances,
                                launch: { page = .init(name: "launch", profile: $0.id) },
                                manage: { page = .init(name: "instance", profile: $0.id) },
                                controls: { page = .init(name: "touch", profile: $0.id) })
                        } else { ForEach(library.instances) { instance in
                            HarborInstanceCard(instance: instance, compact: verticalSizeClass == .compact,
                                launch: { page = .init(name: "launch", profile: instance.id) },
                                manage: { page = .init(name: "instance", profile: instance.id) },
                                controls: { page = .init(name: "touch", profile: instance.id) })
                        } }
                    }
                }
                .harborPageBackground()
                .navigationTitle("游戏").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { page = .init(name: "accounts") } label: { Image(systemName: "person.crop.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .accessibilityLabel("账号与皮肤")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button("安装 Minecraft") { page = .init(name: "install") }
                            Button("从文件导入 Modrinth 整合包") { page = .init(name: "importPack") }
                            Button("浏览在线整合包") { page = .init(name: "resources") }
                            Button(coverFlow ? "使用列表选择实例" : "使用封面流选择实例") { coverFlow.toggle() }
                        } label: { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .accessibilityLabel("安装或导入")
                    }
                }.refreshable { library.refresh() }
            }.tabItem { Label("游戏", systemImage: "square.stack.3d.up") }
            NavigationStack {
                List {
                    Section("实例资源") {
                      HarborGlassPanel {
                        nativeRow("Modrinth 整合包", symbol: "shippingbox", pageName: "resources")
                        nativeRow("从文件导入整合包", symbol: "doc.zipper", pageName: "importPack")
                        nativeRow("Fabric 与 Quilt", symbol: "square.stack.3d.down.right", pageName: "fabric")
                        nativeRow("Forge 与 NeoForge", symbol: "square.stack.3d.down.right", pageName: "forge")
                        nativeRow("打开 JAR 安装器", symbol: "square.and.arrow.down", pageName: "import")
                      }
                    }
                    Section {
                        Text("本地导入支持 .mrpack，以及包含 modrinth.index.json 的 ZIP。原文件会保留；下载与校验完成后才创建实例。Forge / NeoForge 整合包需要先安装对应的加载器。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.harborPageBackground().navigationTitle("资源")
            }.tabItem { Label("资源", systemImage: "arrow.down.circle") }
            NavigationStack { HarborFoldersView(model: folders) }
                .tabItem { Label("模组夹", systemImage: "folder") }
            NavigationStack {
                List {
                  if matchesSettings("触控 摇杆 手柄 键鼠 控制 布局") {
                    Section("游戏控制") {
                      HarborGlassPanel {
                        Button { page = .init(name: "touch") } label: {
                            Label("触控与摇杆", systemImage: "hand.draw").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("settings.touch")
                        nativeRow("手柄、键鼠与原生控制设置", symbol: "gamecontroller", pageName: "controls")
                      }
                    }
                  }
                  if matchesSettings("Java 渲染 性能 内存 JVM 运行") {
                    Section("运行") {
                        HarborGlassPanel { nativeRow("Java、渲染与性能", symbol: "speedometer", pageName: "settings") }
                    }
                  }
                  if matchesSettings("外观 性能 动画 独家优化 Liquid Glass 玻璃") {
                    HarborPerformanceSettings()
                  }
                  if matchesSettings("游戏库 实例 封面流 Cover Flow 列表 音效 触感 振动") {
                    HarborLibraryPresentationSettings()
                  }
                  if matchesSettings("模组夹 图标 名称 加载器 版本 简介 收藏 信息 显示") {
                    Section("模组夹") {
                        NavigationLink { HarborFolderDisplaySettings() } label: {
                            Label("模组夹内的信息显示", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        }
                    }
                  }
                  if matchesSettings("关于 作者 贡献 GitHub issues 开发者 ADsurfboard") {
                    Section("关于") {
                        LabeledContent("作者", value: "ADsurfboard")
                        NavigationLink { HarborPeopleView() } label: { Label("开发者与贡献名单", systemImage: "person.2").frame(minHeight: 44) }
                        Text(services.runtimeDescription).font(.footnote).foregroundStyle(.secondary)
                        Link("GitHub 项目", destination: URL(string: "https://github.com/ADsurfboard/MC-Harbor")!)
                        Link("提交问题或建议", destination: URL(string: "https://github.com/ADsurfboard/MC-Harbor/issues")!)
                    }
                  }
                }.harborPageBackground().navigationTitle("设置")
                    .searchable(text: $settingsQuery, prompt: "搜索设置、功能或关键词")
            }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .tint(Color(red: 0.12, green: 0.52, blue: 0.36))
        .sheet(item: $page, onDismiss: { library.refresh() }) { selected in
            NativePresentationContent(services: services, page: selected)
        }.harborMotionPolicy()
        .onChange(of: scenePhase) { phase in if phase == .active { library.refresh() } }
        .onAppear {
            if ProcessInfo.processInfo.environment["HARBOR_SMOKE_TEST"] == "1" {
                NSLog("[MC Harbor] HARBOR_ROOT_READY")
                try? Data("HARBOR_ROOT_READY".utf8).write(
                    to: services.harborHomeURL.appendingPathComponent(".native-smoke-ready"), options: .atomic)
            }
        }
    }
    private func matchesSettings(_ keywords: String) -> Bool {
        settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keywords.localizedCaseInsensitiveContains(settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func nativeRow(_ title: String, symbol: String, pageName: String) -> some View {
        Button { page = .init(name: pageName) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("native.page." + pageName)
    }
}
