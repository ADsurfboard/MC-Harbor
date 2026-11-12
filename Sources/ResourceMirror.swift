import Foundation

enum ResourceMirror {
    static var source:String{get{UserDefaults.standard.string(forKey:"harbor.resourceSource") ?? "auto"}set{UserDefaults.standard.set(newValue,forKey:"harbor.resourceSource")}}
    static var metadataBases:[String]{source == "official" ? ["https://api.modrinth.com/v2","https://mod.mcimirror.top/modrinth/v2"]:["https://mod.mcimirror.top/modrinth/v2","https://api.modrinth.com/v2"]}
    static func artworkURL(_ value:String)->URL?{guard var url=URLComponents(string:value) else{return nil};if source != "official",["cdn.modrinth.com","media.forgecdn.net","edge.forgecdn.net"].contains(url.host ?? ""){url.host="mod.mcimirror.top"};return url.url}
}

actor MCIMSummaryStore {
    static let shared=MCIMSummaryStore()
    private var values:[String:(Date,String?)]=[:]
    private var flights:[String:Task<String?,Never>]=[:]
    private let gate=TranslationRequestGate(limit:4)
    private var retryAfter=Date.distantPast
    private let session:URLSession={let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=3;config.timeoutIntervalForResource=6;config.httpMaximumConnectionsPerHost=4;return URLSession(configuration:config)}()
    private func fetch(_ url:URL,original:String)async->String? {
        guard Date()>=retryAfter else{return nil}
        do{
            var req=URLRequest(url:url);req.setValue("MC-Harbor/1.6.1",forHTTPHeaderField:"User-Agent")
            let(data,response)=try await session.data(for:req),status=(response as? HTTPURLResponse)?.statusCode ?? 0
            if status==429 || status>=500{retryAfter=Date().addingTimeInterval(60)}
            guard status==200,data.count<100_000,let obj=try JSONSerialization.jsonObject(with:data) as? [String:Any],obj["original"] as? String==original,let translated=obj["translated"] as? String,translated.range(of:"[\\p{Han}]",options:.regularExpression) != nil else{return nil};return translated
        }catch{if !Task.isCancelled{retryAfter=Date().addingTimeInterval(60)};return nil}
    }
    func translation(project:String?,source:AddonSource,original:String)async->String?{
        guard ResourceMirror.source != "official",let project,project.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else{return nil}
        let key=source.rawValue+"/"+project+"/"+original
        if let(date,value)=values[key],Date().timeIntervalSince(date)<(value==nil ? 600:86400){return value}
        if let task=flights[key]{return await task.value}
        guard !Task.isCancelled,Date()>=retryAfter else{return nil}
        let id=source == .curseforge ? project.replacingOccurrences(of:"cf-",with:""):project,url=URL(string:"https://mod.mcimirror.top/translate/"+source.rawValue+"/"+id)!
        let task=Task<String?,Never>{try? await gate.run{await self.fetch(url,original:original)}}
        flights[key]=task;let result=await task.value;flights.removeValue(forKey:key)
        if values.count>=256,let oldest=values.min(by:{$0.value.0<$1.value.0}){values.removeValue(forKey:oldest.key)}
        values[key]=(Date(),result);return result
    }
}
