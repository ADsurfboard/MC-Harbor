import Foundation
import zlib

public struct WorldNBTField: Sendable {
    public let name: String
    public let node: WorldNBTNode
}
public struct WorldNBTNode: Sendable {
    fileprivate let owner: UUID
    public let type: UInt8
    public let payload: Range<Int>
    public let fields: [WorldNBTField]
    public func child(_ name: String) throws -> WorldNBTNode? {
        let matches = fields.filter { $0.name == name }
        guard matches.count <= 1 else { throw ResourceError.invalid("NBT 存在重复的字段，无法安全编辑：" + name) }
        return matches.first?.node
    }
    public func at(_ path: [String]) throws -> WorldNBTNode? {
        var node: WorldNBTNode? = self
        for name in path { node = try node?.child(name) }; return node
    }
}

public enum WorldNBTCompression: Sendable, Equatable { case raw, gzip, zlib }

/// Preserve every untouched payload byte, including mod-owned tags, arrays,
/// unknown strings, NaN bit patterns, list order and the original root name.
/// The editor replaces only existing, typed primitive spans; it never rebuilds
/// the entire document from a lossy JSON representation.
public struct WorldNBTDocument: Sendable {
    public let original: Data
    public let bytes: Data
    public let root: WorldNBTNode
    public let compression: WorldNBTCompression
    private let identity: UUID
    public init(_ original: Data) throws {
        guard !original.isEmpty, original.count <= 16 * 1024 * 1024 else { throw ResourceError.invalid("NBT 元数据为空或超过 16 MB。") }
        self.original = Data(original)
        let prefix = Array(original.prefix(2))
        if prefix.count == 2, prefix == [31, 139] { compression = .gzip }
        else if prefix.count == 2, prefix[0] & 15 == 8, (Int(prefix[0]) * 256 + Int(prefix[1])) % 31 == 0 { compression = .zlib }
        else { compression = .raw }
        bytes = try WorldNBTCodec.inflate(original, compression: compression)
        identity = UUID()
        var parser = WorldNBTParser(bytes: bytes, owner: identity)
        guard try parser.byte() == 10 else { throw ResourceError.invalid("NBT 根节点必须是复合类型。") }
        _ = try parser.string()
        root = try parser.node(type: 10, depth: 0, retain: true)
        guard parser.position == bytes.count else { throw ResourceError.invalid("NBT 元数据结尾存在额外内容，原文件未修改。") }
    }
    public func number(_ node: WorldNBTNode) throws -> Double {
        guard node.owner == identity else { throw ResourceError.invalid("NBT 数字来自其他文档，请重新读取。") }
        let value = try unsigned(node.payload, count: node.payload.count)
        switch node.type {
        case 1: return Double(Int8(bitPattern: UInt8(value)))
        case 2: return Double(Int16(bitPattern: UInt16(value)))
        case 3: return Double(Int32(bitPattern: UInt32(value)))
        case 4: return Double(Int64(bitPattern: value))
        case 5: return Double(Float(bitPattern: UInt32(value)))
        case 6: return Double(bitPattern: value)
        default: throw ResourceError.invalid("NBT 字段不是受支持的数字类型。")
        }
    }
    public func integer(_ node: WorldNBTNode) throws -> Int64 {
        guard node.owner == identity else { throw ResourceError.invalid("NBT 整数来自其他文档，请重新读取。") }
        if node.type == 4 { return Int64(bitPattern: try unsigned(node.payload, count: 8)) }
        let value = try number(node)
        guard value.isFinite, value.rounded(.towardZero) == value, value >= -9_007_199_254_740_991, value <= 9_007_199_254_740_991 else { throw ResourceError.invalid("NBT 整数超出安全范围。") }
        return Int64(value)
    }
    public func string(_ node: WorldNBTNode) throws -> String {
        guard node.type == 8 else { throw ResourceError.invalid("NBT 字段不是字符串。") }
        guard node.owner == identity else { throw ResourceError.invalid("NBT 字符串来自其他文档，请重新读取。") }
        var parser = WorldNBTParser(bytes: bytes, owner: identity, position: node.payload.lowerBound)
        return try parser.string()
    }
    public func uuid(_ node: WorldNBTNode) throws -> UUID? {
        guard node.owner == identity else { throw ResourceError.invalid("NBT UUID 来自其他文档，请重新读取。") }
        if node.type == 8 { return UUID(uuidString: try string(node)) }
        guard node.type == 11, node.payload.count == 20, try unsigned(node.payload, count: 4) == 4 else { return nil }
        let values = Array(bytes[(node.payload.lowerBound + 4)..<node.payload.upperBound])
        let text = values.enumerated().map { index, value in ([4, 6, 8, 10].contains(index) ? "-" : "") + String(format: "%02x", value) }.joined()
        return UUID(uuidString: text)
    }
    private func unsigned(_ range: Range<Int>, count: Int) throws -> UInt64 {
        guard count > 0, count <= 8, range.lowerBound >= 0, range.lowerBound + count <= range.upperBound, range.upperBound <= bytes.count else { throw ResourceError.invalid("NBT 字段长度无效。") }
        var value: UInt64 = 0
        for byte in bytes[range.lowerBound..<(range.lowerBound + count)] { value = value << 8 | UInt64(byte) }; return value
    }
    public func encoded(replacements: [WorldNBTReplacement]) throws -> Data {
        guard !replacements.isEmpty else { return original }
        var output = bytes, boundary = bytes.count
        for replacement in replacements.sorted(by: { $0.node.payload.lowerBound > $1.node.payload.lowerBound }) {
            let range = replacement.node.payload
            guard range.lowerBound >= 0, range.upperBound <= boundary, range.lowerBound < range.upperBound else { throw ResourceError.invalid("NBT 编辑范围重叠或失效。") }
            // A node must refer to this exact document and primitive payload.
            guard replacement.node.owner == identity, let found = Self.find(root, range: range), found.type == replacement.node.type else { throw ResourceError.invalid("NBT 字段已变化，请重新读取。") }
            output.replaceSubrange(range, with: replacement.bytes); boundary = range.lowerBound
        }
        let encoded = try WorldNBTCodec.deflate(output, compression: compression)
        let roundTrip = try Self(encoded)
        guard roundTrip.bytes == output else { throw ResourceError.invalid("NBT 写入后校验失败，原文件未修改。") }
        return encoded
    }
    private static func find(_ node: WorldNBTNode, range: Range<Int>) -> WorldNBTNode? {
        if node.payload == range { return node }
        for field in node.fields where field.node.payload.contains(range.lowerBound) && field.node.payload.upperBound >= range.upperBound {
            if let found = find(field.node, range: range) { return found }
        }
        return nil
    }
}

public struct WorldNBTReplacement: Sendable {
    public let node: WorldNBTNode
    let bytes: Data
    public static func number(_ node: WorldNBTNode, _ value: Double) throws -> Self {
        guard value.isFinite else { throw ResourceError.invalid("请输入有限数字。") }
        let integer = value.rounded(.towardZero) == value
        let bits: UInt64, count: Int
        switch node.type {
        case 1:
            guard integer, value >= -128, value <= 127 else { throw ResourceError.invalid("数值超出 NBT 字节范围。") }; bits = UInt64(UInt8(bitPattern: Int8(value))); count = 1
        case 2:
            guard integer, value >= -32768, value <= 32767 else { throw ResourceError.invalid("数值超出 NBT 短整数范围。") }; bits = UInt64(UInt16(bitPattern: Int16(value))); count = 2
        case 3:
            guard integer, value >= Double(Int32.min), value <= Double(Int32.max) else { throw ResourceError.invalid("数值超出 NBT 整数范围。") }; bits = UInt64(UInt32(bitPattern: Int32(value))); count = 4
        case 4:
            guard integer, abs(value) <= 9_007_199_254_740_991 else { throw ResourceError.invalid("数值超出 NBT 安全长整数范围。") }; bits = UInt64(bitPattern: Int64(value)); count = 8
        case 5:
            guard Float(value).isFinite else { throw ResourceError.invalid("数值超出 NBT 浮点范围。") }; bits = UInt64(Float(value).bitPattern); count = 4
        case 6: bits = value.bitPattern; count = 8
        default: throw ResourceError.invalid("此 NBT 字段不是数字，原文件未修改。")
        }
        var bytes = Data()
        for shift in stride(from: (count - 1) * 8, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        return .init(node: node, bytes: bytes)
    }
    public static func string(_ node: WorldNBTNode, _ value: String) throws -> Self {
        guard node.type == 8 else { throw ResourceError.invalid("此 NBT 字段不是字符串。") }
        var payload = Data()
        for unit in value.utf16 {
            if unit > 0 && unit < 128 { payload.append(UInt8(unit)) }
            else if unit < 2048 { payload.append(UInt8(0xc0 | unit >> 6)); payload.append(UInt8(0x80 | unit & 63)) }
            else { payload.append(UInt8(0xe0 | unit >> 12)); payload.append(UInt8(0x80 | unit >> 6 & 63)); payload.append(UInt8(0x80 | unit & 63)) }
        }
        guard payload.count <= 65535 else { throw ResourceError.invalid("NBT 字符串过长。") }
        var bytes = Data([UInt8(payload.count >> 8), UInt8(payload.count & 255)]); bytes.append(payload)
        return .init(node: node, bytes: bytes)
    }
}

private struct WorldNBTParser {
    let bytes: Data
    let owner: UUID
    var position = 0
    var nodes = 0
    mutating func take(_ count: Int) throws -> Range<Int> {
        guard count >= 0, position <= bytes.count - count else { throw ResourceError.invalid("NBT 文件不完整，原文件未修改。") }
        let start = position; position += count; return start..<position
    }
    mutating func byte() throws -> UInt8 { bytes[try take(1).lowerBound] }
    mutating func uint(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes[try take(count)] { value = value << 8 | UInt64(byte) }; return value
    }
    mutating func string() throws -> String {
        let length = Int(try uint(2)), range = try take(length)
        var index = range.lowerBound, units: [UInt16] = []
        while index < range.upperBound {
            let first = bytes[index]; index += 1
            if first < 128 { units.append(UInt16(first)); continue }
            if first & 0xe0 == 0xc0 {
                guard index < range.upperBound, bytes[index] & 0xc0 == 0x80 else { throw ResourceError.invalid("NBT 修改版 UTF-8 编码无效。") }
                units.append(UInt16(first & 31) << 6 | UInt16(bytes[index] & 63)); index += 1
            } else if first & 0xf0 == 0xe0 {
                guard index + 1 < range.upperBound, bytes[index] & 0xc0 == 0x80, bytes[index + 1] & 0xc0 == 0x80 else { throw ResourceError.invalid("NBT 修改版 UTF-8 编码无效。") }
                units.append(UInt16(first & 15) << 12 | UInt16(bytes[index] & 63) << 6 | UInt16(bytes[index + 1] & 63)); index += 2
            } else { throw ResourceError.invalid("NBT 修改版 UTF-8 编码不受支持。") }
        }
        return String(decoding: units, as: UTF16.self)
    }
    mutating func length(width: Int) throws {
        let count = Int32(bitPattern: UInt32(try uint(4)))
        guard count >= 0, Int(count) <= (bytes.count - position) / width else { throw ResourceError.invalid("NBT 数组长度无效。") }
        _ = try take(Int(count) * width)
    }
    mutating func node(type: UInt8, depth: Int, retain: Bool) throws -> WorldNBTNode {
        nodes += 1
        guard depth <= 128, nodes <= 500_000 else { throw ResourceError.invalid("NBT 嵌套或节点数量超过安全上限。") }
        let start = position; var fields: [WorldNBTField] = []
        switch type {
        case 1: _ = try take(1)
        case 2: _ = try take(2)
        case 3, 5: _ = try take(4)
        case 4, 6: _ = try take(8)
        case 7: try length(width: 1)
        case 8: let count = Int(try uint(2)); _ = try take(count)
        case 9:
            let element = try byte(), count = Int32(bitPattern: UInt32(try uint(4)))
            guard count >= 0, count <= 2_000_000, element <= 12, count == 0 || element != 0 else { throw ResourceError.invalid("NBT 列表类型或长度无效。") }
            let width = [1: 1, 2: 2, 3: 4, 4: 8, 5: 4, 6: 8][Int(element)]
            if let width { guard Int(count) <= (bytes.count - position) / width else { throw ResourceError.invalid("NBT 列表未完整读取。") }; _ = try take(Int(count) * width) }
            else { for _ in 0..<count { _ = try node(type: element, depth: depth + 1, retain: false) } }
        case 10:
            while true {
                let type = try byte(); if type == 0 { break }
                let name = try string(), child = try node(type: type, depth: depth + 1, retain: retain)
                if retain { fields.append(.init(name: name, node: child)) }
            }
        case 11: try length(width: 4)
        case 12: try length(width: 8)
        default: throw ResourceError.invalid("未知 NBT 标签类型，原文件未修改。")
        }
        return .init(owner: owner, type: type, payload: start..<position, fields: fields)
    }
}

public enum WorldNBTCodec {
    public static func inflate(_ data: Data, compression: WorldNBTCompression) throws -> Data {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw ResourceError.invalid("NBT 输入超过 16 MB 或为空。") }
        if compression == .raw { return Data(data) }
        var stream = z_stream()
        guard inflateInit2_(&stream, compression == .gzip ? 31 : 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ResourceError.invalid("NBT 解压器初始化失败。") }
        defer { inflateEnd(&stream) }
        return try process(data, stream: &stream, compressing: false)
    }
    public static func deflate(_ data: Data, compression: WorldNBTCompression) throws -> Data {
        if compression == .raw { guard data.count <= 16 * 1024 * 1024 else { throw ResourceError.invalid("NBT 文件超过 16 MB。")} ; return data }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, compression == .gzip ? 31 : 15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ResourceError.invalid("NBT 压缩器初始化失败。") }
        defer { deflateEnd(&stream) }
        return try process(data, stream: &stream, compressing: true)
    }
    private static func process(_ data: Data, stream: inout z_stream, compressing: Bool) throws -> Data {
        guard !data.isEmpty, data.count <= (compressing ? 64 : 16) * 1024 * 1024 else { throw ResourceError.invalid("NBT 数据超过安全上限。") }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress); stream.avail_in = UInt32(data.count)
            defer { stream.next_in = nil; stream.next_out = nil }
            while true {
                try Task.checkCancellation()
                let status = buffer.withUnsafeMutableBytes { bytes -> Int32 in
                    stream.next_out = bytes.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = UInt32(bytes.count)
                    return compressing ? zlib.deflate(&stream, Z_FINISH) : zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out), limit = (compressing ? 16 : 64) * 1024 * 1024
                guard output.count <= limit - produced else { throw ResourceError.invalid("NBT 解压 / 压缩结果超过安全上限。") }
                output.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw ResourceError.invalid("NBT 压缩流含有多余数据。") }; break
                }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { throw ResourceError.invalid("NBT 压缩流损坏或不完整。") }
            }
        }
        return output
    }
}
