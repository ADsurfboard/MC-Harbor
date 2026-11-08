from pathlib import Path
import subprocess
root=Path(__file__).resolve().parent.parent
source=(root/'Sources/Components.swift').read_text().split('struct WindowDragRegion:')[0]
source+='''
final class QAWindowDelegate:NSObject,NSWindowDelegate{var resizes=0;func windowDidResize(_ notification:Notification){resizes+=1}}
@main enum WindowLifecycleChecks {
 static func main(){
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.regular)
  NSApp.finishLaunching()
  var failed=0
  func check(_ name:String,_ value:Bool){print((value ? "PASS ":"FAIL ")+name);if !value{failed+=1}}
  func settle(){let end=Date().addingTimeInterval(0.3);while Date()<end{RunLoop.main.run(until:min(end,Date().addingTimeInterval(0.03)))}}
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  window.identifier=NSUserInterfaceItemIdentifier("QA-SwiftUI-scene-identifier")
  window.contentView=NSHostingView(rootView:Text("Window lifecycle QA").background(WindowConfigurator()))
  window.makeKeyAndOrderFront(nil);settle()
  check("attached-window-registered",HarborWindowController.shared.mainWindow===window)
  check("scene-identifier-preserved",window.identifier?.rawValue=="QA-SwiftUI-scene-identifier")
  check("close-delegate-registered",window.delegate is HarborCloseDelegate)
  let original=QAWindowDelegate();window.delegate=original;HarborWindowController.shared.register(window)
  window.setContentSize(NSSize(width:1080,height:720));settle()
  check("original-delegate-resize-forwarded",original.resizes>0)
  let delegate=HarborAppDelegate()
  for attempt in 1...3{
   window.miniaturize(nil);settle();check("miniaturized-\\(attempt)",window.isMiniaturized)
   let handled=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true);settle()
   check("reopen-restores-minimized-\\(attempt)",!window.isMiniaturized && window.isVisible)
   check("reopen-suppresses-default-new-window-\\(attempt)",!handled)
   let close=window.standardWindowButton(.closeButton)!
   print("close-state",attempt,"enabled",close.isEnabled,"action",String(describing:close.action),"delegate",String(describing:window.delegate))
   close.performClick(nil);settle()
   check("close-hides-retains-window-\\(attempt)",!window.isVisible && HarborWindowController.shared.mainWindow===window)
   NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification,object:NSApp);settle()
   check("late-activation-keeps-closed-\\(attempt)",!window.isVisible)
   _ = delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false);settle()
   check("reopen-restores-closed-\\(attempt)",window.isVisible)
  }
  window.performClose(nil);settle();check("keyboard-close-retains-scene",!window.isVisible && HarborWindowController.shared.mainWindow===window)
  HarborWindowController.shared.showMainWindow();settle()
  NSApp.hide(nil);settle();HarborWindowController.shared.showMainWindow();settle()
  check("reopen-unhides-application",!NSApp.isHidden && window.isVisible)
  check("only-original-window-restored",NSApp.windows.filter{$0===window}.count==1)
  window.orderOut(nil)
  if failed>0{exit(1)}
 }
}
'''
fixture=root/'build/WindowLifecycleChecks.swift';fixture.write_text(source)
binary=root/'build/window-lifecycle-checks'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-target','x86_64-apple-macos12.0',str(fixture),'-o',str(binary)],check=True)
subprocess.run([str(binary)],check=True,timeout=60)
