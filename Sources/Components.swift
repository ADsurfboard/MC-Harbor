import AppKit
import SwiftUI

final class HarborAppDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSWindow.allowsAutomaticWindowTabbing=false
        HarborWindowController.shared.installReopenHandler()
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        HarborWindowController.shared.showMainWindow()
        return false
    }
}

/// SwiftUI's WindowGroup can consume reopen events before the delegate adaptor.
/// Handle only the standard reopen event, and leave other Apple Events to SwiftUI.
final class HarborWindowController:NSObject {
    static let shared=HarborWindowController()
    private(set) weak var mainWindow:NSWindow?
    func register(_ window:NSWindow) {
        mainWindow=window
        installReopenHandler()
    }
    func installReopenHandler() {
        NSAppleEventManager.shared().setEventHandler(self,andSelector:#selector(reopen(_:withReplyEvent:)),forEventClass:AEEventClass(kCoreEventClass),andEventID:AEEventID(kAEReopenApplication))

    }
    @objc private func reopen(_ event:NSAppleEventDescriptor,withReplyEvent reply:NSAppleEventDescriptor) {showMainWindow()}
    @objc func showMainWindow() {
        guard let window=mainWindow else{return}
        NSApp.unhide(nil)
        if window.isMiniaturized{window.deminiaturize(nil)}
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
}

struct WindowConfigurator: NSViewRepresentable {
    final class Coordinator:NSObject { weak var configuredWindow:NSWindow?
        @objc func hideMainWindow(_ sender:Any?){configuredWindow?.orderOut(sender)}
    }
    func makeCoordinator()->Coordinator{Coordinator()}
    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView()
        let coordinator=context.coordinator
        view.attached={window in configure(window,coordinator:coordinator)}
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard nsView.window !== context.coordinator.configuredWindow else{return}
        DispatchQueue.main.async { configure(nsView.window,coordinator:context.coordinator) }
    }

    private func configure(_ window: NSWindow?,coordinator:Coordinator) {
        guard let window,window !== coordinator.configuredWindow else { return }
        coordinator.configuredWindow=window
        // The identifier belongs to SwiftUI's scene lifecycle; do not replace it.
        HarborWindowController.shared.register(window)
        window.isReleasedWhenClosed=false
        if let button=window.standardWindowButton(.closeButton){button.target=coordinator;button.action=#selector(Coordinator.hideMainWindow(_:))}
        window.contentMinSize=NSSize(width:1040,height:700)
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

private final class WindowAttachmentView:NSView {
    var attached:((NSWindow)->Void)?
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if let window{attached?(window)}}
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
    @Environment(\.harborThemeRuntime) private var customization
    let eyebrow: String
    let title: String
    let detail: String
    let appearance: HarborAppearance

    var body: some View {
        let theme = HarborTheme(appearance: appearance,style:customization)
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
    @Environment(\.harborThemeRuntime) private var customization
    let icon: String
    let title: String
    let detail: String
    let appearance: HarborAppearance

    var body: some View {
        let theme = HarborTheme(appearance: appearance,style:customization)
        VStack(spacing: 14) {
            HarborSymbol(systemName: icon)
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
    @Environment(\.harborThemeRuntime) private var customization
    let title: String
    let detail: String
    let appearance: HarborAppearance

    var body: some View {
        let theme = HarborTheme(appearance: appearance,style:customization)
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
    @Environment(\.harborThemeRuntime) private var customization
    let message: String
    let appearance: HarborAppearance

    var body: some View {
        let theme = HarborTheme(appearance: appearance,style:customization)
        HStack(spacing: 10) {
            HarborSymbol(systemName: "checkmark.circle.fill")
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
