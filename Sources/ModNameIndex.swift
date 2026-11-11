import Foundation

/// Uses the same bundled MCMod.cn name index as HMCL, retaining its notices.
actor ModNameIndex {
    static let shared=ModNameIndex()
    private struct Entry:Sendable{let chinese:String;let english:String;let slug:String}
    private var entries:[Entry]?
    func query(_ text:String)async->String?{
        if entries==nil{
            let file=NativePaths.resources.appendingPathComponent("Localization/mod_data.txt")
            entries=await Task.detached(priority:.userInitiated){()->[Entry] in
                guard let text=try? String(contentsOf:file,encoding:.utf8) else{return []}
                return text.split(whereSeparator:\.isNewline).compactMap{line in
                    guard !line.hasPrefix("#") else{return nil};let fields=line.split(separator:";",omittingEmptySubsequences:false).map(String.init)
                    guard fields.count>=5,!fields[3].isEmpty,!fields[4].isEmpty else{return nil}
                    return Entry(chinese:fields[3],english:fields[4],slug:fields[0])
                }
            }.value
        }
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty else{return nil}
        if let exact=entries?.first(where:{$0.chinese.split(separator:"/").contains(Substring(value))}){return exact.english}
        return entries?.filter{$0.chinese.localizedCaseInsensitiveContains(value)}.min(by:{$0.chinese.count<$1.chinese.count})?.english
    }
}
