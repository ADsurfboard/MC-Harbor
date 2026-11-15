import SwiftUI
import UIKit
import HarborCore
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Combine


@MainActor final class HarborWallpaperState: ObservableObject {
    static let shared = HarborWallpaperState()
    @Published private(set) var snapshot = HarborWallpaperSnapshot()
    @Published private(set) var image: UIImage?
    @Published private(set) var player: AVQueuePlayer?
    @Published var error: String?
    @Published var busy = false
    private(set) var library: WallpaperLibrary?
    private var home: URL?
    private var looper: AVPlayerLooper?
    private var observers: Set<AnyCancellable> = []
    private var active = true
    private var inGame = false
    private var previewing = false
    private var exclusive = UserDefaults.standard.bool(forKey: HarborAppearance.exclusiveOptimizationKey)
    private var generation = UUID()
    private var importing: Task<Void, Never>?
    private let previews = NSCache<NSUUID, UIImage>()
    private init() {
        previews.totalCostLimit = 8 * 1024 * 1024; previews.countLimit = 40
        for event in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
                      UIApplication.didReceiveMemoryWarningNotification, HarborGameEvents.started, HarborGameEvents.stopped] {
            NotificationCenter.default.publisher(for: event).sink { [weak self] notification in
                let name = notification.name
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == UIApplication.willResignActiveNotification { self.active = false; self.importing?.cancel() }
                    if name == UIApplication.didBecomeActiveNotification { self.active = true }
                    if name == HarborGameEvents.started { self.inGame = true }
                    if name == HarborGameEvents.stopped { self.inGame = false }
                    if name == UIApplication.didReceiveMemoryWarningNotification { self.previews.removeAllObjects() }
                    self.updatePlayback()
                }
            }.store(in: &observers)
        }
    }
    func configure(home: URL) async {
        guard self.home != home else { return }
        self.home = home; library = WallpaperLibrary(home: home)
        await refresh()
    }
    func setPolicy(exclusive: Bool) { guard self.exclusive != exclusive else { return }; self.exclusive = exclusive; updatePlayback() }
    func setPreviewing(_ value: Bool) { previewing = value; updatePlayback() }
    private func updatePlayback() {
        if active && !inGame && !exclusive && !previewing { player?.play() } else { player?.pause() }
    }
    private func stopPlayer() {
        player?.pause(); looper?.disableLooping(); looper = nil; player?.removeAllItems(); player = nil
    }
    func refresh() async {
        guard let library else { return }
        do { snapshot = try await library.load(); await displaySelection() } catch { self.error = error.localizedDescription; stopPlayer(); image = nil }
    }
    private func displaySelection() async {
        let current = UUID(); generation = current; stopPlayer(); image = nil
        guard let library, let id = snapshot.selected, let item = snapshot.items.first(where: { $0.id == id }) else { return }
        do {
            let url = try await library.media(item)
            if item.video {
                let data = try await library.preview(item.id)
                guard generation == current else { return }
                image = Self.previewImage(data)
                let queue = AVQueuePlayer(); queue.isMuted = true; queue.allowsExternalPlayback = false
                let loop = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
                looper = loop; player = queue; updatePlayback()
            } else {
                let data = try await Task.detached(priority: .utility) { try HarborWallpaperMedia.png(HarborWallpaperMedia.image(url, maximum: 2560)) }.value
                guard generation == current else { return }
                image = Self.previewImage(data)
                guard image != nil else { throw ResourceError.invalid("所选壁纸无法显示，请重新导入。") }
            }
        } catch { if generation == current { self.error = error.localizedDescription; stopPlayer(); image = nil } }
    }
    static func previewImage(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2560, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    func thumbnail(_ item: HarborWallpaper) async -> UIImage? {
        if let image = previews.object(forKey: item.id as NSUUID) { return image }
        guard let library, let data = try? await library.preview(item.id), let image = Self.previewImage(data) else { return nil }
        previews.setObject(image, forKey: item.id as NSUUID, cost: Int(image.size.width * image.size.height * 4)); return image
    }
    func select(_ id: UUID?) async {
        guard let library, !busy else { return }
        do { try await library.select(id); await refresh() } catch { self.error = error.localizedDescription }
    }
    func rename(_ id: UUID, name: String) async {
        guard let library, !busy else { return }
        do { try await library.rename(id, name: name); snapshot = try await library.load() } catch { self.error = error.localizedDescription }
    }
    func remove(_ id: UUID) async {
        guard let library, !busy else { return }
        do {
            try await library.remove(id); previews.removeObject(forKey: id as NSUUID)
            let previous = snapshot.selected; snapshot = try await library.load()
            if previous != snapshot.selected { await displaySelection() }
        } catch { self.error = error.localizedDescription; await refresh() }
    }
    func importFile(_ file: URL) {
        guard !busy, let home, let library else { return }; busy = true; error = nil
        importing = Task {
            defer { busy = false; importing = nil }
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let stage = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("harbor-wallpaper-import-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: stage) }
                let copy = stage.appendingPathComponent("source." + file.pathExtension.lowercased())
                try await Task.detached(priority: .utility) {
                    var failure: NSError?, inner: Error?
                    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: .withoutChanges, error: &failure) { source in
                        do {
                            let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                            let limit = ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) ? 512 : 50
                            guard properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? Int.max) <= limit * 1024 * 1024 else { throw ResourceError.invalid("请选择有效本地文件。图片上限 50 MB，视频上限 512 MB。") }
                            try FileManager.default.copyItem(at: source, to: copy)
                        } catch { inner = error }
                    }
                    if let failure { throw failure }; if let inner { throw inner }
                }.value
                try Task.checkCancellation()
                let media = try await Task.detached(priority: .utility) { try await HarborWallpaperMedia.prepare(copy) }.value
                try Task.checkCancellation()
                _ = try await library.add(media, name: String(file.deletingPathExtension().lastPathComponent.prefix(80)))
                snapshot = try await library.load()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private final class HarborWallpaperPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}
struct HarborWallpaperVideo: UIViewRepresentable {
    let player: AVQueuePlayer
    func makeUIView(context: Context) -> UIView {
        let view = HarborWallpaperPlayerView(); view.isUserInteractionEnabled = false
        view.playerLayer?.videoGravity = .resizeAspectFill; view.playerLayer?.player = player; return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { (uiView as? HarborWallpaperPlayerView)?.playerLayer?.player = player }
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) { (uiView as? HarborWallpaperPlayerView)?.playerLayer?.player = nil }
}
