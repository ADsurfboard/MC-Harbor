import SwiftUI
import UIKit
import HarborIOSUI
import HarborCore

/// Disposable native UI host. It never claims to run Java or to authenticate a real
/// account; game-engine integration is tested separately in the native app target.
@main struct HarborIOSHarness: App {
    private let services = HarnessServices()
    var body: some Scene { WindowGroup { HarnessRoot(services: services).ignoresSafeArea() } }
}

struct HarnessRoot: UIViewControllerRepresentable {
    let services: HarnessServices
    func makeUIViewController(context: Context) -> UIViewController { HarborRootFactory.makeController(services: services) }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

@MainActor final class HarnessServices: NSObject, HarborNativeServices, HarborSocialTransportProvider {
    private var fixtureAccess: String?
    var socialCredential: String? { ProcessInfo.processInfo.environment["HARBOR_FRIENDS_FIXTURE"] == "1" ? String(repeating: "a", count: 96) : nil }
    var socialTransport: ResourceTransport? {
        guard socialCredential != nil else { return nil }
        return { request, _ in
            let person: @Sendable (Int) -> [String: Any] = { index in
                ["id": String(format: "00000000-0000-4000-8000-%012d", index), "code": String(format: "%012d", index), "name": String(format: "隔离测试好友 %02d", index), "sharing": true, "skinHash": "", "skinModel": "default"]
            }
            let object: Any
            if request.url?.path == "/health" { object = ["ok": true, "chat": true, "realtime": false] }
            else if request.url?.path == "/v1/friends" { object = ["me": person(999), "friends": (1...48).map(person), "requests": [], "sent": []] }
            else { object = [] as [String] }
            return ResourceHTTPResult(data: try JSONSerialization.data(withJSONObject: object), status: 200)
        }
    }
    let harborHomeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeUITest")
    let runtimeDescription = "隔离界面测试环境，不包含游戏 JVM，不使用玩家账号或存档。"
    override init() {
        super.init()
        // The shared production root can publish its ready marker only inside
        // this disposable UI host's own Application Support directory.
        try? FileManager.default.createDirectory(at: harborHomeURL, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["HARBOR_WORLD_FIXTURE"] == "1" { try? WorldFixture.prepare(home: harborHomeURL) }
        if ProcessInfo.processInfo.environment["HARBOR_LOCALIZATION_FIXTURE"] == "1" {
            // Only this disposable UI host has fixtures. No environment flag
            // enables synthetic resources inside the complete native app.
            let root = harborHomeURL.appendingPathComponent("localization-fixture")
            let files = ["kubejs/assets/harborqa/lang/en_us.json": #"{"item.harborqa.tool":"Fixture tool %s"}"#,
                         "config/ftbquests/quests/start.snbt": "{id:'QA0001' title:'Fixture quest' rewards:[{xp:25}]}" ]
            for (path, text) in files {
                let file = root.appendingPathComponent(path)
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(text.utf8).write(to: file, options: .atomic)
            }
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("mods"), withIntermediateDirectories: true)
        }
        if ProcessInfo.processInfo.environment["HARBOR_WALLPAPER_FIXTURE"] == "1" {
            let folder = harborHomeURL.appendingPathComponent("harbor-wallpapers"), index = folder.appendingPathComponent("library.json")
            if !FileManager.default.fileExists(atPath: index.path) {
                let id = "12345678-1234-4321-8765-123456789ABC"
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
                    UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
                }
                if let data = image.pngData() {
                    try? data.write(to: folder.appendingPathComponent(id + ".png"))
                    try? data.write(to: folder.appendingPathComponent(id + ".preview.png"))
                    let object: [String: Any] = ["items": [["id": id, "name": "QA Wallpaper", "filename": id + ".png", "video": false, "added": Date().timeIntervalSinceReferenceDate]]]
                    if let json = try? JSONSerialization.data(withJSONObject: object) { try? json.write(to: index) }
                }
            }
        }
    }
    func instanceListJSON() -> Data {
        Data("""
        [{"id":"fabric-example","name":"触控验证 · Fabric","version":"1.20.1","loader":"Fabric"},
         {"id":"forge-example","name":"很长的实例名称用于验证小屏幕、两行文字和完整点击范围","version":"1.20.1","loader":"Forge"}]
        """.utf8)
    }
    func controller(forPage page: String, profile: String?) -> UIViewController {
        let controller = UIViewController(); controller.view.backgroundColor = .systemBackground
        let label = UILabel(); label.text = "原生接口测试：\(page)\n\(profile ?? "")"; label.numberOfLines = 0; label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 24), label.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -24), label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
        return controller
    }
    func sendKey(_ key: Int32, pressed: Bool) {}
    func sendMouseButton(_ button: Int32, pressed: Bool) {}
    func showGameKeyboard() {}
    func isPointerGrabbed() -> Bool { false }
    func readModArchive(at url: URL, entry: String?, completion: @escaping (Data?, String?) -> Void) {
        completion(nil, "隔离界面测试不读取玩家模组归档。")
    }
    func beginModAccess(profile: String) throws -> Data {
        if ProcessInfo.processInfo.environment["HARBOR_LOCALIZATION_FIXTURE"] == "1", profile == "fabric-example", fixtureAccess == nil {
            let token = UUID().uuidString; fixtureAccess = token
            return try JSONSerialization.data(withJSONObject: ["token": token, "directory": harborHomeURL.appendingPathComponent("localization-fixture/mods").path, "files": [] as [String]])
        }
        throw NSError(domain: "HarborQAHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试实例不包含游戏文件。"])
    }
    func endModAccess(token: String) { if token == fixtureAccess { fixtureAccess = nil } }
    func beginResourceAccess(profile: String, kind: String) throws -> Data {
        if ProcessInfo.processInfo.environment["HARBOR_WORLD_FIXTURE"] == "1", profile == "fabric-example", kind == "saves", fixtureAccess == nil {
            let token = UUID().uuidString; fixtureAccess = token
            return try JSONSerialization.data(withJSONObject: ["token": token, "directory": harborHomeURL.appendingPathComponent("world-fixture/saves").path, "files": [] as [String]])
        }
        throw NSError(domain: "HarborQAHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试实例不包含游戏文件。"])
    }
}
