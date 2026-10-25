import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    final class Coordinator { weak var configuredWindow:NSWindow? }
    func makeCoordinator()->Coordinator{Coordinator()}
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window,coordinator:context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard nsView.window !== context.coordinator.configuredWindow else{return}
        DispatchQueue.main.async { configure(nsView.window,coordinator:context.coordinator) }
    }

    private func configure(_ window: NSWindow?,coordinator:Coordinator) {
        guard let window,window !== coordinator.configuredWindow else { return }
        coordinator.configuredWindow=window
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.toolbarStyle = .unifiedCompact
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        if !window.styleMask.contains(.fullScreen),
           let visibleFrame = window.screen?.visibleFrame,
           window.frame.width > visibleFrame.width
                || window.frame.height > visibleFrame.height {
            let repairedSize = NSSize(
                width: min(1120, visibleFrame.width - 80),
                height: min(760, visibleFrame.height - 80)
            )
            window.setContentSize(repairedSize)
            window.center()
        }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragSurfaceView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragSurfaceView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}


struct HarborSectionHeader: View {
    let eyebrow: String
    let title: String
    let detail: String
    let appearance: HarborAppearance

    var body: some View {
        let theme = HarborTheme(appearance: appearance)
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(HarborPalette.seaGlass)
            Text(title)
                .font(.system(size: 31, weight: .semibold, design: .serif))
                .foregroundStyle(theme.primaryText)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
        }
    }
}

struct HarborStatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }
}

struct HarborEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    let appearance: HarborAppearance

    var body: some View {
        let theme = HarborTheme(appearance: appearance)
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(HarborPalette.seaGlass)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .foregroundStyle(theme.primaryText)
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(28)
        .harborGlass(appearance: appearance)
    }
}

struct HarborActivityOverlay: View {
    let title: String
    let detail: String
    let appearance: HarborAppearance

    var body: some View {
        let theme = HarborTheme(appearance: appearance)
        HStack(spacing: 15) {
            ProgressView()
                .controlSize(.small)
                .tint(HarborPalette.seaGlass)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .harborGlass(appearance: appearance, radius: 18)
    }
}

struct HarborToast: View {
    let message: String
    let appearance: HarborAppearance

    var body: some View {
        let theme = HarborTheme(appearance: appearance)
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(HarborPalette.seaGlass)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(3)
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .harborGlass(appearance: appearance, radius: 16)
    }
}
