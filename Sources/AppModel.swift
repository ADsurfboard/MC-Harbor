import AppKit
import SwiftUI
import Combine
import Security
import UniformTypeIdentifiers

@MainActor final class LauncherModel: ObservableObject {
    @Published var preferences: NativePreferences { didSet { persist() } }
    @Published var section: NativeSection = .library
    @Published var games: [GameInstance] = []
    @Published var remote: [RemoteGame] = []
    @Published var accounts: [LauncherAccount] = []
    @Published var skinProfiles:[String:SkinProfile]=[:]
    @Published var skinLoading:Set<String>=[]
    @Published var skinErrors:[String:String]=[:]
    @Published var search = ""
    @Published var downloadCategory="minecraft"
    @Published var works: [WorkItem] = []
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    @Published var inspectedGame: GameInstance?
    @Published var modal: HarborModal?
    @Published var modMetadata: [String:[ModFile]] = [:]
    @Published var resourceRecords:[String:InstanceResourceRecord]=[:]
    @Published var resourceIndexing:Set<String>=[]
    @Published var resourceLookupStatus:[String:String]=[:]
    var resourceIndexed:Set<String>=[]
    let contentChanged=PassthroughSubject<Void,Never>()
    @Published var editingContent=false
    var nativeTasks:[UUID:Task<Void,Never>]=[:]
    @Published var migrating=false
    @Published var migrationStatus=""
    @Published var cachedCatalog = false
    @Published var loadingCatalog = false
    @Published var deviceCode: String?
    @Published var verificationURL: String?
    @Published var showIntro = true
    @Published var running: Set<String> = []
    @Published var logLines: [String] = []
    private var processes: [UUID:Process] = [:]
    private var preferenceWork:DispatchWorkItem?
    private let preferenceQueue=DispatchQueue(label:"net.morben.mcharbor.preferences")
    private var toastTask: Task<Void,Never>?
    var selected: GameInstance? { games.first{$0.id==preferences.selectedGame} ?? games.first }
    var selectedAccount: LauncherAccount? { accounts.first{$0.id==preferences.selectedAccount} ?? accounts.first }
    var appearance: HarborAppearance { preferences.appearance }
    var themeColor: Color { Color(hexString:preferences.themeHex) }
    var surfaceClarity:Double{max(0,min(1,(preferences.glassClarity+1)/2))}
    func displayName(_ game:GameInstance)->String { let alias=(preferences.nickname[game.id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines);return alias.isEmpty ? game.id:alias }
    var filteredGames: [GameInstance] { games.filter{search.isEmpty || ($0.id+" "+$0.version+" "+$0.loader).localizedCaseInsensitiveContains(search)}.sorted { a,b in let af=preferences.favorites.contains(a.id),bf=preferences.favorites.contains(b.id);if af != bf{return af};return a.modified > b.modified } }
    init() {
        NativePaths.prepare()
        let defaults = (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(NativePreferences()))) as? [String:Any] ?? [:]
        let stored = (try? JSONSerialization.jsonObject(with:Data(contentsOf:NativePaths.root.appendingPathComponent("preferences.json")))) as? [String:Any] ?? [:]
        let merged = defaults.merging(stored){ _,saved in saved }
        preferences = (try? JSONDecoder().decode(NativePreferences.self,from:JSONSerialization.data(withJSONObject:merged))) ?? NativePreferences()
        accounts=(try? JSONDecoder().decode([LauncherAccount].self,from:Data(contentsOf:NativePaths.root.appendingPathComponent("accounts.json")))) ?? []
        for account in accounts{if let profile=SkinStorage.cached(account.id){skinProfiles[account.id]=profile}}
        showIntro=preferences.introEnabled && ProcessInfo.processInfo.environment["SHENGGAN_SKIP_INTRO"] != "1"
        HarborAudio.shared.configure(enabled:preferences.soundsEnabled,volume:preferences.soundVolume)
        scan()
        if let bytes=try? Data(contentsOf:NativePaths.root.appendingPathComponent("migration.json")),let receipt=try? JSONDecoder().decode(MigrationReceipt.self,from:bytes){migrationStatus="已接入 \(receipt.instances) 个游戏 · \(accounts.count) 个账号"}
        else if ProcessInfo.processInfo.environment["SHENGGAN_DATA_DIR"]==nil{Task{migrateHMCL()}}
    }
    func persist() {
        HarborAudio.shared.configure(enabled:preferences.soundsEnabled,volume:preferences.soundVolume)
        preferenceWork?.cancel();guard let data=try? JSONEncoder().encode(preferences) else{return}
        let work=DispatchWorkItem{try? data.write(to:NativePaths.root.appendingPathComponent("preferences.json"),options:.atomic)}
        preferenceWork=work;preferenceQueue.asyncAfter(deadline:.now()+0.22,execute:work)
    }
    func flushPreferences(){preferenceWork?.cancel();guard let data=try? JSONEncoder().encode(preferences) else{return};preferenceQueue.sync{try? data.write(to:NativePaths.root.appendingPathComponent("preferences.json"),options:.atomic)}}

    func scan() { let root=preferences.gameRoot;Task { let scanned=await Task.detached(priority:.userInitiated){NativeScanner.scan(root)}.value;games=scanned } }
    func toast(_ text:String) { toastTask?.cancel();toastMessage=text;toastTask=Task{try? await Task.sleep(for:.seconds(3.2));if !Task.isCancelled{toastMessage=nil}} }
    func open(_ path:String) { guard FileManager.default.fileExists(atPath:path) else{errorMessage="目录尚不存在。";return};NSWorkspace.shared.open(URL(fileURLWithPath:path)) }
    func selectRoot() { let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.prompt="选择游戏库";if panel.runModal() == .OK,let url=panel.url{preferences.gameRoot=url.path;scan()} }
    func favorite(_ game:GameInstance) { if preferences.favorites.contains(game.id){preferences.favorites.remove(game.id)}else{preferences.favorites.insert(game.id)} }
    func selectWallpaper() { let p=NSOpenPanel();p.allowedContentTypes=[.png,.jpeg,.heic,.movie];if p.runModal() == .OK,let url=p.url {preferences.wallpaper.filePath=url.path;preferences.wallpaper.kind=["mp4","mov","m4v"].contains(url.pathExtension.lowercased()) ? .video:.image} }
    func fetchCatalog() async {
        guard !loadingCatalog else{return};loadingCatalog=true;defer{loadingCatalog=false}
        let official="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json",mirror="https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
        let endpoints=preferences.downloadSource=="mirror" ? [mirror,official]:[official,mirror]
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=8;config.timeoutIntervalForResource=15;let session=URLSession(configuration:config);defer{session.invalidateAndCancel()}
        var failures:[String]=[]
        for url in endpoints {
            do {let(data,response)=try await session.data(from:URL(string:url)!);guard (response as? HTTPURLResponse)?.statusCode==200,data.count<8_000_000 else{throw NSError(domain:"下载",code:1,userInfo:[NSLocalizedDescriptionKey:"服务返回无效响应"])};let manifest=try JSONDecoder().decode(VersionManifest.self,from:data);guard !manifest.versions.isEmpty else{throw NSError(domain:"下载",code:2)};remote=manifest.versions;cachedCatalog=false;try? data.write(to:NativePaths.root.appendingPathComponent("versions-cache.json"),options:.atomic);return}
            catch {failures.append(error.localizedDescription)}
        }
        if let data=try? Data(contentsOf:NativePaths.root.appendingPathComponent("versions-cache.json")),let manifest=try? JSONDecoder().decode(VersionManifest.self,from:data) {remote=manifest.versions;cachedCatalog=true}
        else{errorMessage="版本列表暂不可用。\n"+failures.joined(separator:"\n")}
    }
    func install(_ version:RemoteGame,name:String,loader:String,loaderVersion:String) {
        guard !name.isEmpty,!name.contains("/"),!name.contains("\\"),name != ".",name != ".." else{errorMessage="请输入有效的版本名称。";return}
        if games.contains(where:{$0.id==name}){errorMessage="该版本名称已存在。";return}
        backend("install",title:"安装 "+name,arguments:["version":version.id,"name":name,"loader":loader,"loaderVersion":loaderVersion]){_ in self.scan();self.preferences.selectedGame=name;self.toast("安装完成")}
    }
    func launch(_ game:GameInstance) {
        guard !running.contains(game.id) else{return}
        guard let account=selectedAccount else{inspectedGame=nil;section = .accounts;return}
        var args:[String:Any]=["id":game.id,"runDirectory":game.runDirectory,"memory":preferences.memory,"gameJava":preferences.javaPath,"accountType":account.kind,"username":account.name,"uuid":account.uuid,"accountID":account.id,"javaExplicit":false,"completeDependencies":preferences.completeDependencies,"loader":game.loader,"version":game.version]
        let options=preferences.instanceOptions[game.id]
        let original=NativeScanner.readJSON(URL(fileURLWithPath:game.directory).appendingPathComponent(".hmcl/config/instance-game-settings.json"))
        if let originalMemory=original["maxMemory"] as? Int,(original["overrideProperties"] as? [String] ?? []).contains("maxMemory"){args["memory"]=originalMemory}
        if let options {if options.memory>0{args["memory"]=options.memory};if !options.javaPath.isEmpty{args["gameJava"]=options.javaPath;args["javaExplicit"]=true};args["jvmArguments"]=options.jvmArguments;args["fullscreen"]=options.fullscreen;args["width"]=options.width;args["height"]=options.height}
        HarborAudio.shared.play(.launch)
        if let privateJSON=KeychainStore.read(account.id),let obj=try? JSONSerialization.jsonObject(with:privateJSON){args["account"]=obj}
        running.insert(game.id)
        backend("launch",title:"启动 "+game.id,arguments:args){_ in self.running.remove(game.id)}
    }
    func repair(_ game:GameInstance) { backend("repair",title:"校验 "+game.id,arguments:["id":game.id,"runDirectory":game.runDirectory]){_ in self.toast("校验完成") } }
    func importPack() { let p=NSOpenPanel();p.allowedContentTypes=[.zip,UTType(filenameExtension:"mrpack") ?? .data];if p.runModal() == .OK,let url=p.url {backend("import",title:"导入整合包",arguments:["file":url.path,"name":url.deletingPathExtension().lastPathComponent]){_ in self.scan();self.toast("整合包已导入")}} }
    func backup(_ game:GameInstance) { backend("backup",title:"备份 "+game.id,arguments:["runDirectory":game.runDirectory]){result in self.toast("存档备份完成");if let path=result["path"] as? String{NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])}} }
    func diagnostics() { backend("diagnostics",title:"检查下载连接",arguments:[:]){result in self.toast("诊断完成");if let report=result["report"] as? String{self.logLines.append(report)}} }
    func addOffline(_ name:String) { guard name.range(of:"^[A-Za-z0-9_]{3,16}$",options:.regularExpression) != nil else{errorMessage="用户名需为 3—16 位英文字母、数字或下划线。";return};let account=LauncherAccount(id:UUID().uuidString,name:name,kind:"offline",uuid:"");accounts.append(account);preferences.selectedAccount=account.id;saveAccounts() }
    func loginMicrosoft() {
        backend("login",title:"Microsoft 登录",arguments:[:]) { result in
            guard let metadata=result["metadata"] as? [String:Any],let name=metadata["name"] as? String,let uuid=metadata["uuid"] as? String else{return}
            let existing=self.accounts.first{$0.kind=="microsoft" && $0.uuid.replacingOccurrences(of:"-",with:"").lowercased()==uuid.replacingOccurrences(of:"-",with:"").lowercased()}
            let id=existing?.id ?? UUID().uuidString
            do {
                try KeychainStore.write(try JSONSerialization.data(withJSONObject:result),id:id)
                let account=LauncherAccount(id:id,name:name,kind:"microsoft",uuid:uuid)
                if let index=self.accounts.firstIndex(where:{$0.id==id}){self.accounts[index]=account}else{self.accounts.append(account)}
                self.preferences.selectedAccount=id;self.saveAccounts();self.deviceCode=nil;self.loadSkin(account,refresh:true);self.toast("登录成功")
            }catch{self.errorMessage=error.localizedDescription}
        }
    }

    func removeAccount(_ account:LauncherAccount) { accounts.removeAll{$0.id==account.id};KeychainStore.remove(account.id);saveAccounts() }
    func saveAccounts() { if let data=try? JSONEncoder().encode(accounts){try? data.write(to:NativePaths.root.appendingPathComponent("accounts.json"),options:.atomic)} }
    func backend(_ command:String,title:String,arguments:[String:Any],silent:Bool=false,done:@escaping([String:Any])->Void) {
        let job=WorkItem(title:title);if !silent { works.insert(job,at:0) }
        var input=arguments;input["command"]=command;input["root"]=preferences.gameRoot;input["source"]=preferences.downloadSource;input["threads"]=preferences.downloadThreads;input["clientID"]=preferences.microsoftClientID
        do {
            let process=try JavaBridge.start(input:input,event:{[weak self] event in Task{@MainActor in guard let self else{return};if let updated=event["data"],event["event"] as? String=="accountUpdated",let id=arguments["accountID"] as? String,let bytes=try? JSONSerialization.data(withJSONObject:updated){try? KeychainStore.write(bytes,id:id)}
                if !silent,let message=event["message"] as? String{if self.logLines.count>400{self.logLines.removeFirst(100)};self.logLines.append(message);if let i=self.works.firstIndex(where:{$0.id==job.id}){self.works[i].detail=message}}
                if let value=event["progress"] as? Double,let i=self.works.firstIndex(where:{$0.id==job.id}){self.works[i].progress=value}
                if let code=event["deviceCode"] as? String{self.deviceCode=code;self.verificationURL=event["url"] as? String}
                if event["event"] as? String == "launched",let id=arguments["id"] as? String{self.running.insert(id);if let i=self.works.firstIndex(where:{$0.id==job.id}){self.works[i].active=false};self.toast("游戏已启动")}
            }},completion:{[weak self] result in Task{@MainActor in guard let self else{return};self.processes.removeValue(forKey:job.id);if command=="migrate"{self.migrating=false};if let i=self.works.firstIndex(where:{$0.id==job.id}){self.works[i].active=false;switch result{case .success:self.works[i].progress=1;case .failure:self.works[i].error=true}}
                switch result{case .success(let object):done(object);case .failure(let error):self.errorMessage=error.localizedDescription;if let id=arguments["id"] as? String{self.running.remove(id)}}
            }})
            processes[job.id]=process
        }catch{if command=="migrate"{migrating=false};if let id=arguments["id"] as? String,command=="launch"{running.remove(id)};if let index=works.firstIndex(where:{$0.id==job.id}){works[index].active=false;works[index].error=true};errorMessage=error.localizedDescription}
    }
    func loadMods(_ game:GameInstance,force:Bool=false) {
        if modMetadata[game.id] != nil && !force{return}
        backend("mods",title:"读取模组",arguments:["id":game.id,"runDirectory":game.runDirectory],silent:true){result in
            self.modMetadata[game.id]=(result["mods"] as? [[String:Any]] ?? []).compactMap{m in guard let path=m["path"] as? String else{return nil};return ModFile(id:path.replacingOccurrences(of:".disabled",with:""),name:m["name"] as? String ?? URL(fileURLWithPath:path).lastPathComponent,path:URL(fileURLWithPath:path),enabled:m["enabled"] as? Bool ?? true,size:(m["size"] as? NSNumber)?.int64Value ?? 0,version:m["version"] as? String ?? "",authors:m["authors"] as? String ?? "",modID:m["modId"] as? String ?? "",iconPath:m["iconPath"] as? String)}
        }
    }
    func cancel(_ work:WorkItem) { processes[work.id]?.terminate();nativeTasks[work.id]?.cancel() }
}

enum KeychainStore {
    static let service="net.morben.shenggan.accounts"
    static func write(_ data:Data,id:String)throws {let query=[kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:id] as CFDictionary;let update=SecItemUpdate(query,[kSecValueData:data] as CFDictionary);if update==errSecSuccess{return};guard update==errSecItemNotFound else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(update))};let result=SecItemAdd([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:id,kSecValueData:data,kSecAttrAccessible:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary,nil);guard result==errSecSuccess else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(result))}}
    static func read(_ id:String)->Data? {var value:CFTypeRef?;let result=SecItemCopyMatching([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:id,kSecReturnData:true,kSecMatchLimit:kSecMatchLimitOne] as CFDictionary,&value);return result==errSecSuccess ? value as? Data:nil}
    static func remove(_ id:String){SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:id] as CFDictionary)}
}

enum JavaBridge {
    static func start(input:[String:Any],event:@escaping([String:Any])->Void,completion:@escaping(Result<[String:Any],Error>)->Void)throws->Process {
        let bundled=NativePaths.resources.appendingPathComponent("Runtime/bin/java").path
        let java=FileManager.default.isExecutableFile(atPath:bundled) ? bundled:"/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home/bin/java"
        guard FileManager.default.isExecutableFile(atPath:java) else{throw NSError(domain:"Java",code:1,userInfo:[NSLocalizedDescriptionKey:"未找到 Java 21。请在设置中选择运行时。"])}
        let resources=NativePaths.resources
        let process=Process();process.executableURL=URL(fileURLWithPath:java)
        let fx=resources.appendingPathComponent("javafx").path+"/*"
        process.arguments=["-Xms32m","-Xmx384m","-Dfile.encoding=UTF-8","-Djava.awt.headless=true","-Dshenggan.headless=true","-Dhmcl.dir="+NativePaths.root.path,"-cp",resources.appendingPathComponent("Backend.jar").path+":"+resources.appendingPathComponent("HMCLCore.jar").path+":"+fx,"net.morben.shenggan.NativeBridge"]
        let stdin=Pipe(),stdout=Pipe(),stderr=Pipe();process.standardInput=stdin;process.standardOutput=stdout;process.standardError=stderr
        let reader=BridgeReader(event:event,completion:completion)
        try process.run()
        DispatchQueue.global(qos:.userInitiated).async { while true {let data=stdout.fileHandleForReading.availableData;if data.isEmpty{break};reader.receive(data)};process.waitUntilExit();reader.finish(process.terminationStatus) }
        stderr.fileHandleForReading.readabilityHandler={handle in _=handle.availableData}
        process.terminationHandler={_ in stderr.fileHandleForReading.readabilityHandler=nil}
        let data=try JSONSerialization.data(withJSONObject:input);try stdin.fileHandleForWriting.write(contentsOf:data+Data([10]));try? stdin.fileHandleForWriting.close();return process
    }
}
final class BridgeReader: @unchecked Sendable {
    private var buffer=Data();private var result:[String:Any]?;private var failure:String?;private let lock=NSLock()
    private let event:([String:Any])->Void;private let completion:(Result<[String:Any],Error>)->Void
    init(event:@escaping([String:Any])->Void,completion:@escaping(Result<[String:Any],Error>)->Void){self.event=event;self.completion=completion}
    func receive(_ data:Data){lock.lock();defer{lock.unlock()};buffer.append(data);while let index=buffer.firstIndex(of:10){let line=buffer[..<index];buffer.removeSubrange(...index);guard let object=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any] else{continue};if object["event"] as? String=="result"{result=object["data"] as? [String:Any] ?? [:]}else if object["event"] as? String=="error"{failure=object["message"] as? String}else{event(object)}}}
    func finish(_ code:Int32){lock.lock();let value=result;let error=failure;lock.unlock();if code==0,let value{completion(.success(value))}else{completion(.failure(NSError(domain:"MC Harbor",code:Int(code),userInfo:[NSLocalizedDescriptionKey:error ?? "后台任务未完成。请查看下载记录。"])))}}
}
