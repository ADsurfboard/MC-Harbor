import XCTest
@testable import HarborCore

@MainActor final class WorldNBTTests: XCTestCase {
    private func fixture() -> Data {
        // A named compound with int, string, opaque byte array, float and list.
        Data([10, 0, 4, 82, 111, 111, 116,
              3, 0, 4, 109, 111, 100, 101, 0, 0, 0, 0,
              8, 0, 4, 110, 97, 109, 101, 0, 3, 79, 108, 100,
              7, 0, 4, 109, 111, 100, 115, 0, 0, 0, 5, 0, 255, 128, 17, 31,
              5, 0, 6, 104, 101, 97, 108, 116, 104, 65, 160, 0, 0,
              9, 0, 4, 108, 105, 115, 116, 3, 0, 0, 0, 2, 0, 0, 0, 1, 255, 255, 255, 255, 0])
    }
    func testRawGzipZlibPreserveRootAndUnknownPayloads() throws {
        let bytes = fixture()
        for compression in [WorldNBTCompression.raw, .gzip, .zlib] {
            let original = try WorldNBTCodec.deflate(bytes, compression: compression), doc = try WorldNBTDocument(original)
            XCTAssertEqual(doc.compression, compression); XCTAssertEqual(doc.bytes, bytes)
            XCTAssertEqual(try doc.encoded(replacements: []), original)
            let node = try XCTUnwrap(doc.root.child("mode")), name = try XCTUnwrap(doc.root.child("name"))
            let result = try WorldNBTDocument(doc.encoded(replacements: [.number(node, 1), .string(name, "新世界😀\u{0}")]))
            XCTAssertEqual(try result.integer(XCTUnwrap(result.root.child("mode"))), 1)
            XCTAssertEqual(try result.string(XCTUnwrap(result.root.child("name"))), "新世界😀\u{0}")
            XCTAssertEqual(Array(result.bytes.prefix(7)), Array(bytes.prefix(7)))
            let oldMod = try XCTUnwrap(doc.root.child("mods")), newMod = try XCTUnwrap(result.root.child("mods"))
            XCTAssertEqual(Data(doc.bytes[oldMod.payload]), Data(result.bytes[newMod.payload]))
            let oldList = try XCTUnwrap(doc.root.child("list")), newList = try XCTUnwrap(result.root.child("list"))
            XCTAssertEqual(Data(doc.bytes[oldList.payload]), Data(result.bytes[newList.payload]))
        }
    }
    func testTypedNumericBoundsAndWrongDocumentAreRejected() throws {
        let first = try WorldNBTDocument(fixture()), second = try WorldNBTDocument(fixture())
        let mode = try XCTUnwrap(first.root.child("mode")), health = try XCTUnwrap(first.root.child("health"))
        XCTAssertEqual(try first.number(health), 20)
        XCTAssertThrowsError(try WorldNBTReplacement.number(mode, 1.5))
        XCTAssertThrowsError(try WorldNBTReplacement.number(mode, Double(Int32.max) + 1))
        XCTAssertThrowsError(try WorldNBTReplacement.number(mode, .infinity))
        XCTAssertThrowsError(try WorldNBTReplacement.number(health, Double.greatestFiniteMagnitude))
        XCTAssertThrowsError(try second.encoded(replacements: [.number(mode, 1)]))
        XCTAssertThrowsError(try second.number(mode))
        XCTAssertThrowsError(try first.encoded(replacements: [.number(mode, 1), .number(mode, 2)]))
    }
    func testTruncationInvalidTagsAndTrailingStreamsAreRejected() throws {
        let original = fixture()
        for cut in [0, 1, 2, 7, original.count - 1] { XCTAssertThrowsError(try WorldNBTDocument(original.prefix(cut))) }
        var bad = original; bad[7] = 77; XCTAssertThrowsError(try WorldNBTDocument(bad))
        bad = original; bad.append(0); XCTAssertThrowsError(try WorldNBTDocument(bad))
        let gzip = try WorldNBTCodec.deflate(original, compression: .gzip)
        var corrupt = gzip; corrupt[corrupt.count - 6] ^= 255; XCTAssertThrowsError(try WorldNBTDocument(corrupt))
        var trailing = gzip; trailing.append(contentsOf: [1, 2, 3]); XCTAssertThrowsError(try WorldNBTDocument(trailing))
        XCTAssertThrowsError(try WorldNBTDocument(gzip.dropLast(4)))
    }
    func testInvalidArrayLengthsAndListTypesAreRejected() throws {
        for payload: [UInt8] in [
            [10, 0, 0, 7, 0, 1, 97, 255, 255, 255, 255, 0],
            [10, 0, 0, 11, 0, 1, 97, 127, 255, 255, 255, 0],
            [10, 0, 0, 9, 0, 1, 97, 0, 0, 0, 0, 1, 0],
            [10, 0, 0, 9, 0, 1, 97, 13, 0, 0, 0, 0, 0]
        ] { XCTAssertThrowsError(try WorldNBTDocument(Data(payload))) }
        let emptyList = Data([10, 0, 0, 9, 0, 1, 97, 0, 0, 0, 0, 0, 0])
        XCTAssertNoThrow(try WorldNBTDocument(emptyList))
    }
    func testDuplicateFieldsCannotBeAmbiguouslyEdited() throws {
        let document = try WorldNBTDocument(Data([10, 0, 0, 1, 0, 1, 97, 1, 1, 0, 1, 97, 2, 0]))
        XCTAssertThrowsError(try document.root.child("a"))
    }
    func testDepthLimitRejectsHostileNesting() throws {
        var bytes = Data([10, 0, 0])
        for _ in 0..<130 { bytes.append(contentsOf: [10, 0, 1, 97]) }
        bytes.append(contentsOf: repeatElement(UInt8(0), count: 131))
        XCTAssertThrowsError(try WorldNBTDocument(bytes))
    }
}
