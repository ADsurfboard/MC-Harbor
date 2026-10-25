import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Translation

// Visual components alone are omitted from this command-line harness.
struct WorldIcon:View{let game:GameInstance;var body:some View{EmptyView()}}
struct ShengganMark:View{var body:some View{EmptyView()}}
struct FluidField:View{let dark:Bool;let color:Color;let active:Bool;var body:some View{EmptyView()}}

@main struct UpdateChecks {
    @MainActor static func main()async throws {
        _ = NSApplication.shared
        let config=NativeScanner.readJSON(URL(fileURLWithPath:CommandLine.arguments[1]))
        let root=URL(fileURLWithPath:CommandLine.arguments[2]);setenv("SHENGGAN_DATA_DIR",root.path,1);NativePaths.prepare()
        let assets=URL(fileURLWithPath:CommandLine.arguments[3])
        if config["multi"] as? Bool==true{try await multi(config,root:root);return}
        if config["terracotta"] as? Bool==true{try await terracotta(root);return}
        var checks:[String:Bool]=[:];var notes:[String:Any]=[:]
        func check(_ name:String,_ value:Bool){checks[name]=value;print((value ? "PASS ":"FAIL ")+name)}
        func wait(_ social:HarborSocial)async throws{for _ in 0..<500{if !social.busy{return};try await Task.sleep(for:.milliseconds(20))};throw FileTransactions.error("Social operation timed out")}
        func perform(_ name:String,_ action:()async throws->Void)async{do{try await action()}catch{check(name,false);notes[name]=error.localizedDescription}}
        let policies=(0...100).map{HarborSurfacePolicy(clarity:Double($0)/100,frosted:false)}
        check("glass-monotonic-diffusion",zip(policies,policies.dropFirst()).allSatisfy{$0.diffusion >= $1.diffusion && $0.liquid <= $1.liquid})
        check("glass-negative-clamped",HarborSurfacePolicy(clarity:-1,frosted:false).clarity==0)
        check("frost-independent-of-clarity",[0.0,0.5,1.0].allSatisfy{let p=HarborSurfacePolicy(clarity:$0,frosted:true);return p.diffusion==1 && p.liquid==0})
        check("theme-light-ink",HarborAppearance.theme.isLight && !HarborAppearance.dark.isLight)
        check("four-welcome-recordings",WelcomeVoice.allCases.count==4 && WelcomeVoice.allCases.allSatisfy{$0.duration>1.0 && $0.url != nil})
        check("address-default",try MinecraftAddress("play.example.com").string=="play.example.com:25565")
        check("address-IPv6",try MinecraftAddress("[::1]:25566").port==25566)
        for address in ["https://example.com","host:0","host:65536","host\n:80","host:abc","x/y","x@evil","host:"] {check("reject-address-"+address.replacingOccurrences(of:"\n",with:"newline"),(try? MinecraftAddress(address))==nil)}
        let invitation=HarborInvitation(transport:"address",target:"127.0.0.1:25565",instance:"",version:"1.20.1",loader:"Forge")
        check("valid-invitation",(try? invitation.validate()) != nil)
        check("invalid-invitation-protocol",(try? HarborInvitation(transport:"javascript",target:"alert(1)",instance:"",version:"",loader:"").validate())==nil)
        let original=assets.appendingPathComponent("Skins/wide/steve.png")
        await perform("wallpaper-flow") {
            let image=try await WallpaperLibrary.copy(original);check("wallpaper-import-copies",image.owned && image.path != original.path && FileManager.default.fileExists(atPath:image.path))
            check("wallpaper-original-bytes",try Data(contentsOf:original)==Data(contentsOf:URL(fileURLWithPath:image.path)))
            check("wallpaper-image-preview",await WallpaperThumbnails.image(image) != nil)
            let library=WallpaperLibrary(current:WallpaperSettings());library.items=[image];try library.save();library.rename(image,to:"草地 · 测试壁纸")
            let restored=WallpaperLibrary(current:WallpaperSettings());check("wallpaper-name-persists",restored.items.first?.name=="草地 · 测试壁纸");restored.remove(image);check("wallpaper-remove-preserves-original",FileManager.default.fileExists(atPath:original.path) && !FileManager.default.fileExists(atPath:image.path))
            let video=try await WallpaperLibrary.copy(URL(fileURLWithPath:config["video"] as! String));check("wallpaper-video-detection",video.kind == .video);check("wallpaper-video-preview",await WallpaperThumbnails.image(video) != nil);library.items=[video];try library.save();library.remove(video)
            var setting=WallpaperSettings();setting.kind = .image;setting.filePath=original.path;let old=WallpaperLibrary(current:setting);check("wallpaper-migrates-legacy-reference",old.items.contains{$0.path==original.path && !$0.owned});if let item=old.items.first{old.remove(item)};check("legacy-remove-preserves-original",FileManager.default.fileExists(atPath:original.path))
        }
        await perform("disk-space-flow") {
            let folder=root.appendingPathComponent("game/versions/Test");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let data=Data(repeating:42,count:8192),a=folder.appendingPathComponent("a.bin");try data.write(to:a);try FileManager.default.linkItem(at:a,to:folder.appendingPathComponent("hardlink.bin"));try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("escape"),withDestinationURL:assets)
            let game=GameInstance(id:"Test",version:"1.20.1",loader:"Forge",directory:folder.path,runDirectory:folder.path,iconPath:nil,modified:Date());let footprint=try DiskFootprint.measure(game)
            check("disk-hardlink-counted-once",footprint.files==1 && footprint.logical==8192);check("disk-real-allocation",footprint.allocated>0);check("disk-symlink-not-followed",footprint.files==1)
        }
        let formatted="§aWelcome %1$s, collect %2$d {item:minecraft:stone}.\nOpen [[quest:123]] ${name} https://example.org/a"
        let parts=TranslationText.parts(formatted);let originalValues=Dictionary(parts.filter(\.translate).map{($0.text,$0.text)},uniquingKeysWith:{first,_ in first})
        check("translation-lossless-tokenization",try TranslationText.restore(parts,values:originalValues)==formatted)
        let long=String(repeating:"Collect one stone and open the quest book. ",count:100);let longParts=TranslationText.parts(long)
        check("translation-long-paragraph-chunks",longParts.filter(\.translate).allSatisfy{$0.text.count<=1200})
        check("translation-long-spacing",try TranslationText.restore(longParts,values:Dictionary(longParts.filter(\.translate).map{($0.text,$0.text)},uniquingKeysWith:{first,_ in first}))==long)
        await perform("real-on-device-translation") {
            let availability=await LanguageAvailability().status(from:LocalLanguageTranslation.source,to:LocalLanguageTranslation.target)
            notes["systemModelStatus"]=String(describing:availability)
            guard availability == .installed else{notes["translationSkipped"]="System language model is not installed; the visible app prepares it on first use.";return}
            let session=TranslationSession(installedSource:LocalLanguageTranslation.source,target:LocalLanguageTranslation.target)
            let rows=[PendingLanguageEntry(resource:"fixture",id:"simple",source:"Reload Shaders"),PendingLanguageEntry(resource:"fixture",id:"format",source:formatted),PendingLanguageEntry(resource:"fixture",id:"long",source:long)]
            let translations=try await LocalLanguageTranslation.translate(rows,session:session)
            check("real-Chinese-output",translations[0]["translation"]?.range(of:"[\\p{Han}]",options:.regularExpression) != nil)
            let value=translations[1]["translation"] ?? "";check("real-placeholder-preservation",["§a","%1$s","%2$d","{item:minecraft:stone}","\n","[[quest:123]]","${name}","https://example.org/a"].allSatisfy{value.contains($0)})
            check("real-long-quest-translated",(translations[2]["translation"] ?? "").range(of:"[\\p{Han}]",options:.regularExpression) != nil)
            notes["onDeviceSample"]=translations[0]["translation"]
        }
        await perform("live-LittleSkin") {
            let (entries,pages)=try await LittleSkinService.search("",page:1,sort:"likes");check("LittleSkin-live-list",!entries.isEmpty && pages>0)
            let entry=LittleSkinEntry(id:916947,name:"Public fixture",author:"LittleSkin",type:"alex",hd:false);let file=try await LittleSkinService.skin(entry);try SkinStorage.validate(file);check("LittleSkin-real-standard-skin",FileManager.default.fileExists(atPath:file.path));check("LittleSkin-cached-idempotent",try await LittleSkinService.skin(entry)==file)
            try LittleSkinService.save([entry]);check("LittleSkin-favorites-persist",LittleSkinService.favorites()==[entry])
        }
        await perform("live-Sakura-client") {
            let(binary,version)=try await SakuraBinary.obtain();let process=Process(),output=Pipe();process.executableURL=binary;process.arguments=["--version"];process.standardOutput=output;process.standardError=output;try process.run();let text=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);process.waitUntilExit();check("Sakura-official-client-verified",process.terminationStatus==0 && text.contains(version));notes["frpcVersion"]=text.trimmingCharacters(in:.whitespacesAndNewlines)
            check("Sakura-public-node-flag",SakuraNode(id:1,name:"游戏",host:"example.org",flag:2052).available && SakuraNode(id:1,name:"游戏",host:"example.org",flag:2052).publicGames)
            check("Sakura-offline-filter",!SakuraNode(id:2,name:"多线",host:"example.org",flag:516).available)
        }
        await perform("social-native-client") {
            let social=HarborSocial(),url=config["url"] as! String,token=config["token"] as! String,id=config["friendID"] as! String;let credential=HarborSocial.credentialID(url);let savedCredential=KeychainStore.read(credential);defer{if let savedCredential{try? KeychainStore.write(savedCredential,id:credential)}else{KeychainStore.remove(credential)}};try social.configure(url);social.restore(token);do{try social.configure("https://other.example.com");check("social-busy-origin-change-refused",false)}catch{check("social-busy-origin-change-refused",true)};try await wait(social)
            notes["socialStatus"]=social.status;check("social-native-login",social.me?.name==(config["expectedName"] as? String ?? "ClientQA"))
            check("social-native-mutual-list",social.friends.contains{$0.id==id})
            if let friend=social.friends.first(where:{$0.id==id}){social.history(friend);try await wait(social);check("social-native-friend-history",social.remoteSessions[id]?.first?.world=="TestWorld");check("social-native-friend-skin",social.skinPaths[id] != nil);social.remoteSessions[id]=nil;social.refresh(friend:friend);try await wait(social);check("social-refreshes-selected-friend",social.remoteSessions[id]?.first?.world=="TestWorld")}
            if let friend=social.friends.first(where:{$0.id==id}){await social.chat.refresh(id);try await social.chat.send("Native chat\n你好",to:friend);check("social-native-chat-send",social.chat.messages[id]?.last?.text=="Native chat\n你好");await social.chat.refresh(id);check("social-native-chat-refresh",social.chat.messages[id]?.last?.sender==social.me?.id);let invitation=HarborInvitation(transport:"address",target:"127.0.0.1:25565",instance:"QA Pack",version:"1.20.1",loader:"Forge");try await social.chat.send("一起游玩",to:friend,invite:invitation);check("social-native-invitation",social.chat.messages[id]?.last?.invite==invitation);if url.hasPrefix("https:"){for _ in 0..<100{if social.chat.live{break};try await Task.sleep(for:.milliseconds(100))};check("social-native-live-websocket",social.chat.live)};social.chat.disconnect()}
            if url.hasPrefix("https:"),let peerToken=config["peerToken"] as? String,let me=social.me {
                social.chat.connect();for _ in 0..<100{if social.chat.live{break};try await Task.sleep(for:.milliseconds(100))};social.chat.selected=""
                _ = try await HarborHTTP.json(URL(string:url+"/v1/messages/"+me.id)!,method:"POST",body:["id":UUID().uuidString,"kind":"text","text":"Public native WebSocket delivery QA"],token:peerToken)
                for _ in 0..<100{if social.chat.unread.contains(id){break};try await Task.sleep(for:.milliseconds(100))}
                check("native-public-push-unread",social.chat.live && social.chat.unread.contains(id));social.chat.disconnect();social.chat.connect();await social.chat.refreshInbox();check("native-offline-inbox-restored",social.chat.unread.contains(id));social.chat.disconnect()
            }
            social.note("本机备注",for:id);let other=HarborSocial();check("social-note-persists",other.notes[id]=="本机备注")
            let game=GameInstance(id:"play",version:"1.20.1",loader:"Forge",directory:root.path,runDirectory:root.path,iconPath:nil,modified:Date());social.launchFriends=[id];let playID=UUID().uuidString;social.begin(game,name:"真实启动事件夹具",id:playID);try await Task.sleep(for:.milliseconds(80));social.finish(game.id);check("social-local-duration",(social.sessions.first?.seconds ?? 0)>0 && social.sessions.first?.active==false);check("social-selected-companions",social.sessions.first?.friends==[id]);let record=HarborSocial();check("social-history-persists",record.sessions.first?.id==playID)
            let receipts=root.appendingPathComponent("social/receipts");try FileManager.default.createDirectory(at:receipts,withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:["id":playID,"seconds":3600.0,"finished":true,"world":"AfterWindowClosed","pid":0]).write(to:receipts.appendingPathComponent(playID+".json"));record.refreshLocal();check("engine-receipt-recovers-duration",record.sessions.first?.seconds==3600 && record.sessions.first?.world=="AfterWindowClosed")
        }
        let report:[String:Any]=["passed":checks.values.filter{$0}.count,"failed":checks.values.filter{!$0}.count,"checks":checks,"notes":notes,"externalSakuraTunnelCreated":false,"realAccountSkinChanged":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.deletingLastPathComponent().appendingPathComponent("update-1.5-report.json"));print("Update checks",checks.values.filter{$0}.count,"passed",checks.values.filter{!$0}.count,"failed");if checks.values.contains(false){exit(1)}
    }
    @MainActor static func terracotta(_ root:URL)async throws{
        let connection=TerracottaConnection();connection.host(name:"Harbor Native QA")
        for _ in 0..<1200{if !connection.busy{break};try await Task.sleep(for:.milliseconds(100))}
        for _ in 0..<30{if connection.state=="host-scanning" || connection.state=="exception"{break};try await Task.sleep(for:.milliseconds(100))}
        let started=connection.state=="host-scanning",version=connection.version
        connection.stop(synchronous:true)
        let result:[String:Any]=["nativeHostStarts":started,"nativeStopResets":connection.state=="waiting","officialVersion":version,"status":connection.status,"twoExternalNetworksTested":false]
        try JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:root.deletingLastPathComponent().appendingPathComponent("terracotta-native-report.json"));print(result);if !started{exit(1)}
    }
    @MainActor static func multi(_ config:[String:Any],root:URL)async throws{
        let url=config["url"] as! String,token=config["token"] as! String
        guard URL(string:url)?.host=="127.0.0.1" else{throw FileTransactions.error("Multi fixture must stay local")}
        var checks:[String:Bool]=[:]
        func check(_ name:String,_ value:Bool){checks[name]=value;print((value ? "PASS ":"FAIL ")+name)}
        func wait(_ social:HarborSocial)async throws{for _ in 0..<500{if !social.busy{return};try await Task.sleep(for:.milliseconds(20))};throw FileTransactions.error("Multi operation timed out")}
        let social=HarborSocial(),key=HarborSocial.credentialID(url);let backup=KeychainStore.read(key);defer{social.chat.disconnect();if let backup{try? KeychainStore.write(backup,id:key)}else{KeychainStore.remove(key)}}
        try social.configure(url);social.restore(token);try await wait(social)
        check("24-mutual-friends",social.friends.count==24);check("two-incoming-two-sent",social.requests.count==2 && social.sent.count==2)
        await social.chat.refreshInbox();for _ in 0..<150{if social.chat.unread.count==24{break};try await Task.sleep(for:.milliseconds(20))};check("24-independent-unread-conversations",social.chat.unread.count==24)
        var skins=0,heads=0
        for friend in social.friends{await social.avatar(friend);if !friend.skinHash.isEmpty{skins += 1;if let path=social.skinPaths[friend.id],MinecraftHeads.image(path) != nil{heads += 1}}}
        check("all-shared-skins-have-real-heads",skins>15 && heads==skins)
        check("unshared-skins-use-default",social.friends.filter{$0.skinHash.isEmpty}.allSatisfy{social.skinPaths[$0.id]==nil})
        let people=Array(social.friends.prefix(3));var originals:Set<String>=[]
        for friend in people{await social.chat.refresh(friend.id);if let first=social.chat.messages[friend.id]?.first{originals.insert(first.text);check("sender-is-"+friend.code,first.sender==friend.id)};social.chat.drafts[friend.id]="草稿 · "+friend.code}
        check("messages-never-cross-friends",originals.count==3)
        for friend in people{social.chat.select(friend)}
        check("drafts-survive-switching",people.allSatisfy{social.chat.drafts[$0.id]=="草稿 · "+$0.code})
        if let friend=people.first{social.note(String(repeating:"很长备注",count:30),for:friend.id);let restored=HarborSocial();check("long-note-bounded-and-persistent",restored.notes[friend.id]?.count==80);try await social.chat.send("Only first friend's reply",to:friend);check("reply-only-selected-conversation",social.chat.messages[friend.id]?.last?.text=="Only first friend's reply" && people.dropFirst().allSatisfy{social.chat.messages[$0.id]?.count==1})}
        for friend in people where friend.sharing{social.history(friend);try await wait(social);check("history-and-companions-"+friend.code,(social.remoteSessions[friend.id]?.count ?? 0)==4 && social.remoteSessions[friend.id]?.contains(where:{$0.friends.contains(social.me?.id ?? "")})==true)}
        let activeFriends=Array(social.friends.filter(\.sharing).prefix(3));social.remoteSessions=[:];for friend in activeFriends{social.history(friend)};try await wait(social);check("rapid-switch-loads-final-friend",activeFriends.last.map{social.remoteSessions[$0.id]?.count==4} ?? false)
        if let removed=people.last{social.remove(removed);try await wait(social);check("remove-clears-history-chat-avatar",social.friends.count==23 && social.chat.messages[removed.id]==nil && social.skinPaths[removed.id]==nil && social.remoteSessions[removed.id]==nil && !social.chat.unread.contains(removed.id))}
        let report:[String:Any]=["passed":checks.values.filter{$0}.count,"failed":checks.values.filter{!$0}.count,"checks":checks,"fixtureFriends":24,"environment":"Actual Swift clients over loopback HTTP; synthetic disposable identities"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.deletingLastPathComponent().appendingPathComponent("multi-native-report.json"));if checks.values.contains(false){exit(1)}
    }
}
