import Foundation
import CryptoKit

public struct LocalizationRow: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let key: String
    public let source: String
    public var translation: String
    public let start: Int
    public let end: Int
}

public enum LocalizationDocumentKind: String, Codable, Sendable {
    case languageJSON, languageLegacy, ftbQuest, ftbLocale, datapack, function
}

/// Byte ranges refer to the original UTF-8 document, never to rendered text.
/// Replacements leave IDs, commands, comments and task relationships intact.
public struct LocalizationDocument: Codable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let kind: LocalizationDocumentKind
    public let original: Data
    public var rows: [LocalizationRow]
    public var revision: String { Self.digest(original) }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func read(_ data: Data, path: String, kind: LocalizationDocumentKind) throws -> Self {
        let data = Data(data)
        guard data.count <= 4 * 1024 * 1024, String(data: data, encoding: .utf8) != nil else {
            throw ResourceError.invalid("语言 / 任务文件超过 4 MB，或不是有效 UTF-8：" + path)
        }
        try validatePath(path)
        if kind == .languageJSON {
            guard (try JSONSerialization.jsonObject(with: data)) is [String: String] else { throw ResourceError.invalid("语言 JSON 必须是字符串键值表：" + path) }
        }
        let identity = digest(Data(path.utf8) + data)
        var rows: [LocalizationRow] = []
        func add(_ key: String, _ value: String, _ start: Int, _ end: Int) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            rows.append(.init(id: digest(Data((path + "\u{0}" + key + "\u{0}" + value).utf8)), key: key,
                              source: value, translation: "", start: start, end: end))
        }
        if kind == .languageLegacy {
            var offset = 0, keys: Set<String> = []
            for line in data.split(separator: 10, omittingEmptySubsequences: false) {
                let raw = String(decoding: line, as: UTF8.self)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("!") {
                    guard let equal = line.firstIndex(of: 61) else { throw ResourceError.invalid("LANG 条目缺少等号：" + path) }
                    let key = String(decoding: line[..<equal], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty, keys.insert(key).inserted else { throw ResourceError.invalid("LANG 存在空键或重复键：" + path) }
                    let valueBytes = line[line.index(after: equal)...]
                    let trailingCR = valueBytes.last == 13 ? 1 : 0
                    let value = String(decoding: valueBytes.dropLast(trailingCR), as: UTF8.self)
                    add(key, value, offset + line.distance(from: line.startIndex, to: equal) + 1, offset + line.count - trailingCR)
                }
                offset += line.count + 1
            }
        } else if kind == .function {
            var offset = 0, number = 0
            let pattern = #"(?:^|\srun\s)(?:tellraw\s+\S+\s+|title\s+\S+\s+(?:title|subtitle|actionbar)\s+)"#
            let regex = try NSRegularExpression(pattern: pattern)
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
                number += 1
                if !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let range = Range(match.range, in: line) {
                    let prefix = line[..<range.upperBound].utf8.count
                    let suffix = Data(line[range.upperBound...].utf8)
                    let tree = try LocalizationSyntax.parse(suffix)
                    tree.walk(pointer: "/line\(number)", all: false, inherited: tree.string != nil, book: false) {
                        add($0, $1, offset + prefix + $2, offset + prefix + $3)
                    }
                }
                offset += line.utf8.count + 1
            }
        } else {
            let tree = try LocalizationSyntax.parse(data)
            if kind == .languageJSON {
                guard let fields = tree.fields, fields.allSatisfy({ $0.1.string != nil }) else { throw ResourceError.invalid("语言 JSON 必须是字符串键值表：" + path) }
                for (key, value) in fields { add(key, value.string!, value.start, value.end) }
            } else {
                tree.walk(pointer: "", all: kind == .ftbLocale, inherited: false, book: path.contains("/patchouli_books/")) { add($0, $1, $2, $3) }
            }
        }
        guard rows.count <= 100_000 else { throw ResourceError.invalid("单个语言文件条目过多。") }
        return Self(id: identity, path: path, kind: kind, original: data, rows: rows)
    }

    public func rendered(sourceOnly: Bool = false) throws -> Data {
        var bytes = original
        for row in rows.sorted(by: { $0.start > $1.start }) {
            let value = sourceOnly || row.translation.isEmpty ? row.source : row.translation
            guard sourceOnly || row.translation.isEmpty || LocalizationPlaceholders.compatible(row.source, value) else {
                throw ResourceError.invalid("译文占位符 / 格式与原文不一致：" + row.key)
            }
            guard row.start >= 0, row.end >= row.start, row.end <= original.count else { throw ResourceError.invalid("语言编辑范围已失效，请重新读取。") }
            let replacement: Data
            if kind == .languageLegacy {
                guard !value.contains("\n"), !value.contains("\r") else { throw ResourceError.invalid("旧版 LANG 的单条译文不能包含换行。") }
                replacement = Data(value.utf8)
            } else {
                let array = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
                replacement = array.dropFirst().dropLast()
            }
            bytes.replaceSubrange(row.start..<row.end, with: replacement)
        }
        // Parse the result before allowing export, even when no original file
        // will be overwritten. This catches broken syntax and stale ranges.
        _ = try Self.read(bytes, path: path, kind: kind)
        return bytes
    }

    public static func validatePath(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 1024, !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { $0.value < 32 }),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ResourceError.invalid("语言 / 任务路径无效。")
        }
    }
}

public enum LocalizationPlaceholders {
    /// Preserve the multiset, allowing a translator to reorder numbered slots.
    public static func tokens(_ text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[-#+ 0,(<]*\d*(?:\.\d+)?[a-zA-Z%]|\{\d+(?:,[^{}]+)?\}|\$\{[^{}]+\}|\$\([^()]+\)|§[0-9a-fk-orA-FK-OR]|</?[A-Za-z][^<>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
    }
    public static func compatible(_ source: String, _ translation: String) -> Bool {
        !translation.isEmpty && translation.utf8.count <= 32_000 && tokens(source) == tokens(translation)
    }
}

/// Bounded JSON/JSON5/SNBT parser. Containers retain duplicate-key detection and
/// original spans. No regex attempts to translate arbitrary JavaScript or IDs.
private struct LocalizationSyntax {
    let start: Int
    let end: Int
    let string: String?
    let fields: [(String, LocalizationSyntax)]?
    let list: [LocalizationSyntax]?
    static let textFields: Set<String> = ["title", "subtitle", "description", "text", "hover", "quest_desc", "quest_subtitle", "chapter_subtitle", "fallback"]
    func walk(pointer: String, all: Bool, inherited: Bool, book: Bool, add: (String, String, Int, Int) -> Void) {
        if let string {
            if all || inherited {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !(trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && !trimmed.dropFirst().dropLast().contains("{")) { add(pointer, string, start, end) }
            }
        } else if let fields {
            for (key, node) in fields { node.walk(pointer: pointer + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1"), all: all,
                                                 inherited: Self.textFields.contains(key) || book && key == "name", book: book, add: add) }
        } else if let list { for (index, node) in list.enumerated() { node.walk(pointer: pointer + "/\(index)", all: all, inherited: inherited, book: book, add: add) } }
    }
    static func parse(_ data: Data) throws -> Self {
        var parser = Parser(bytes: Array(data)); let result = try parser.value(depth: 0)
        try parser.skip(); guard parser.position == parser.bytes.count else { throw parser.failure() }; return result
    }
    private struct Parser {
        let bytes: [UInt8]
        var position = 0
        var nodes = 0
        func failure() -> ResourceError { .invalid("无法解析任务 / 语言文件（字节 \(position)），原文件未修改。") }
        func starts(_ sequence: [UInt8]) -> Bool { position + sequence.count <= bytes.count && bytes[position..<(position + sequence.count)].elementsEqual(sequence) }
        mutating func skip() throws {
            while position < bytes.count {
                let c = bytes[position]
                if [9, 10, 13, 32, 44].contains(c) { position += 1 }
                else if position == 0 && starts([239, 187, 191]) { position += 3 }
                else if c == 35 || starts([47, 47]) { while position < bytes.count && bytes[position] != 10 { position += 1 } }
                else if starts([47, 42]) {
                    position += 2
                    while position < bytes.count && !starts([42, 47]) { position += 1 }
                    guard position < bytes.count else { throw failure() }; position += 2
                } else { break }
            }
        }
        mutating func quoted() throws -> String {
            let quote = bytes[position]; position += 1
            if starts([quote, quote]) {
                position += 2; let start = position
                while position < bytes.count && !starts([quote, quote, quote]) { position += 1 }
                guard position < bytes.count, let result = String(bytes: bytes[start..<position], encoding: .utf8) else { throw failure() }
                position += 3; return result
            }
            var result: [UInt8] = []
            while position < bytes.count {
                let c = bytes[position]; position += 1
                if c == quote { guard let text = String(bytes: result, encoding: .utf8) else { throw failure() }; return text }
                guard c >= 32 || c == 9 else { throw failure() }
                if c != 92 { result.append(c); continue }
                guard position < bytes.count else { throw failure() }
                let e = bytes[position]; position += 1
                switch e {
                case 110: result.append(10)
                case 114: result.append(13)
                case 116: result.append(9)
                case 98: result.append(8)
                case 102: result.append(12)
                case 10: break
                case 13: if position < bytes.count && bytes[position] == 10 { position += 1 }
                case 117, 120:
                    let length = e == 117 ? 4 : 2
                    guard position + length <= bytes.count,
                          let hex = UInt32(String(decoding: bytes[position..<(position + length)], as: UTF8.self), radix: 16) else { throw failure() }
                    position += length
                    var scalar = hex
                    if (0xD800...0xDBFF).contains(hex) {
                        guard starts([92, 117]), position + 6 <= bytes.count,
                              let low = UInt32(String(decoding: bytes[(position + 2)..<(position + 6)], as: UTF8.self), radix: 16),
                              (0xDC00...0xDFFF).contains(low) else { throw failure() }
                        scalar = 0x10000 + (hex - 0xD800) * 1024 + low - 0xDC00; position += 6
                    }
                    guard let value = Unicode.Scalar(scalar) else { throw failure() }
                    result.append(contentsOf: String(value).utf8)
                default: result.append(e)
                }
            }
            throw failure()
        }
        mutating func key() throws -> String {
            try skip(); guard position < bytes.count else { throw failure() }
            if bytes[position] == 34 || bytes[position] == 39 { return try quoted() }
            let start = position
            while position < bytes.count && ![9, 10, 13, 32, 58, 123, 125, 91, 93, 44].contains(bytes[position]) { position += 1 }
            guard position > start else { throw failure() }; return String(decoding: bytes[start..<position], as: UTF8.self)
        }
        mutating func value(depth: Int) throws -> LocalizationSyntax {
            try skip(); nodes += 1
            guard depth <= 96, nodes <= 200_000, position < bytes.count else { throw failure() }
            let start = position, c = bytes[position]
            var string: String?, fields: [(String, LocalizationSyntax)]?, list: [LocalizationSyntax]?
            if c == 123 {
                position += 1; fields = []; var keys: Set<String> = []; try skip()
                while position < bytes.count && bytes[position] != 125 {
                    let key = try key(); try skip()
                    guard position < bytes.count, bytes[position] == 58, keys.insert(key).inserted else { throw failure() }
                    position += 1; fields?.append((key, try value(depth: depth + 1))); try skip()
                }
                guard position < bytes.count else { throw failure() }; position += 1
            } else if c == 91 {
                position += 1; list = []; try skip()
                if position + 1 < bytes.count, [66, 73, 76, 98, 105, 108].contains(bytes[position]), bytes[position + 1] == 59 { position += 2 }
                try skip()
                while position < bytes.count && bytes[position] != 93 { list?.append(try value(depth: depth + 1)); try skip() }
                guard position < bytes.count else { throw failure() }; position += 1
            } else if c == 34 || c == 39 { string = try quoted() }
            else {
                while position < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
                guard position > start else { throw failure() }
                let raw = String(decoding: bytes[start..<position], as: UTF8.self)
                let number = #"(?i)^(?:true|false|null|[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:e[+-]?[0-9]+)?[bslfd]?|[+-]?(?:Infinity|NaN)|0x[0-9a-f]+)$"#
                if raw.range(of: number, options: .regularExpression) == nil { string = raw }
            }
            return .init(start: start, end: position, string: string, fields: fields, list: list)
        }
    }
}
