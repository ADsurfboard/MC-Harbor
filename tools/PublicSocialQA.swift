import CryptoKit
import Foundation
import Security

@main struct PublicSocialQA {
 static func main()async throws{
    let file=URL(fileURLWithPath:CommandLine.arguments[1]),data=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
    let base=data["base"] as! String,owner=data["ownerID"] as! String
    guard base=="https://mc-harbor-friends.dinakesidkeiwkkeksos.workers.dev",data["ownerName"] as? String=="Harbor UI QA" else{fatalError("Refusing non-QA identity")}
    let account="mc-harbor-social-"+SHA256.hash(data:Data(base.utf8)).map{String(format:"%02x",$0)}.joined()
    let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"net.morben.shenggan.accounts",kSecAttrAccount as String:account]
    if CommandLine.arguments.contains("--remove-local-test-key"){let status=SecItemDelete(query as CFDictionary);guard status==errSecSuccess || status==errSecItemNotFound else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))};print("Known QA key removed:",status);return}
    var value:CFTypeRef?;var read=query;read[kSecReturnData as String]=true;read[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail
    guard SecItemCopyMatching(read as CFDictionary,&value)==errSecSuccess,let bytes=value as? Data,let token=String(data:bytes,encoding:.utf8) else{fatalError("QA key missing")}
    print("QA key read authorized");fflush(stdout)
    func call(_ path:String,_ secret:String,method:String="GET")async throws->[String:Any]{var request=URLRequest(url:URL(string:base+"/v1/"+path)!);request.httpMethod=method;request.setValue("Bearer "+secret,forHTTPHeaderField:"Authorization");request.setValue("MC-Harbor-QA/1.5.0",forHTTPHeaderField:"User-Agent");let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=20;config.timeoutIntervalForResource=25;let session=URLSession(configuration:config);defer{session.invalidateAndCancel()};let(response,meta)=try await session.data(for:request);guard (meta as? HTTPURLResponse)?.statusCode==200 else{throw NSError(domain:"QA HTTP",code:1)};return try JSONSerialization.jsonObject(with:response) as! [String:Any]}
    let me=(try await call("friends",token))["me"] as? [String:Any]
    guard me?["id"] as? String==owner,me?["name"] as? String==data["ownerName"] as? String,me?["code"] as? String==data["ownerCode"] as? String else{fatalError("Refusing to touch unknown identity")}
    if CommandLine.arguments.contains("--remove"){
        let peerToken=data["token"] as! String
        let peer=(try await call("friends",peerToken))["me"] as? [String:Any]
        guard peer?["id"] as? String==data["id"] as? String,peer?["name"] as? String=="Harbor Friend QA" else{fatalError("Unknown QA peer")}
        _ = try await call("me",peerToken,method:"DELETE");_ = try await call("me",token,method:"DELETE");SecItemDelete(query as CFDictionary);print("Removed both known disposable cloud QA identities and their test key.")
    }else{
        let output=file.deletingLastPathComponent().appendingPathComponent("native-config.json")
        let config:[String:Any]=["url":base,"token":token,"friendID":data["id"]!,"peerToken":data["token"]!,"expectedName":"Harbor UI QA","video":file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("update-1.5-fixture/test-wallpaper.mp4").path]
        try JSONSerialization.data(withJSONObject:config).write(to:output,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path);print("Prepared public native QA configuration without exposing keys.")
    }
 }
}
