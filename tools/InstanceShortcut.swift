import AppKit
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let info=Bundle.main.infoDictionary ?? [:]
do {
    guard let value=info["HarborURL"] as? String,let url=URL(string:value),url.scheme=="mcharbor",url.host=="launch",let rootPath=info["HarborDataRoot"] as? String else{throw NSError(domain:"MC Harbor",code:1,userInfo:[NSLocalizedDescriptionKey:"请在最新版 MC Harbor 中重新创建此快捷方式。"])}
    let token=url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"));let root=URL(fileURLWithPath:rootPath,isDirectory:true)
    let targets=(try? JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("instance-shortcuts.json")))) as? [String:Any]
    guard UUID(uuidString:token) != nil,targets?[token] != nil else{throw NSError(domain:"MC Harbor",code:1,userInfo:[NSLocalizedDescriptionKey:"快捷方式数据已移动或失效，请重新创建。"])}
    let stored=(info["HarborApplication"] as? String).map{URL(fileURLWithPath:$0)}
    guard let destination=stored.flatMap({FileManager.default.fileExists(atPath:$0.path) ? $0:nil}) ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier:info["HarborBundleID"] as? String ?? "net.morben.shenggan.launcher") else{throw NSError(domain:"MC Harbor",code:1,userInfo:[NSLocalizedDescriptionKey:"找不到 MC Harbor，请安装后重新创建快捷方式。"])}
    let directory=root.appendingPathComponent("shortcut-inbox");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);guard (try directory.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else{throw NSError(domain:"MC Harbor",code:1,userInfo:[NSLocalizedDescriptionKey:"快捷方式目录无效。"])}
    let file=directory.appendingPathComponent(UUID().uuidString+".json");try JSONSerialization.data(withJSONObject:["url":value,"created":Date().timeIntervalSince1970]).write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    let config=NSWorkspace.OpenConfiguration();config.activates=true
    NSWorkspace.shared.openApplication(at:destination,configuration:config){_,error in DispatchQueue.main.async{if let error{try? FileManager.default.removeItem(at:file);let alert=NSAlert(error:error);alert.runModal()};app.terminate(nil)}}
    app.run()
}catch{let alert=NSAlert(error:error);alert.runModal()}
