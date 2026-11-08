from pathlib import Path
import subprocess
root=Path(__file__).resolve().parent.parent
source=(root/'Sources/Components.swift').read_text().split('struct WindowDragRegion:')[0]
source+='''
@main enum WindowLifecycleChecks {
 static func main(){
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.regular)
  var failed=0
  func check(_ name:String,_ value:Bool){print((value ? "PASS ":"FAIL ")+name);if !value{failed+=1}}
  func settle(){RunLoop.main.run(until:Date().addingTimeInterval(0.25))}
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  window.identifier=NSUserInterfaceItemIdentifier("QA-SwiftUI-scene-identifier")
  window.contentView=NSHostingView(rootView:Text("Window lifecycle QA").background(WindowConfigurator()))
  window.makeKeyAndOrderFront(nil);settle()
  check("attached-window-registered",HarborWindowController.shared.mainWindow===window)
  check("scene-identifier-preserved",window.identifier?.rawValue=="QA-SwiftUI-scene-identifier")
  let delegate=HarborAppDelegate()
  for attempt in 1...3{
   window.miniaturize(nil);settle();check("miniaturized-\\(attempt)",window.isMiniaturized)
   let handled=delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true);settle()
   check("reopen-restores-minimized-\\(attempt)",!window.isMiniaturized && window.isVisible)
   check("reopen-suppresses-default-new-window-\\(attempt)",!handled)
   window.standardWindowButton(.closeButton)!.performClick(nil);settle()
   check("close-hides-retains-window-\\(attempt)",!window.isVisible && HarborWindowController.shared.mainWindow===window)
   NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification,object:NSApp);settle()
   check("late-activation-keeps-closed-\\(attempt)",!window.isVisible)
   _ = delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false);settle()
   check("reopen-restores-closed-\\(attempt)",window.isVisible)
  }
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
