import AppKit
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let info=Bundle.main.infoDictionary ?? [:]
if let value=info["HarborURL"] as? String,let url=URL(string:value){
    let stored=(info["HarborApplication"] as? String).map{URL(fileURLWithPath:$0)}
    let destination=stored.flatMap{FileManager.default.fileExists(atPath:$0.path) ? $0:nil} ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier:info["HarborBundleID"] as? String ?? "net.morben.shenggan.launcher")
    if let destination{let config=NSWorkspace.OpenConfiguration();config.activates=true;NSWorkspace.shared.open([url],withApplicationAt:destination,configuration:config){_,error in DispatchQueue.main.async{if let error{let alert=NSAlert(error:error);alert.runModal()};app.terminate(nil)}};app.run()}
    else{let alert=NSAlert();alert.messageText="找不到 MC Harbor";alert.informativeText="请安装 MC Harbor，再重新创建实例快捷方式。";alert.runModal()}
}
