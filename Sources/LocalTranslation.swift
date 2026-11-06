import CryptoKit
import Foundation
import Translation

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
    static func parts(_ text:String)->[Part] {
        let ns=text as NSString;var result:[Part]=[],offset=0
        func add(_ range:NSRange,protected:Bool){guard range.length>0 else{return};let s=ns.substring(with:range);if protected{result.append(Part(text:s,translate:false));return};let trimmed=s.trimmingCharacters(in:.whitespacesAndNewlines);guard !trimmed.isEmpty,trimmed.range(of:"[A-Za-z]",options:.regularExpression) != nil else{result.append(Part(text:s,translate:false));return};let prefix=String(s.prefix(while:{$0.isWhitespace})),suffix=String(s.reversed().prefix(while:{$0.isWhitespace}).reversed());if !prefix.isEmpty{result.append(Part(text:prefix,translate:false))};result.append(Part(text:trimmed,translate:true));if !suffix.isEmpty{result.append(Part(text:suffix,translate:false))}}
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

    // MyMemory accepts at most 500 UTF-8 bytes per segment. Preserve whitespace
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
        var url = URLComponents(string: "https://api.mymemory.translated.net/get")!
        url.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "langpair", value: "en|zh-CN")]
        let data = try await HarborHTTP.data(url.url!, limit: 100_000)
        return try parseResponse(data,source:text)
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
