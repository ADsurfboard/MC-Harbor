import AppKit
import AVKit
import SwiftUI

/// Embed AppKit directly. The AVKit SwiftUI VideoPlayer overlay crashes while
/// resolving its superclass metadata on affected macOS releases, even when the
/// conditional video branch is not currently visible.
struct WallpaperVideoPreview: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsSharingServiceButton = false
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.updatesNowPlayingInfoCenter = false
        if #available(macOS 13.0, *) { view.allowsVideoFrameAnalysis = false }
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard view.player !== player else { return }
        view.player?.pause()
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
