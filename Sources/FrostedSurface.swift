import AppKit
import SwiftUI
import QuartzCore

/// A native in-window backdrop: the material blurs background detail, not foreground text.
struct FrostedSurface:NSViewRepresentable {
    let blur:CGFloat
    let radius:CGFloat
    func makeNSView(context:Context)->FrostedSurfaceView{FrostedSurfaceView()}
    func updateNSView(_ view:FrostedSurfaceView,context:Context){view.configure(blur:blur,radius:radius)}
}
final class FrostedSurfaceView:NSVisualEffectView {
    override var isOpaque:Bool{false}
    override func hitTest(_ point:NSPoint)->NSView?{nil}
    override init(frame:NSRect){
        super.init(frame:frame)
        material = .popover;blendingMode = .withinWindow;state = .active
        appearance = NSAppearance(named:.aqua)
        wantsLayer=true;layer?.masksToBounds=true;layer?.cornerCurve = .continuous
    }
    required init?(coder:NSCoder){nil}
    func configure(blur:CGFloat,radius:CGFloat){
        // Do not inherit a SwiftUI modal/appearance animation or window emphasis.
        // Only the explicit clarity setting changes this material's diffusion.
        state = .active
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer?.cornerRadius=radius;alphaValue=min(1,max(0,blur/36))
        CATransaction.commit()
    }
}
