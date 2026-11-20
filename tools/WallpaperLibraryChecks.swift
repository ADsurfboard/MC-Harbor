import AppKit
import AVKit
import SwiftUI

extension UpdateChecks {
    @MainActor static func wallpaperUI(_ config: [String: Any], root: URL) async throws {
        var results: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) { results[name] = value; print((value ? "PASS " : "FAIL ") + name) }
        func players(_ view: NSView) -> [AVPlayerView] {
            (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap { players($0) }
        }
        var preferences = NativePreferences()
        preferences.gameRoot = root.appendingPathComponent("empty-game").path
        preferences.soundsEnabled = false
        preferences.introEnabled = false
        try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("preferences.json"), options: .atomic)
        let model = LauncherModel()
        let library = WallpaperLibrary(current: WallpaperSettings())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for scenario in ["empty", "image", "video", "missing-image", "missing-video"] {
            if scenario != "empty" {
                let video = scenario.hasSuffix("video")
                let path = scenario.hasPrefix("missing") ? root.appendingPathComponent("missing." + (video ? "mp4" : "png")).path :
                    (video ? config["video"] as! String : config["image"] as! String)
                let item = LibraryWallpaper(id: scenario, name: scenario, path: path, kind: video ? .video : .image, owned: false)
                library.items = [item]; try library.save()
                model.preferences.wallpaper.kind = item.kind
                model.preferences.wallpaper.filePath = path
            }
            for cycle in 1...3 {
                let host = NSHostingView(rootView: WallpaperLibraryPanel(model: model))
                window.contentView = host; window.orderBack(nil); host.layoutSubtreeIfNeeded()
                try await HarborDelay.sleep(seconds: 0.25)
                host.layoutSubtreeIfNeeded()
                let native = players(host)
                check("panel-\(scenario)-mount-\(cycle)", host.frame.width > 0 && host.frame.height > 0)
                check("panel-\(scenario)-preview-kind-\(cycle)", scenario.hasSuffix("video") ? native.count == 1 : native.isEmpty)
                let playback = native.first?.player
                window.contentView = nil
                try await HarborDelay.sleep(seconds: 0.15)
                check("panel-\(scenario)-close-pauses-\(cycle)", playback == nil || playback?.rate == 0)
            }
        }
        window.orderOut(nil); model.flushPreferences()
        let report: [String: Any] = ["checks": results, "passed": results.values.filter { $0 }.count,
            "failed": results.values.filter { !$0 }.count,
            "scope": "Full production WallpaperLibraryPanel and LauncherModel in disposable data directory; no player data",
            "os": ProcessInfo.processInfo.operatingSystemVersionString]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.deletingLastPathComponent().appendingPathComponent("wallpaper-library-report.json"))
        if results.values.contains(false) { exit(1) }
    }
}
