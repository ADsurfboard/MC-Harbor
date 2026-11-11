from pathlib import Path
import subprocess
root=Path(__file__).resolve().parent.parent
(root/'build').mkdir(exist_ok=True)
source=(root/'Sources/Components.swift').read_text().split('struct WindowDragRegion:')[0]
source+='''
final class QAWindowDelegate:NSObject,NSWindowDelegate{var resizes=0;func windowDidResize(_ notification:Notification){resizes+=1}}
@main enum WindowLifecycleChecks {
 static func main(){
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.regular)
  Task { @MainActor in await runChecks() }
  NSApp.run()
 }
 @MainActor static func runChecks() async {
  var failed=0
  func check(_ name:String,_ value:Bool){print((value ? "PASS ":"FAIL ")+name);if !value{failed+=1};fflush(stdout)}
  func settle() async{try? await Task<Never,Never>.sleep(nanoseconds:300_000_000)}
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  window.identifier=NSUserInterfaceItemIdentifier("QA-SwiftUI-scene-identifier")
  window.contentView=NSHostingView(rootView:Text("Window lifecycle QA").background(WindowConfigurator()))
  window.makeKeyAndOrderFront(nil);await settle()
  check("attached-window-registered",HarborWindowController.shared.mainWindow===window)
  check("scene-identifier-preserved",window.identifier?.rawValue=="QA-SwiftUI-scene-identifier")
  check("close-delegate-registered",window.delegate is HarborCloseDelegate)
  let original=QAWindowDelegate();window.delegate=original;HarborWindowController.shared.register(window)
  // Hosted runners can have a 1024px work area: asking for a larger
  // window may be clamped to the same size, producing no resize event.
  window.minSize=NSSize(width:400,height:300)
  let beforeResize=window.frame.size
  window.setContentSize(NSSize(width:640,height:460));await settle()
  print("resize-state",beforeResize,window.frame.size,"forwarded",original.resizes)
  check("native-frame-actually-resized",window.frame.size != beforeResize)
  check("original-delegate-resize-forwarded",original.resizes>0)
  let delegate=HarborAppDelegate()
  for attempt in 1...3{
   window.miniaturize(nil);await settle();check("miniaturized-\\(attempt)",window.isMiniaturized)
   let handled=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true);await settle()
   check("reopen-restores-minimized-\\(attempt)",!window.isMiniaturized && window.isVisible)
   check("reopen-suppresses-default-new-window-\\(attempt)",!handled)
   let close=window.standardWindowButton(.closeButton)!
   print("close-state",attempt,"enabled",close.isEnabled,"action",String(describing:close.action),"delegate",String(describing:window.delegate))
   close.performClick(nil);await settle()
   check("close-hides-retains-window-\\(attempt)",!window.isVisible && HarborWindowController.shared.mainWindow===window)
   NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification,object:NSApp);await settle()
   check("late-activation-keeps-closed-\\(attempt)",!window.isVisible)
   _ = delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false);await settle()
   check("reopen-restores-closed-\\(attempt)",window.isVisible)
  }
  window.performClose(nil);await settle();check("keyboard-close-retains-scene",!window.isVisible && HarborWindowController.shared.mainWindow===window)
  HarborWindowController.shared.showMainWindow();await settle()
  NSApp.hide(nil);await settle();HarborWindowController.shared.showMainWindow();await settle()
  check("reopen-unhides-application",!NSApp.isHidden && window.isVisible)
  check("only-original-window-restored",NSApp.windows.filter{$0===window}.count==1)
  window.orderOut(nil)
  exit(failed>0 ? 1:0)
 }
}
'''
fixture=root/'build/WindowLifecycleChecks.swift';fixture.write_text(source)
binary=root/'build/window-lifecycle-checks'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-target','arm64-apple-macos26.0',str(fixture),'-o',str(binary)],check=True)
subprocess.run([str(binary)],check=True,timeout=60)
