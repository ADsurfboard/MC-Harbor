import CryptoKit
import Foundation
import Translation
import Security

struct PendingLanguageEntry:Decodable,Sendable {
    let resource:String
    let id:String
    let source:String
    var identity:String{resource+"/"+id}
}
struct PendingLanguageBatch:Decodable {let entries:[PendingLanguageEntry];let pending:Int}

/// Formatting and game references never enter the translation engine.
enum TranslationText {
    struct Part:Equatable {let text:String;let translate:Bool}
    private static let protected=try! NSRegularExpression(pattern:#"%(?:(\d+)\$)?[-+#0,(<]*\d*(?:\.\d+)?[tT]?[A-Za-z%]|\$\{[^{}]+\}|\$\([^()]+\)|\{[^{}\r\n]+\}|(?:&|§)(?:#[0-9a-fA-F]{6}|[0-9A-FK-ORZa-fk-orz])|https?://[^\s<>]+|\[\[[^\]\r\n]+\]\]|\r?\n"#)
    static func parts(_ text:String,toChinese:Bool=true)->[Part] {
        let ns=text as NSString;var result:[Part]=[],offset=0
        func add(_ range:NSRange,protected:Bool){guard range.length>0 else{return};let s=ns.substring(with:range);if protected{result.append(Part(text:s,translate:false));return};let trimmed=s.trimmingCharacters(in:.whitespacesAndNewlines);guard !trimmed.isEmpty,trimmed.range(of:toChinese ? "[A-Za-z]":"[\\p{Han}]",options:.regularExpression) != nil else{result.append(Part(text:s,translate:false));return};let prefix=String(s.prefix(while:{$0.isWhitespace})),suffix=String(s.reversed().prefix(while:{$0.isWhitespace}).reversed());if !prefix.isEmpty{result.append(Part(text:prefix,translate:false))};result.append(Part(text:trimmed,translate:true));if !suffix.isEmpty{result.append(Part(text:suffix,translate:false))}}
        for match in protected.matches(in:text,range:NSRange(location:0,length:ns.length)){add(NSRange(location:offset,length:match.range.location-offset),protected:false);add(match.range,protected:true);offset=match.range.location+match.range.length}
        add(NSRange(location:offset,length:ns.length-offset),protected:false)
        // Long quest paragraphs are split at word boundaries; whitespace remains byte-for-byte.
        return result.flatMap{part->[Part] in
            guard part.translate,part.text.count>1200 else{return [part]};var tail=part.text,parts:[Part]=[]
            while tail.count>1200{let limit=tail.index(tail.startIndex,offsetBy:1200);let cut=tail[..<limit].lastIndex(where:{$0.isWhitespace}) ?? limit;let chunk=String(tail[..<cut]);if !chunk.isEmpty{parts.append(Part(text:chunk,translate:true))};tail=String(tail[cut...]);let gap=String(tail.prefix(while:{$0.isWhitespace}));if !gap.isEmpty{parts.append(Part(text:gap,translate:false));tail.removeFirst(gap.count)}}
            if !tail.isEmpty{parts.append(Part(text:tail,translate:true))};return parts
        }
    }
    static func restore(_ parts:[Part],values:[String:String])throws->String {
        try parts.map{part in guard part.translate else{return part.text};guard let value=values[part.text],!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw FileTransactions.error("本机翻译未返回完整结果，已保留此条待翻译。")} ;return value}.joined()
    }
}

@available(macOS 15.0, *)
enum LocalLanguageTranslation {
    static let source=Locale.Language(identifier:"en")
    static let target=Locale.Language(identifier:"zh-Hans")
    static func translate(_ entries:[PendingLanguageEntry],session:TranslationSession)async throws->[[String:String]] {
        let parsed=entries.map{TranslationText.parts($0.source)}
        let strings=Array(Set(parsed.flatMap{$0.filter(\.translate).map(\.text)})).sorted()
        var values:[String:String]=[:]
        for start in stride(from:0,to:strings.count,by:32) {
            try Task.checkCancellation();let batch=Array(strings[start..<min(start+32,strings.count)])
            let responses=try await session.translations(from:batch.enumerated().map{TranslationSession.Request(sourceText:$0.element,clientIdentifier:String($0.offset))})
            for response in responses{guard let key=response.clientIdentifier,let index=Int(key),batch.indices.contains(index) else{continue};values[batch[index]]=response.targetText}
        }
        return try zip(entries,parsed).map{entry,parts in ["resource":entry.resource,"entry":entry.id,"source":entry.source,"translation":try TranslationText.restore(parts,values:values)]}
    }
}

/// Optional online fallback for macOS 13 and 14, used only after the player consents.
enum LegacyLanguageTranslation {
    enum Failure: LocalizedError {
        case unavailable(String)
        case unchanged
        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .unchanged: return "翻译服务没有返回可用译文。"
            }
        }
    }

    // Keep short, bounded UTF-8 segments and preserve whitespace
    // between segments instead of asking the remote service to recreate it.
    static func chunks(_ input: String, limit: Int = 400) throws -> [TranslationText.Part] {
        var rest = input
        var result: [TranslationText.Part] = []
        while !rest.isEmpty {
            var end = rest.startIndex
            var bytes = 0
            while end < rest.endIndex {
                let next = rest.index(after: end)
                let count = rest[end..<next].utf8.count
                if bytes + count > limit { break }
                bytes += count
                end = next
            }
            guard end > rest.startIndex else { throw Failure.unavailable("原文中有无法分段的字符。") }
            if end < rest.endIndex, let space = rest[..<end].lastIndex(where: { $0.isWhitespace }), space > rest.startIndex { end = space }
            let part = String(rest[..<end])
            if !part.isEmpty { result.append(.init(text: part, translate: true)) }
            rest = String(rest[end...])
            let whitespace = String(rest.prefix(while: { $0.isWhitespace }))
            if !whitespace.isEmpty { result.append(.init(text: whitespace, translate: false)); rest.removeFirst(whitespace.count) }
        }
        return result
    }

    static func query(_ text: String) async throws -> String {
        try await DomesticTranslation.query(text,toChinese:true)
    }

    static func parseResponse(_ data:Data,source:String)throws->String {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = response["responseStatus"] as? Int, status == 200,
              let body = response["responseData"] as? [String: Any],
              let result = body["translatedText"] as? String else {
            throw Failure.unavailable("在线翻译暂不可用或已达到服务额度；已完成的译文会保留。")
        }
        if result.uppercased().contains("MYMEMORY WARNING") { throw Failure.unavailable("在线翻译服务额度已用完，请稍后重试；已完成的译文会保留。") }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.caseInsensitiveCompare(source) != .orderedSame else { throw Failure.unchanged }
        return result
    }

    static func translate(_ entry: PendingLanguageEntry, lookup: (String) async throws -> String = query) async throws -> [String: String] {
        let parsed = try TranslationText.parts(entry.source).flatMap { part in
            part.translate ? try chunks(part.text) : [part]
        }
        guard parsed.contains(where: \.translate) else { throw Failure.unchanged }
        var values: [String: String] = [:]
        for part in parsed where part.translate && values[part.text] == nil {
            try Task.checkCancellation()
            values[part.text] = try await lookup(part.text)
        }
        return ["resource": entry.resource, "entry": entry.id, "source": entry.source,
                "translation": try TranslationText.restore(parsed, values: values)]
    }
}

enum OnlineTranslationProvider:String,CaseIterable,Identifiable {
    case bilibili,aliyun,mymemory,google
    var id:String{rawValue}
    var title:String{switch self{case .bilibili:return "B站 Index-Translate（国内，无需密钥）";case .aliyun:return "阿里云 Qwen-MT（自备密钥）";case .mymemory:return "MyMemory（国外备选，有额度限制）";case .google:return "Google 公共接口（国外备选）"}}
}

/// Domestic by default; foreign providers are explicit opt-in, never a hidden fallback.
enum DomesticTranslation {
    static var provider:String{get{let value=UserDefaults.standard.string(forKey:"harbor.translationProvider") ?? "bilibili";return OnlineTranslationProvider(rawValue:value)?.rawValue ?? "bilibili"}set{UserDefaults.standard.set(newValue,forKey:"harbor.translationProvider")}}
    static var providerTitle:String{OnlineTranslationProvider(rawValue:provider)?.title ?? "B站 Index-Translate"}
    static var aliEndpoint:String{UserDefaults.standard.string(forKey:"harbor.aliTranslationEndpoint") ?? "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"}
    private static let keyService="net.morben.harbor.translation.aliyun"
    static func configureAli(endpoint:String,key:String)throws{guard let url=URL(string:endpoint),url.scheme=="https",url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,url.path.hasSuffix("/chat/completions"),url.host=="dashscope.aliyuncs.com" || (url.host?.hasSuffix(".cn-beijing.maas.aliyuncs.com") ?? false) else{throw FileTransactions.error("请填写阿里云北京地域的官方 HTTPS 接口，不支持任意第三方转发地址。")};if !key.isEmpty{let query=[kSecClass:kSecClassGenericPassword,kSecAttrService:keyService,kSecAttrAccount:"api"] as CFDictionary;let update=SecItemUpdate(query,[kSecValueData:Data(key.utf8)] as CFDictionary);if update==errSecItemNotFound{let result=SecItemAdd([kSecClass:kSecClassGenericPassword,kSecAttrService:keyService,kSecAttrAccount:"api",kSecValueData:Data(key.utf8),kSecAttrAccessible:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary,nil);guard result==errSecSuccess else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(result))}}else if update != errSecSuccess{throw NSError(domain:NSOSStatusErrorDomain,code:Int(update))}};UserDefaults.standard.set(url.absoluteString,forKey:"harbor.aliTranslationEndpoint")}
    static func removeAliKey(){SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrService:keyService,kSecAttrAccount:"api"] as CFDictionary)}
    private static func aliKey()->String?{var value:CFTypeRef?;guard SecItemCopyMatching([kSecClass:kSecClassGenericPassword,kSecAttrService:keyService,kSecAttrAccount:"api",kSecReturnData:true,kSecMatchLimit:kSecMatchLimitOne] as CFDictionary,&value)==errSecSuccess,let data=value as? Data else{return nil};return String(data:data,encoding:.utf8)}
    static let endpoint=URL(string:"https://index-translate.bilibili.com/v1/chat/completions")!
    static func parse(_ data:Data,source:String,toChinese:Bool)throws->String {
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],let choices=root["choices"] as? [[String:Any]],let choice=choices.first,choice["finish_reason"] as? String == "stop",let message=choice["message"] as? [String:Any],let raw=message["content"] as? String else{throw LegacyLanguageTranslation.Failure.unavailable("国内翻译服务没有返回完整译文，请稍后重试。")}
        let value=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.caseInsensitiveCompare(source) != .orderedSame,!toChinese || value.range(of:"[\\p{Han}]",options:.regularExpression) != nil else{throw LegacyLanguageTranslation.Failure.unchanged}
        return value
    }
    static func query(_ text:String,toChinese:Bool,provider:String=provider)async throws->String {
        if provider=="mymemory" || provider=="google"{return try await ForeignTranslation.query(text,toChinese:toChinese,provider:provider)}
        var body:[String:Any]=["model":"Index-Translate-35B-A3B","messages":[["role":"user","content":"Translate the following Minecraft text to "+(toChinese ? "Simplified Chinese":"English")+". Return only the translation. Preserve placeholders, formatting codes and identifiers.\n\n"+text]],"stream":false,"max_tokens":2048,"chat_template_kwargs":["enable_thinking":false]]
        var destination=endpoint;var token:String?
        if provider=="aliyun"{guard let key=aliKey(),!key.isEmpty,let url=URL(string:aliEndpoint) else{throw FileTransactions.error("请先在设置中保存阿里翻译接口和 API Key。")};destination=url;token=key;body=["model":"qwen-mt-plus","messages":[["role":"user","content":text]],"translation_options":["source_lang":"auto","target_lang":toChinese ? "Chinese":"English"]]}
        var last:Error=LegacyLanguageTranslation.Failure.unavailable("国内翻译服务暂不可用。")
        for attempt in 0..<2{try Task.checkCancellation();do{return try parse(await HarborHTTP.data(destination,method:"POST",body:JSONSerialization.data(withJSONObject:body),token:token,limit:160_000),source:text,toChinese:toChinese)}catch{last=error;try Task.checkCancellation();if attempt==0{try await Task.sleep(nanoseconds:1_000_000_000)}}}
        throw last
    }
}

enum ForeignTranslation {
    static func parseGoogle(_ data:Data,source:String)throws->String {
        guard let root=try JSONSerialization.jsonObject(with:data) as? [Any],let segments=root.first as? [[Any]] else{throw LegacyLanguageTranslation.Failure.unchanged}
        let value=segments.compactMap{$0.first as? String}.joined()
        guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.caseInsensitiveCompare(source) != .orderedSame else{throw LegacyLanguageTranslation.Failure.unchanged};return value
    }
    static func query(_ text:String,toChinese:Bool,provider:String)async throws->String {
        let value:String
        if provider=="mymemory" {
            guard text.utf8.count<=500 else{throw LegacyLanguageTranslation.Failure.unavailable("MyMemory 单段文本超过 500 字节，请分段翻译。")}
            var url=URLComponents(string:"https://api.mymemory.translated.net/get")!
            url.queryItems=[.init(name:"q",value:text),.init(name:"langpair",value:toChinese ? "en|zh-CN":"zh-CN|en")]
            value=try LegacyLanguageTranslation.parseResponse(await HarborHTTP.data(url.url!,limit:100_000),source:text)
        }else if provider=="google" {
            var url=URLComponents(string:"https://translate.googleapis.com/translate_a/single")!
            url.queryItems=[.init(name:"client",value:"gtx"),.init(name:"sl",value:toChinese ? "en":"zh-CN"),.init(name:"tl",value:toChinese ? "zh-CN":"en"),.init(name:"dt",value:"t"),.init(name:"q",value:text)]
            value=try parseGoogle(await HarborHTTP.data(url.url!,limit:160_000),source:text)
        }else{throw LegacyLanguageTranslation.Failure.unavailable("未识别的翻译服务。")}
        guard !toChinese || value.range(of:"[\\p{Han}]",options:.regularExpression) != nil else{throw LegacyLanguageTranslation.Failure.unchanged};return value
    }
}
