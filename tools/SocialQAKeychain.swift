import CryptoKit
import Foundation
import Security

// Only installs credentials created by our disposable loopback fixture.
let file=URL(fileURLWithPath:CommandLine.arguments[1])
let config=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
let url=config["url"] as! String
guard URL(string:url)?.host=="127.0.0.1",file.path.contains("/evidence/friends-multi-qa/") else{fatalError("Refusing non-QA credential")}
let identity=(config["identities"] as! [[String:Any]])[0]
guard identity["name"] as? String=="多好友界面 QA" else{fatalError("Refusing non-QA identity")}
let account="mc-harbor-friends-net.morben.mcharbor.updateqa-"+SHA256.hash(data:Data(url.utf8)).map{String(format:"%02x",$0)}.joined()
let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"net.morben.shenggan.accounts",kSecAttrAccount as String:account]
if CommandLine.arguments.contains("--remove"){SecItemDelete(query as CFDictionary)}else{
    let data=Data((identity["token"] as! String).utf8)
    let result=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
    if result==errSecItemNotFound{var entry=query;entry[kSecValueData as String]=data;guard SecItemAdd(entry as CFDictionary,nil)==errSecSuccess else{fatalError("QA keychain insert failed")}}
    else if result != errSecSuccess{fatalError("QA keychain update failed")}
}
print("QA credential operation complete; no player credentials accessed.")
