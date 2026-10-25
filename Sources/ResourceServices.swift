import Foundation

enum AddonSource:String,CaseIterable,Identifiable {case modrinth,curseforge;var id:String{rawValue};var title:String{self == .modrinth ? "Modrinth":"CurseForge"}}
private final class QueryProcess:@unchecked Sendable {
    let lock=NSLock();var process:Process?;var continuation:CheckedContinuation<[String:Any],Error>?;var finished=false;var cancelled=false
    func register(_ continuation:CheckedContinuation<[String:Any],Error>){lock.lock();self.continuation=continuation;let cancel=cancelled;lock.unlock();if cancel{resolve(.failure(CancellationError()))}}
    func set(_ process:Process){lock.lock();self.process=process;let cancel=cancelled;lock.unlock();if cancel{process.terminate()}}
    func resolve(_ result:Result<[String:Any],Error>){lock.lock();guard !finished,let continuation else{lock.unlock();return};finished=true;lock.unlock();continuation.resume(with:result)}
    func cancel(){lock.lock();cancelled=true;let process=process;lock.unlock();process?.terminate();resolve(.failure(CancellationError()))}
}
enum BackendQuery {
    static func run(_ input:[String:Any],event:@escaping([String:Any])->Void={_ in})async throws->[String:Any]{
        let state=QueryProcess();return try await withTaskCancellationHandler{try await withCheckedThrowingContinuation{continuation in state.register(continuation);do{try Task.checkCancellation();let process=try JavaBridge.start(input:input,event:event,completion:{state.resolve($0)});state.set(process)}catch{state.resolve(.failure(error))}}}onCancel:{state.cancel()}
    }
}
enum ResourceService {
    private struct VersionResponse:Decodable{let versions:[AddonVersion]}
    static func decode<T:Decodable>(_ object:[String:Any])throws->T{let decoder=JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase;return try decoder.decode(T.self,from:JSONSerialization.data(withJSONObject:object))}
    static func input(_ command:String,game:GameInstance,kind:ContentKind)->[String:Any]{["command":command,"root":URL(fileURLWithPath:game.directory).deletingLastPathComponent().deletingLastPathComponent().path,"version":game.version,"loader":game.loader,"kind":kind.projectType,"source":"auto"]}
    static func search(_ query:String,game:GameInstance,kind:ContentKind,source:AddonSource,page:Int=0)async throws->AddonSearch{
        if source == .modrinth{return try await AddonService.search(query,game:game,kind:kind,offset:page*30)}
        var request=input("cfSearch",game:game,kind:kind);request["query"]=query;request["page"]=page;return try decode(await BackendQuery.run(request))
    }
    static func versions(_ project:String,game:GameInstance,kind:ContentKind,source:AddonSource)async throws->[AddonVersion]{
        if source == .modrinth{return try await AddonService.versions(project,game:game,kind:kind)}
        var request=input("cfVersions",game:game,kind:kind);request["project"]=project;let result:VersionResponse=try decode(await BackendQuery.run(request));return result.versions
    }
    static func plan(_ version:AddonVersion,game:GameInstance,kind:ContentKind,source:AddonSource)async throws->[AddonPlanItem]{
        if source == .modrinth{return try await AddonService.plan(version,game:game,kind:kind)}
        var request=input("cfPlan",game:game,kind:kind);request["project"]=version.projectId;request["file"]=version.id;let result:VersionResponse=try decode(await BackendQuery.run(request));return try result.versions.map{version in guard let file=version.files.first,!file.filename.contains("/"),!file.filename.contains("\\"),!file.filename.hasPrefix("."),["jar","zip","mrpack"].contains(URL(fileURLWithPath:file.filename).pathExtension.lowercased()),file.size>0,file.size<2_000_000_000 else{throw FileTransactions.error("资源文件名或大小无效。")};return AddonPlanItem(version:version,file:file)}
    }
}
