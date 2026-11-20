import AppKit
import AVKit
import SwiftUI

private struct PreviewFixture: View {
    let player: AVPlayer?
    var body: some View {
        VStack {
            Text("壁纸预览")
            if let player { WallpaperVideoPreview(player: player) }
            else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(width: 320, height: 220)
    }
}

@main enum WallpaperPreviewChecks {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in await checks() }
        NSApp.run()
    }

    @MainActor static func checks() async {
        var results: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) {
            results[name] = value
            print((value ? "PASS " : "FAIL ") + name); fflush(stdout)
        }
        func views(_ view: NSView) -> [AVPlayerView] {
            (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap { views($0) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for cycle in 1...8 {
            let host = NSHostingView(rootView: PreviewFixture(player: nil))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            check("empty-image-branch-\(cycle)", views(host).isEmpty)
            let player = AVPlayer(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            player.isMuted = true
            host.rootView = PreviewFixture(player: player)
            host.layoutSubtreeIfNeeded()
            let native = views(host).first
            check("native-preview-created-\(cycle)", native?.player === player)
            check("native-inline-controls-\(cycle)", native?.controlsStyle == .inline)
            check("no-external-playback-ui-\(cycle)", native?.showsSharingServiceButton == false && native?.allowsPictureInPicturePlayback == false)
            if cycle == 1 {
                player.play()
                for _ in 0..<100 {
                    if player.currentItem?.status != .unknown { break }
                    try? await Task<Never, Never>.sleep(nanoseconds: 50_000_000)
                }
                check("actual-video-decodes", player.currentItem?.status == .readyToPlay)
            }
            let replacement = AVPlayer(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            host.rootView = PreviewFixture(player: replacement)
            host.layoutSubtreeIfNeeded()
            check("switch-releases-old-playback-\(cycle)", player.rate == 0 && views(host).first?.player === replacement)
            replacement.play()
            host.rootView = PreviewFixture(player: nil)
            host.layoutSubtreeIfNeeded()
            // SwiftUI tears down removed native views during the next update.
            try? await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
            check("dismiss-pauses-video-\(cycle)", replacement.rate == 0)
            check("dismiss-detaches-player-\(cycle)", native?.player == nil)
            window.contentView = nil
        }
        let missing = AVPlayer(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        let brokenHost = NSHostingView(rootView: PreviewFixture(player: missing))
        window.contentView = brokenHost; brokenHost.layoutSubtreeIfNeeded()
        check("missing-file-keeps-native-view-alive", views(brokenHost).first?.player === missing)
        let report: [String: Any] = ["checks": results, "passed": results.values.filter { $0 }.count,
            "failed": results.values.filter { !$0 }.count,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Production NSViewRepresentable mounted in SwiftUI, actual video decoding and teardown; no player data"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        window.orderOut(nil)
        exit(results.values.contains(false) ? 1 : 0)
    }
}
