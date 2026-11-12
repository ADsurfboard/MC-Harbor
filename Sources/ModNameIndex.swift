import Foundation

/// HMCL's bundled MCMod.cn index, parsed once off the UI thread in both directions.
actor ModNameIndex {
    static let shared=ModNameIndex()
    private struct Index:Sendable {
        var chinese:[String:String]=[:];var names:[String:String]=[:];var slugs:[String:String]=[:]
        var search:[(String,String)]=[]
    }
    private var loading:Task<Index,Never>?
    private let file:URL
    init(file:URL=NativePaths.resources.appendingPathComponent("Localization/mod_data.txt")){self.file=file}
    private static func normalize(_ text:String)->String {
        text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).filter{$0.isLetter || $0.isNumber}
    }
    private func index()async->Index {
        if let loading{return await loading.value}
        let file=file
        let task=Task.detached(priority:.userInitiated){()->Index in
            guard let text=try? String(contentsOf:file,encoding:.utf8) else{return Index()}
            var result=Index()
            for line in text.split(whereSeparator:\.isNewline) where !line.hasPrefix("#") {
                let fields=line.split(separator:";",omittingEmptySubsequences:false).map(String.init)
                guard fields.count>=5,fields[3].range(of:"[\\p{Han}]",options:.regularExpression) != nil else{continue}
                let chinese=fields[3],english=fields[4].isEmpty ? fields[0]:fields[4]
                if !english.isEmpty {
                    for alias in chinese.split(separator:"/"){result.chinese[String(alias).lowercased()]=english}
                    result.search.append((chinese,english))
                }
                for name in [fields[4]]+(fields.count>5 ? [fields[5]]:[])+fields[2].split(separator:",").map(String.init) where !name.isEmpty {
                    let key=Self.normalize(name);if result.names[key]==nil{result.names[key]=chinese}
                }
                if !fields[0].isEmpty{result.slugs[fields[0].lowercased()]=chinese}
            }
            result.search.sort{$0.0.count<$1.0.count};return result
        }
        loading=task;return await task.value
    }
    func query(_ text:String)async->String? {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else{return nil}
        let index=await index()
        return index.chinese[value] ?? index.search.first{$0.0.localizedCaseInsensitiveContains(value)}?.1
    }
    func chinese(title:String,slug:String?=nil)async->String? {
        if title.range(of:"[\\p{Han}]",options:.regularExpression) != nil{return title}
        let index=await index()
        if let slug,let found=index.slugs[slug.lowercased()]{return found}
        return index.names[Self.normalize(title)]
    }
    static func projectName(_ project:AddonProject,provider:String=DomesticTranslation.provider)async->String? {
        let slug=project.slug ?? project.pageUrl.flatMap(URL.init(string:))?.lastPathComponent
        if let found=await shared.chinese(title:project.title,slug:slug){return found}
        return try? await ModTextTranslation.shared.translate(project.title,provider:provider)
    }
}
