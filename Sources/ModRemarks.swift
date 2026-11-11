import Foundation
import Combine

struct ModRemarkList:Codable,Identifiable,Equatable {let id:String;var name:String}
struct ModRemark:Codable,Identifiable {
    let source:AddonSource;let project:AddonProject;var name:String;var listID:String
    var id:String{listID+":"+source.rawValue+":"+project.id}
}
struct ModRemarkArchive:Codable {
    var lists:[ModRemarkList]=[.init(id:"personal",name:"我的备注")]
    var entries:[ModRemark]=[]
}
@MainActor final class ModRemarkStore:ObservableObject {
    static let shared=ModRemarkStore()
    @Published private(set) var archive:ModRemarkArchive
    private let file:URL
    init(file:URL=NativePaths.root.appendingPathComponent("mod-remarks.json")){
        self.file=file
        let saved=(try? JSONDecoder().decode(ModRemarkArchive.self,from:Data(contentsOf:file))) ?? ModRemarkArchive()
        archive=saved.lists.isEmpty ? ModRemarkArchive():saved
    }
    var lists:[ModRemarkList]{archive.lists}
    func listName(_ id:String)->String{lists.first{$0.id==id}?.name ?? "我的备注"}
    func entry(_ project:String,source:AddonSource,listID:String?=nil)->ModRemark?{archive.entries.first{$0.project.id==project && $0.source==source && (listID==nil || $0.listID==listID)}}
    func matches(_ query:String,listID:String="")->[ModRemark]{
        let query=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return archive.entries.filter{item in
            (listID.isEmpty || item.listID==listID) && (query.isEmpty || [item.name,item.project.title,listName(item.listID)].contains{$0.localizedCaseInsensitiveContains(query)})
        }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    @discardableResult func createList(_ title:String)throws->String{
        let name=title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=60 else{throw FileTransactions.error("列表名称需为 1–60 个字符。")}
        if let existing=lists.first(where:{$0.name.caseInsensitiveCompare(name) == .orderedSame}){return existing.id}
        var updated=archive;let id=UUID().uuidString;updated.lists.append(.init(id:id,name:name));try commit(updated);return id
    }
    func save(project:AddonProject,source:AddonSource,name:String,listID:String)throws{
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=120,lists.contains(where:{$0.id==listID}) else{throw FileTransactions.error("请输入 1–120 字的备注，并选择有效列表。")}
        var updated=archive;updated.entries.removeAll{$0.project.id==project.id && $0.source==source && $0.listID==listID};updated.entries.append(.init(source:source,project:project,name:name,listID:listID));try commit(updated)
    }
    func remove(_ project:String,source:AddonSource,listID:String)throws{var updated=archive;updated.entries.removeAll{$0.project.id==project && $0.source==source && $0.listID==listID};try commit(updated)}
    private func commit(_ value:ModRemarkArchive)throws{
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:file,options:.atomic);archive=value
    }
}
