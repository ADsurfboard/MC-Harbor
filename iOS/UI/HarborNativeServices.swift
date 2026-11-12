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
}

@MainActor @objc(HarborRootFactory) public final class HarborRootFactory: NSObject {
    @objc public static func makeController(services: HarborNativeServices) -> UIViewController {
        UIHostingController(rootView: HarborPhoneRoot(services: services))
    }
    @objc public static func controlConfigurationURL(home: URL, profile: String?) -> URL {
        // A file name never contains a profile name supplied by a modpack.
        let component = SHA256.hash(data: Data((profile ?? "global").utf8)).map { String(format: "%02x", $0) }.joined()
        return home.appendingPathComponent("harbor-touch", isDirectory: true)
            .appendingPathComponent(component + ".json")
    }
}

struct PhoneInstance: Decodable, Identifiable {
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

struct HarborPhoneRoot: View {
    let services: HarborNativeServices
    @StateObject private var library: PhoneLibrary
    @State private var page: NativePage?
    @State private var touchProfile: String?
    @State private var showsTouchEditor = false
    @Environment(\.scenePhase) private var scenePhase
    init(services: HarborNativeServices) {
        self.services = services
        _library = StateObject(wrappedValue: PhoneLibrary(services))
    }
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        HStack(alignment: .center, spacing: 16) {
                            Image(systemName: "cube.transparent.fill").font(.system(size: 36)).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("MC Harbor").font(.largeTitle.bold())
                                Text("Minecraft，随身出发。").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 18).listRowBackground(Color.clear)
                    }
                    Section("游戏库") {
                        if let error = library.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        if library.instances.isEmpty && library.error == nil {
                            Button { page = .init(name: "install") } label: {
                                Label("安装 Minecraft 或导入整合包", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
                            }.accessibilityIdentifier("library.install.empty")
                        }
                        ForEach(library.instances) { instance in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 14) {
                                    Image(systemName: instance.loader.lowercased().contains("forge") ? "hammer.fill" : "cube.fill")
                                        .font(.system(size: 28)).frame(width: 48, height: 48).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(instance.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                                        Text([instance.version, instance.loader].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Menu {
                                        Button { page = .init(name: "instance", profile: instance.id) } label: { Label("实例管理", systemImage: "slider.horizontal.3") }
                                        Button { touchProfile = instance.id; showsTouchEditor = true } label: { Label("触控布局", systemImage: "hand.draw") }
                                    } label: {
                                        Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
                                            .background(.thinMaterial, in: Circle()).contentShape(Circle())
                                    }.accessibilityLabel(instance.name + "，更多操作")
                                }
                                Button { page = .init(name: "launch", profile: instance.id) } label: {
                                    Label("启动游戏", systemImage: "play.fill").font(.headline)
                                        .frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
                                }.buttonStyle(.borderedProminent).accessibilityIdentifier("instance.launch." + instance.id)
                            }.padding(.vertical, 12)
                        }
                    }
                }
                .navigationTitle("游戏")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { page = .init(name: "accounts") } label: { Image(systemName: "person.crop.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .accessibilityLabel("账号与皮肤")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { page = .init(name: "install") } label: { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .accessibilityLabel("安装或导入")
                    }
                }.refreshable { library.refresh() }
            }.tabItem { Label("游戏", systemImage: "square.stack.3d.up") }
            NavigationStack {
                List {
                    Section("实例资源") {
                        nativeRow("模组与整合包", symbol: "shippingbox", pageName: "resources")
                        nativeRow("加载器安装", symbol: "square.stack.3d.down.right", pageName: "loaders")
                        nativeRow("导入文件", symbol: "square.and.arrow.down", pageName: "import")
                    }
                }.navigationTitle("资源")
            }.tabItem { Label("资源", systemImage: "arrow.down.circle") }
            NavigationStack {
                List {
                    Section("游戏控制") {
                        Button { touchProfile = nil; showsTouchEditor = true } label: {
                            Label("触控与摇杆", systemImage: "hand.draw").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.accessibilityIdentifier("settings.touch")
                        nativeRow("手柄、键鼠与原生控制设置", symbol: "gamecontroller", pageName: "controls")
                    }
                    Section("运行") { nativeRow("Java、渲染与性能", symbol: "speedometer", pageName: "settings") }
                    Section("关于") {
                        LabeledContent("作者", value: "ADsurfboard")
                        Text(services.runtimeDescription).font(.footnote).foregroundStyle(.secondary)
                        Link("GitHub 项目", destination: URL(string: "https://github.com/ADsurfboard/MC-Harbor")!)
                        Link("提交问题或建议", destination: URL(string: "https://github.com/ADsurfboard/MC-Harbor/issues")!)
                    }
                }.navigationTitle("设置")
            }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .tint(Color(red: 0.12, green: 0.52, blue: 0.36))
        .sheet(item: $page, onDismiss: { library.refresh() }) { selected in
            NativePageHost(services: services, page: selected).ignoresSafeArea()
        }
        .sheet(isPresented: $showsTouchEditor) {
            TouchLayoutEditor(home: services.harborHomeURL, profile: touchProfile)
        }
        .onChange(of: scenePhase) { phase in if phase == .active { library.refresh() } }
    }
    private func nativeRow(_ title: String, symbol: String, pageName: String) -> some View {
        Button { page = .init(name: pageName) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
    }
}
