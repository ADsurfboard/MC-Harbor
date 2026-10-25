import AppKit
import SwiftUI

/// SwiftUI hides the table body background but leaves AppKit's corner filler opaque.
/// Repair only the enclosing table's scroll chrome, without changing rows or hit areas.
struct TableChromeAnchor:NSViewRepresentable {
    func makeNSView(context:Context)->TableChromeView{TableChromeView()}
    func updateNSView(_ view:TableChromeView,context:Context){view.schedule()}
}
final class TableChromeView:NSView {
    override var isOpaque:Bool{false}
    override func hitTest(_ point:NSPoint)->NSView?{nil}
    private var queued=false
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();schedule()}
    func schedule(){guard !queued else{return};queued=true;DispatchQueue.main.async{[weak self] in self?.queued=false;self?.repair()}}
    private func repair(){
        func tables(_ view:NSView)->[NSTableView]{if let table=view as? NSTableView{return [table]};return view.subviews.flatMap(tables)}
        var ancestor:NSView?=superview
        for _ in 0..<6 {guard let view=ancestor else{return};let found=tables(view);if !found.isEmpty{for table in found{table.backgroundColor = .clear;guard let scroll=table.enclosingScrollView else{continue};scroll.drawsBackground=false;scroll.backgroundColor = .clear;scroll.contentView.drawsBackground=false;scroll.scrollerStyle = .overlay;scroll.borderType = .noBorder;if !(table.cornerView is TransparentTableCorner){table.cornerView=TransparentTableCorner(frame:.zero)}};return};ancestor=view.superview}
    }
}
private final class TransparentTableCorner:NSView {
    override var isOpaque:Bool{false}
    override func draw(_ dirtyRect:NSRect){}
    override func hitTest(_ point:NSPoint)->NSView?{nil}
}
