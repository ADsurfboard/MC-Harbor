import SwiftUI
import UIKit
import HarborIOSUI

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

@MainActor final class HarnessServices: NSObject, HarborNativeServices {
    let harborHomeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeUITest")
    let runtimeDescription = "隔离界面测试环境，不包含游戏 JVM，不使用玩家账号或存档。"
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
}
