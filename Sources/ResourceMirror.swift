import Foundation

enum ResourceMirror {
    static var source:String{get{UserDefaults.standard.string(forKey:"harbor.resourceSource") ?? "auto"}set{UserDefaults.standard.set(newValue,forKey:"harbor.resourceSource")}}
    static var metadataBases:[String]{source == "official" ? ["https://api.modrinth.com/v2","https://mod.mcimirror.top/modrinth/v2"]:["https://mod.mcimirror.top/modrinth/v2","https://api.modrinth.com/v2"]}
    static func artworkURL(_ value:String)->URL?{guard var url=URLComponents(string:value) else{return nil};if source != "official",["cdn.modrinth.com","media.forgecdn.net","edge.forgecdn.net"].contains(url.host ?? ""){url.host="mod.mcimirror.top"};return url.url}
}

actor MCIMSummaryStore {
    static let shared=MCIMSummaryStore()
    private var values:[String:(Date,String?)]=[:]
    private var active=0
    func translation(project:String?,source:AddonSource,original:String)async->String?{
        guard ResourceMirror.source != "official",let project,project.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else{return nil}
        let key=source.rawValue+"/"+project+"/"+original
        if let (date,value)=values[key],Date().timeIntervalSince(date)<(value==nil ? 600:86400){return value}
        while active>=4{do{try await Task.sleep(nanoseconds:100_000_000)}catch{return nil};if let (_,value)=values[key]{return value}}
        guard !Task.isCancelled else{return nil};active+=1;defer{active-=1}
        let id=source == .curseforge ? project.replacingOccurrences(of:"cf-",with:""):project
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=6;config.timeoutIntervalForResource=10
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel()}
        var result:String?
        do{var req=URLRequest(url:URL(string:"https://mod.mcimirror.top/translate/"+source.rawValue+"/"+id)!);req.setValue("MC-Harbor/1.6.0",forHTTPHeaderField:"User-Agent");let (data,response)=try await session.data(for:req);if (response as? HTTPURLResponse)?.statusCode==200,data.count<100_000,let obj=try JSONSerialization.jsonObject(with:data) as? [String:Any],obj["original"] as? String==original,let translated=obj["translated"] as? String,translated.range(of:"[\\p{Han}]",options:.regularExpression) != nil{result=translated}}
        catch{};if !Task.isCancelled{values[key]=(Date(),result)};return result
    }
}
